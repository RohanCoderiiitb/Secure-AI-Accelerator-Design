#!/usr/bin/env python3
"""
calibrate_sensitivity.py -- how small a leak would our TVLA have caught?

A synthetic leak of KNOWN size is planted into the existing traces at one
clean cycle, and the exact same detection rule as the main analysis is
run on it many times (bootstrap resamples). The fraction of runs that
detect it is the detection probability. Plotting it against the leak
size gives the sensitivity curve; the size where it reaches 95% is the
minimum reliably detectable leak (Delta95).

The leak size is ALWAYS the injected group-mean difference Delta (in
toggles), never a raw scale factor: with a fixed secret whose Hamming
weight equals the random-group mean, a scale factor gives no mean
difference at all and a flat, misleading curve (shown in the pitfall
plot).

Leak models (planted at one cycle, added to the raw toggle counts)
  A  shift  : fixed group + Delta                       (main result)
  B  hd     : Hamming-distance leak, leak = k * HD(old, new) = k * (bits that
              flip when a register goes from its old byte to its new byte).
              Fixed group: always OLD_FIX -> NEW_FIX, which flips 6 bits.
              Random group: a random old byte -> a random new byte per trace,
              which flips 4 bits on average.
              k = Delta / (6 - 4)  -> mean difference exactly Delta
  V  var    : fixed group + (+a or -a, random sign)     (second order)
              mean difference 0, variance difference a^2
  S  spread : a total leak Delta (in sigma) split evenly over m neighbouring
              cycles c .. c+m-1; each cycle gets Delta/m of its own sigma as a
              mean shift; detected if ANY of the m cycles passes the rule
              (exactly what the whole-trace TVLA does); m = 1, 2, 4, 8

Detection rule (identical to tvla.detect / run_tvla_second_order.py)
  first order : Welch t, fixed vs random; detected if BOTH halves of the
                (resampled) data give |t| > 4.5 with the same sign
  second order: each group centred on its own mean and squared, then the
                same first-order rule

Usage
  python3 calibrate_sensitivity.py --npz traces/X.npz --out out/sensitivity_outputs/X
          [--ref traces/unprotected.npz] [--cycles 33,75,135] [--proxies P_tot,P_reg]
          [--n 1000,2500,5000] [--trials 200] [--levels 25] [--seed 1] [--snr inf]
          [--spread 1,2,4,8]
  python3 calibrate_sensitivity.py --self-test
"""

import argparse
import csv
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "unprotected", "scripts")))
import tvla  # noqa: E402

THR = tvla.THRESHOLD
HW8 = np.array([bin(v).count("1") for v in range(256)], dtype=np.float64)
OLD_FIX = 0x5A                      # model B, fixed group: register goes OLD_FIX -> NEW_FIX
NEW_FIX = OLD_FIX ^ 0x3F            # flips 6 bits
NEW_PITFALL = OLD_FIX ^ 0x0F        # flips 4 bits = random-group mean -> no first-order effect
HD_FIX = HW8[OLD_FIX ^ NEW_FIX]     # 6
HD_PIT = HW8[OLD_FIX ^ NEW_PITFALL] # 4
HD_RAND_MEAN = 4.0                  # random old -> random new: each bit flips with chance 1/2
MNAME = {"A": "shift", "B": "hd", "V": "var"}


def hd_random(rng, shape):
    """bits flipped going from a random old byte to a random new byte, per trace"""
    old = rng.integers(0, 256, size=shape)
    new = rng.integers(0, 256, size=shape)
    return HW8[old ^ new]


def mname(m):
    return MNAME.get(m, "spread m=%s" % m[1:] if m.startswith("S") else m)


# ---------------------------------------------------------------------
# statistics (row-wise, many trials at once; same formula as tvla.welch_t)
# ---------------------------------------------------------------------
def welch_rows(A, B):
    """A: (trials, nA), B: (trials, nB) -> t per trial (ddof=1, as tvla.welch_t)."""
    nA, nB = A.shape[1], B.shape[1]
    vA, vB = A.var(1, ddof=1) / nA, B.var(1, ddof=1) / nB
    d = np.sqrt(vA + vB)
    t = np.zeros(A.shape[0])
    nz = d > 0
    t[nz] = (A.mean(1)[nz] - B.mean(1)[nz]) / d[nz]
    return t


