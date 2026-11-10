#!/usr/bin/env python3
"""Collect post-route area and both-corner timing of every complete-accelerator
build under results/ and print the markdown tables used in REPORT_v2.md.
Also writes results/summary_v2.csv.

Area = post-route standard-cell area from the routed OpenROAD database
(postroute_metrics.txt): registers (flip-flops), combinational logic (incl.
timing-repair buffers/inverters and tie cells) and the clock tree. Fillers
excluded. Overheads are against acc_unmasked (the timing-closed baseline).
"""
import csv
from pathlib import Path

RES = Path(__file__).resolve().parent.parent / "results"
BUILDS = [
    ("acc_unmasked",         "Unprotected (baseline)"),
    ("acc_arr_masked",       "Array masked only"),
    ("acc_rq_masked_nrq1",   "Requantizer masked only, NRQ=1"),
    ("acc_rq_masked_nrq2",   "Requantizer masked only, NRQ=2"),
    ("acc_rq_masked_nrq5",   "Requantizer masked only, NRQ=5"),
    ("acc_both_masked_nrq1", "Array + requantizer masked, NRQ=1"),
    ("acc_both_masked_nrq2", "Array + requantizer masked, NRQ=2"),
    ("acc_both_masked_nrq5", "Array + requantizer masked, NRQ=5"),
]
BASE = "acc_unmasked"


def kv(path):
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            p = line.split()
            if len(p) >= 2:
                try:
                    out[p[0]] = float(p[1])
                except ValueError:
                    out[p[0]] = p[1]
    return out


def load(d):
    r = RES / d
    m = kv(r / "postroute_metrics.txt")
    if not m:
        return None
    m["reg"] = m["area_seq"]
    m["comb"] = m["area_comb"] + m["area_bufinv"] + m["area_tie"]
    m["clk"] = m["area_clkbuf"]
    m["total"] = m["stdcell_area"]
    for c in ("fast", "slow"):
        for k, v in kv(r / f"sta_metrics_{c}.txt").items():
            m[f"{c}_{k}"] = v
    return m


def ok(m):
    return all(m.get(f"{c}_{k}", -1) >= 0 for c in ("fast", "slow")
               for k in ("setup_wns_ns", "hold_wns_ns"))


def main():
    data = {d: load(d) for d, _ in BUILDS}
    b = data.get(BASE)
    rows = []
    print("| Build | Total (um^2) | Registers (um^2) | Combinational (um^2) | Clock tree (um^2) | Total overhead | Register overhead | Combinational overhead |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for d, lab in BUILDS:
        m = data[d]
        if m is None:
            print(f"| {lab} | (not run) | | | | | | |")
            continue
        if b and d != BASE:
            ov = lambda k: f"{m[k] / b[k]:.2f}x (+{100 * (m[k] / b[k] - 1):.0f} %)"
            o = (ov("total"), ov("reg"), ov("comb"))
        else:
            o = ("1.00x", "1.00x", "1.00x")
        print(f"| {lab} | {m['total']:,.0f} | {m['reg']:,.0f} | {m['comb']:,.0f} | {m['clk']:,.0f} | "
              f"{o[0]} | {o[1]} | {o[2]} |")
        rows.append([d, m["total"], m["reg"], m["comb"], m["clk"], m.get("core_util", ""),
                     m.get("route_drc_violations", "")] +
                    [m.get(f"{c}_{k}", "") for c in ("fast", "slow")
                     for k in ("setup_wns_ns", "setup_tns_ns", "hold_wns_ns", "hold_tns_ns")])
    print()
    print("| Build | Setup WNS fast (ns) | Hold WNS fast (ns) | Setup WNS slow (ns) | Hold WNS slow (ns) | Setup TNS slow (ns) | Met at both corners | Route DRC |")
    print("|---|---:|---:|---:|---:|---:|:---:|---:|")
    for d, lab in BUILDS:
        m = data[d]
        if m is None:
            continue
        print(f"| {lab} | {m.get('fast_setup_wns_ns', float('nan')):+.3f} | {m.get('fast_hold_wns_ns', float('nan')):+.3f} | "
              f"{m.get('slow_setup_wns_ns', float('nan')):+.3f} | {m.get('slow_hold_wns_ns', float('nan')):+.3f} | "
              f"{m.get('slow_setup_tns_ns', float('nan')):.3f} | {'yes' if ok(m) else '**NO**'} | "
              f"{int(m.get('route_drc_violations', 0))} |")
    with open(RES / "summary_v2.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["design", "total", "reg", "comb", "clktree", "core_util", "route_drc"] +
                   [f"{c}_{k}" for c in ("fast", "slow")
                    for k in ("setup_wns", "setup_tns", "hold_wns", "hold_tns")])
        w.writerows(rows)


if __name__ == "__main__":
    main()
