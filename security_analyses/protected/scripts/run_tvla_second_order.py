#!/usr/bin/env python3
"""
run_tvla_second_order.py -- univariate second-order TVLA on .npz traces.

For a first-order masked design with both shares processed in PARALLEL
(the weight-masked multiplier: two share datapaths switch in the same
clock cycle), both shares land in the same time sample. The leakage is
then in the VARIANCE of each sample, not its mean, so the standard
univariate second-order preprocessing is used (Schneider & Moradi,
CHES 2015):

    for each group g separately, at every sample t:
        y = (x - mean_g(t))^2
    then the ordinary Welch t-test on y, |t| > 4.5.

Centering uses each group's OWN mean. Using a pooled mean would let a
first-order mean difference leak into the second-order statistic.

Expected outcome for a correct 2-share design at Tier 0:
    first-order  TVLA : no detection
    second-order TVLA : detection  (a 2-share scheme is only first-order
                        secure; seeing this confirms the masking is
                        active and the analysis can see it)

Noise for TTD is added to the RAW traces before preprocessing, which is
what a real measurement does.

BIVARIATE second order (--bivariate)
    When the two shares switch in DIFFERENT cycles t1 and t2, no single
    sample depends on the secret, so the univariate test above is blind.
    The bivariate test combines the two samples (Schneider & Moradi,
    CHES 2015, centered product):

        for each group g separately, for every pair t1 < t2:
            y = (x(t1) - mean_g(t1)) * (x(t2) - mean_g(t2))
        then the ordinary Welch t-test on y, |t| > 4.5, half-split confirmed.

    All pairs are tested (or only those with lag <= --max-lag). With ~T^2/2
    pairs the per-pair 4.5 threshold is checked against an empirical
    label-permutation null (--biv-perm), and --biv-bonferroni raises the
    threshold for the number of pairs.

Usage
    python3 run_tvla_second_order.py --self-test
    python3 run_tvla_second_order.py --npz X_null.npz --null
    python3 run_tvla_second_order.py --npz X_wt.npz --compare --profile \
        --ttd --plot ../out/second_order_tvla_outputs/X --csv .../summary.csv
    python3 run_tvla_second_order.py --npz X_wt.npz --bivariate --no-univariate \
        --biv-plot ../out/second_order_tvla_outputs/X --csv .../summary.csv
"""

import argparse
import csv
import os
import sys

import numpy as np
from statistics import NormalDist

# reuse the first-order statistics from the unprotected flow
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "unprotected", "scripts")))
import tvla  # noqa: E402

PROXIES = ("P_reg", "P_comb", "P_tot")
DEFAULT_SNRS = [np.inf, 100.0, 10.0, 1.0, 0.1]


# ---------------------------------------------------------------------
# Preprocessing
# ---------------------------------------------------------------------
def centered_square(P, labels):
    """Per-group centering, then square. Returns a new array."""
    P = np.asarray(P, dtype=np.float64)
    Y = np.empty_like(P)
    for g in (0, 1):
        sel = labels == g
        if sel.any():
            X = P[sel]
            Y[sel] = (X - X.mean(0)) ** 2
    return Y


def detect2(P, labels, thr):
    return tvla.detect(centered_square(P, labels), labels, thr=thr)


def ttd2(P, labels, snr, thr, repeats=20, seed=0, quantile=0.5):
    """Traces to detection for the second-order test. Noise is added to
    the raw subset, then the subset is centered and squared."""
    rng = np.random.default_rng(seed)
    idxF = np.flatnonzero(labels == 0)
    idxR = np.flatnonzero(labels == 1)
    nmax = min(len(idxF), len(idxR))
    grid = sorted(set(int(x) for x in np.geomspace(20, nmax, num=16).astype(int)))
    curve, found = [], None
    for n in grid:
        hits = 0
        for _ in range(repeats):
            fs = rng.choice(idxF, size=n, replace=False)
            rs = rng.choice(idxR, size=n, replace=False)
            sub = np.vstack([P[fs], P[rs]]).astype(np.float64)
            lab = np.concatenate([np.zeros(n, np.int8), np.ones(n, np.int8)])
            sub = tvla.add_noise(sub, snr, rng)
            hits += int(detect2(sub, lab, thr)["detected"])
        rate = hits / repeats
        curve.append((n, rate))
        if found is None and rate >= quantile:
            found = n
    return found, curve


