#!/usr/bin/env python3
"""md_to_pdf.py -- render a Markdown doc to PDF without pandoc/LibreOffice.

    scripts/md_to_pdf.py <source.md> <output.pdf>

WHY THIS EXISTS, ALONGSIDE render-doc-pdf.sh: that script's toolchain
(pandoc -> docx -> LibreOffice `soffice`) is the repo's established way to
keep a docs/*.pdf honest against its Markdown source -- see its own header
comment for the full rationale (staleness via `--check`, etc.). But it needs
`pandoc` and `soffice` installed, which this Windows checkout does not have.
This script uses a pure-Python toolchain (`markdown` + `xhtml2pdf`, both pip
packages) instead, for exactly the same purpose on a box without that
toolchain. Prefer render-doc-pdf.sh when pandoc/soffice ARE available --
don't let a doc's PDF start drifting depending on which script last touched
it; pick one per doc and stay with it.

Run via make-pdf.sh / make-pdf.ps1 in this same directory, which set up a
venv with this script's two dependencies rather than requiring them
globally.
"""
from __future__ import annotations

import os
import re
import sys

import markdown
from xhtml2pdf import pisa

# xhtml2pdf's base-14 fonts round-trip some typographic glyphs unreliably --
# confirmed: the arrow U+2192 has no glyph in Helvetica at all (xhtml2pdf
# warns and renders it blank); em/en-dash are unconfirmed but extracted text
# came back with replacement characters after a round trip, so treat them as
# suspect too rather than assume they're fine. Substituted for PDF rendering
# only -- the .md source keeps its real typography untouched.
_PDF_SAFE = {
    "→": "->",         # right arrow
    "—": "--",         # em dash
    "–": "-",          # en dash
    "§": "Section ",   # section sign
    "×": "x",          # multiplication sign
}

_CSS = """
@page {
  size: letter;
  margin: 1.6cm;
  @frame footer_frame {
    -pdf-frame-content: footer_content;
    bottom: 1cm; margin-left: 1.6cm; margin-right: 1.6cm; height: 1cm;
  }
}
body { font-family: Helvetica, Arial, sans-serif; font-size: 9.5pt; line-height: 1.45; color: #1a1a1a; }
h1 { font-size: 17pt; color: #1b3a5c; border-bottom: 2px solid #1b3a5c; padding-bottom: 4px; margin-top: 0; }
h2 { font-size: 13pt; color: #1b3a5c; margin-top: 18px; border-bottom: 1px solid #b7c6d6; padding-bottom: 2px; }
h3 { font-size: 11pt; color: #2d4f73; margin-top: 12px; }
p { margin: 6px 0; text-align: left; }
ul, ol { margin: 4px 0 8px 0; padding-left: 20px; }
li { margin: 2px 0; }
code { font-family: Courier, monospace; font-size: 8.3pt; background-color: #f0f0f0; padding: 1px 3px; }
pre { font-family: Courier, monospace; font-size: 7.6pt; background-color: #f5f5f5; padding: 6px 8px;
      border: 0.5px solid #ccc; white-space: pre-wrap; margin: 6px 0; }
pre code { background-color: transparent; padding: 0; }
table { width: 100%; margin: 8px 0; font-size: 8.3pt; }
th { background-color: #1b3a5c; color: white; padding: 4px 6px; text-align: left; border: 0.5px solid #0f2438; }
td { padding: 4px 6px; border: 0.5px solid #ccc; vertical-align: top; }
tr:nth-child(even) td { background-color: #f7f9fb; }
a { color: #1b5fab; text-decoration: none; }
strong { color: #111; }
hr { border: none; border-top: 1px solid #ccc; margin: 10px 0; }
"""


def render(src: str, dst: str) -> None:
    with open(src, "r", encoding="utf-8") as f:
        md_text = f.read()

    for char, replacement in _PDF_SAFE.items():
        md_text = md_text.replace(char, replacement)

    body_html = markdown.markdown(
        md_text,
        extensions=["tables", "fenced_code", "sane_lists", "toc"],
    )

    # Markdown images use paths relative to the .md source; xhtml2pdf
    # resolves relative src against the process cwd, not the source file,
    # so a diagram sitting next to the doc wouldn't be found when this
    # script is invoked from elsewhere. Rewrite each relative img src to an
    # absolute file path based on the source's own directory.
    src_dir = os.path.dirname(os.path.abspath(src))

    def _absolutize(match: "re.Match[str]") -> str:
        path = match.group(1)
        if re.match(r"^([a-zA-Z]+:|/)", path):  # already absolute or a URL
            return match.group(0)
        return f'src="{os.path.join(src_dir, path)}"'

    body_html = re.sub(r'src="([^"]+)"', _absolutize, body_html)

    html = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        f"<style>{_CSS}</style></head><body>{body_html}"
        "<div id=\"footer_content\" style=\"font-size:7.5pt; color:#888; "
        "text-align:center;\"><pdf:pagenumber/> / <pdf:pagecount/></div>"
        "</body></html>"
    )

    with open(dst, "wb") as out:
        # xhtml2pdf refuses to load a local image outside its `path` base
        # directory (a path-traversal guard) -- without this, it defaults
        # to the process cwd, not the source file's directory, so a
        # diagram sitting next to the doc 404s whenever this script runs
        # from anywhere else.
        result = pisa.CreatePDF(src=html, dest=out, path=src_dir)

    if result.err:
        print(f"xhtml2pdf reported {result.err} error(s) rendering {src}", file=sys.stderr)
        sys.exit(1)
    print(f"wrote {dst}")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <source.md> <output.pdf>", file=sys.stderr)
        return 2
    render(sys.argv[1], sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
