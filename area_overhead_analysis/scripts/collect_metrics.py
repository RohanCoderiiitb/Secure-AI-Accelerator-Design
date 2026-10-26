#!/usr/bin/env python3
"""Collect post-route area / timing metrics for every design under results/
and write results/area_results.csv plus results/area_tables.md.

All area numbers are POST-ROUTE standard-cell area (um^2) read from the routed
OpenROAD database: logic + flops + timing-repair buffers + CTS buffers + tap
cells + tie cells. Filler cells are excluded. Post-synthesis (Yosys) area is
kept as a secondary column only to show how much the physical flow adds.
"""
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "results"

# (design, level, label, baseline design for the overhead column)
ROWS = [
    ("mult_unmasked",             "Multiplier",      "Unmasked BW multiplier (comb. only)",       None),
    ("mult_unmasked_wreg",        "Multiplier",      "Unmasked BW multiplier + weight reg",        None),
    ("mult_wt_masked",            "Multiplier",      "Weight-masked multiplier",                   "mult_unmasked_wreg"),
    ("mult_act_masked",           "Multiplier",      "Activation-masked multiplier",               "mult_unmasked_wreg"),
    ("mult_act_wt_masked",        "Multiplier",      "Activation+weight-masked multiplier",        "mult_unmasked_wreg"),
    ("pe_unmasked",               "PE",              "Unmasked PE",                                None),
    ("pe_act_masked",             "PE",              "Activation-masked PE",                       "pe_unmasked"),
    ("pe_wt_masked",              "PE",              "Weight-masked PE",                           "pe_unmasked"),
    ("sa_unmasked",               "Systolic array",  "Unmasked 5x5 array",                         None),
    ("sa_act_masked",             "Systolic array",  "Activation-masked 5x5 array",                "sa_unmasked"),
    ("sa_actlink_masked",         "Systolic array",  "Act.-link-masked 5x5 array (plain PEs)",     "sa_unmasked"),
    ("sa_wt_masked",              "Systolic array",  "Weight-masked 5x5 array",                    "sa_unmasked"),
    ("act_masker",                "Support",         "act_masker alone (5 rows: RNG + splitter)",  None),
]


def kv_file(path):
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                out[parts[0]] = float(parts[1])
            except ValueError:
                out[parts[0]] = parts[1]
    return out


def synth_area(path):
    if not path.exists():
        return None
    m = re.findall(r"Chip area for (?:top )?module '\\?([^']+)':\s+([\d.]+)", path.read_text())
    # the top module is reported last
    return float(m[-1][1]) if m else None


def load(design):
    d = RES / design
    m = kv_file(d / "postroute_metrics.txt")
    # fast corner = implementation corner (lab flow); slow = worst-case check
    m.update(kv_file(d / "sta_metrics_fast.txt"))
    m.update({k + "_slow": v for k, v in kv_file(d / "sta_metrics_slow.txt").items()})
    m["synth_area"] = synth_area(d / "synth_stat.rpt")
    return m


def fmt(v, spec):
    return format(v, spec) if isinstance(v, (int, float)) else "n/a"


def ratio(a, b):
    return round(a / b, 3) if b else ""


def ox(v):
    return f"{v:.2f}×" if isinstance(v, (int, float)) else "—"