# ---------------------------------------------------------------------
# Bivariate (two-cycle) second order
# ---------------------------------------------------------------------
def _center_groups(P, labels):
    """Each group centered on its OWN mean (same rule as centered_square)."""
    P = np.asarray(P, dtype=np.float64)
    return P[labels == 0] - P[labels == 0].mean(0), P[labels == 1] - P[labels == 1].mean(0)


def _pair_t(CF, CR):
    """Welch t of the centered product for ALL pairs at once.
    CF, CR: centered (n, T) matrices. mean(x1*x2) = X^T X / n and
    E[(x1*x2)^2] = (X^2)^T (X^2) / n, so no (n, T, T) array is built."""
    out = []
    for C in (CF, CR):
        n = C.shape[0]
        m = C.T @ C / n
        q = (C * C).T @ (C * C) / n
        v = np.maximum(q - m * m, 0.0) * n / (n - 1)
        out.append((m, v, n))
    (mF, vF, nF), (mR, vR, nR) = out
    d = np.sqrt(vF / nF + vR / nR)
    t = np.zeros_like(d)
    nz = d > 0
    t[nz] = (mF[nz] - mR[nz]) / d[nz]
    return t


def biv_threshold(n_pairs, bonferroni):
    if not bonferroni:
        return tvla.THRESHOLD
    alpha = 1e-5 / max(n_pairs, 1)
    return float(abs(NormalDist().inv_cdf(alpha / 2.0)))


def bivariate(P, labels, thr=None, min_lag=1, max_lag=None, bonferroni=False,
              n_perm=0, seed=0):
    """Bivariate second-order TVLA over every pair (t1, t2), t1 < t2.
    Returns the |t| matrix, the confirmed pairs (half-split, same sign)
    and, with n_perm > 0, the label-permutation null of max|t|."""
    P = np.asarray(P, dtype=np.float64)
    T = P.shape[1]
    i, j = np.triu_indices(T, 1)
    lag = j - i
    keep = lag >= min_lag
    if max_lag:
        keep &= lag <= max_lag
    i, j = i[keep], j[keep]
    if thr is None:
        thr = biv_threshold(len(i), bonferroni)

    CF, CR = _center_groups(P, labels)
    t = _pair_t(CF, CR)
    fh, rh = CF.shape[0] // 2, CR.shape[0] // 2
    t1 = _pair_t(CF[:fh], CR[:rh])
    t2 = _pair_t(CF[fh:], CR[rh:])

    tp, t1p, t2p = t[i, j], t1[i, j], t2[i, j]
    conf = (np.abs(t1p) > thr) & (np.abs(t2p) > thr) & (np.sign(t1p) == np.sign(t2p))
    over = np.abs(tp) > thr
    k = int(np.argmax(np.abs(tp))) if len(tp) else 0
    order = np.argsort(-np.abs(tp))
    res = {
        "t_matrix": t, "pairs_i": i, "pairs_j": j, "t_pairs": tp,
        "threshold": thr, "n_pairs": int(len(i)), "n_samples": T,
        "max_abs_t": float(abs(tp[k])) if len(tp) else 0.0,
        "argmax_pair": (int(i[k]), int(j[k])) if len(tp) else (-1, -1),
        "n_leaking": int(over.sum()), "n_confirmed": int(conf.sum()),
        "confirmed_pairs": [(int(i[q]), int(j[q]), float(tp[q]), float(t1p[q]), float(t2p[q]))
                            for q in order if conf[q]],
        "top_pairs": [(int(i[q]), int(j[q]), float(tp[q]), float(t1p[q]), float(t2p[q]))
                      for q in order[:10]],
        "n_fixed": int(CF.shape[0]), "n_random": int(CR.shape[0]),
        "detected": bool(conf.any()),
    }
    if n_perm > 0:
        rng = np.random.default_rng(seed)
        lab = np.asarray(labels).copy()
        maxima = np.empty(n_perm)
        for q in range(n_perm):
            rng.shuffle(lab)
            a, b = _center_groups(P, lab)
            maxima[q] = np.max(np.abs(_pair_t(a, b)[i, j]))
        res["perm_p95"] = float(np.percentile(maxima, 95))
        res["perm_p99"] = float(np.percentile(maxima, 99))
        res["perm_exceedance"] = float(np.mean(maxima > thr))
        res["n_perm"] = n_perm
    return res


