#!/usr/bin/env python3
"""make_vscode_copilot_diagram.py -- regenerate the components/message-flow
diagram embedded in docs/vscode-copilot/VscodeCopilotAgentManagement.md.

    scripts/make_vscode_copilot_diagram.py [output.png]

A diagram with no regeneratable source is a diagram nobody can refresh --
same rationale as render-doc-pdf.sh's own header. This is that source: edit
the BOXES/ARROWS data below, re-run, and the PNG is back in sync. Run via
the same venv make-pdf.sh/make-pdf.ps1 use (needs matplotlib in addition to
markdown/xhtml2pdf):

    scripts/.venv/Scripts/python.exe scripts/make_vscode_copilot_diagram.py \
        docs/vscode-copilot/architecture-diagram.png

Layout note: boxes that are only reachable via a side round-trip (e.g.
"issuer") are placed OFF the main vertical column on purpose -- a box sitting
inline on a straight connector's path gets run over by that connector's
line/label. Every row leaves >=1.0 unit of clear vertical gap and every
same-row pair leaves >=1.6 units of clear horizontal gap so a label never
has to touch box text.
"""
from __future__ import annotations

import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

NAVY = "#1b3a5c"
NAVY_LIGHT = "#e8eef4"
AMBER = "#c9780c"
AMBER_LIGHT = "#fbeedd"
GRAY = "#555555"
WHITE = "#ffffff"

# (x, y, width, height, label, fill_color, text_color)
BOXES = {
    "protect":   (0.6, 16.4, 3.8, 1.0, "ai-protect\ndaemon", NAVY_LIGHT, NAVY),
    "admin":     (7.0, 16.4, 3.4, 1.0, "Admin\n(human)", AMBER_LIGHT, "#5a3a00"),
    "issuer":    (-5.6, 14.0, 4.2, 1.0, "OIDC Issuer\n(zslogin.net)", "#eeeeee", "#222222"),
    "mgr1":      (0.6, 14.0, 3.8, 1.0, "ai-gateway\nAgentManager", NAVY, WHITE),
    "vector":    (6.2, 14.0, 4.4, 1.4, "Vector / Bumblebee\n(ZAX control plane)", NAVY, WHITE),
    "listener1": (0.6, 11.0, 3.8, 1.2, "ai-gateway Listener\nstarts; config delta", NAVY, WHITE),
    "settings":  (0.6, 8.6, 3.8, 1.0, "VS Code\nsettings.json", "#eeeeee", "#222222"),
    "vscode":    (0.6, 6.2, 3.8, 1.0, "VS Code +\nCopilot Chat extension", NAVY_LIGHT, NAVY),
    "listener2": (0.6, 3.4, 3.8, 1.0, "ai-gateway\nListener", NAVY, WHITE),
    "direct":    (-4.6, 0.6, 3.2, 1.0, "real host\n(direct, no Optimus)", "#eeeeee", "#222222"),
    "optimus":   (2.0, 0.6, 3.8, 1.0, "Optimus\n(gateway.zsagentic.ai)", AMBER, WHITE),
    "github":    (2.0, -2.0, 3.8, 1.0, "GitHub Copilot API\n(*.githubcopilot.com)", "#eeeeee", "#222222"),
}

# (from, to, number, label, curve, style, label_offset) -- style: "solid"
# (main flow) or "dashed" (approval / control side-branch). label_offset is
# an (dx, dy) ADDED TO THE STRAIGHT-LINE MIDPOINT (not the curved one) --
# chosen per arrow to land in a clear patch of whitespace, not derived from
# the curve amount, so two near-parallel arrows can't drift into collision.
ARROWS = [
    ("protect", "mgr1", "1", ".broker.zip", 0.0, "solid", (0.0, 0.0)),
    ("mgr1", "issuer", "2", "browser OIDC login", 0.3, "solid", (0.0, 0.35)),
    ("issuer", "mgr1", "3", "ZAX user JWT", -0.3, "solid", (0.0, -0.35)),
    ("mgr1", "vector", "4", "agents:register", 0.3, "solid", (0.0, 0.45)),
    ("admin", "vector", "5", "approve", 0.0, "dashed", (0.55, 0.0)),
    ("vector", "mgr1", "6,7", "active -> Bumblebee\nactivate/exchange ->\ntriple JWT + mcp list", -0.3, "solid", (0.0, -0.75)),
    ("mgr1", "listener1", "", "", 0.0, "solid", (0.0, 0.0)),
    ("listener1", "settings", "8", "ai-protect applies the delta", 0.0, "solid", (0.0, 0.0)),
    ("settings", "vscode", "", "reads http.proxy", 0.0, "solid", (0.0, 0.0)),
    ("vscode", "listener2", "9", "CONNECT / HTTPS via http.proxy", 0.0, "solid", (0.0, 0.0)),
    ("listener2", "direct", "10", "bypass: telemetry /\nupdate / CDN", -0.2, "solid", (-0.5, 0.0)),
    ("listener2", "optimus", "11", "MITM + relay,\ntriple JWT attached", 0.2, "solid", (0.9, 0.0)),
    ("optimus", "github", "12", "forwards", 0.0, "solid", (0.0, 0.0)),
]


