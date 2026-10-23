#!/usr/bin/env bash
# make-pdf.sh -- render a Markdown doc to PDF, picking whichever toolchain
# actually works on this machine.
#
#   scripts/make-pdf.sh <source.md> <output.pdf>
#
# Two independent toolchains, deliberately not forced to match the
# PowerShell launcher's choice -- each platform uses whatever's best on it:
#   1. pandoc + LibreOffice `soffice` (this repo's established pipeline,
#      render-doc-pdf.sh -- delegated to as-is, not reimplemented) when
#      both are on PATH. Prefer this: it's the pipeline docs/*.pdf's
#      `--check` staleness mode already assumes.
#   2. Otherwise, the pure-Python fallback (md_to_pdf.py, via a local venv
#      so markdown/xhtml2pdf don't need installing globally) -- for a bash
#      checkout without pandoc/soffice (e.g. this one, run under Git Bash
#      on Windows).
#
# PowerShell equivalent: scripts/make-pdf.ps1 -- always uses the Python
# fallback, since pandoc/soffice realistically aren't on a Windows box in
# this workflow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$ROOT/.venv"

die() { printf '\033[1;31m[make-pdf] error:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m[make-pdf]\033[0m %s\n' "$*" >&2; }

[[ $# -eq 2 ]] || die "usage: $(basename "$0") <source.md> <output.pdf>"

if command -v pandoc >/dev/null 2>&1 && command -v soffice >/dev/null 2>&1; then
  log "pandoc + soffice found -- delegating to render-doc-pdf.sh"
  exec "$ROOT/render-doc-pdf.sh" "$1" "$2"
fi

log "pandoc/soffice not both found -- falling back to the Python (xhtml2pdf) pipeline"

if [[ ! -d "$VENV" ]]; then
  log "creating venv at $VENV"
  command -v python3 >/dev/null 2>&1 && PY=python3 || PY=python
  "$PY" -m venv "$VENV" || die "could not create a venv with $PY -- is Python installed?"
fi

VENV_PY="$VENV/bin/python"
[[ -x "$VENV_PY" ]] || VENV_PY="$VENV/Scripts/python.exe"  # a venv made on Windows
[[ -x "$VENV_PY" ]] || die "no python found in $VENV"

log "ensuring markdown + xhtml2pdf are installed"
"$VENV_PY" -m pip install --quiet --upgrade pip
"$VENV_PY" -m pip install --quiet markdown xhtml2pdf

"$VENV_PY" "$ROOT/md_to_pdf.py" "$1" "$2"
