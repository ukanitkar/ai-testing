# Phase C -- exercise the --mcp-server stdio relay directly.
# Run in the REGULAR umesh window.
#
# Why this instead of "the MCP leg through Codex": the Codex CLI is NOT
# installed on this VM, so a real agent-driven MCP call would mean installing
# Node + Codex + giving it its own auth -- an install project, not a test. But
# the relay speaks newline-delimited JSON-RPC on stdin/stdout (bridge.rs
# serve_stdio), so it can be driven directly. That matters because
# --mcp-server has had ZERO Windows coverage: every Windows test so far has
# exercised --llm-proxy or --control, never this mode.
#
# CWD must be ~/.ai-broker: sdk_config::init resolves the bundled base config
# from ./config/ relative to the process CWD (the compiled-in
# CARGO_MANIFEST_DIR path is the build machine's), same reason Path A had to
# launch from there.
#
# !! If this HANGS: the SDK may be attempting interactive OIDC because the
# cached credential has aged out (it was cached ~24h ago with a 24h expiry, and
# there is no refresh token -- offline_access is not granted, temp workaround
# #2). Ctrl+C and check zax.log. A hang is itself a finding for a mode that an
# agent spawns non-interactively.

$exe = "C:\Users\umesh\work\ai-broker-mon.exe"
$out = "C:\ai-broker-test\mcp-stdio.out"
$err = "C:\ai-broker-test\mcp-stdio.err"

New-Item -ItemType Directory -Path "C:\ai-broker-test" -Force | Out-Null

# Six probes: four expecting replies, two expecting silence.
$requests = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    '{"jsonrpc":"2.0","id":2,"method":"ping"}'
    '{"jsonrpc":"2.0","id":3,"method":"tools/list"}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":4,"method":"totally/bogus"}'
    'this is not json at all'
) -join "`n"

Write-Host "=== driving the relay over stdio (stdin EOF ends it) ===" -ForegroundColor Cyan
Push-Location "C:\Users\umesh\.ai-broker"
$requests | & $exe --mcp-server 2> $err | Out-File -Encoding ascii $out
Pop-Location

Write-Host ""
Write-Host "=== raw responses ===" -ForegroundColor Cyan
Get-Content $out -ErrorAction SilentlyContinue

$lines = @(Get-Content $out -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\{' })
$byId = @{}
foreach ($l in $lines) {
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($null -ne $o.id) { $byId[[string]$o.id] = $o }
}

Write-Host ""
Write-Host "=== checks ===" -ForegroundColor Cyan

function Check($label, $ok, $detail) {
    Write-Host ("  {0,-46} {1}" -f $label, $(if ($ok) { "PASS" } else { "FAIL" })) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
    if ($detail) { Write-Host "      $detail" }
}

$init = $byId["1"]
Check "initialize replied" ($null -ne $init) $(if ($init) { "serverInfo.name=$($init.result.serverInfo.name) protocolVersion=$($init.result.protocolVersion)" })
Check "initialize advertises tools capability" ($null -ne $init -and $null -ne $init.result.capabilities.tools) ""

$ping = $byId["2"]
Check "ping replied" ($null -ne $ping) ""

$tl = $byId["3"]
$toolsOk = ($null -ne $tl) -and ($null -ne $tl.result.tools)
Check "tools/list replied with a tools array" $toolsOk $(if ($toolsOk) { "count=$(@($tl.result.tools).Count) (0 is expected -- config.yaml declares no upstream MCP servers)" })

$bogus = $byId["4"]
$bogusOk = ($null -ne $bogus) -and ($bogus.error.code -eq -32601)
Check "unknown method -> JSON-RPC -32601" $bogusOk $(if ($bogus) { "code=$($bogus.error.code) message=$($bogus.error.message)" })

# Notifications carry no id and must draw NO reply; the non-JSON line must be
# ignored rather than crashing the relay. Together: exactly 4 replies for 6
# inputs.
Check "notification + non-JSON drew no reply (exactly 4 replies)" ($lines.Count -eq 4) "got $($lines.Count) JSON replies"

Write-Host ""
Write-Host "=== stderr / clean shutdown ===" -ForegroundColor Cyan
Get-Content $err -Tail 15 -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "=== relay log (expect 'stdin closed; shutting down') ===" -ForegroundColor Cyan
Get-Content "C:\Users\umesh\.ai-broker\logs\zax.log" -Tail 25 -ErrorAction SilentlyContinue |
    Select-String "bridge|stdin closed|OIDC" | Select-Object -Last 8