def csq_rows(X):
    """centre each row on its own mean, square (run_tvla_second_order.centered_square)."""
    return (X - X.mean(1, keepdims=True)) ** 2


def detect_rows(F, R, order):
    """Half-split rule of tvla.detect on each row-trial. F, R: (trials, n)."""
    h = F.shape[1] // 2
    hr = R.shape[1] // 2
    halves = ((F[:, :h], R[:, :hr]), (F[:, h:], R[:, hr:]))
    ts = []
    for f, r in halves:
        if order == 2:
            f, r = csq_rows(f), csq_rows(r)      # each half centred on its own group mean
        ts.append(welch_rows(f, r))
    t1, t2 = ts
    return (np.abs(t1) > THR) & (np.abs(t2) > THR) & (np.sign(t1) == np.sign(t2))


def wilson(k, n, z=1.96):
    p = k / n
    den = 1 + z * z / n
    c = (p + z * z / (2 * n)) / den
    h = z * np.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return np.minimum(c - h, p), np.maximum(c + h, p)      # guard rounding at p = 0 or 1


def phi(x):
    from math import erf, sqrt
    return 0.5 * (1 + np.vectorize(erf)(np.asarray(x) / sqrt(2)))


def theory_first(dsig, n):
    """P(detect) for a pure mean shift Delta/sigma, n traces per group, half-split rule:
    each half has n/2 per group, so its t has mean (Delta/sigma)*sqrt(n/4)."""
    mu = np.asarray(dsig) * np.sqrt(n / 4.0)
    return phi(mu - THR) ** 2 + phi(-mu - THR) ** 2


# ---------------------------------------------------------------------
# data preparation
# ---------------------------------------------------------------------
def neutralise(x, lab, order):
    """Remove any REAL group difference at the planting cycle so the only
    difference left is the one we inject. First order: equalise the group
    means. Second order: also equalise the group variances."""
    x = x.astype(np.float64).copy()
    mu = x.mean()
    sd = x.std(ddof=1)
    for g in (0, 1):
        s = lab == g
        xg = x[s]
        dev = xg - xg.mean()
        if order == 2 and xg.std(ddof=1) > 0:
            dev = dev * (sd / xg.std(ddof=1))
        x[s] = mu + dev
    return x


