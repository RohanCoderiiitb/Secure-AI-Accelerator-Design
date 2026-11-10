#!/usr/bin/env python3
"""Per-block area of a hierarchically synthesised design (Yosys `stat` with
module boundaries kept, results/<design>/hier/hier_stat.txt).

Every module's total = its own cells + (instances x total) of its submodules,
recomputed from the per-module sections at full precision. Register area =
flip-flop cells (DFF*/EDFF*). Prints markdown tables (same layout as the
earlier BLOCK_AREA_REPORT.md) for the both-masked accelerator.

Usage: block_area.py <hier_stat.txt> [--json out.json]
"""
import json
import re
import sys
from collections import defaultdict


def parse(path):
    mods = {}
    cur = None
    in_sub = False
    for line in open(path):
        m = re.match(r"^=== (.+) ===$", line.strip())
        if m:
            name = m.group(1)
            if name == "design hierarchy":
                cur = None
                continue
            cur = {"cells": {}, "subs": defaultdict(int), "local": 0.0, "reg": 0.0}
            mods[name] = cur
            in_sub = False
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*Chip area for module '(.+)':\s+([\d.]+)", line)
        if m:
            cur["local"] = float(m.group(2))
            continue
        if re.match(r"^\s*\d+\s+-\s+submodules", line):
            in_sub = True
            continue
        m = re.match(r"^\s*(\d+)\s+-\s+(\S+)$", line)
        if m and in_sub:
            cur["subs"][m.group(2)] += int(m.group(1))
            continue
        m = re.match(r"^\s*(\d+)\s+([\d.E+-]+)\s+([A-Z][A-Z0-9]*)$", line)
        if m:
            cnt, area, cell = int(m.group(1)), float(m.group(2)), m.group(3)
            cur["cells"][cell] = (cnt, area)
            if re.match(r"^(DFF|EDFF|SDFF|SEDFF|MDFF|SMDFF|TLAT|RDFF)", cell):
                cur["reg"] += area
    return mods


def base(name):
    """'$paramod$abc\\requantize_masked' -> 'requantize_masked'."""
    parts = name.split("\\")
    if len(parts) == 1:
        return name.lstrip("$")
    # '$paramod$<hash>\\name'  or  '$paramod\\name\\P=V...'
    return parts[1] if parts[0] == "$paramod" else parts[-1]


class Design:
    def __init__(self, mods):
        self.mods = mods
        self.memo = {}

    def total(self, name):
        if name in self.memo:
            return self.memo[name]
        m = self.mods[name]
        a, r = m["local"], m["reg"]
        for s, n in m["subs"].items():
            sa, sr = self.total(s)
            a += n * sa
            r += n * sr
        self.memo[name] = (a, r)
        return a, r

    def instances(self, root):
        """flattened instance count of every module below root (incl. root)."""
        cnt = defaultdict(int)

        def walk(name, mult):
            cnt[name] += mult
            for s, n in self.mods[name]["subs"].items():
                walk(s, mult * n)
        walk(root, 1)
        return cnt


def find(mods, b):
    return [n for n in mods if base(n) == b]


def pct(a, b):
    return f"{100.0 * a / b:.1f} %" if b else "-"


