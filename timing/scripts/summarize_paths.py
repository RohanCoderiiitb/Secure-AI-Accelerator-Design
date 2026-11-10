#!/usr/bin/env python3
"""Turn hier_paths_<corner>.tsv (from hier_paths.tcl) into a markdown table.

Usage: summarize_paths.py <tsv> <title>
Block = the hierarchical instance that owns the start/end register (top-level
glue and ports are shown as 'top'). Generate indices are kept, so the table
says which PE / column / requantizer the path is in.
"""
import csv
import re
import sys


def block(pin):
    """'u_array/g_row[1].g_col[2].pe_inst/psum_out_reg[3]/CK' -> (block, register).
    Registers are named after the RTL signal they drive (synth.tcl rename -wire);
    a bare name is a top-level port."""
    parts = pin.split("/")
    if len(parts) == 1:
        return "top (port)", pin
    cell = parts[-2]
    blk = "/".join(parts[:-2]) or "top"
    return blk, cell


def kind(blk):
    """Coarse block class: strip generate indices so paths can be grouped."""
    return re.sub(r"\[\d+\]", "[*]", blk)


def main():
    tsv, title = sys.argv[1], sys.argv[2]
    rows = list(csv.DictReader(open(tsv), delimiter="\t"))
    print(f"### Top {len(rows)} setup paths: {title}\n")
    print("| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |")
    print("|---:|---:|---:|---|---|---|---|---|")
    groups = {}
    for r in rows:
        sb, ss = block(r["startpoint"])
        eb, es = block(r["endpoint"])
        crossed = r["instances"].split() if r["instances"] else []
        n_cross = len(crossed)
        print(f"| {r['rank']} | {float(r['slack_ns']):.3f} | {float(r['arrival_ns']):.3f} | "
              f"`{sb}` | `{ss}` | `{eb}` | `{es}` | {n_cross} |")
        key = (kind(sb), kind(eb))
        groups.setdefault(key, []).append(float(r["slack_ns"]))
    print("\n| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |")
    print("|---|---|---:|---:|")
    for (s, e), v in sorted(groups.items(), key=lambda kv: min(kv[1])):
        print(f"| `{s}` | `{e}` | {len(v)} | {min(v):.3f} |")

    # every failing endpoint, grouped by the block class of its END register
    ep = tsv.replace("hier_paths_", "hier_endpoints_")
    try:
        eps = list(csv.DictReader(open(ep), delimiter="\t"))
    except FileNotFoundError:
        return
    cls = {}
    for r in eps:
        eb, _ = block(r["endpoint"])
        sb, _ = block(r["startpoint"])
        k = kind(eb)
        d = cls.setdefault(k, {"n": 0, "worst": 0.0, "tns": 0.0, "start": {}})
        sl = float(r["slack_ns"])
        d["n"] += 1
        d["tns"] += sl
        if sl < d["worst"]:
            d["worst"] = sl
        d["start"][kind(sb)] = min(d["start"].get(kind(sb), 0.0), sl)
    print(f"\n#### All {len(eps)} failing endpoints, by end block\n")
    print("| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |")
    print("|---|---:|---:|---:|---|")
    for k, d in sorted(cls.items(), key=lambda kv: kv[1]["worst"]):
        wst = min(d["start"].items(), key=lambda kv: kv[1])[0]
        print(f"| `{k}` | {d['n']} | {d['worst']:.3f} | {d['tns']:.1f} | `{wst}` |")


if __name__ == "__main__":
    main()
