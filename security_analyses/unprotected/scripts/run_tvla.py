#!/usr/bin/env python3
"""
run_tvla.py -- driver: .npz power traces -> TVLA report.

Runs the Welch test on all three power proxies (P_reg, P_comb, P_tot),
prints the per-cycle t profile, computes TTD as a function of SNR, and
optionally writes plots and a CSV of the results.

Typical sequence for one DUT:

    # 1. null test FIRST -- infrastructure validation
    vvp build/tb_pe.vvp +NTRACES=2000 +MODE=null +TAG=pe_null
    python3 py/vcd_power.py --vcd traces/pe_null.vcd \
                            --meta traces/pe_null.meta.csv \
                            --out traces/pe_null.npz
    python3 py/run_tvla.py --npz traces/pe_null.npz --null

    # 2. only if the null test passes:
    vvp build/tb_pe.vvp +NTRACES=2000 +MODE=tvla +TAG=pe_tvla
    python3 py/vcd_power.py --vcd traces/pe_tvla.vcd \
                            --meta traces/pe_tvla.meta.csv \
                            --out traces/pe_tvla.npz
    python3 py/run_tvla.py --npz traces/pe_tvla.npz --ttd --plot out/pe
"""

import argparse
import csv
import json
import os

import numpy as np

import tvla

PROXIES = ("P_reg", "P_comb", "P_tot")
DEFAULT_SNRS = [np.inf, 100.0, 10.0, 1.0, 0.1, 0.01]


def load(npz_path):
    d = np.load(npz_path, allow_pickle=False)
    meta = {
        "dut": str(d["dut"]),
        "mode": str(d["mode"]),
        "tvla_target": str(d["tvla_target"]),
        "clk_period_ns": float(d["clk_period_ns"]),
        "capture_cycles": int(d["capture_cycles"]),
        "n_reg_bits": int(d["n_reg_bits"]),
        "n_comb_bits": int(d["n_comb_bits"]),
    }
    return d, meta


