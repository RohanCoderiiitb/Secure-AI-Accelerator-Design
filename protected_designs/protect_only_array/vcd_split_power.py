#!/usr/bin/env python3
"""
vcd_split_power.py -- split the toggle-count power proxy per module, then
run the fixed-vs-random Welch t-test per module / per clock cycle.

It reads the VCD you already have (no re-simulation) plus a small CSV of
capture windows, counts bit toggles per (trace, cycle, module-group,
net-kind) and prints where the leakage lives.

INPUTS
  vcd       the VCD from the TVLA run (whole-top dump, i.e. -DTVLA_DUMP_TOP)
  windows   CSV with header  begin_ps,end_ps,group
            one row per trace, group = 0 or 1 (fixed / random).
            Only begin_ps and group are used: cycles are binned from
            begin_ps for --ncycles cycles, so --ncycles can be larger than
            your capture window to look at the pipeline tail (the VCD
            contains it anyway).
            Produce it from whatever sca_close_meta wrote (trace begin/end
            times and group labels) -- this script does not know that
            file's format.

HOW A TOGGLE IS COUNTED
  Every value change of a signal inside a window adds Hamming distance
  (old vs new value) to the cycle bin floor((t - begin) / clk).
  Changes from/to x/z are not counted. A net that appears under several
  scopes (port aliases share one VCD id) is counted ONCE, attributed to the
  declaration in a recognised module (not 'other'), preferring a 'reg'
  declaration, else the first one seen.

KIND
  'reg'  = VCD $var type reg   (registers, plus procedural-assigned vars)
  'net'  = every other type    (wires: combinational + port aliases)
  This mirrors a reg/comb split but is NOT guaranteed to equal your
  P_reg / P_comb definition -- check how your own script defines them and
  edit classify_kind() if needed.

USAGE
  python vcd_split_power.py run.vcd windows.csv --clk-ns 10 --ncycles 18 \
         --show 13,16 --out per_module_t.csv
"""
import argparse, bisect, csv, re, sys
import numpy as np

# (label, regex on the full dotted path) -- first match wins.
GROUPS = [
    ("array",      r"\.u_array\."),
    ("masker",     r"\.u_weight_masker\."),
    ("psum_accum", r"\.u_psum_accum\."),
    ("requantize", r"\.u_requant\."),
    ("activation", r"\.u_act\."),
    ("maxpool",    r"\.u_pool\."),
    ("of_spad",    r"\.u_of_spad"),
    ("ctrl_mem",   r"\.(u_load_ctrl|u_ag|u_act_spad|u_if_gb|u_fl_gb)"),
    ("recombine",  r"\.g_recombine\["),     # psum0+psum1 -> plaintext column sum (top.sv)
    ("top_glue",   r"\.u_dut\.[^.]+$"),     # other nets directly in flexnn_top
]
GROUP_RE = [(n, re.compile(p)) for n, p in GROUPS]
OTHER = "other"


def classify_group(path):
    for name, rx in GROUP_RE:
        if rx.search(path):
            return name
    return OTHER


def classify_kind(vtype):
    return "reg" if vtype == "reg" else "net"


TS_UNIT = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1.0, "fs": 1e-3}


def parse_header(f):
    """Returns (ps_per_tick, id -> (group, kind, size))."""
    scope, decls, ps_per_tick = [], {}, 1.0
    tokens_buf = []
    while True:
        line = f.readline()
        if not line:
            sys.exit("VCD ended before $enddefinitions")
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "$timescale":
            body = " ".join(tok[1:])
            while "$end" not in body:
                body += " " + f.readline().strip()
            m = re.search(r"(\d+)\s*(s|ms|us|ns|ps|fs)", body)
            ps_per_tick = int(m.group(1)) * TS_UNIT[m.group(2)]
        elif tok[0] == "$scope":
            scope.append(tok[2])
        elif tok[0] == "$upscope":
            scope.pop()
        elif tok[0] == "$var":
            vtype, size, vid, name = tok[1], int(tok[2]), tok[3], tok[4]
            path = ".".join(scope + [name])
            cand = (classify_group(path), classify_kind(vtype), size)
            old = decls.get(vid)
            # one VCD id can be declared under several scopes (port aliases).
            # Keep the best declaration: a recognised module beats 'other'
            # (e.g. testbench-level aliases), then 'reg' beats 'net', then
            # the first one seen wins.
            rank = lambda d: (d[0] != OTHER, d[1] == "reg")
            if old is None or rank(cand) > rank(old):
                decls[vid] = cand
        elif tok[0] == "$enddefinitions":
            return ps_per_tick, decls


