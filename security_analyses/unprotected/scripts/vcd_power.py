#!/usr/bin/env python3
"""
vcd_power.py -- streaming VCD -> per-cycle power-proxy traces.

Single parse pass over the VCD produces three proxies simultaneously:

    P_reg   Hamming Distance on sequential elements only.
            sum over registers of popcount(v_new XOR v_old), accumulated
            per clock cycle. This is the classical HD model and is the
            proxy that transfers most directly to a gate-level result,
            because flip-flop output transitions dominate switched
            capacitance in a datapath.

    P_comb  Toggle count on every internal combinational net in the
            dumped scope. Captures the multiplier array's internal
            switching, which HD-on-registers is blind to. In a Baugh-
            Wooley array this is where most of the activity lives.

    P_tot   P_reg + P_comb. Composite proxy.

All three are unweighted bit counts. No net capacitance weighting is
applied, because at RTL there is no capacitance to weight with -- a
fanout- or width-weighted proxy at this tier would be a fabricated
precision. Weighting belongs at Tier 1 (Joules, post-layout parasitics).

KNOWN AND LOAD-BEARING LIMITATION
---------------------------------
Zero-delay RTL simulation collapses every combinational transition in a
cycle onto a single timestamp. Glitches -- the dominant leakage source
in unprotected arithmetic, and the mechanism that breaks most first-order
masking schemes -- are therefore invisible to P_comb. A Tier 0 result
showing no leakage means the *infrastructure* works. It is not evidence
that a design is secure, and must never be reported as such. Security
claims require Tier 1: gate-level simulation with SDF back-annotation
and pulse filtering disabled.

Usage
-----
    python3 vcd_power.py --vcd traces/pe.vcd --meta traces/pe.meta.csv \
                         --out traces/pe.npz
"""

import argparse
import csv
import gzip
import io
import os
import re
import sys
import time

import numpy as np

# ---------------------------------------------------------------------
# VCD variable types that represent sequential storage.
# ---------------------------------------------------------------------
REG_TYPES = {"reg", "integer", "time", "supply0", "supply1"}
# 'reg' in a VCD only means "declared as reg in Verilog". A combinational
# always @(*) block driving a reg (e.g. y_comb in activation_unit.v) is
# misclassified as sequential by that rule alone. Use --comb-regex to
# move such nets into the combinational bucket; the default patterns
# below catch the common naming conventions in this design.
DEFAULT_COMB_REGEX = r"(_comb$|_next$|_nxt$|^y_comb$)"

# Clock ports are dumped along with the rest of the DUT scope. They carry no
# data dependence, so they add a constant offset to P_comb.
DEFAULT_EXCLUDE_REGEX = r"(^|\.)(clk|clock|clk_i)$"


def _open_maybe_gz(path):
    """Accepts a plain .vcd, a .vcd.gz, or '-' for stdin.

    stdin matters for large runs: Icarus can dump FST (far smaller than
    VCD) and fst2vcd will stream it back without ever materialising the
    VCD on disk:

        vvp -fst build/tb_array8x8.vvp +NTRACES=5000 +TAG=arr8
        fst2vcd traces/arr8.fst | \
          python3 py/vcd_power.py --vcd - --meta traces/arr8.meta.csv \
                                  --out traces/arr8.npz
    """
    if path == "-":
        return sys.stdin
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "r", encoding="utf-8", errors="replace")


def parse_timescale(tokens):
    """'1ps' or '1','ps' -> nanoseconds per VCD tick."""
    s = "".join(tokens).strip()
    m = re.match(r"([0-9]+)\s*([munpf]?s)", s)
    if not m:
        raise ValueError("unparseable $timescale: %r" % s)
    mag = int(m.group(1))
    unit = m.group(2)
    to_ns = {"s": 1e9, "ms": 1e6, "us": 1e3, "ns": 1.0, "ps": 1e-3, "fs": 1e-6}[unit]
    return mag * to_ns


def normalize(val, width):
    """Left-extend a VCD vector value to `width` chars, per IEEE 1364 rules."""
    if len(val) >= width:
        return val[-width:]
    pad = val[0] if val[0] in "xXzZ" else "0"
    return pad * (width - len(val)) + val


class VcdVar:
    __slots__ = ("width", "is_reg", "names", "v_int", "v_str")

    def __init__(self, width, is_reg, name):
        self.width = width
        self.is_reg = is_reg
        self.names = [name]
        self.v_int = None      # int when the value is fully 0/1
        self.v_str = None      # normalized string when it contains x/z