def format_biv(name, r):
    s = ("  %-8s max|t| = %7.2f at cycles (%d, %d)  (%d/%d pairs > %.2f, %d confirmed by half-split)"
         % (name, r["max_abs_t"], r["argmax_pair"][0], r["argmax_pair"][1],
            r["n_leaking"], r["n_pairs"], r["threshold"], r["n_confirmed"]))
    if "perm_p95" in r:
        s += ("\n           permutation null (%d label shuffles): max|t| p95 = %.2f, p99 = %.2f, "
              "P(max|t| > thr) = %.3f" % (r["n_perm"], r["perm_p95"], r["perm_p99"], r["perm_exceedance"]))
    if r["confirmed_pairs"]:
        s += "\n           confirmed pairs (cycle1, cycle2: t, half1, half2):"
        for a, b, tt, h1, h2 in r["confirmed_pairs"][:20]:
            s += "\n             (%3d, %3d): %7.2f  %7.2f  %7.2f" % (a, b, tt, h1, h2)
        if len(r["confirmed_pairs"]) > 20:
            s += "\n             ... %d more" % (len(r["confirmed_pairs"]) - 20)
    else:
        s += "\n           strongest pairs (not confirmed):"
        for a, b, tt, h1, h2 in r["top_pairs"][:5]:
            s += "\n             (%3d, %3d): %7.2f  %7.2f  %7.2f" % (a, b, tt, h1, h2)
    return s


