# AI Broker Windows E2E suite -- ELEVATED companion.
#
# Run this ONCE, from an elevated PowerShell window (Administrator, reached via
# `runas /user:<host>\administrator powershell.exe` from inside umesh's own
# session -- see docs/ai-broker-work/ai-broker-windows-e2e-runbook.html §1).
# Leave the window open for the whole test run; this script just sits and
# waits. `run-e2e-suite.ps1` (the umesh-context orchestrator) hands it work by
# dropping a small request file and waiting for the matching response.
#
# WHY TWO SCRIPTS, NOT ONE: several checklist items (starting/stopping the
# AiBrokerTest service, reading another session's process owner) need
# elevation; several others (phase-a-acl.ps1's DACL check, the credential and
# config-apply watcher tests, --recover) must NOT run elevated -- their own
# comments explain why (e.g. an elevated token isn't the file's owner, so it
# exercises a different code path than the one under test). One PowerShell
# process can't hold both identities, so the suite is genuinely a two-window
# dance -- this just automates the hand-off instead of the operator typing
# `sc.exe start AiBrokerTest` at the right moment by hand.
#
# SECURITY NOTE: the request file only ever carries an ACTION NAME from the
# fixed list below -- never a command string, path, or argument. Every action
# this script performs is hardcoded here. This is deliberate: a helper that
# executed whatever a dropped file told it to would be a local
# privilege-escalation primitive (anything else that can write to
# C:\ai-broker-test could get arbitrary Administrator-context execution).
#
# ONE narrow exception: "read-daemon-log" additionally carries a regex
# `pattern` (and optional integer `tail`). That's still not a command or a
# path -- the path stays hardcoded to $daemonLog below, never taken from the
# request -- so the worst a hostile pattern can do is a slow regex against a
# text file this process could already read; it cannot execute code or touch
# any other file. This action exists because daemon.log lives under
# C:\ProgramData\ZscalerAIProtect, which is deliberately SYSTEM/Administrators-
# only (windows_security::allow_system_admins_traverse_only in the daemon
# source) -- the non-elevated orchestrator and phase scripts get "path not
# found" reading it directly, even though the file is right there.

$reqDir     = "C:\ai-broker-test"
$reqFile    = "$reqDir\elevated-request.json"
$service    = "AiBrokerTest"
$daemonLog  = "C:\ProgramData\ZscalerAIProtect\daemon.log"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

New-Item -ItemType Directory -Path $reqDir -Force | Out-Null

Write-Host "=== AI Broker E2E suite -- elevated helper ===" -ForegroundColor Cyan
Write-Host "Watching $reqFile for work. Leave this window open." -ForegroundColor Cyan
Write-Host "Ctrl+C to stop." -ForegroundColor Cyan
Write-Host ""

function Write-Response($id, $ok, $exitCode, $note, [string[]]$Lines = @()) {
    $resp = @{ id = $id; ok = $ok; exitCode = $exitCode; note = $note; lines = $Lines } | ConvertTo-Json
    Set-Content -Path "$reqDir\elevated-response-$id.json" -Value $resp -Encoding ascii
}