# ---------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------
def parse_header(fh, scope_filter=None, reg_regex=None, comb_regex=None,
                 exclude_regex=None):
    ns_per_tick = 1.0
    scope = []
    vars_by_id = {}
    reg_re = re.compile(reg_regex) if reg_regex else None
    comb_re = re.compile(comb_regex) if comb_regex else None
    excl_re = re.compile(exclude_regex) if exclude_regex else None

    pending = []
    dropped_ids = set()
    for line in fh:
        toks = line.split()
        if not toks:
            continue
        i = 0
        while i < len(toks):
            tk = toks[i]
            if tk == "$timescale":
                buf = []
                i += 1
                while i < len(toks) and toks[i] != "$end":
                    buf.append(toks[i]); i += 1
                if not buf:
                    pending = ["timescale"]
                else:
                    ns_per_tick = parse_timescale(buf)
            elif pending == ["timescale"] and tk != "$end":
                ns_per_tick = parse_timescale([tk])
                pending = []
            elif tk == "$scope":
                # $scope module name $end
                if i + 2 < len(toks):
                    scope.append(toks[i + 2])
                i = len(toks)
                break
            elif tk == "$upscope":
                if scope:
                    scope.pop()
                i = len(toks)
                break
            elif tk == "$var":
                # $var <type> <width> <id> <ref> [range] $end
                vtype = toks[i + 1]
                width = int(toks[i + 2])
                vid = toks[i + 3]
                ref = toks[i + 4]
                full = ".".join(scope + [ref])
                keep = True
                if scope_filter and not full.startswith(scope_filter):
                    keep = False
                if keep and excl_re and excl_re.search(full):
                    keep = False
                if not keep:
                    dropped_ids.add(vid)
                if keep:
                    is_reg = vtype in REG_TYPES
                    if reg_re and reg_re.search(full):
                        is_reg = True
                    if comb_re and comb_re.search(full):
                        is_reg = False
                    if vid in vars_by_id:
                        v = vars_by_id[vid]
                        v.names.append(full)
                        # aliases: a flop output aliased to a wire is still
                        # a flop output.
                        v.is_reg = v.is_reg or is_reg
                    else:
                        vars_by_id[vid] = VcdVar(width, is_reg, full)
                i = len(toks)
                break
            elif tk == "$enddefinitions":
                for vid in list(dropped_ids):
                    if vid in vars_by_id:
                        dropped_ids.discard(vid)   # aliased into a kept net
                return ns_per_tick, vars_by_id, dropped_ids
            i += 1
    raise ValueError("VCD header ended without $enddefinitions")


