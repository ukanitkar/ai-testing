<#
.SYNOPSIS
    Diagnoses Claude's local LLM proxy leg on a real (MSI-installed) Windows
    machine — isolates WHICH link in the chain is broken rather than just
    reporting pass/fail.

.DESCRIPTION
    The chain, in order, matching how it actually works (see
    ai-gateway/agent-manager/src/agents/claude.rs and
    ai-gateway/agent-manager/src/ports.rs):

      1. The gateway service is actually running.
      2. `--agents` reports claude enabled + installed + llm=true.
      3. ~\.claude\settings.json has env.ANTHROPIC_BASE_URL set to a real
         loopback URL (the config-delivery leg landed).
      4. That port is actually listening (TCP-reachable).
      5. A real HTTP request shaped like Claude's own traffic gets a
         response — and the response is inspected to tell "the round trip
         works" apart from "the listener answered but something specific
         (no credentials yet, wrong upstream, TLS/signing failure) is wrong".
      6. The gateway's own log around the same request, if anything in the
         above pointed at a problem.

    Each step only runs if the one before it looks OK, and each step prints
    enough to tell you exactly where to look next rather than a bare PASS/FAIL.

    NOTE: this targets a REAL install (searches Program Files for the actual
    binary), not a dev target\debug build or the zax-sim.exe fixture harness
    ..\integration.ps1 / ..\agents\*.ps1 use — this is a live-machine triage
    script, not an automated test.

.PARAMETER GatewayHome
    Override the gateway state dir. Defaults to $env:ZSAI_GATEWAY_HOME if
    set, else ~\.zsai-gateway (see ai-gateway/util/src/paths.rs::resolve_home).

.EXAMPLE
    .\diagnose-claude-proxy.ps1
#>
param([string] $GatewayHome)

function Write-Step   { param($m) Write-Host "`n── $m" -ForegroundColor Cyan }
function Write-Ok     { param($m) Write-Host "  OK   $m" -ForegroundColor Green }
function Write-Bad    { param($m) Write-Host "  FAIL $m" -ForegroundColor Red }
function Write-Info   { param($m) Write-Host "  ..   $m" -ForegroundColor DarkGray }