def main():
    path = sys.argv[1]
    mods = parse(path)
    d = Design(mods)
    tops = [n for n in mods if base(n).startswith("flexnn_top")]
    top = tops[0]
    T, TR = d.total(top)
    inst = d.instances(top)

    def group(b):
        """(instances, area each, total, reg total) over all variants of module b."""
        ns = find(mods, b)
        n = sum(inst[x] for x in ns)
        tot = sum(inst[x] * d.total(x)[0] for x in ns)
        reg = sum(inst[x] * d.total(x)[1] for x in ns)
        return n, (tot / n if n else 0.0), tot, reg

    def local(b):
        ns = find(mods, b)
        n = sum(inst[x] for x in ns)
        tot = sum(inst[x] * mods[x]["local"] for x in ns)
        reg = sum(inst[x] * mods[x]["reg"] for x in ns)
        return n, (tot / n if n else 0.0), tot, reg

    rows = [
        ("PEs (`processing_element_wshare`)", group("processing_element_wshare")),
        ("Shadow column (`shadow_pe`)", group("shadow_pe")),
        ("Mask generator (`wmask_gen`)", group("wmask_gen")),
        ("Array glue (north-edge subtractors, S delay line, load counter, valid delay)",
         local("systolic_array_wmask_shares")),
        ("Masked psum accumulator (`psum_accum_masked`)", group("psum_accum_masked")),
        ("Share buffer + select / routing (`rq_share_server` own logic)", local("rq_share_server")),
        ("Masked requantizer cores (`requantize_masked`)", group("requantize_masked")),
        ("Random number generators (`rng_bank`)", group("rng_bank")),
        ("bias*m0 precompute (`bias_scale`)", group("bias_scale")),
    ]
    masked = sum(r[1][2] for r in rows[:8])
    masked_reg = sum(r[1][3] for r in rows[:8])

    out = []
    out.append(f"Design `{base(top)}`, hierarchical Yosys total {T:,.1f} um^2 "
               f"({TR:,.1f} um^2 registers).\n")
    out.append("| Block | Instances | Area each (um^2) | Total (um^2) | of which registers (um^2) | Share of design |")
    out.append("|---|---:|---:|---:|---:|---:|")
    for lab, (n, each, tot, reg) in rows:
        out.append(f"| {lab} | {n} | {each:,.1f} | {tot:,.1f} | {reg:,.1f} ({pct(reg, tot) if tot else '-'}) | {pct(tot, T)} |")
    out.append(f"| **Masked blocks, subtotal** (all rows above except bias_scale) | | | **{masked:,.1f}** | "
               f"{masked_reg:,.1f} ({pct(masked_reg, masked)}) | **{pct(masked, T)}** |")
    rest = T - masked - rows[8][1][2]
    rest_reg = TR - masked_reg - rows[8][1][3]
    out.append(f"| Unmasked rest (buffers, scratchpads, load controller, address generator, activation units, "
               f"maxpools, registered I/O, top-level glue) | | | {rest:,.1f} | {rest_reg:,.1f} | {pct(rest, T)} |")
    out.append(f"| **Total** | | | **{T:,.1f}** | {TR:,.1f} ({pct(TR, T)}) | 100 % |")

    arr = sum(r[1][2] for r in rows[:4])
    out.append("\n| Group | Total (um^2) | Share of design |")
    out.append("|---|---:|---:|")
    for lab, v in [("Masked array (PEs + shadow column + mask generator + glue)", arr),
                   ("Masked psum accumulator", rows[4][1][2]),
                   ("Share buffer + routing", rows[5][1][2]),
                   (f"Masked requantizer cores (x{rows[6][1][0]})", rows[6][1][2]),
                   (f"Random number generators (x{rows[7][1][0]})", rows[7][1][2]),
                   ("bias*m0 precompute", rows[8][1][2]),
                   ("Unmasked rest", rest)]:
        out.append(f"| {lab} | {v:,.1f} | {pct(v, T)} |")

    # inside one core
    core = find(mods, "requantize_masked")[0]
    ca, cr = d.total(core)
    parts = defaultdict(lambda: [0, 0.0, 0.0])
    for s, n in mods[core]["subs"].items():
        sa, sr = d.total(s)
        p = parts[base(s).split("\\")[0]]
        p[0] += n
        p[1] += n * sa
        p[2] += n * sr
    out.append(f"\nInside one masked requantizer core ({ca:,.1f} um^2):\n")
    out.append("| Part | Instances per core | Area per core (um^2) | of which registers (um^2) | Share of core |")
    out.append("|---|---:|---:|---:|---:|")
    out.append(f"| Own logic: per-share x m0 multipliers (2 stages), B2A/constant adders, B2A mux, "
               f"output-window shifts, constant selection | - | {mods[core]['local']:,.1f} | "
               f"{mods[core]['reg']:,.1f} | {pct(mods[core]['local'], ca)} |")
    for k, (n, a, r) in sorted(parts.items(), key=lambda kv: -kv[1][1]):
        out.append(f"| `{k}` | {n} | {a:,.1f} | {r:,.1f} | {pct(a, ca)} |")
    print("\n".join(out))
    if len(sys.argv) > 3 and sys.argv[2] == "--json":
        json.dump({"total": T, "reg": TR, "rows": {lab: v for lab, v in rows}, "core": ca},
                  open(sys.argv[3], "w"), indent=1)


if __name__ == "__main__":
    main()