def do_plots(outprefix, res_by_proxy, ttd_by_proxy, P_by_proxy, labels, thr):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping plots")
        return

    os.makedirs(os.path.dirname(os.path.abspath(outprefix)) or ".", exist_ok=True)

    # --- t profile ---
    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    for ax, p in zip(np.atleast_1d(axes), PROXIES):
        t = res_by_proxy[p]["t"]
        ax.plot(np.abs(t), lw=1.2)
        ax.axhline(thr, color="r", ls="--", lw=0.8)
        ax.axhline(-thr, color="r", ls="--", lw=0.8)
        ax.set_ylabel("|t| (%s)" % p)
        ax.grid(alpha=0.3)
    np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle("Welch t-statistic, fixed vs random")
    fig.tight_layout()
    fig.savefig(outprefix + "_t.png", dpi=140)
    plt.close(fig)

    # --- mean traces ---
    fig, ax = plt.subplots(figsize=(9, 4))
    for p in PROXIES:
        P = P_by_proxy[p]
        ax.plot(P[labels == 0].mean(0), lw=1.2, label="%s fixed" % p)
        ax.plot(P[labels == 1].mean(0), lw=1.0, ls="--", label="%s random" % p)
    ax.set_xlabel("clock cycle")
    ax.set_ylabel("mean toggled bits")
    ax.legend(fontsize=7, ncol=3)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(outprefix + "_mean.png", dpi=140)
    plt.close(fig)

    # --- TTD vs SNR ---
    if ttd_by_proxy:
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for p in PROXIES:
            rows = ttd_by_proxy.get(p) or []
            xs = [r["snr"] for r in rows if np.isfinite(r["snr"]) and r["ttd"]]
            ys = [r["ttd"] for r in rows if np.isfinite(r["snr"]) and r["ttd"]]
            if xs:
                ax.loglog(xs, ys, "o-", label=p)
        ax.set_xlabel("SNR  (data-dependent variance / noise variance)")
        ax.set_ylabel("traces to detection, per group")
        ax.invert_xaxis()
        ax.grid(alpha=0.3, which="both")
        ax.legend()
        fig.tight_layout()
        fig.savefig(outprefix + "_ttd.png", dpi=140)
        plt.close(fig)
    print("[plot] wrote %s_{t,mean,ttd}.png" % outprefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--null", action="store_true",
                    help="treat as a fixed-vs-fixed null dataset")
    ap.add_argument("--shuffle", type=int, default=200,
                    help="label permutations for the empirical null (with --null)")
    ap.add_argument("--ttd", action="store_true", help="compute TTD vs SNR")
    ap.add_argument("--snrs", type=float, nargs="*", default=None)
    ap.add_argument("--repeats", type=int, default=20)
    ap.add_argument("--noise-snr", type=float, default=None,
                    help="inject noise at this SNR before the main t-test")
    ap.add_argument("--bonferroni", action="store_true")
    ap.add_argument("--profile", action="store_true",
                    help="print the per-cycle |t| bar chart")
    ap.add_argument("--plot", default=None, help="output prefix for PNGs")
    ap.add_argument("--csv", default=None, help="append a summary row here")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    d, meta = load(args.npz)
    labels = d["labels"]
    T = meta["capture_cycles"]
    thr = tvla.threshold_for(T, bonferroni=args.bonferroni)

    print("=" * 74)
    print("TVLA  dut=%s  mode=%s  target=%s" % (meta["dut"], meta["mode"], meta["tvla_target"]))
    print("      %d cycles @ %.1f ns, %d fixed / %d random traces"
          % (T, meta["clk_period_ns"], int((labels == 0).sum()), int((labels == 1).sum())))
    print("      dumped scope: %d sequential bits, %d combinational bits"
          % (meta["n_reg_bits"], meta["n_comb_bits"]))
    print("      threshold |t| > %.2f%s" % (thr, "  (Bonferroni)" if args.bonferroni else ""))
    if meta["mode"] == "null" and not args.null:
        print("      NOTE: dataset was generated in null mode; re-run with --null")
    print("=" * 74)

    rng = np.random.default_rng(args.seed)
    P_by = {}
    res_by = {}
    for p in PROXIES:
        P = d[p].astype(np.float64)
        if args.noise_snr is not None:
            P = tvla.add_noise(P, args.noise_snr, rng)
        P_by[p] = P

    if args.null:
        print("\nNULL TEST (fixed vs fixed)")
        ok = True
        degenerate = False
        for p in PROXIES:
            r = tvla.null_check(P_by[p], labels, thr=thr, seed=args.seed,
                                n_shuffle=args.shuffle)
            res_by[p] = r
            verdict = "PASS" if r["pass"] else "FAIL"
            print("  %-8s max|t| = %7.2f   %d/%d samples over threshold "
                  "(expect ~%.3f)   [%s]"
                  % (p, r["max_abs_t"], r["n_leaking"], r["n_samples"],
                     r["expected_false_positives"], verdict))
            if args.shuffle:
                print("           permutation null: p95 max|t| = %.2f, "
                      "p99 = %.2f, P(max|t| > thr) = %.3f"
                      % (r["perm_max_abs_t_p95"], r["perm_max_abs_t_p99"],
                         r["perm_exceedance"]))
            ok &= r["pass"]
            degenerate |= r["zero_variance"]

        if degenerate:
            print("\n  Across-trace variance is identically zero. In noiseless "
                  "RTL that is\n  the expected and desirable outcome: identical "
                  "inputs into a deterministic\n  model give identical toggle "
                  "counts, which proves the inter-trace flush\n  leaves no state "
                  "carryover and the group label is nowhere in the capture.\n"
                  "  It also means the t-test itself was never exercised, so a "
                  "noise-injected\n  pass is run below to check the estimator.")
            print("\n  NULL TEST WITH INJECTED NOISE (SNR = 1)")
            rng2 = np.random.default_rng(args.seed + 1234)
            for p in PROXIES:
                base = d[p].astype(np.float64)
                # give the degenerate traces a synthetic signal floor so the
                # noise has something to be relative to
                sp = base.mean() * 0.01
                Pn = base + rng2.normal(0.0, max(sp, 1.0), size=base.shape)
                r2 = tvla.null_check(Pn, labels, thr=thr, seed=args.seed,
                                     n_shuffle=max(args.shuffle, 200))
                print("  %-8s max|t| = %7.2f   permutation p95 = %.2f, "
                      "P(max|t| > thr) = %.3f   [%s]"
                      % (p, r2["max_abs_t"], r2["perm_max_abs_t_p95"],
                         r2["perm_exceedance"], "PASS" if r2["pass"] else "FAIL"))
                ok &= r2["pass"]
        print("\n  %s" % ("Null test PASSES. Fixed-vs-random results from this "
                          "setup can be interpreted."
                          if ok else
                          "NULL TEST FAILS. The capture infrastructure is "
                          "producing a group difference on identical inputs. "
                          "Do NOT interpret any fixed-vs-random result until "
                          "this is resolved."))
    else:
        print("\nFIXED vs RANDOM")
        for p in PROXIES:
            r = tvla.detect(P_by[p], labels, thr=thr)
            res_by[p] = r
            print(tvla.format_report(p, r))
            if r["detected"]:
                print("           leaking cycles (half-split confirmed): %s"
                      % r["confirmed_cycles"])

    if args.profile:
        for p in PROXIES:
            print("\n  |t| profile, %s:" % p)
            print(tvla.t_profile_ascii(res_by[p]["t"], thr=thr))

    ttd_by = {}
    if args.ttd and not args.null:
        snrs = args.snrs if args.snrs else DEFAULT_SNRS
        print("\nTRACES TO DETECTION vs SNR (per group, median over %d subsets)"
              % args.repeats)
        print("  %-10s %-12s %-12s %-12s" % ("SNR", "P_reg", "P_comb", "P_tot"))
        rows = {p: tvla.ttd_vs_snr(P_by[p], labels, snrs, thr=thr,
                                   repeats=args.repeats, seed=args.seed)
                for p in PROXIES}
        ttd_by = rows
        for i, s in enumerate(snrs):
            cells = []
            for p in PROXIES:
                v = rows[p][i]["ttd"]
                cells.append(str(v) if v else "> %d" % int((labels == 0).sum()))
            print("  %-10s %-12s %-12s %-12s"
                  % ("inf" if not np.isfinite(s) else "%g" % s, *cells))
        print("\n  A single TTD number is not a reportable result. The curve "
              "above is.\n  Quote TTD at the SNR of your measurement setup, or "
              "quote the whole curve.")

    if args.plot:
        do_plots(args.plot, res_by, ttd_by, P_by, labels, thr)

    if args.csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["npz", "dut", "mode", "target", "proxy", "n_fixed",
                            "n_random", "cycles", "threshold", "max_abs_t",
                            "argmax_cycle", "n_leaking", "n_confirmed"])
            for p in PROXIES:
                r = res_by[p]
                w.writerow([args.npz, meta["dut"], meta["mode"],
                            meta["tvla_target"], p, r["n_fixed"], r["n_random"],
                            r["n_samples"], "%.3f" % r["threshold"],
                            "%.4f" % r["max_abs_t"], r["argmax_cycle"],
                            r["n_leaking"], r.get("n_confirmed", "")])
        print("[csv] appended to %s" % args.csv)

    print("\nReminder: this is Tier 0. Zero-delay RTL has no glitches, so these "
          "\nnumbers validate the pipeline. They are not a security claim about "
          "\nany design, and they will understate leakage in masked variants.")


if __name__ == "__main__":
    main()