# ---------------------------------------------------------------------
# Body
# ---------------------------------------------------------------------
def parse_body(fh, vars_by_id, dropped_ids=frozenset(), skip_xz=True,
               progress=False):
    """
    Returns
        times   int64 array of VCD tick timestamps that carried activity
        reg_hd  int64 array, register Hamming Distance at that timestamp
        comb_hd int64 array, combinational toggle count at that timestamp
        stats   dict of diagnostics
    """
    times, reg_hd, comb_hd = [], [], []
    cur_t = 0
    acc_r = 0
    acc_c = 0
    absorb = True          # true until the first real value-change section
    n_xz_skipped = 0
    n_unknown_id = 0
    started = False
    t0 = time.time()
    nlines = 0

    def flush():
        nonlocal acc_r, acc_c
        if acc_r or acc_c:
            times.append(cur_t)
            reg_hd.append(acc_r)
            comb_hd.append(acc_c)
        acc_r = 0
        acc_c = 0

    for line in fh:
        nlines += 1
        if progress and (nlines % 2000000 == 0):
            sys.stderr.write("  ...%d M lines, %.0f s\n"
                             % (nlines // 1000000, time.time() - t0))
        line = line.strip()
        if not line:
            continue
        c0 = line[0]

        if c0 == "#":
            flush()
            cur_t = int(line[1:])
            started = True
            continue

        if c0 == "$":
            # $dumpvars / $dumpon / $dumpoff / $dumpall carry checkpoint
            # values, not transitions. Absorb them without counting.
            # $dumpoff in particular writes x to every net; counting it
            # would inject a huge false transition at every window edge.
            if line.startswith(("$dumpvars", "$dumpon", "$dumpoff", "$dumpall")):
                absorb = True
            elif line.startswith("$end"):
                absorb = False
            continue

        # ---- value change ----
        if c0 in "bB":
            sp = line.find(" ")
            val = line[1:sp]
            vid = line[sp + 1:].strip()
        elif c0 in "rR":
            continue                      # real-valued nets: no bit model
        else:
            val = c0
            vid = line[1:].strip()

        v = vars_by_id.get(vid)
        if v is None:
            if vid not in dropped_ids:
                n_unknown_id += 1
            continue

        clean = val.find("x") < 0 and val.find("z") < 0 \
            and val.find("X") < 0 and val.find("Z") < 0

        if clean:
            new_int = int(val, 2)
            new_str = None
        else:
            new_int = None
            new_str = normalize(val.lower(), v.width)

        if absorb or not started:
            v.v_int, v.v_str = new_int, new_str
            continue

        # ---- Hamming Distance ----
        hd = 0
        if v.v_int is not None and new_int is not None:
            hd = (v.v_int ^ new_int).bit_count()
        else:
            old_s = v.v_str if v.v_str is not None else (
                format(v.v_int, "0%db" % v.width) if v.v_int is not None else None)
            new_s = new_str if new_str is not None else format(new_int, "0%db" % v.width)
            if old_s is None:
                hd = 0                     # first ever value: no transition
            else:
                old_s = normalize(old_s, v.width)
                for a, b in zip(old_s, new_s):
                    if a == b:
                        continue
                    if a in "xz" or b in "xz":
                        n_xz_skipped += 1
                        if not skip_xz:
                            hd += 1
                    else:
                        hd += 1

        v.v_int, v.v_str = new_int, new_str
        if hd:
            if v.is_reg:
                acc_r += hd
            else:
                acc_c += hd

    flush()

    stats = {
        "n_lines": nlines,
        "n_xz_transitions": n_xz_skipped,
        "n_unknown_id": n_unknown_id,
        "n_vars": len(vars_by_id),
        "n_reg_vars": sum(1 for v in vars_by_id.values() if v.is_reg),
        "n_reg_bits": sum(v.width for v in vars_by_id.values() if v.is_reg),
        "n_comb_bits": sum(v.width for v in vars_by_id.values() if not v.is_reg),
        "parse_seconds": time.time() - t0,
    }
    return (np.asarray(times, dtype=np.int64),
            np.asarray(reg_hd, dtype=np.int64),
            np.asarray(comb_hd, dtype=np.int64),
            stats)


# ---------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------
def read_meta(path):
    hdr = {}
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#"):
                k, _, v = line[1:].strip().partition("=")
                hdr[k.strip()] = v.strip()
            elif line.startswith("trace_id"):
                continue
            elif line.strip():
                tid, grp, t0, t1 = line.split(",")
                rows.append((int(tid), grp.strip(), float(t0), float(t1)))
    if not rows:
        raise ValueError("no trace windows in %s" % path)
    return hdr, rows


# ---------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------
def build_matrices(times_ticks, reg_hd, comb_hd, ns_per_tick, hdr, rows):
    period = float(hdr["clk_period_ns"])
    ncyc = int(hdr["capture_cycles"])
    ntr = len(rows)

    t_ns = times_ticks.astype(np.float64) * ns_per_tick

    P_reg = np.zeros((ntr, ncyc), dtype=np.float64)
    P_comb = np.zeros((ntr, ncyc), dtype=np.float64)
    labels = np.zeros(ntr, dtype=np.int8)

    starts = np.array([r[2] for r in rows])
    order = np.argsort(t_ns)
    t_sorted = t_ns[order]
    r_sorted = reg_hd[order]
    c_sorted = comb_hd[order]

    dropped = 0
    for i, (tid, grp, ts, te) in enumerate(rows):
        labels[i] = 1 if grp == "R" else 0
        lo = np.searchsorted(t_sorted, ts - 0.5 * period, side="left")
        hi = np.searchsorted(t_sorted, te + 0.5 * period, side="left")
        if hi <= lo:
            continue
        seg_t = t_sorted[lo:hi]
        # A "cycle" spans [posedge - T/2, posedge + T/2). Stimulus is driven
        # on the negedge preceding the sampling posedge, so the resulting
        # combinational activity lands in the same bin as the register
        # update it causes. Using rint() around the posedge instead would
        # split a cycle's activity across two bins.
        bins = np.floor((seg_t - ts + 0.5 * period) / period).astype(np.int64)
        ok = (bins >= 0) & (bins < ncyc)
        dropped += int((~ok).sum())
        np.add.at(P_reg[i], bins[ok], r_sorted[lo:hi][ok])
        np.add.at(P_comb[i], bins[ok], c_sorted[lo:hi][ok])

    _ = starts  # kept for debugging convenience
    return P_reg, P_comb, labels, dropped


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vcd", required=True,
                    help="VCD file (.vcd, .vcd.gz, or '-' for stdin)")
    ap.add_argument("--meta", required=True, help="sidecar .meta.csv from the TB")
    ap.add_argument("--out", required=True, help="output .npz")
    ap.add_argument("--scope", default=None,
                    help="only count nets whose hierarchical path starts with this")
    ap.add_argument("--reg-regex", default=None,
                    help="force matching nets into the sequential bucket")
    ap.add_argument("--comb-regex", default=DEFAULT_COMB_REGEX,
                    help="force matching nets into the combinational bucket "
                         "(default catches always @(*) regs named *_comb/*_next)")
    ap.add_argument("--exclude-regex", default=DEFAULT_EXCLUDE_REGEX,
                    help="drop matching nets entirely. Default drops the clock "
                         "port, which otherwise contributes a constant 2 "
                         "toggles/cycle to P_comb -- harmless to the t-test "
                         "(zero variance) but it distorts the reported "
                         "bits/cycle figures.")
    ap.add_argument("--count-xz", action="store_true",
                    help="count transitions involving x/z as toggles "
                         "(default: skip them, which is what you want for RTL)")
    ap.add_argument("--progress", action="store_true")
    args = ap.parse_args()

    hdr, rows = read_meta(args.meta)
    print("[vcd] dut=%s mode=%s target=%s ntraces=%d capture=%s cycles"
          % (hdr.get("dut"), hdr.get("mode"), hdr.get("tvla_target"),
             len(rows), hdr.get("capture_cycles")))

    with _open_maybe_gz(args.vcd) as fh:
        ns_per_tick, vars_by_id, dropped_ids = parse_header(
            fh, scope_filter=args.scope, reg_regex=args.reg_regex,
            comb_regex=args.comb_regex, exclude_regex=args.exclude_regex)
        print("[vcd] timescale = %g ns/tick, %d dumped nets"
              % (ns_per_tick, len(vars_by_id)))
        times, reg_hd, comb_hd, stats = parse_body(
            fh, vars_by_id, dropped_ids=dropped_ids,
            skip_xz=not args.count_xz, progress=args.progress)

    print("[vcd] %(n_reg_vars)d sequential nets (%(n_reg_bits)d bits), "
          "%(n_comb_bits)d combinational bits" % stats)
    print("[vcd] parsed %(n_lines)d lines in %(parse_seconds).1f s; "
          "%(n_xz_transitions)d x/z transitions %(xz_note)s"
          % dict(stats, xz_note=("counted" if args.count_xz else "skipped")))
    if stats["n_unknown_id"]:
        print("[vcd] WARNING: %d value changes for filtered-out ids"
              % stats["n_unknown_id"])

    P_reg, P_comb, labels, dropped = build_matrices(
        times, reg_hd, comb_hd, ns_per_tick, hdr, rows)
    P_tot = P_reg + P_comb

    if dropped:
        print("[vcd] WARNING: %d activity events fell outside a capture "
              "window bin -- check FLUSH/CAPTURE sizing" % dropped)

    nF = int((labels == 0).sum())
    nR = int((labels == 1).sum())
    print("[vcd] matrices %s  (fixed=%d, random=%d)" % (P_reg.shape, nF, nR))
    print("[vcd] mean P_reg=%.1f  P_comb=%.1f  P_tot=%.1f bits/cycle"
          % (P_reg.mean(), P_comb.mean(), P_tot.mean()))

    if P_reg.sum() == 0:
        print("[vcd] ERROR: P_reg is identically zero. Either the DUT has no "
              "registers in the dumped scope, or the capture windows do not "
              "line up with the VCD timeline.")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    np.savez_compressed(
        args.out,
        P_reg=P_reg, P_comb=P_comb, P_tot=P_tot, labels=labels,
        clk_period_ns=float(hdr["clk_period_ns"]),
        capture_cycles=int(hdr["capture_cycles"]),
        dut=hdr.get("dut", ""), mode=hdr.get("mode", ""),
        tvla_target=hdr.get("tvla_target", ""), seed=hdr.get("seed", ""),
        n_reg_bits=stats["n_reg_bits"], n_comb_bits=stats["n_comb_bits"],
    )
    print("[vcd] wrote %s" % args.out)


if __name__ == "__main__":
    main()