def pick_cycles(P, lab, k=3):
    """One clean, active cycle in each third of the capture window: real
    first- and second-order |t| < 2, nonzero spread; the one with median
    spread among those (a typical, not a best-case, cycle)."""
    F, R = P[lab == 0], P[lab == 1]
    t1, _ = tvla.welch_t(F, R)
    t2, _ = tvla.welch_t((F - F.mean(0)) ** 2, (R - R.mean(0)) ** 2)
    sd = P.std(0, ddof=1)
    ok = (np.abs(t1) < 2) & (np.abs(t2) < 2) & (sd > 0)
    T = P.shape[1]
    out = []
    for i in range(k):
        lo, hi = i * T // k, (i + 1) * T // k
        c = np.flatnonzero(ok[lo:hi]) + lo
        if c.size == 0:
            continue
        out.append(int(c[np.argsort(sd[c])[c.size // 2]]))
    return out


# ---------------------------------------------------------------------
# one sensitivity curve
# ---------------------------------------------------------------------
def curve(x, lab, model, n, levels, trials, seed, snr_sigma):
    """x: neutralised column (all traces). levels: injected size in toggles
    (Delta for A/B, a for V). Returns detection counts per level."""
    order = 2 if model == "V" else 1
    iF, iR = np.flatnonzero(lab == 0), np.flatnonzero(lab == 1)
    hits = np.zeros(len(levels), dtype=int)
    for li, lev in enumerate(levels):
        rng = np.random.default_rng([seed, sum(map(ord, model)), n, li])
        F = x[rng.choice(iF, size=(trials, n), replace=True)]       # bootstrap resample
        R = x[rng.choice(iR, size=(trials, n), replace=True)]
        if snr_sigma > 0:
            F = F + rng.normal(0, snr_sigma, F.shape)
            R = R + rng.normal(0, snr_sigma, R.shape)
        if model == "A":
            F = F + lev
        elif model == "B":
            k = lev / (HD_FIX - HD_RAND_MEAN)                       # mean difference = k*(6-4) = Delta
            F = F + k * HD_FIX
            R = R + k * hd_random(rng, R.shape)
        elif model == "P":                                          # pitfall: raw scale k, fixed HD = 4
            F = F + lev * HD_PIT
            R = R + lev * hd_random(rng, R.shape)
        elif model == "P6":                                         # same raw scale k, fixed HD = 6
            F = F + lev * HD_FIX
            R = R + lev * hd_random(rng, R.shape)
        elif model == "V":
            F = F + lev * rng.choice((-1.0, 1.0), size=F.shape)
        hits[li] = int(detect_rows(F, R, order).sum())
    return hits


def curve_spread(X, lab, n, totals, trials, seed, snr_sigma, sigs):
    """Spread model. X: neutralised columns of the m cycles, shape (traces, m).
    totals: total leak in units of sigma; cycle j gets (total/m)*sigma_j.
    The SAME resampled traces are used for all m cycles of a trial (a trace
    is one run of the hardware). Detected if any of the m cycles passes."""
    m = X.shape[1]
    iF, iR = np.flatnonzero(lab == 0), np.flatnonzero(lab == 1)
    hits = np.zeros(len(totals), dtype=int)
    for li, tot in enumerate(totals):
        rng = np.random.default_rng([seed, 83, m, n, li])
        idF = rng.choice(iF, size=(trials, n), replace=True)
        idR = rng.choice(iR, size=(trials, n), replace=True)
        any_hit = np.zeros(trials, dtype=bool)
        for j in range(m):
            F = X[idF, j] + (tot / m) * sigs[j]
            R = X[idR, j]
            if snr_sigma > 0:
                F = F + rng.normal(0, snr_sigma, F.shape)
                R = R + rng.normal(0, snr_sigma, R.shape)
            any_hit |= detect_rows(F, R, 1)
        hits[li] = int(any_hit.sum())
    return hits


def theory_spread(tot, m, n):
    """any of m independent cycles, each with Delta/sigma = tot/m."""
    p1 = theory_first(np.asarray(tot) / m, n)
    return 1 - (1 - p1) ** m


def delta95(levels, p, target=0.95):
    """first crossing of p >= target, linear interpolation; nan if never."""
    idx = np.flatnonzero(p >= target)
    if idx.size == 0:
        return float("nan")
    i = idx[0]
    if i == 0:
        return float(levels[0])
    x0, x1, y0, y1 = levels[i - 1], levels[i], p[i - 1], p[i]
    return float(x0 + (target - y0) * (x1 - x0) / (y1 - y0)) if y1 > y0 else float(x1)


# ---------------------------------------------------------------------
# trace-wide false alarm (whole trace, permuted labels)
# ---------------------------------------------------------------------
def tracewide_fpr(P, lab, nperm, seed, order):
    rng = np.random.default_rng([seed, 99, order])
    X = P.astype(np.float64)
    fa = 0
    for _ in range(nperm):
        l = rng.permutation(lab)
        Y = X
        if order == 2:
            Y = np.empty_like(X)
            for g in (0, 1):
                s = l == g
                Y[s] = (X[s] - X[s].mean(0)) ** 2
        fa += int(tvla.detect(Y, l, thr=THR)["detected"])
    return fa


# ---------------------------------------------------------------------
# self test
# ---------------------------------------------------------------------
def self_test():
    rng = np.random.default_rng(0)
    A, B = rng.normal(0, 1, (3, 400)), rng.normal(0.2, 1.3, (3, 300))
    t_rows = welch_rows(A, B)
    t_ref = np.array([tvla.welch_t(A[i][:, None], B[i][:, None])[0][0] for i in range(3)])
    assert np.allclose(t_rows, t_ref), "welch_rows differs from tvla.welch_t"
    P = rng.normal(100, 10, (4000, 1))
    lab = np.r_[np.zeros(2000, int), np.ones(2000, int)]
    rng.shuffle(lab)
    x = neutralise(P[:, 0], lab, 1)
    sig = x.std(ddof=1)
    lev = np.array([0, 0.1, 0.2, 0.3]) * sig
    h = curve(x, lab, "A", 2000, lev, 400, 1, 0.0) / 400
    th = theory_first(lev / sig, 2000)
    print("  shift model vs theory:", np.round(h, 3), np.round(th, 3))
    assert abs(h[0] - th[0]) < 0.01 and np.all(np.abs(h - th) < 0.08), "simulation does not match theory"
    hp = curve(x, lab, "P", 2000, np.array([0, 2.0, 4.0]), 300, 1, 0.0) / 300
    print("  pitfall (raw scale, fixed HD = 4):", np.round(hp, 3), "(must stay ~0)")
    assert hp.max() < 0.05
    Xs = np.stack([neutralise(rng.normal(100, 10, 4000), lab, 1) for _ in range(4)], 1)
    tots = np.array([0, 0.4, 0.8, 1.2])
    hs = curve_spread(Xs, lab, 2000, tots, 300, 1, 0.0, Xs.std(0, ddof=1)) / 300
    ths = theory_spread(tots, 4, 2000)
    print("  spread m=4 vs theory:", np.round(hs, 3), np.round(ths, 3))
    assert hs[0] < 0.01 and np.all(np.abs(hs - ths) < 0.1), "spread model does not match theory"
    print("[SELF-TEST] PASS")


# ---------------------------------------------------------------------
# plots
# ---------------------------------------------------------------------
def plots(out, tag, res, meta):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    for proxy in meta["proxies"]:
        cyc = meta["cycles"][proxy]
        nmax = max(meta["n"])
        # 1) main: shift model, every n, one panel per cycle, with theory
        fig, axes = plt.subplots(1, len(cyc), figsize=(5 * len(cyc), 4.2), squeeze=False)
        for ax, c in zip(axes[0], cyc):
            for n in meta["n"]:
                r = res[(proxy, c, "A", n)]
                ln = ax.errorbar(r["dsig"], r["p"], yerr=[r["p"] - r["lo"], r["hi"] - r["p"]],
                                 marker="o", ms=3, lw=1.2, capsize=2, label="n=%d / group" % n)
                ax.plot(r["dsig"], theory_first(r["dsig"], n), ls="--", lw=0.9, color=ln[0].get_color())
            ax.axhline(0.95, color="k", lw=0.6, ls=":")
            ax.axhline(0.05, color="k", lw=0.6, ls=":")
            ax.set_title("cycle %d  (sigma = %.1f toggles)" % (c, res[(proxy, c, "A", nmax)]["sigma"]))
            ax.set_xlabel("injected group-mean difference  Delta / sigma")
            ax.set_ylabel("detection probability")
            ax.set_ylim(-0.03, 1.03)
            ax.grid(alpha=0.3)
            ax.legend(fontsize=8)
        fig.suptitle("%s  %s: first-order sensitivity, mean-shift leak (dashed = theory)" % (tag, proxy))
        fig.tight_layout()
        fig.savefig(os.path.join(out, "%s__%s__sensitivity_shift.png" % (tag, proxy)), dpi=150)
        plt.close(fig)

        # 2) model A vs model B at the largest n, all cycles
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for c in cyc:
            for m, ls in (("A", "-"), ("B", "--")):
                r = res[(proxy, c, m, nmax)]
                ax.plot(r["dsig"], r["p"], ls=ls, marker="o", ms=3,
                        label="cycle %d, %s" % (c, "mean shift" if m == "A" else "Hamming-distance leak"))
        ax.axhline(0.95, color="k", lw=0.6, ls=":")
        ax.set_xlabel("injected group-mean difference  Delta / sigma")
        ax.set_ylabel("detection probability")
        ax.set_title("%s %s: leak models, n=%d / group" % (tag, proxy, nmax))
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(out, "%s__%s__sensitivity_models.png" % (tag, proxy)), dpi=150)
        plt.close(fig)

        # 3) pitfall: raw scale factor, fixed group flipping 4 bits vs 6 bits
        c = cyc[0]
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for m, lab in (("P6", "fixed group flips 6 bits"), ("P", "fixed group flips 4 bits (= random mean)")):
            r = res[(proxy, c, m, nmax)]
            ax.plot(r["lev"], r["p"], marker="o", ms=3, label=lab)
        ax.axhline(0.95, color="k", lw=0.6, ls=":")
        ax.set_xlabel("raw scale factor k  (toggles per flipped bit)")
        ax.set_ylabel("detection probability")
        ax.set_title("%s cycle %d: x-axis must be Delta, not raw k" % (proxy, c))
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8)
        fig.tight_layout()
        fig.savefig(os.path.join(out, "%s__%s__sensitivity_pitfall.png" % (tag, proxy)), dpi=150)
        plt.close(fig)

        # 4) second order: variance leak
        fig, axes = plt.subplots(1, len(cyc), figsize=(5 * len(cyc), 4.2), squeeze=False)
        for ax, c in zip(axes[0], cyc):
            for n in meta["n"]:
                r = res[(proxy, c, "V", n)]
                ax.errorbar(r["vsig"], r["p"], yerr=[r["p"] - r["lo"], r["hi"] - r["p"]],
                            marker="o", ms=3, lw=1.2, capsize=2, label="n=%d / group" % n)
            ax.axhline(0.95, color="k", lw=0.6, ls=":")
            ax.axhline(0.05, color="k", lw=0.6, ls=":")
            ax.set_title("cycle %d" % c)
            ax.set_xlabel("injected variance difference  a^2 / sigma^2")
            ax.set_ylabel("detection probability")
            ax.set_ylim(-0.03, 1.03)
            ax.grid(alpha=0.3)
            ax.legend(fontsize=8)
        fig.suptitle("%s  %s: second-order sensitivity, variance leak (equal means)" % (tag, proxy))
        fig.tight_layout()
        fig.savefig(os.path.join(out, "%s__%s__sensitivity_2nd_order.png" % (tag, proxy)), dpi=150)
        plt.close(fig)

        # 5) spread: total leak over m neighbouring cycles, largest n
        fig, axes = plt.subplots(1, len(cyc), figsize=(5 * len(cyc), 4.2), squeeze=False)
        for ax, c in zip(axes[0], cyc):
            for mm in meta["spread"]:
                key = (proxy, c, "S%d" % mm, nmax)
                if key not in res:
                    continue
                r = res[key]
                ln = ax.errorbar(r["dsig"], r["p"], yerr=[r["p"] - r["lo"], r["hi"] - r["p"]],
                                 marker="o", ms=3, lw=1.2, capsize=2,
                                 label="m=%d cycles (%d..%d)" % (mm, c, c + mm - 1))
                ax.plot(r["dsig"], theory_spread(r["dsig"], mm, nmax), ls="--", lw=0.9,
                        color=ln[0].get_color())
            ax.axhline(0.95, color="k", lw=0.6, ls=":")
            ax.axhline(0.05, color="k", lw=0.6, ls=":")
            ax.set_title("starting at cycle %d, n=%d / group" % (c, nmax))
            ax.set_xlabel("TOTAL leak over the m cycles  (sum of Delta/sigma)")
            ax.set_ylabel("detection probability (any of the m cycles)")
            ax.set_ylim(-0.03, 1.03)
            ax.grid(alpha=0.3)
            ax.legend(fontsize=8)
        fig.suptitle("%s  %s: leak spread thinly over m neighbouring cycles (dashed = theory)" % (tag, proxy))
        fig.tight_layout()
        fig.savefig(os.path.join(out, "%s__%s__sensitivity_spread.png" % (tag, proxy)), dpi=150)
        plt.close(fig)


# ---------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz")
    ap.add_argument("--out")
    ap.add_argument("--ref", help="unprotected npz, to compare Delta95 with its real leak")
    ap.add_argument("--cycles", default="", help="comma list; default = auto (one clean cycle per third)")
    ap.add_argument("--proxies", default="P_tot")
    ap.add_argument("--n", default="", help="traces per group, comma list; default 1000,2500,all")
    ap.add_argument("--trials", type=int, default=200)
    ap.add_argument("--levels", type=int, default=25)
    ap.add_argument("--nperm", type=int, default=200, help="label permutations for trace-wide false alarm")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--spread", default="1,2,4,8", help="m values for the spread model")
    ap.add_argument("--snr", type=float, default=float("inf"),
                    help="optional extra Gaussian noise, same SNR definition as tvla.add_noise")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        self_test()
        return
    if not a.npz or not a.out:
        ap.error("--npz and --out are required")

    d = np.load(a.npz, allow_pickle=True)
    lab = d["labels"].astype(int)
    nF, nR = int((lab == 0).sum()), int((lab == 1).sum())
    ngrp = min(nF, nR)
    ns = [int(v) for v in a.n.split(",")] if a.n else sorted({1000, 2500, ngrp})
    ns = [n for n in ns if 8 <= n <= ngrp]
    proxies = [p.strip() for p in a.proxies.split(",") if p.strip()]
    tag = os.path.basename(a.npz).replace(".npz", "")
    os.makedirs(a.out, exist_ok=True)
    ref = np.load(a.ref, allow_pickle=True) if a.ref and os.path.exists(a.ref) else None

    print("=" * 78)
    print("SENSITIVITY CALIBRATION  %s" % tag)
    print("  traces: %d fixed, %d random; threshold |t| > %.1f with half-split confirmation" % (nF, nR, THR))
    print("  n per group: %s; trials per point: %d; seed %d; extra noise SNR: %s"
          % (ns, a.trials, a.seed, a.snr))

    spread = [int(v) for v in a.spread.split(",") if v.strip()]
    res, meta = {}, {"proxies": proxies, "n": ns, "cycles": {}, "spread": spread}
    rows, summ = [], []
    for proxy in proxies:
        P = d[proxy].astype(np.float64)
        cyc = [int(c) for c in a.cycles.split(",")] if a.cycles else pick_cycles(P, lab)
        meta["cycles"][proxy] = cyc
        snr_sigma = 0.0
        if np.isfinite(a.snr):
            snr_sigma = float(np.sqrt(tvla.signal_power(P) / a.snr))

        F, R = P[lab == 0], P[lab == 1]
        t1_real, _ = tvla.welch_t(F, R)
        t2_real, _ = tvla.welch_t((F - F.mean(0)) ** 2, (R - R.mean(0)) ** 2)
        print("-" * 78)
        print("%s: planting cycles %s" % (proxy, cyc))

        for c in cyc:
            x1 = neutralise(P[:, c], lab, 1)
            x2 = neutralise(P[:, c], lab, 2)
            sig = float(np.sqrt(x1.var(ddof=1) + snr_sigma ** 2))
            mean_act = float(P[:, c].mean())
            dreal = float(F[:, c].mean() - R[:, c].mean())
            print("  cycle %d: sigma %.2f toggles, mean activity %.1f toggles, real t1 %.2f t2 %.2f "
                  "(real Delta %.3f removed before planting)" % (c, sig, mean_act, t1_real[c], t2_real[c], dreal))
            if sig <= 0:
                print("    skipped: no spread at this cycle")
                continue

            nmin = min(ns)
            dmax = (THR + 3.0) / np.sqrt(nmin / 4.0) * 1.25          # theory reaches ~1 for the smallest n
            dsig = np.linspace(0, dmax, a.levels)
            xc = x2 - x2.mean()
            s4 = float(np.mean(xc ** 4) - np.mean(xc ** 2) ** 2) + 2 * snr_sigma ** 4
            rmax = (THR + 3.0) * np.sqrt(2 * s4 / (nmin / 2.0)) / sig ** 2 * 1.3
            vsig = np.linspace(0, rmax, a.levels)

            for n in ns:
                for m in ("A", "B", "V"):
                    if m == "V":
                        lev = np.sqrt(vsig) * sig
                        h = curve(x2, lab, m, n, lev, a.trials, a.seed, snr_sigma)
                    else:
                        lev = dsig * sig
                        h = curve(x1, lab, m, n, lev, a.trials, a.seed, snr_sigma)
                    p = h / a.trials
                    lo, hi = wilson(h, a.trials)
                    r = {"lev": lev, "dsig": dsig, "vsig": vsig, "p": p, "lo": lo, "hi": hi, "sigma": sig}
                    res[(proxy, c, m, n)] = r
                    for i in range(len(lev)):
                        rows.append([proxy, c, m, n, "%.6g" % lev[i],
                                     "%.6g" % (vsig[i] if m == "V" else dsig[i]),
                                     h[i], a.trials, "%.4f" % p[i], "%.4f" % lo[i], "%.4f" % hi[i],
                                     "%.4f" % theory_first(dsig[i], n) if m == "A" else ""])
                    xs = vsig if m == "V" else dsig
                    d95 = delta95(xs, p)
                    tog = d95 * sig ** 2 if m == "V" else d95 * sig
                    summ.append({"proxy": proxy, "cycle": c, "model": m, "n": n, "sigma": sig,
                                 "mean_act": mean_act, "x95": d95, "tog95": tog, "fpr": p[0]})

            # pitfall at the largest n (first cycle only, it is an illustration)
            if c == cyc[0]:
                nmax = max(ns)
                k6 = (dsig * sig) / (HD_FIX - HD_RAND_MEAN)
                for m in ("P", "P6"):
                    h = curve(x1, lab, m, nmax, k6, a.trials, a.seed, snr_sigma)
                    p = h / a.trials
                    lo, hi = wilson(h, a.trials)
                    res[(proxy, c, m, nmax)] = {"lev": k6, "dsig": dsig, "vsig": vsig, "p": p,
                                                "lo": lo, "hi": hi, "sigma": sig}

            # spread model at the largest n: total leak split over cycles c .. c+m-1
            nmax = max(ns)
            T = P.shape[1]
            dmax1 = (THR + 3.0) / np.sqrt(nmax / 4.0) * 1.25
            tots = np.linspace(0, dmax1 * max(spread), 2 * a.levels)
            for mm in spread:
                if c + mm > T:
                    print("    spread m=%d skipped: runs past the end of the trace" % mm)
                    continue
                cols = list(range(c, c + mm))
                X = np.stack([neutralise(P[:, j], lab, 1) for j in cols], 1)
                sigs = np.sqrt(X.var(0, ddof=1) + snr_sigma ** 2)
                if np.any(sigs <= 0):
                    print("    spread m=%d skipped: a cycle in %s has no spread" % (mm, cols))
                    continue
                h = curve_spread(X, lab, nmax, tots, a.trials, a.seed, snr_sigma, sigs)
                p = h / a.trials
                lo, hi = wilson(h, a.trials)
                key = "S%d" % mm
                res[(proxy, c, key, nmax)] = {"lev": tots, "dsig": tots, "vsig": vsig, "p": p,
                                              "lo": lo, "hi": hi, "sigma": sig}
                for i in range(len(tots)):
                    rows.append([proxy, c, key, nmax, "%.6g" % ((tots[i] / mm) * sigs.sum()),
                                 "%.6g" % tots[i], h[i], a.trials, "%.4f" % p[i], "%.4f" % lo[i],
                                 "%.4f" % hi[i], "%.4f" % theory_spread(tots[i], mm, nmax)])
                d95 = delta95(tots, p)
                summ.append({"proxy": proxy, "cycle": c, "model": key, "n": nmax, "sigma": sig,
                             "mean_act": float(P[:, cols].mean(0).sum()), "x95": d95,
                             "tog95": (d95 / mm) * float(sigs.sum()), "fpr": p[0]})

        # trace-wide false alarm with permuted labels (any cycle, whole trace)
        fa1 = tracewide_fpr(P, lab, a.nperm, a.seed, 1)
        fa2 = tracewide_fpr(P, lab, a.nperm, a.seed, 2)
        meta.setdefault("fpr", {})[proxy] = (fa1, fa2)

        print("  %-6s %-12s %4s %10s %10s %12s %8s" % ("cycle", "model", "n", "D95/sigma", "D95 tog",
                                                    "% of mean", "FPR@0"))
        for s in summ:
            if s["proxy"] != proxy:
                continue
            name = mname(s["model"])
            if s["model"].startswith("S"):
                print("  %-6d %-12s %4d %10.4f %10.3f %11.3f%% %8.3f   (TOTAL over the cycles; per cycle %.4f sigma)"
                      % (s["cycle"], name, s["n"], s["x95"], s["tog95"],
                         100 * s["tog95"] / s["mean_act"] if s["mean_act"] else float("nan"), s["fpr"],
                         s["x95"] / int(s["model"][1:])))
            elif s["model"] == "V":
                print("  %-6d %-12s %4d %10s %10s %12s %8.3f   (a^2/sigma^2 = %.3f, a^2 = %.2f toggles^2)"
                      % (s["cycle"], name, s["n"], "-", "-", "-", s["fpr"], s["x95"], s["tog95"]))
            else:
                print("  %-6d %-12s %4d %10.4f %10.3f %11.3f%% %8.3f"
                      % (s["cycle"], name, s["n"], s["x95"], s["tog95"],
                         100 * s["tog95"] / s["mean_act"] if s["mean_act"] else float("nan"), s["fpr"]))
        print("  trace-wide false alarm (permuted labels, any cycle): first order %d/%d, second order %d/%d"
              % (fa1, a.nperm, fa2, a.nperm))

        if ref is not None and proxy in ref.files:
            Pu, lu = ref[proxy].astype(np.float64), ref["labels"].astype(int)
            du = np.abs(Pu[lu == 0].mean(0) - Pu[lu == 1].mean(0))
            cu = int(np.argmax(du))
            best = min((s["tog95"] for s in summ if s["proxy"] == proxy and s["model"] == "A"
                        and s["n"] == max(ns) and np.isfinite(s["tog95"])), default=float("nan"))
            worst = max((s["tog95"] for s in summ if s["proxy"] == proxy and s["model"] == "A"
                         and s["n"] == max(ns) and np.isfinite(s["tog95"])), default=float("nan"))
            print("  unprotected reference: largest real leak %.2f toggles at cycle %d" % (du[cu], cu))
            print("  -> with n=%d/group a leak %.1fx to %.1fx smaller than that is still caught at 95%%"
                  % (max(ns), du[cu] / worst, du[cu] / best))
            meta.setdefault("ref", {})[proxy] = (float(du[cu]), cu)

    with open(os.path.join(a.out, "%s__sensitivity_curves.csv" % tag), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["proxy", "cycle", "model", "n_per_group", "injected_toggles",
                    "x_axis (Delta/sigma; a^2/sigma^2 for var; total Delta/sigma for spread)",
                    "detected", "trials", "p_detect", "ci95_low", "ci95_high", "theory (shift, spread)"])
        w.writerows(rows)
    with open(os.path.join(a.out, "%s__sensitivity_summary.csv" % tag), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["proxy", "cycle", "model", "n_per_group", "sigma_toggles", "mean_activity",
                    "x95 (Delta/sigma; a^2/sigma^2 for var; total Delta/sigma for spread)",
                    "toggles95 (Delta; a^2 for var; total over the cycles for spread)",
                    "false_alarm_at_0", "tracewide_fa_1st", "tracewide_fa_2nd", "nperm"])
        for s in summ:
            fa1, fa2 = meta["fpr"][s["proxy"]]
            w.writerow([s["proxy"], s["cycle"], mname(s["model"]), s["n"],
                        "%.4f" % s["sigma"], "%.2f" % s["mean_act"], "%.5f" % s["x95"], "%.4f" % s["tog95"],
                        "%.4f" % s["fpr"], fa1, fa2, a.nperm])
    plots(a.out, tag, res, meta)
    print("-" * 78)
    print("written to %s" % a.out)
    print("=" * 78)


if __name__ == "__main__":
    main()
