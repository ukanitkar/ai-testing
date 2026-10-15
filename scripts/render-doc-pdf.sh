#!/usr/bin/env bash
# render-doc-pdf.sh — regenerate a committed docs/*.pdf from its Markdown source.
#
# WHY THIS EXISTS: docs/ carries PDFs that were originally committed as binaries
# with no source in the repo. They then went stale silently — a reader had no
# way to tell a PDF apart from the Markdown it was rendered from, and no way to
# refresh it. Anything under docs/ that is a render of Markdown should be
# produced by this script so "is the PDF current?" is answerable by re-running
# it and diffing, instead of by reading both and guessing.
#
#   scripts/render-doc-pdf.sh <source.md> <output.pdf>
#   scripts/render-doc-pdf.sh --all          # every mapping in the table below
#
# Toolchain: pandoc (md -> docx) then LibreOffice (docx -> pdf). Not pandoc's
# direct PDF output, which needs a LaTeX engine this repo does not assume.
# LibreOffice styling is plain; fidelity of CONTENT is the point, not matching
# whatever styled whatever the first version of a PDF.
#
#   brew install pandoc
#   brew install --cask libreoffice
#
# NOT every PDF in docs/ is renderable this way. The hand-authored diagrams
# (sequence diagrams, swimlanes, the itemization's page 1) have no Markdown
# source and are NOT listed below — regenerating those means re-drawing them.
# See docs/vscode-copilot-redirect-sequence-itemization-errata.md for how that
# case is handled instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Markdown sources that live in the sibling ai-protect checkout, not here.
AI_PROTECT="${AI_PROTECT:-$(cd "$ROOT/../ai-protect" 2>/dev/null && pwd || true)}"

# source-markdown => output-pdf (paths relative to this repo root; a source may
# be absolute or live in the sibling repo via $AI_PROTECT).
render_all() {
  [[ -n "$AI_PROTECT" ]] || die "set AI_PROTECT=<path to ai-protect checkout> (sibling dir not found)"
  render "$AI_PROTECT/driver/zsai-netflt/CONNECT-REDIRECT-CRASH-SAFETY.md" \
         "$ROOT/docs/crash_safety.pdf"
}

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

die() { printf '\033[1;31m[render-doc-pdf] error:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m[render-doc-pdf]\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found — see the install notes at the top of this script"; }

render() {
  local src="$1" out="$2"
  [[ -f "$src" ]] || die "source not found: $src"
  need pandoc
  need soffice

  # One scratch dir per run, cleaned on EXIT. Deliberately not a RETURN trap:
  # that stays installed after the function returns and fires again on the
  # NEXT function return, where $tmp is unset — which under `set -u` makes the
  # script exit non-zero after having written the PDF correctly.
  local tmp="$SCRATCH"

  # No --metadata title: the Markdown already opens with its own H1, and
  # setting a title too renders the heading twice.
  log "pandoc: $(basename "$src") -> docx"
  pandoc "$src" -o "$tmp/doc.docx"

  log "soffice: docx -> pdf"
  soffice --headless --convert-to pdf --outdir "$tmp" "$tmp/doc.docx" >/dev/null 2>&1

  [[ -f "$tmp/doc.pdf" ]] || die "soffice produced no PDF (is another LibreOffice instance running?)"
  mv "$tmp/doc.pdf" "$out"
  log "wrote $out ($(wc -c <"$out" | tr -d ' ') bytes)"
}

main() {
  case "${1:-}" in
    --all) render_all ;;
    "" | -h | --help)
      sed -n '1,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      [[ $# -eq 2 ]] || die "usage: $(basename "$0") <source.md> <output.pdf>  |  --all"
      render "$1" "$2"
      ;;
  esac
}

main "$@"