def center(box):
    x, y, w, h = BOXES[box][:4]
    return x + w / 2, y + h / 2


def edge_point(box, towards):
    """Where an arrow should touch `box`'s border, aimed at point `towards`."""
    x, y, w, h = BOXES[box][:4]
    cx, cy = x + w / 2, y + h / 2
    tx, ty = towards
    if abs(ty - cy) >= abs(tx - cx):
        return cx, (y + h if ty > cy else y)
    return (x + w if tx > cx else x), cy


def draw():
    fig, ax = plt.subplots(figsize=(11, 15))
    ax.set_xlim(-8.3, 11.4)
    ax.set_ylim(-2.8, 18.0)
    ax.axis("off")

    ax.text(1.4, 17.6, "Enrollment & config wiring", fontsize=13, fontweight="bold",
            color=NAVY, ha="center")
    ax.text(8.8, 3.9, "Runtime: a real\nCopilot Chat request", fontsize=12,
            fontweight="bold", color=AMBER, ha="center", linespacing=1.4)
    ax.axhline(y=5.3, xmin=0.0, xmax=1.0, color="#bbbbbb", linestyle=(0, (6, 4)), linewidth=1.2)

    for key, (x, y, w, h, label, fill, text_color) in BOXES.items():
        box = FancyBboxPatch(
            (x, y), w, h,
            boxstyle="round,pad=0.08,rounding_size=0.12",
            linewidth=1.3, edgecolor=NAVY if fill != NAVY else "#0f2438",
            facecolor=fill, zorder=2,
        )
        ax.add_patch(box)
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=10, color=text_color, fontweight="normal", zorder=3,
                linespacing=1.3)

    for src, dst, num, label, curve, style, (odx, ody) in ARROWS:
        c_src, c_dst = center(src), center(dst)
        p1 = edge_point(src, c_dst)
        p2 = edge_point(dst, c_src)
        arrow = FancyArrowPatch(
            p1, p2,
            connectionstyle=f"arc3,rad={curve}",
            arrowstyle="-|>", mutation_scale=16,
            linewidth=1.6, color=GRAY if style == "solid" else AMBER,
            linestyle="-" if style == "solid" else (0, (4, 3)),
            zorder=1,
        )
        ax.add_patch(arrow)
        if num or label:
            mx, my = (p1[0] + p2[0]) / 2 + odx, (p1[1] + p2[1]) / 2 + ody
            text = f"({num}) {label}" if num else label
            ax.text(mx, my, text, fontsize=7.6, color="#333333",
                    ha="center", va="center", zorder=4,
                    bbox=dict(boxstyle="round,pad=0.15", facecolor="white",
                              edgecolor="none", alpha=0.95))

    # Final response arrow: GitHub -> back up to the VS Code box, routed far
    # to the left of everything (including the "direct" box) so it never
    # crosses, or lands anywhere near, the main downward flow.
    gh = edge_point("github", (-7.0, center("github")[1]))
    vs = edge_point("vscode", (-7.0, center("vscode")[1]))
    loop_x = -7.0
    loop = FancyArrowPatch(
        (loop_x, gh[1]), (loop_x, vs[1]),
        connectionstyle="arc3,rad=-0.15",
        arrowstyle="-|>", mutation_scale=16, linewidth=1.6,
        color=AMBER, linestyle=(0, (4, 3)), zorder=1,
    )
    ax.add_patch(loop)
    ax.plot([gh[0], loop_x], [gh[1], gh[1]], color=AMBER, linestyle=(0, (4, 3)), linewidth=1.6, zorder=1)
    ax.plot([vs[0], loop_x], [vs[1], vs[1]], color=AMBER, linestyle=(0, (4, 3)), linewidth=1.6, zorder=1)
    ax.text(loop_x - 0.3, (gh[1] + vs[1]) / 2,
            "(13) response relayed back:\nGitHub -> Optimus -> Listener ->\nCopilot Chat ext -> VS Code UI",
            fontsize=7.6, color="#333333", ha="right", va="center",
            bbox=dict(boxstyle="round,pad=0.25", facecolor="white", edgecolor="#cccccc"))

    return fig


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "architecture-diagram.png"
    fig = draw()
    fig.savefig(out, dpi=200, bbox_inches="tight", facecolor="white")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
