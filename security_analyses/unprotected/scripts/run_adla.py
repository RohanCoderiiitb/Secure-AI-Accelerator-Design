#!/usr/bin/env python3
"""
run_adla.py -- driver: .npz power traces -> Anderson-Darling leakage report.

Consumes exactly the same .npz files run_tvla.py does. No re-simulation.

    python3 run_adla.py --npz ../traces/pe_act.npz --compare --profile \
                        --plot ../out/pe_act --csv ../out/adla_summary.csv

Run the null dataset through it first, same discipline as TVLA:

    python3 run_adla.py --npz ../traces/pe_null.npz --null
"""

import argparse
import csv
import os

import numpy as np

import adla
import tvla

PROXIES = ("P_reg", "P_comb", "P_tot")
DEFAULT_SNRS = [np.inf, 100.0, 10.0, 1.0, 0.1]


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


def do_plots(outprefix, ad_by, t_by, ttd_by, thr_t):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping plots")
        return

    os.makedirs(os.path.dirname(os.path.abspath(outprefix)) or ".", exist_ok=True)

    # --- AD statistic profile ---
    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    n = ad_by[PROXIES[0]]["n_samples"]
    cycles = np.arange(n)
    for ax, p in zip(np.atleast_1d(axes), PROXIES):
        r = ad_by[p]
        s = np.maximum(r["stat"], 0.0)
        ax.plot(cycles, s, lw=1.4, color="darkorange")
        ax.axhline(r["threshold"], color="r", ls="--", lw=1.0,
                   label="perm. thr = %.2f" % r["threshold"])
        ax.fill_between(cycles, r["threshold"], s, where=(s > r["threshold"]),
                        alpha=0.25, color="red", label="detected")
        ax.set_ylabel("$A^2$ (%s)" % p)
        ax.set_ylim(bottom=0)
        ax.legend(fontsize=7, loc="upper right")
        ax.grid(alpha=0.3)
    np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle("Anderson-Darling statistic, fixed vs random")
    fig.tight_layout()
    fig.savefig(outprefix + "_adla.png", dpi=140)
    plt.close(fig)

    # --- ADLA vs TVLA overlay, normalised to each test's own threshold ---
    if t_by:
        fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
        for ax, p in zip(np.atleast_1d(axes), PROXIES):
            r = ad_by[p]
            ad_n = np.maximum(r["stat"], 0.0) / r["threshold"]
            t_n = np.abs(t_by[p]["t"]) / thr_t
            ax.plot(cycles, t_n, lw=1.3, label="TVLA  |t|/4.5", color="steelblue")
            ax.plot(cycles, ad_n, lw=1.3, label="ADLA  $A^2$/thr", color="darkorange")
            ax.axhline(1.0, color="r", ls="--", lw=1.0)
            ax.set_ylabel(p)
            ax.set_yscale("log")
            ax.legend(fontsize=7, loc="upper right")
            ax.grid(alpha=0.3, which="both")
        np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
        fig.suptitle("Detection strength relative to each test's own threshold\n"
                     "(> 1 means detected; where the orange line rises above "
                     "blue, leakage is distributional rather than mean-shifted)",
                     fontsize=10)
        fig.tight_layout()
        fig.savefig(outprefix + "_adla_vs_tvla.png", dpi=140)
        plt.close(fig)

    # --- TTD vs SNR ---
    if ttd_by:
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for p in PROXIES:
            rows = ttd_by.get(p) or []
            xs = [r["snr"] for r in rows if np.isfinite(r["snr"]) and r["ttd"]]
            ys = [r["ttd"] for r in rows if np.isfinite(r["snr"]) and r["ttd"]]
            if xs:
                ax.loglog(xs, ys, "o-", label=p)
        ax.set_xlabel("SNR  (data-dependent variance / noise variance)")
        ax.set_ylabel("traces to detection, per group")
        ax.invert_xaxis()
        ax.grid(alpha=0.3, which="both")
        ax.legend()
        ax.set_title("ADLA traces to detection")
        fig.tight_layout()
        fig.savefig(outprefix + "_adla_ttd.png", dpi=140)
        plt.close(fig)

    print("[plot] wrote %s_adla*.png" % outprefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--null", action="store_true")
    ap.add_argument("--alpha", type=float, default=adla.DEFAULT_ALPHA)
    ap.add_argument("--perm", type=int, default=500,
                    help="label permutations for the empirical threshold")
    ap.add_argument("--compare", action="store_true",
                    help="also run Welch's t and report cycle-by-cycle agreement")
    ap.add_argument("--ttd", action="store_true")
    ap.add_argument("--snrs", type=float, nargs="*", default=None)
    ap.add_argument("--repeats", type=int, default=15)
    ap.add_argument("--noise-snr", type=float, default=None)
    ap.add_argument("--raw", action="store_true",
                    help="report raw A^2 instead of the standardised statistic")
    ap.add_argument("--profile", action="store_true")
    ap.add_argument("--plot", default=None)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    d, meta = load(args.npz)
    labels = d["labels"]
    T = meta["capture_cycles"]
    norm = not args.raw

    print("=" * 76)
    print("ADLA  dut=%s  mode=%s  target=%s" % (meta["dut"], meta["mode"],
                                                meta["tvla_target"]))
    print("      %d cycles @ %.1f ns, %d fixed / %d random traces"
          % (T, meta["clk_period_ns"], int((labels == 0).sum()),
             int((labels == 1).sum())))
    print("      statistic: Scholz-Stephens midrank-corrected two-sample A^2 %s"
          % ("(standardised)" if norm else "(raw)"))
    print("      threshold: empirical, %d label permutations, alpha=%g"
          % (args.perm, args.alpha))
    print("=" * 76)

    rng = np.random.default_rng(args.seed)
    P_by = {}
    for p in PROXIES:
        P = d[p].astype(np.float64)
        if args.noise_snr is not None:
            P = tvla.add_noise(P, args.noise_snr, rng)
        P_by[p] = P

    ad_by = {}
    if args.null:
        print("\nNULL TEST (fixed vs fixed)")
        ok = True
        degen = False
        for p in PROXIES:
            r = adla.null_check(P_by[p], labels, alpha=args.alpha,
                                n_perm=args.perm, seed=args.seed, normalize=norm)
            ad_by[p] = r
            print("  %-8s max A2 = %9.2f   threshold = %7.2f   "
                  "%d/%d samples over   [%s]"
                  % (p, r["max_stat"], r["threshold"], r["n_leaking"],
                     r["n_samples"], "PASS" if r["pass"] else "FAIL"))
            ok &= r["pass"]
            degen |= r["degenerate"]

        if degen:
            print("\n  Across-trace variance is identically zero, so every pooled\n"
                  "  sample has a single distinct value and A^2 = 0 by construction.\n"
                  "  This is the ADLA counterpart of t = 0 and carries the same\n"
                  "  meaning: the flush leaves no carryover and the group label is\n"
                  "  nowhere in the capture. Note that scipy.stats.anderson_ksamp\n"
                  "  raises ValueError on this input; adla.py returns 0 instead.\n"
                  "  Re-run with --noise-snr 1 to exercise the statistic itself.")
        print("\n  %s" % ("Null test PASSES." if ok else
                          "NULL TEST FAILS -- do not interpret fixed-vs-random."))
    else:
        print("\nFIXED vs RANDOM")
        for p in PROXIES:
            r = adla.detect(P_by[p], labels, alpha=args.alpha,
                            n_perm=args.perm, seed=args.seed, normalize=norm)
            ad_by[p] = r
            print(adla.format_report(p, r))
            if r["detected"]:
                print("           leaking cycles (half-split confirmed): %s"
                      % r["confirmed_cycles"])

    # ---- side-by-side with Welch's t on the identical data ----
    t_by = {}
    if args.compare and not args.null:
        print("\nAGREEMENT WITH TVLA (same traces, same cycles)")
        thr_t = tvla.threshold_for(T)
        for p in PROXIES:
            tr = tvla.detect(P_by[p], labels, thr=thr_t)
            t_by[p] = tr
            cmp = adla.compare_with_tvla(ad_by[p], tr, thr_t=thr_t)
            print("  %-8s both=%-3d  ADLA-only=%-3d  TVLA-only=%-3d  neither=%-3d"
                  % (p, len(cmp["both"]), len(cmp["adla_only"]),
                     len(cmp["tvla_only"]), len(cmp["neither"])))
            if cmp["adla_only"]:
                print("           ADLA-only cycles %s -- distributional leakage "
                      "with no mean shift" % cmp["adla_only"])
        print("\n  On unprotected hardware ADLA-only is normally near-empty: both\n"
              "  tests see the same strong mean difference. That column is the one\n"
              "  to watch once masking is applied, where it becomes the result.")

    if args.profile:
        for p in PROXIES:
            print("\n  A^2 profile, %s:" % p)
            print(adla.stat_profile_ascii(ad_by[p]["stat"], ad_by[p]["threshold"]))

    ttd_by = {}
    if args.ttd and not args.null:
        snrs = args.snrs if args.snrs else DEFAULT_SNRS
        print("\nADLA TRACES TO DETECTION vs SNR (per group, %d subsets each)"
              % args.repeats)
        print("  %-10s %-12s %-12s %-12s" % ("SNR", "P_reg", "P_comb", "P_tot"))
        for p in PROXIES:
            rows = []
            for i, s in enumerate(snrs):
                n, curve = adla.ttd(P_by[p], labels, snr=s, alpha=args.alpha,
                                    repeats=args.repeats, seed=args.seed + i,
                                    n_perm=max(args.perm // 5, 100),
                                    add_noise=tvla.add_noise)
                rows.append({"snr": s, "ttd": n, "curve": curve})
            ttd_by[p] = rows
        for i, s in enumerate(snrs):
            cells = [str(ttd_by[p][i]["ttd"]) if ttd_by[p][i]["ttd"]
                     else "> %d" % int((labels == 0).sum()) for p in PROXIES]
            print("  %-10s %-12s %-12s %-12s"
                  % ("inf" if not np.isfinite(s) else "%g" % s, *cells))

    if args.plot:
        do_plots(args.plot, ad_by, t_by, ttd_by,
                 tvla.threshold_for(T))

    if args.csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["npz", "dut", "mode", "target", "proxy", "n_fixed",
                            "n_random", "cycles", "alpha", "threshold",
                            "max_A2", "argmax_cycle", "n_leaking",
                            "n_confirmed", "degenerate"])
            for p in PROXIES:
                r = ad_by[p]
                w.writerow([args.npz, meta["dut"], meta["mode"],
                            meta["tvla_target"], p, r["n_fixed"], r["n_random"],
                            r["n_samples"], args.alpha, "%.4f" % r["threshold"],
                            "%.4f" % r["max_stat"], r["argmax_cycle"],
                            r["n_leaking"], r["n_confirmed"],
                            int(r["degenerate"])])
        print("[csv] appended to %s" % args.csv)

    print("\nReminder: Tier 0. ADLA's distribution sensitivity is what makes it\n"
          "worth running on MASKED designs, where means are equalised by\n"
          "construction. On unprotected RTL it mostly confirms what TVLA said.")


if __name__ == "__main__":
    main()