def biv_plots(prefix, rb_by, thr):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping bivariate plots")
        return
    os.makedirs(os.path.dirname(os.path.abspath(prefix)) or ".", exist_ok=True)
    names = [p for p in PROXIES if p in rb_by]

    # |t| for every pair (upper triangle), threshold-crossing pairs circled
    fig, axes = plt.subplots(1, len(names), figsize=(5.4 * len(names), 4.8), squeeze=False)
    for ax, p in zip(axes[0], names):
        r = rb_by[p]
        T = r["n_samples"]
        M = np.full((T, T), np.nan)
        M[r["pairs_i"], r["pairs_j"]] = np.abs(r["t_pairs"])
        vmax = max(thr * 1.5, np.nanmax(M) if np.isfinite(np.nanmax(M)) else thr)
        im = ax.imshow(M.T, origin="lower", cmap="viridis", vmin=0, vmax=vmax,
                       interpolation="nearest", aspect="auto")
        over = np.abs(r["t_pairs"]) > thr
        if over.any():
            ax.scatter(r["pairs_i"][over], r["pairs_j"][over], s=28, facecolors="none",
                       edgecolors="r", lw=1.0, label="|t| > %.1f" % thr)
        for a, b, *_ in r["confirmed_pairs"]:
            ax.scatter([a], [b], s=60, marker="x", c="r")
        ax.set_xlabel("cycle 1")
        ax.set_ylabel("cycle 2")
        ax.set_title("%s: max|t| %.2f at (%d, %d), %d confirmed"
                     % (p, r["max_abs_t"], r["argmax_pair"][0], r["argmax_pair"][1], r["n_confirmed"]),
                     fontsize=9)
        fig.colorbar(im, ax=ax, label="|t|")
        if over.any():
            ax.legend(fontsize=7, loc="upper left")
    fig.suptitle("Bivariate second-order Welch t (centered product of two cycles), fixed vs random")
    fig.tight_layout()
    fig.savefig(prefix + "__bivariate__t-heatmap.png", dpi=140)
    plt.close(fig)

    # for each cycle: the strongest pair it takes part in
    fig, axes = plt.subplots(len(names), 1, figsize=(9, 2.7 * len(names)), sharex=True, squeeze=False)
    for ax, p in zip(axes[:, 0], names):
        r = rb_by[p]
        T = r["n_samples"]
        best = np.zeros(T)
        a = np.abs(r["t_pairs"])
        np.maximum.at(best, r["pairs_i"], a)
        np.maximum.at(best, r["pairs_j"], a)
        ax.plot(best, lw=1.2)
        ax.axhline(thr, color="r", ls="--", lw=0.8)
        if "perm_p95" in r:
            ax.axhline(r["perm_p95"], color="gray", ls=":", lw=0.9, label="permutation p95")
            ax.legend(fontsize=7)
        ax.set_ylabel("max |t| (%s)" % p)
        ax.grid(alpha=0.3)
    axes[-1, 0].set_xlabel("clock cycle within capture window")
    fig.suptitle("Bivariate second order: strongest pair each cycle takes part in")
    fig.tight_layout()
    fig.savefig(prefix + "__bivariate__max-t-per-cycle.png", dpi=140)
    plt.close(fig)
    print("[plot] wrote %s__bivariate__{t-heatmap,max-t-per-cycle}.png" % prefix)