# ── 0. locate the real installed gateway binary ─────────────────────────────
Write-Step "0. locating the installed gateway binary"
$candidates = @(
    (Join-Path ${env:ProgramFiles} '*\zscaler-ai-gateway.exe'),
    (Join-Path ${env:ProgramFiles(x86)} '*\zscaler-ai-gateway.exe')
) | Where-Object { $_ }
$Gw = $candidates | ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $Gw) {
    # fall back to a broader (slower) search once, in case the install
    # subdir isn't directly under Program Files\<name>\.
    $Gw = Get-ChildItem -Path $env:ProgramFiles, ${env:ProgramFiles(x86)} -Filter 'zscaler-ai-gateway.exe' `
        -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Gw) {
    Write-Bad "could not find zscaler-ai-gateway.exe under Program Files — pass its path directly if it's installed elsewhere"
    exit 2
}
Write-Ok "found: $Gw"

# ── 1. is the service actually running? ──────────────────────────────────────
Write-Step "1. is the gateway service running"
$gwProc = Get-Process -Name 'zscaler-ai-gateway' -ErrorAction SilentlyContinue
if ($gwProc) {
    Write-Ok "running, pid $($gwProc.Id -join ', ')"
} else {
    Write-Bad "no zscaler-ai-gateway process found at all"
    Write-Info "nothing downstream of this can work — check the ai-protect daemon started it (ai_broker.enabled?) before continuing"
}

# ── 2. --agents: claude enabled / installed / llm capability ────────────────
Write-Step "2. zscaler-ai-gateway --agents"
$diag = & $Gw --agents 2>&1
$diag | ForEach-Object { Write-Host "    $_" }
$claudeLine = $diag | Where-Object { $_ -match '^\s*claude\s' }
if (-not $claudeLine) {
    Write-Bad "no 'claude' row at all in --agents output"
} elseif ($claudeLine -match 'enabled=true' -and $claudeLine -match 'installed=true' -and $claudeLine -match 'llm=true') {
    Write-Ok "claude: enabled + installed + llm capability all true"
} else {
    Write-Bad "claude row present but one of enabled/installed/llm is false — see the line above"
}

# ── 3. the real config: did ANTHROPIC_BASE_URL actually land? ───────────────
Write-Step "3. ~\.claude\settings.json env.ANTHROPIC_BASE_URL"
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$baseUrl = $null
if (-not (Test-Path $settingsPath)) {
    Write-Bad "$settingsPath does not exist at all — the config delta never landed"
} else {
    try {
        $doc = Get-Content -Raw $settingsPath | ConvertFrom-Json
        $baseUrl = $doc.env.ANTHROPIC_BASE_URL
    } catch {
        Write-Bad "$settingsPath exists but is not valid JSON: $($_.Exception.Message)"
    }
    if (-not $baseUrl) {
        Write-Bad "settings.json exists but env.ANTHROPIC_BASE_URL is not set"
        Write-Info "raw env block: $($doc.env | ConvertTo-Json -Compress)"
    } elseif ($baseUrl -notmatch '^https?://(127\.0\.0\.1|localhost):(\d+)') {
        Write-Bad "ANTHROPIC_BASE_URL is set but does NOT point at loopback: $baseUrl"
        Write-Info "this means Claude is talking directly to the real API, or to something else — not this proxy"
    } else {
        Write-Ok "ANTHROPIC_BASE_URL = $baseUrl"
    }
}

# ── 4. is that port actually listening ───────────────────────────────────────
$port = $null
if ($baseUrl -match ':(\d+)$' -or $baseUrl -match ':(\d+)/') { $port = [int]$Matches[1] }
if ($port) {
    Write-Step "4. TCP reachability on port $port"
    $tnc = Test-NetConnection -ComputerName '127.0.0.1' -Port $port -WarningAction SilentlyContinue
    if ($tnc.TcpTestSucceeded) {
        Write-Ok "port $port is accepting connections"
    } else {
        Write-Bad "port $port refused the connection — the listener for claude's slot never bound, or bound elsewhere"
        Write-Info "check the gateway log for 'listener' + 'claude' — it may have been DISPLACED to an overflow port (see ports.rs's candidates()); re-read settings.json's value, don't assume the default base (8790 + claude's slot)"
    }
} else {
    Write-Step "4. TCP reachability"
    Write-Info "skipped — no usable base URL from step 3"
}

# ── 5. a real request, shaped like Claude's own traffic ─────────────────────
if ($port) {
    Write-Step "5. sending a real /v1/messages request through $baseUrl"
    $uri = "$baseUrl/v1/messages"
    $headers = @{
        'x-api-key'        = 'diagnostic-placeholder-key'
        'anthropic-version' = '2023-06-01'
        'content-type'     = 'application/json'
    }
    $body = @{
        model      = 'claude-3-5-sonnet-20241022'
        max_tokens = 16
        messages   = @(@{ role = 'user'; content = 'ping' })
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body `
            -ContentType 'application/json' -TimeoutSec 20 -SkipHttpErrorCheck -ErrorAction Stop
        $status = $resp.StatusCode
        $respBody = $resp.Content
    } catch {
        # Older PowerShell without -SkipHttpErrorCheck throws on non-2xx; the
        # real response is still on the exception.
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $respBody = $reader.ReadToEnd()
            } catch { $respBody = "(could not read error body: $($_.Exception.Message))" }
        } else {
            $status = $null
            $respBody = $_.Exception.Message
        }
    }

    Write-Info "HTTP status: $status"
    Write-Info "body: $($respBody -replace '\s+', ' ' | Select-Object -First 1)"

    # NOTE: PowerShell's `switch` tests every clause and runs ALL matches,
    # not just the first — unlike C-style switch/case. Each clause here ends
    # in `break` so only the first (most specific) match wins; without it, a
    # body matching two patterns (e.g. a "certificate" error also shaped as
    # `"type":"error"`) would print two, contradictory diagnoses.
    switch -Regex ($respBody) {
        '"type"\s*:\s*"message"' {
            Write-Ok "got back a real Anthropic message object — the full round trip works"
            break
        }
        'NoCredentials|no.?credentials' {
            Write-Bad "listener answered but reports NO CREDENTIALS — this agent never received a real triple-JWT (enrolment never completed, or lapsed). Check the gateway log for 'enrolment' / 'onboard' lines."
            break
        }
        'x509|certificate|TLS|SSL' {
            Write-Bad "TLS/certificate error — unexpected for claude (Dual transport serves plain http://), check listener_transport hasn't changed and $baseUrl really is http://, not https://"
            break
        }
        '"type"\s*:\s*"error"' {
            Write-Bad "listener answered with an explicit error object — see the body above for the real reason (upstream 4xx/5xx, bad model name, etc.)"
            break
        }
        '^\s*$' {
            Write-Bad "empty response body with status $status — check the gateway log directly, this shape isn't recognized"
            break
        }
        default {
            if ($status -ge 200 -and $status -lt 300) {
                Write-Ok "2xx response, unrecognized shape — inspect the body above manually"
            } else {
                Write-Bad "non-2xx ($status) with an unrecognized body — inspect above, and check the gateway log"
            }
        }
    }
} else {
    Write-Step "5. request test"
    Write-Info "skipped — no port to test"
}

# ── 6. the gateway's own log, for corroborating evidence ────────────────────
Write-Step "6. gateway log (last 40 lines mentioning claude/listener/enrol)"
if (-not $GatewayHome) {
    $GatewayHome = if ($env:ZSAI_GATEWAY_HOME) { $env:ZSAI_GATEWAY_HOME } else { Join-Path $env:USERPROFILE '.zsai-gateway' }
}
$logPath = Join-Path $GatewayHome 'logs\zax.log'
if (Test-Path $logPath) {
    Select-String -Path $logPath -Pattern 'claude|listener|enrol|onboard' -ErrorAction SilentlyContinue |
        Select-Object -Last 40 | ForEach-Object { Write-Host "    $($_.Line)" }
} else {
    Write-Info "no log at $logPath — pass -GatewayHome if it's installed at a non-default location (check `$env:ZSAI_GATEWAY_HOME)"
}

Write-Host "`n────────────────────────────────────────"
Write-Host "Done. Work bottom-up from the first FAIL above — everything after it is a downstream symptom, not a separate bug."
