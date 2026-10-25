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

Usage
    python3 run_tvla_second_order.py --self-test
    python3 run_tvla_second_order.py --npz X_null.npz --null
    python3 run_tvla_second_order.py --npz X_wt.npz --compare --profile \
        --ttd --plot ../out/second_order_tvla_outputs/X --csv .../summary.csv
"""

import argparse
import csv
import os
import sys

import numpy as np

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
# Self-test on synthetic 2-share leakage
# ---------------------------------------------------------------------
def self_test(seed=0):
    """
    Synthetic first-order masked leakage: secret x (8 bits), mask m,
    one sample = HW(m) + HW(x ^ m) + noise. Fixed x vs random x.
    The mean of HW(m) + HW(x^m) is 8 whatever x is, so first order must
    not detect; the variance depends on HW(x), so second order must.
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
    return ok


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
    print("SECOND-ORDER TVLA (univariate, centered-squared)")
    print("  dut=%s  mode=%s  target=%s  %d cycles, %d fixed / %d random"
          % (str(d["dut"]), str(d["mode"]), str(d["tvla_target"]), T,
             int((labels == 0).sum()), int((labels == 1).sum())))
    print("  threshold |t| > %.2f" % thr)
    print("=" * 74)

    P_by = {p: d[p].astype(np.float64) for p in PROXIES}
    P2_by = {p: centered_square(P_by[p], labels) for p in PROXIES}
    r1_by, r2_by = {}, {}

    if args.null:
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
    else:
        if args.compare:
            print("\nFIRST ORDER (same data, for reference)")
            for p in PROXIES:
                r1_by[p] = tvla.detect(P_by[p], labels, thr=thr)
                print(tvla.format_report(p, r1_by[p]))
        print("\nSECOND ORDER")
        for p in PROXIES:
            r2_by[p] = tvla.detect(P2_by[p], labels, thr=thr)
            print(tvla.format_report(p, r2_by[p]))
            if r2_by[p]["detected"]:
                print("           leaking cycles (half-split confirmed): %s"
                      % r2_by[p]["confirmed_cycles"])

    if args.profile:
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

    if args.plot:
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
        print("[csv] appended to %s" % args.csv)

    print("\nReminder: Tier 0 (zero-delay RTL, no glitches). A clean first-order"
          "\nresult here validates the masking logic, not its security in silicon.")


if __name__ == "__main__":
    main()