# ---------------------------------------------------------------------
# Self-test on synthetic 2-share leakage
# ---------------------------------------------------------------------
def self_test(seed=0):
    """
    Synthetic first-order masked leakage: secret x (8 bits), mask m.
    Univariate: one sample = HW(m) + HW(x ^ m) + noise. The mean is 8
    whatever x is, so first order must not detect; the variance depends
    on HW(x), so second order must.
    Bivariate: HW(m) in sample 0 and HW(x ^ m) in sample 1. Each sample
    alone is independent of x, so first order and univariate second order
    must not detect; their product (centered) depends on x, so the
    bivariate test must, at the pair (0, 1).
    """
    rng = np.random.default_rng(seed)
    n = 20000
    hw = np.array([bin(v).count("1") for v in range(256)])
    labels = np.repeat([0, 1], n // 2).astype(np.int8)
    rng.shuffle(labels)
    x = np.where(labels == 0, 0x00, rng.integers(0, 256, n))   # fixed x = 0
    m = rng.integers(0, 256, n)
    s = hw[m] + hw[x ^ m] + rng.normal(0, 0.5, n)
    P = np.stack([s, rng.normal(8, 1, n)], axis=1)              # 2 samples
    thr = tvla.THRESHOLD
    r1 = tvla.detect(P, labels, thr=thr)
    r2 = detect2(P, labels, thr)
    ok = (not r1["detected"]) and r2["detected"]
    print("SELF-TEST (synthetic 2-share masking, fixed x = 0 vs random x)")
    print("  first-order  max|t| = %6.2f  -> %s (expected: no detection)"
          % (r1["max_abs_t"], "detected" if r1["detected"] else "not detected"))
    print("  second-order max|t| = %6.2f  -> %s (expected: detection)"
          % (r2["max_abs_t"], "detected" if r2["detected"] else "not detected"))
    print("  %s" % ("PASS" if ok else "FAIL"))

    # bivariate: the two shares leak in DIFFERENT samples (0 and 1)
    s0 = hw[m] + rng.normal(0, 0.5, n)
    s1 = hw[x ^ m] + rng.normal(0, 0.5, n)
    Pb = np.stack([s0, s1, rng.normal(8, 1, n)], axis=1)
    b1 = tvla.detect(Pb, labels, thr=thr)
    b2 = detect2(Pb, labels, thr)
    bb = bivariate(Pb, labels, thr=thr)
    okb = (not b1["detected"]) and (not b2["detected"]) and bb["detected"] \
        and bb["argmax_pair"] == (0, 1)
    print("SELF-TEST (bivariate: share 1 in sample 0, share 2 in sample 1)")
    print("  first-order     max|t| = %6.2f  -> %s (expected: no detection)"
          % (b1["max_abs_t"], "detected" if b1["detected"] else "not detected"))
    print("  univariate 2nd  max|t| = %6.2f  -> %s (expected: no detection)"
          % (b2["max_abs_t"], "detected" if b2["detected"] else "not detected"))
    print("  bivariate 2nd   max|t| = %6.2f at %s -> %s (expected: detection at (0, 1))"
          % (bb["max_abs_t"], bb["argmax_pair"], "detected" if bb["detected"] else "not detected"))
    # the all-pairs matrix formula must equal the direct centered-product t
    CF, CR = _center_groups(Pb[:400], labels[:400])
    tf = _pair_t(CF, CR)[0, 1]
    tr = tvla.welch_t((CF[:, 0] * CF[:, 1])[:, None], (CR[:, 0] * CR[:, 1])[:, None])[0][0]
    okm = abs(tf - tr) < 1e-9
    print("  all-pairs formula == direct centered product: %s" % ("yes" if okm else "NO"))
    okb = okb and okm
    print("  %s" % ("PASS" if okb else "FAIL"))
    return ok and okb


# ---------------------------------------------------------------------
def do_plots(prefix, r1_by, r2_by, P2_by, labels, thr, ttd_by):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping plots")
        return
    os.makedirs(os.path.dirname(os.path.abspath(prefix)) or ".", exist_ok=True)

    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    for ax, p in zip(np.atleast_1d(axes), PROXIES):
        ax.plot(np.abs(r2_by[p]["t"]), lw=1.4, label="2nd order")
        if r1_by:
            ax.plot(np.abs(r1_by[p]["t"]), lw=1.0, ls="--", label="1st order")
        ax.axhline(thr, color="r", ls="--", lw=0.8)
        ax.set_ylabel("|t| (%s)" % p)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=7)
    np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle("Second-order (centered-squared) Welch t, fixed vs random")
    fig.tight_layout()
    fig.savefig(prefix + "_t.png", dpi=140)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 4))
    for p in PROXIES:
        Y = P2_by[p]
        ax.plot(Y[labels == 0].mean(0), lw=1.2, label="%s fixed" % p)
        ax.plot(Y[labels == 1].mean(0), lw=1.0, ls="--", label="%s random" % p)
    ax.set_xlabel("clock cycle")
    ax.set_ylabel("per-group variance (centered square)")
    ax.legend(fontsize=7, ncol=3)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(prefix + "_var.png", dpi=140)
    plt.close(fig)

    if ttd_by:
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for p in PROXIES:
            xs = [r["snr"] for r in ttd_by[p] if np.isfinite(r["snr"]) and r["ttd"]]
            ys = [r["ttd"] for r in ttd_by[p] if np.isfinite(r["snr"]) and r["ttd"]]
            if xs:
                ax.loglog(xs, ys, "o-", label=p)
        ax.set_xlabel("SNR")
        ax.set_ylabel("traces to detection, per group")
        ax.invert_xaxis()
        ax.grid(alpha=0.3, which="both")
        ax.legend()
        fig.tight_layout()
        fig.savefig(prefix + "_ttd.png", dpi=140)
        plt.close(fig)
    print("[plot] wrote %s_{t,var%s}.png" % (prefix, ",ttd" if ttd_by else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--null", action="store_true", help="fixed-vs-fixed dataset")
    ap.add_argument("--compare", action="store_true",
                    help="also print first-order results on the same data")
    ap.add_argument("--profile", action="store_true")
    ap.add_argument("--ttd", action="store_true")
    ap.add_argument("--snrs", type=float, nargs="*", default=None)
    ap.add_argument("--repeats", type=int, default=20)
    ap.add_argument("--plot", default=None)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--bivariate", action="store_true",
                    help="also run the bivariate (two-cycle) second-order test")
    ap.add_argument("--no-univariate", action="store_true",
                    help="skip the univariate second-order test (bivariate only)")
    ap.add_argument("--min-lag", type=int, default=1,
                    help="bivariate: smallest cycle distance t2 - t1 tested (default 1)")
    ap.add_argument("--max-lag", type=int, default=0,
                    help="bivariate: largest cycle distance tested (default 0 = all pairs)")
    ap.add_argument("--biv-bonferroni", action="store_true",
                    help="bivariate: raise 4.5 for the number of pairs tested")
    ap.add_argument("--biv-perm", type=int, default=100,
                    help="bivariate: label shuffles for the empirical null of max|t| (0 = off)")
    ap.add_argument("--biv-plot", default=None,
                    help="bivariate: plot prefix (writes <prefix>__bivariate__*.png)")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(0 if self_test(args.seed) else 1)
    if not args.npz:
        ap.error("--npz is required unless --self-test is given")

    d = np.load(args.npz, allow_pickle=False)
    labels = d["labels"]
    T = int(d["capture_cycles"])
    thr = tvla.THRESHOLD
    print("=" * 74)
    print("SECOND-ORDER TVLA (%s)" % ("bivariate, centered product of two cycles" if args.no_univariate and args.bivariate
          else "univariate, centered-squared" + (" + bivariate" if args.bivariate else "")))
    print("  dut=%s  mode=%s  target=%s  %d cycles, %d fixed / %d random"
          % (str(d["dut"]), str(d["mode"]), str(d["tvla_target"]), T,
             int((labels == 0).sum()), int((labels == 1).sum())))
    print("  threshold |t| > %.2f" % thr)
    print("=" * 74)

    P_by = {p: d[p].astype(np.float64) for p in PROXIES}
    P2_by = {p: centered_square(P_by[p], labels) for p in PROXIES}
    r1_by, r2_by, rb_by = {}, {}, {}
    univ = not args.no_univariate

    if args.null and univ:
        print("\nNULL TEST (fixed vs fixed), second order")
        ok = True
        for p in PROXIES:
            r = tvla.null_check(P2_by[p], labels, thr=thr, seed=args.seed, n_shuffle=200)
            r2_by[p] = r
            print("  %-8s max|t| = %7.2f   permutation p95 = %.2f   [%s]"
                  % (p, r["max_abs_t"], r["perm_max_abs_t_p95"],
                     "PASS" if r["pass"] else "FAIL"))
            ok &= r["pass"]
        print("\n  %s" % ("Null test PASSES." if ok else
                          "NULL TEST FAILS -- do not interpret fixed-vs-random results."))
    elif not args.null:
        if args.compare:
            print("\nFIRST ORDER (same data, for reference)")
            for p in PROXIES:
                r1_by[p] = tvla.detect(P_by[p], labels, thr=thr)
                print(tvla.format_report(p, r1_by[p]))
        if univ:
            print("\nSECOND ORDER (univariate)")
            for p in PROXIES:
                r2_by[p] = tvla.detect(P2_by[p], labels, thr=thr)
                print(tvla.format_report(p, r2_by[p]))
                if r2_by[p]["detected"]:
                    print("           leaking cycles (half-split confirmed): %s"
                          % r2_by[p]["confirmed_cycles"])

    if args.bivariate:
        print("\nSECOND ORDER, BIVARIATE (centered product of two cycles%s)"
              % (", NULL dataset" if args.null else ""))
        print("  pairs with lag %d..%s; threshold |t| > %s; half-split confirmation"
              % (args.min_lag, args.max_lag if args.max_lag else T - 1,
                 "Bonferroni over pairs" if args.biv_bonferroni else "%.2f" % thr))
        okb = True
        for p in PROXIES:
            rb_by[p] = bivariate(P_by[p], labels, min_lag=args.min_lag,
                                 max_lag=args.max_lag or None, bonferroni=args.biv_bonferroni,
                                 n_perm=args.biv_perm, seed=args.seed)
            print(format_biv(p, rb_by[p]))
            okb &= not rb_by[p]["detected"]
        print("\n  %s" % ("No confirmed bivariate leakage." if okb else
                          "BIVARIATE LEAKAGE CONFIRMED at the pairs listed above."))
        if args.biv_plot:
            biv_plots(args.biv_plot, rb_by, rb_by[PROXIES[0]]["threshold"])

    if args.profile and r2_by and not args.null:
        for p in PROXIES:
            print("\n  second-order |t| profile, %s:" % p)
            print(tvla.t_profile_ascii(r2_by[p]["t"], thr=thr))

    ttd_by = {}
    if args.ttd and not args.null:
        snrs = args.snrs if args.snrs else DEFAULT_SNRS
        print("\nSECOND-ORDER TRACES TO DETECTION vs SNR (per group, %d subsets)"
              % args.repeats)
        print("  %-10s %-12s %-12s %-12s" % ("SNR", "P_reg", "P_comb", "P_tot"))
        for p in PROXIES:
            ttd_by[p] = []
            for i, s in enumerate(snrs):
                n, curve = ttd2(P_by[p], labels, s, thr, repeats=args.repeats,
                                seed=args.seed + i)
                ttd_by[p].append({"snr": s, "ttd": n, "curve": curve})
        nmax = int(min((labels == 0).sum(), (labels == 1).sum()))
        for i, s in enumerate(snrs):
            cells = [str(ttd_by[p][i]["ttd"]) if ttd_by[p][i]["ttd"] else "> %d" % nmax
                     for p in PROXIES]
            print("  %-10s %-12s %-12s %-12s"
                  % ("inf" if not np.isfinite(s) else "%g" % s, *cells))

    if args.plot and r2_by:
        do_plots(args.plot, r1_by, r2_by, P2_by, labels, thr, ttd_by)

    if args.csv:
        os.makedirs(os.path.dirname(os.path.abspath(args.csv)) or ".", exist_ok=True)
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["npz", "dut", "mode", "target", "order", "proxy",
                            "n_fixed", "n_random", "cycles", "threshold",
                            "max_abs_t", "argmax_cycle", "n_leaking", "n_confirmed"])
            for order, res in (("1", r1_by), ("2", r2_by)):
                for p, r in res.items():
                    w.writerow([args.npz, str(d["dut"]), str(d["mode"]),
                                str(d["tvla_target"]), order, p,
                                r.get("n_fixed", ""), r.get("n_random", ""),
                                r["n_samples"], "%.3f" % r["threshold"],
                                "%.4f" % r["max_abs_t"], r["argmax_cycle"],
                                r["n_leaking"], r.get("n_confirmed", "")])
            for p, r in rb_by.items():
                w.writerow([args.npz, str(d["dut"]), str(d["mode"]),
                            str(d["tvla_target"]), "2-bivariate", p,
                            r["n_fixed"], r["n_random"], r["n_pairs"],
                            "%.3f" % r["threshold"], "%.4f" % r["max_abs_t"],
                            "%d-%d" % r["argmax_pair"], r["n_leaking"], r["n_confirmed"]])
        print("[csv] appended to %s" % args.csv)

    print("\nReminder: Tier 0 (zero-delay RTL, no glitches). A clean first-order"
          "\nresult here validates the masking logic, not its security in silicon.")


if __name__ == "__main__":
    main()
