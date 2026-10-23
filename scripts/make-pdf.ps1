<#
.SYNOPSIS
    Render a Markdown doc to PDF via md_to_pdf.py, without requiring
    markdown/xhtml2pdf installed globally.

.DESCRIPTION
    Creates scripts\.venv on first run (gitignored -- never commit it) and
    installs this script's two dependencies into it; later runs reuse it
    as-is. See md_to_pdf.py's own header for why this exists alongside
    render-doc-pdf.sh (the pandoc/LibreOffice pipeline) rather than
    replacing it -- this is the no-pandoc/-soffice alternative, not a
    second way to do the same thing on a box that already has those.

    Bash equivalent: scripts/make-pdf.sh (same behavior, for a checkout
    without PowerShell).

.EXAMPLE
    .\make-pdf.ps1 ..\docs\vscode-copilot\VscodeCopilotAgentManagement.md ..\docs\vscode-copilot\VscodeCopilotAgentManagement.pdf
#>
param(
    [Parameter(Mandatory)] [string] $SourceMd,
    [Parameter(Mandatory)] [string] $OutputPdf
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Venv = Join-Path $Root '.venv'

function Write-Log { param($m) Write-Host "[make-pdf] $m" -ForegroundColor Cyan }
function Write-Err { param($m) Write-Host "[make-pdf] error: $m" -ForegroundColor Red }

if (-not (Test-Path $Venv)) {
    Write-Log "creating venv at $Venv"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Err "no 'python' found on PATH -- install Python first"
        exit 1
    }
    & $py.Source -m venv $Venv
    if ($LASTEXITCODE -ne 0) {
        Write-Err "could not create a venv with $($py.Source)"
        exit 1
    }
}

$VenvPy = Join-Path $Venv 'Scripts\python.exe'
if (-not (Test-Path $VenvPy)) { $VenvPy = Join-Path $Venv 'bin/python' }  # a venv made on Unix
if (-not (Test-Path $VenvPy)) {
    Write-Err "no python found in $Venv"
    exit 1
}

Write-Log "ensuring markdown + xhtml2pdf are installed"
& $VenvPy -m pip install --quiet --upgrade pip
& $VenvPy -m pip install --quiet markdown xhtml2pdf

& $VenvPy (Join-Path $Root 'md_to_pdf.py') $SourceMd $OutputPdf
exit $LASTEXITCODE
