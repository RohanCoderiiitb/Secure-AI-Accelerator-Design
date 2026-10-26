#!/usr/bin/env python3
"""Plot post-route area from results/area_results.csv.

  results/area_postroute.png  - post-route area per design, one panel per
                                hierarchy level (multiplier / PE / array; scales
                                differ ~200x, so no shared axis). Each design gets
                                three bars side by side - total, register,
                                combinational - with the total-area overhead vs.
                                the baseline under its name.
  results/area_overhead.png   - masked / unmasked area ratio for every masked
                                design, one small panel per metric: total,
                                register, combinational, die.
"""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

RES = Path(__file__).resolve().parent.parent / "results"

# Reference categorical palette (light mode). One colour per area component,
# identical in both figures.
REG, COMB, PHYS, DIE = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
TOTAL = "#3d3c39"
SURFACE, INK, INK2, GRID = "#ffffff", "#0b0b0b", "#52514e", "#e4e3df"

# Plain-English names, used on every axis.
NAME = {
    "mult_unmasked":             "Unprotected, multiplier logic only",
    "mult_unmasked_wreg":        "Unprotected + weight register  (baseline)",
    "mult_wt_masked":            "Weight-masked",
    "mult_act_masked":           "Activation-masked",
    "mult_act_wt_masked":        "Activation- and weight-masked",
    "pe_unmasked":               "Unprotected  (baseline)",
    "pe_act_masked":             "Activation-masked",
    "pe_wt_masked":              "Weight-masked",
    "sa_unmasked":               "Unprotected  (baseline)",
    "sa_act_masked":             "Activation-masked",
    "sa_actlink_masked":         "Activation-link-masked (plain PEs)",
    "sa_wt_masked":              "Weight-masked",
}
PANELS = [
    ("8×8 multiplier", ["mult_unmasked", "mult_unmasked_wreg", "mult_wt_masked",
                        "mult_act_masked", "mult_act_wt_masked"]),
    ("Processing element (PE)", ["pe_unmasked", "pe_act_masked", "pe_wt_masked"]),
    ("5×5 systolic array", ["sa_unmasked", "sa_act_masked", "sa_wt_masked",
                            "sa_actlink_masked"]),
]
COMPONENTS = [("Register (flip-flops)", "reg_um2", REG),
              ("Combinational logic", "comb_um2", COMB),
              ("Clock tree + tap/tie cells", "other_um2", PHYS)]

# Figure 2: masked designs, grouped by level (blank row between groups).
OVERHEAD_ROWS = [
    ("Multiplier", "mult_wt_masked", "Weight-masked"),
    ("Multiplier", "mult_act_masked", "Activation-masked"),
    ("Multiplier", "mult_act_wt_masked", "Act.- and weight-masked"),
    None,
    ("PE", "pe_act_masked", "Activation-masked"),
    ("PE", "pe_wt_masked", "Weight-masked"),
    None,
    ("Array", "sa_act_masked", "Activation-masked"),
    ("Array", "sa_wt_masked", "Weight-masked"),
    ("Array", "sa_actlink_masked", "Act.-link-masked (plain PEs)"),
]
METRICS = [("Total cell area", "total_x", TOTAL),
           ("Register area", "reg_x", REG),
           ("Combinational area", "comb_x", COMB),
           ("Die area", "die_x", DIE)]

FS = 11  # base font size


def clean(ax, grid="x"):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(INK2)
    ax.tick_params(colors=INK2, labelsize=FS - 1, length=0)
    getattr(ax, f"{grid}axis").grid(True, color=GRID, linewidth=0.9)
    ax.set_axisbelow(True)