def main():
    data = {r[0]: load(r[0]) for r in ROWS}
    missing = [k for k, v in data.items() if "stdcell_area" not in v]
    if missing:
        print("WARNING: no post-route metrics for:", ", ".join(missing))

    # Area split used throughout the report:
    #   reg   = flip-flops
    #   comb  = all combinational cells (logic + buffers/inverters)
    #   other = clock-tree buffers + tap + tie cells
    #   total = reg + comb + other   (= total post-route std-cell area)
    #   die   = total die (chip) area at the common 50 % utilisation target
    def split(m):
        reg = m["area_seq"]
        comb = m["area_comb"] + m["area_bufinv"]
        other = m["area_clkbuf"] + m["area_tap"] + m["area_tie"]
        return reg, comb, other, m["stdcell_area"], m["die_area"]

    fields = ["design", "level", "label", "baseline",
              "total_um2", "reg_um2", "comb_um2", "other_um2", "die_um2",
              "total_x", "reg_x", "comb_x", "die_x", "total_pct",
              "logic_um2", "buf_inv_um2", "clk_buf_um2", "tap_tie_um2",
              "cell_count", "synth_area_um2", "core_area_um2", "core_util",
              "setup_wns_ns", "hold_wns_ns", "crit_arrival_ns",
              "setup_wns_slow_ns", "hold_wns_slow_ns", "crit_arrival_slow_ns", "route_drc"]
    rows = []
    for design, level, label, base in ROWS:
        m = data[design]
        if "stdcell_area" not in m:
            continue
        reg, comb, other, total, die = split(m)
        r = {
            "design": design, "level": level, "label": label, "baseline": base or "",
            "total_um2": round(total, 2), "reg_um2": round(reg, 2),
            "comb_um2": round(comb, 2), "other_um2": round(other, 2),
            "die_um2": round(die, 1),
            "total_x": "", "reg_x": "", "comb_x": "", "die_x": "", "total_pct": "",
            "logic_um2": round(m["area_comb"], 2),
            "buf_inv_um2": round(m["area_bufinv"], 2),
            "clk_buf_um2": round(m["area_clkbuf"], 2),
            "tap_tie_um2": round(m["area_tap"] + m["area_tie"], 2),
            "cell_count": int(m["stdcell_count"]),
            "synth_area_um2": round(m["synth_area"], 2) if m["synth_area"] else "",
            "core_area_um2": round(m["core_area"], 1),
            "core_util": round(m["core_util"], 3),
            "setup_wns_ns": m.get("setup_wns_ns", ""),
            "hold_wns_ns": m.get("hold_wns_ns", ""),
            "crit_arrival_ns": m.get("crit_arrival_ns", ""),
            "setup_wns_slow_ns": m.get("setup_wns_ns_slow", ""),
            "hold_wns_slow_ns": m.get("hold_wns_ns_slow", ""),
            "crit_arrival_slow_ns": m.get("crit_arrival_ns_slow", ""),
            "route_drc": int(m.get("route_drc_violations", -1)),
        }
        if base and "stdcell_area" in data.get(base, {}):
            breg, bcomb, _, btotal, bdie = split(data[base])
            r.update(total_x=ratio(total, btotal), reg_x=ratio(reg, breg),
                     comb_x=ratio(comb, bcomb), die_x=ratio(die, bdie),
                     total_pct=round((total / btotal - 1.0) * 100.0, 1))
        rows.append(r)

    with open(RES / "area_results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    # Markdown tables, pasted into REPORT.md
    md = ["| Level | Design | Total (µm²) | Register (µm²) | Comb. (µm²) | Clock/tap/tie (µm²) | Die (µm²) | "
          "Total × | Register × | Comb. × | Die × |",
          "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        md.append(f"| {r['level']} | {r['label']} | {r['total_um2']:,.1f} | {r['reg_um2']:,.1f} | "
                  f"{r['comb_um2']:,.1f} | {r['other_um2']:,.1f} | {r['die_um2']:,.0f} | "
                  f"{ox(r['total_x'])} | {ox(r['reg_x'])} | {ox(r['comb_x'])} | {ox(r['die_x'])} |")
    md += ["", "| Design | Register | Comb. logic | Buf/Inv | Clock buf (CTS) | Tap/Tie | Total | Yosys area | Cells | "
           "Core util | Setup WNS fast (ns) | Hold WNS fast (ns) | Setup WNS slow (ns) | DRC |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        md.append(f"| {r['design']} | {r['reg_um2']:,.1f} | {r['logic_um2']:,.1f} | {r['buf_inv_um2']:,.1f} | "
                  f"{r['clk_buf_um2']:,.1f} | {r['tap_tie_um2']:,.1f} | {r['total_um2']:,.1f} | "
                  f"{fmt(r['synth_area_um2'], ',.1f')} | {r['cell_count']:,} | {r['core_util']*100:.1f} % | "
                  f"{fmt(r['setup_wns_ns'], '+.3f')} | {fmt(r['hold_wns_ns'], '+.3f')} | "
                  f"{fmt(r['setup_wns_slow_ns'], '+.3f')} | {r['route_drc']} |")
    (RES / "area_tables.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