while ($true) {
    if (Test-Path $reqFile) {
        $raw = Get-Content $reqFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
        if (-not $raw) { Start-Sleep -Milliseconds 500; continue }

        $req = $null
        try { $req = $raw | ConvertFrom-Json } catch {}
        if (-not $req -or -not $req.id -or -not $req.action) {
            Write-Host "[helper] malformed request, ignoring: $raw" -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500
            continue
        }

        Write-Host ""
        Write-Host "[helper] request $($req.id): action=$($req.action)" -ForegroundColor Cyan

        switch ($req.action) {

            # ---- service control (AiBrokerTest hosts the daemon; the daemon
            # is what performs the SYSTEM -> console-user privilege drop and
            # spawns ai-broker-mon --control) ---------------------------------
            "sc-query" {
                sc.exe query $service
                Write-Response $req.id $true 0 "queried $service"
            }
            "sc-stop" {
                sc.exe stop $service
                Start-Sleep -Seconds 3
                # sc.exe stop is async and a SYSTEM process ignores a
                # non-elevated Stop-Process -- force-kill from here, where we
                # can actually reach it, then confirm empty (see the runbook's
                # "stale binary after redeploy" trap).
                Get-Process ai-broker-mon, zscaler-ai-protect -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 2
                $leftover = Get-Process ai-broker-mon, zscaler-ai-protect -ErrorAction SilentlyContinue
                if ($leftover) {
                    Write-Host "[helper] leftover processes after stop:" -ForegroundColor Red
                    $leftover | Format-Table Id, ProcessName
                    Write-Response $req.id $false 1 "leftover processes after stop"
                } else {
                    Write-Host "[helper] confirmed clean (no daemon/broker processes left)" -ForegroundColor Green
                    Write-Response $req.id $true 0 "stopped and confirmed clean"
                }
            }
            "sc-start" {
                sc.exe start $service
                Start-Sleep -Seconds 20
                $state = (sc.exe query $service | Select-String "STATE").ToString()
                Write-Host "[helper] $state" -ForegroundColor $(if ($state -match "RUNNING") { "Green" } else { "Red" })
                Write-Response $req.id ($state -match "RUNNING") 0 $state
            }

            # ---- privilege-drop verdict: needs an elevated token to see the
            # UserName column across sessions (-IncludeUserName requires it;
            # WMI's GetOwner() errors cross-session -- don't use it) ----------
            "psinfo" {
                $procs = Get-Process ai-broker-mon, zscaler-ai-protect -IncludeUserName -ErrorAction SilentlyContinue |
                         Select-Object Id, ProcessName, UserName, SI
                if ($procs) {
                    $procs | Format-Table -AutoSize
                    # The presence of processes alone proves nothing about the
                    # privilege drop -- the whole point of this check is that
                    # the daemon stays SYSTEM and the broker does NOT.
                    $daemonProcs = @($procs | Where-Object { $_.ProcessName -eq "zscaler-ai-protect" })
                    $brokerProcs = @($procs | Where-Object { $_.ProcessName -eq "ai-broker-mon" })
                    $daemonIsSystem = $daemonProcs.Count -gt 0 -and -not ($daemonProcs | Where-Object { $_.UserName -notmatch "SYSTEM" })
                    $brokerNotSystem = $brokerProcs.Count -gt 0 -and -not ($brokerProcs | Where-Object { $_.UserName -match "SYSTEM" })
                    $verdict = $daemonIsSystem -and $brokerNotSystem
                    Write-Host ("[helper] daemon is SYSTEM: {0}   broker is NOT SYSTEM: {1}" -f $daemonIsSystem, $brokerNotSystem) `
                        -ForegroundColor $(if ($verdict) { "Green" } else { "Red" })
                    Write-Response $req.id $verdict 0 ($procs | ConvertTo-Json -Compress)
                } else {
                    Write-Host "[helper] nothing running" -ForegroundColor Yellow
                    Write-Response $req.id $false 0 "nothing running"
                }
            }

            # ---- the PROTOCOL_VERSION-mismatch negative case. This whole
            # phase script needs elevation (sc.exe + it swaps/restores the
            # broker exe), so run it wholesale rather than re-deriving its
            # logic here. Path is HARDCODED -- never taken from the request. --
            "protocol-mismatch-test" {
                $script = "$repoRoot\commands\phase-c-protocol-mismatch.ps1"
                if (-not (Test-Path $script)) {
                    Write-Response $req.id $false 1 "script not found: $script"
                } else {
                    & $script
                    Write-Response $req.id ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) $LASTEXITCODE "ran $script"
                }
            }

            # ---- elevated half of the unit-suite run (the 8 permission_apply
            # + app_capture tests that need SeRestorePrivilege) ---------------
            "cargo-test-elevated" {
                $cargo = Get-Command cargo -ErrorAction SilentlyContinue
                if (-not $cargo) {
                    Write-Host "[helper] cargo not found on PATH -- skipping" -ForegroundColor Yellow
                    Write-Response $req.id $true 0 "skipped: no cargo toolchain on this box"
                } else {
                    Push-Location $repoRoot
                    cargo test -p ai-warden --lib
                    $code = $LASTEXITCODE
                    Pop-Location
                    Write-Response $req.id ($code -eq 0) $code "cargo test -p ai-warden --lib (elevated)"
                }
            }

            # ---- read daemon.log, elevated-side (see the SECURITY NOTE above:
            # $daemonLog is hardcoded, never taken from the request -- only
            # `pattern`/`tail` are caller-supplied, and both are inert against
            # anything but this one text file). Replaces the phase scripts'
            # old direct `Select-String -Path $daemonLog`, which always failed
            # with "path not found" from the non-elevated umesh session: the
            # dir is SYSTEM/Administrators-only, and BUILTIN\Users gets bare
            # traverse there, nothing on files created inside it. -------------
            "read-daemon-log" {
                if (-not (Test-Path $daemonLog)) {
                    Write-Response $req.id $false 1 "daemon.log not found at $daemonLog"
                } else {
                    $tail = 0
                    if ($req.tail) { $tail = [int]$req.tail }
                    $content = if ($tail -gt 0) {
                        Get-Content -Path $daemonLog -Tail $tail -ErrorAction SilentlyContinue
                    } else {
                        Get-Content -Path $daemonLog -ErrorAction SilentlyContinue
                    }
                    $pattern = [string]$req.pattern
                    $matched = if ($pattern) {
                        @($content | Select-String -Pattern $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.Line })
                    } else {
                        @($content)
                    }
                    Write-Host "[helper] read-daemon-log: pattern='$pattern' tail=$tail -> $($matched.Count) line(s)" -ForegroundColor Cyan
                    Write-Response $req.id $true 0 "$($matched.Count) line(s)" -Lines $matched
                }
            }

            default {
                Write-Host "[helper] unknown action '$($req.action)', ignoring" -ForegroundColor Red
                Write-Response $req.id $false 1 "unknown action"
            }
        }
    }
    Start-Sleep -Milliseconds 750
}