def hd(a, b):
    """Hamming distance of two VCD vector strings (no x/z counted)."""
    if len(a) < len(b):
        a = (a[0] if a[0] in "xz" else "0") * (len(b) - len(a)) + a
    elif len(b) < len(a):
        b = (b[0] if b[0] in "xz" else "0") * (len(a) - len(b)) + b
    n = 0
    for x, y in zip(a, b):
        if x != y and x in "01" and y in "01":
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("windows")
    ap.add_argument("--clk-ns", type=float, default=10.0)
    ap.add_argument("--ncycles", type=int, default=18)
    ap.add_argument("--show", default="", help="comma list of cycles to print, e.g. 13,16")
    ap.add_argument("--out", default="per_module_t.csv")
    a = ap.parse_args()

    wins = []
    with open(a.windows, newline="") as fh:
        for row in csv.DictReader(fh):
            wins.append((float(row["begin_ps"]), float(row["end_ps"]), int(row["group"])))
    wins.sort()
    begins = [w[0] for w in wins]
    grp = np.array([w[2] for w in wins])
    clk_ps = a.clk_ns * 1000.0
    ntr, ncy = len(wins), a.ncycles

    with open(a.vcd, "r") as f:
        ps_per_tick, decls = parse_header(f)
        labels = sorted({(g, k) for g, k, _ in decls.values()})
        col = {gk: i for i, gk in enumerate(labels)}
        counts = np.zeros((ntr, ncy, len(labels)), dtype=np.int32)

        last, cur_w, cur_t = {}, -1, 0.0
        for line in f:
            c = line[0]
            if c == "#":
                cur_t = int(line[1:]) * ps_per_tick
                i = bisect.bisect_right(begins, cur_t) - 1
                cur_w = i if (i >= 0 and cur_t < begins[i] + ncy * clk_ps) else -1
                continue
            if c in "01xzXZ":
                vid, val = line[1:].strip(), c.lower()
            elif c in "bB":
                val, vid = line[1:].split()
                val = val.lower()
            else:
                continue
            old = last.get(vid)
            last[vid] = val
            if cur_w < 0 or old is None:
                continue
            d = hd(old, val)
            if d == 0:
                continue
            cyc = int((cur_t - begins[cur_w]) // clk_ps)
            if 0 <= cyc < ncy:
                g, k, _ = decls[vid]
                counts[cur_w, cyc, col[(g, k)]] += d

    # Welch t per (module, kind, cycle)
    x0, x1 = counts[grp == 0].astype(float), counts[grp == 1].astype(float)
    n0, n1 = len(x0), len(x1)
    if n0 < 2 or n1 < 2:
        sys.exit("need >=2 traces in each group")
    m0, m1 = x0.mean(0), x1.mean(0)
    v0, v1 = x0.var(0, ddof=1), x1.var(0, ddof=1)
    den = np.sqrt(v0 / n0 + v1 / n1)
    with np.errstate(divide="ignore", invalid="ignore"):
        t = np.where(den > 0, (m0 - m1) / den, np.where(np.abs(m0 - m1) > 0, np.inf, 0.0))

    show = [int(s) for s in a.show.split(",") if s.strip()]
    print(f"{ntr} traces ({n0} group-0, {n1} group-1), {ncy} cycles, clk {a.clk_ns} ns")
    hdr = f"{'module':<11}{'kind':<5}{'max|t|':>9}{'@cyc':>6}{'leak cyc':>9}"
    hdr += "".join(f"{'|t|@'+str(s):>10}" for s in show) + "   mean toggles/cycle"
    print(hdr)
    for (g, k), i in col.items():
        at = np.abs(t[:, i])
        row = f"{g:<11}{k:<5}{np.nanmax(at):9.1f}{int(np.nanargmax(at)):6d}{int((at > 4.5).sum()):9d}"
        row += "".join(f"{at[s]:10.1f}" if s < ncy else f"{'-':>10}" for s in show)
        row += f"   {counts[:, :, i].mean():.1f}"
        print(row)

    with open(a.out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["module", "kind", "cycle", "t", "mean_g0", "mean_g1", "var_g0", "var_g1"])
        for (g, k), i in col.items():
            for cy in range(ncy):
                w.writerow([g, k, cy, f"{t[cy, i]:.4f}", f"{m0[cy, i]:.3f}", f"{m1[cy, i]:.3f}",
                            f"{v0[cy, i]:.3f}", f"{v1[cy, i]:.3f}"])
    print(f"per-cycle table written to {a.out}")


if __name__ == "__main__":
    main()