def fig_area(rows):
    """Grouped bars: for every design, total / register / combinational side by
    side, read straight off one axis. One panel per level; baseline first."""
    panels = [(t, [d for d in ds if d in rows and d != "mult_unmasked"]) for t, ds in PANELS]
    bars = [("Total", "total_um2", TOTAL), ("Register", "reg_um2", REG),
            ("Combinational", "comb_um2", COMB)]
    w = 0.26
    fig, axes = plt.subplots(len(panels), 1, figsize=(13, 13.5), facecolor=SURFACE,
                             gridspec_kw={"hspace": 0.75})
    for ax, (title, designs) in zip(axes, panels):
        top = max(float(rows[d]["total_um2"]) for d in designs)
        for i, (label, key, col) in enumerate(bars):
            xs = [j + (i - 1) * w for j in range(len(designs))]
            v = [float(rows[d][key]) for d in designs]
            ax.bar(xs, v, width=w * 0.92, color=col, label=label)
            for x, vi in zip(xs, v):
                ax.text(x, vi + top * 0.015, f"{vi:,.0f}", ha="center", va="bottom",
                        fontsize=FS - 2, color=INK)
        ticks = []
        for d in designs:
            name = NAME[d].replace("  (baseline)", "")
            ox = rows[d]["total_x"]
            ticks.append(f"{name}\n" + (f"{float(ox):.2f}× total area" if ox else "baseline"))
        ax.set_xticks(range(len(designs)), ticks, fontsize=FS - 0.5)
        for lbl, d in zip(ax.get_xticklabels(), designs):
            lbl.set_color(INK if rows[d]["total_x"] else INK2)
            lbl.set_fontweight("bold" if rows[d]["total_x"] else "normal")
        ax.set_ylim(0, top * 1.15)
        ax.set_ylabel("Area (µm²)", fontsize=FS - 0.5, color=INK2)
        ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f}"))
        ax.set_title(title, fontsize=FS + 2, color=INK, loc="left", fontweight="bold", pad=10)
        clean(ax, grid="y")
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper right", bbox_to_anchor=(0.99, 0.945), ncol=3, frameon=False,
               fontsize=FS, handlelength=1.2, columnspacing=2.0, labelcolor=INK)
    fig.suptitle("Post-route area: unprotected vs. masked — 45nm PDK (fast corner), 100 MHz",
                 x=0.01, y=0.995, ha="left", fontsize=FS + 4, color=INK, fontweight="bold")
    fig.text(0.01, 0.962, "Total = register + combinational + clock tree/tap/tie cells "
             "(the last is ≤ 3 % of total and not drawn separately). "
             "Multiplier baseline = unprotected multiplier + weight register.",
             fontsize=FS - 1, color=INK2)
    fig.subplots_adjust(left=0.07, right=0.99, top=0.90, bottom=0.06)
    fig.savefig(RES / "area_postroute.png", dpi=200, facecolor=SURFACE)
    plt.close(fig)


def fig_overhead(rows):
    entries = [e for e in OVERHEAD_ROWS if e is None or e[1] in rows]
    ypos, labels, keys = [], [], []
    y = 0.0
    for e in reversed(entries):
        if e is None:
            y += 0.6                                         # gap between levels
            continue
        ypos.append(y); labels.append(f"{e[0]} — {e[2]}"); keys.append(e[1])
        y += 1.0
    xmax = max(float(rows[k][m]) for k in keys for _, m, _ in METRICS)

    fig, axes = plt.subplots(1, len(METRICS), figsize=(16, 6.4), sharey=True, facecolor=SURFACE)
    for ax, (title, m, col) in zip(axes, METRICS):
        v = [float(rows[k][m]) for k in keys]
        ax.barh(ypos, v, height=0.68, color=col, edgecolor=SURFACE)
        for yi, vi in zip(ypos, v):
            ax.text(vi + xmax * 0.02, yi, f"{vi:.2f}×", ha="left", va="center",
                    fontsize=FS - 0.5, color=INK)
        ax.axvline(1.0, color=INK2, linewidth=1.2, linestyle=(0, (4, 3)))
        ax.set_xlim(0, xmax * 1.25)
        ax.set_title(title, fontsize=FS + 1.5, color=INK, fontweight="bold", loc="left")
        ax.set_xlabel("masked ÷ unmasked", fontsize=FS - 1, color=INK2)
        clean(ax)
    axes[0].set_yticks(ypos, labels, fontsize=FS)
    fig.suptitle("Masking overhead by area component — post-route, 45nm PDK (fast corner)",
                 x=0.01, y=0.985, ha="left", fontsize=FS + 4, color=INK, fontweight="bold")
    fig.text(0.01, 0.905, "Dashed line = 1× (no overhead).  Baselines: multipliers vs. unprotected "
             "multiplier + weight register; PEs vs. unprotected PE; arrays vs. unprotected array.",
             fontsize=FS - 0.5, color=INK2)
    fig.subplots_adjust(left=0.20, right=0.99, top=0.83, bottom=0.10, wspace=0.12)
    fig.savefig(RES / "area_overhead.png", dpi=200, facecolor=SURFACE)
    plt.close(fig)


def main():
    rows = {r["design"]: r for r in csv.DictReader(open(RES / "area_results.csv"))}
    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": INK})
    fig_area(rows)
    fig_overhead(rows)
    print("wrote", RES / "area_postroute.png", "and", RES / "area_overhead.png")


if __name__ == "__main__":
    main()
