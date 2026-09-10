#!/usr/bin/env python3
"""
run_qif.py -- driver: enumerated .npz -> quantitative leakage report.

    python3 qif_validate.py                       # ALWAYS first
    python3 run_qif.py --npz ../traces/qif_pe.npz --snr

Reports, per power proxy:
  * per-cycle MI  -- literally the "leaked bits per clock cycle" figure
  * L_min, H_inf(S|O)  -- one-guess vulnerability and bits remaining
  * three threat models when a context column is present
  * g-leakage vs tolerance eps -- the neural-network IP curve
  * MI vs SNR, computed semi-analytically rather than estimated

Every number is tagged EXACT or SAMPLED. Exact means the input space was
enumerated exhaustively, the channel is the true channel, and the figure
is a bound. Never merge the two in one column without the tag.
"""

import argparse
import csv
import os

import numpy as np

import qif_channel as qc
import qif_estimate as qe
import qif_measures as qm

PROXIES = ("P_reg", "P_comb", "P_tot")
DEFAULT_SNRS = [np.inf, 100.0, 10.0, 1.0, 0.1]
DEFAULT_EPS = (0, 1, 2, 4, 8, 16)


def load(path):
    d = np.load(path, allow_pickle=False)
    if "secret_val" not in d.files or np.all(d["secret_val"] == -1):
        raise SystemExit("%s has no secret column -- it was captured in TVLA "
                         "mode. Re-run the QIF testbench (MODE=qif)." % path)
    meta = {
        "dut": str(d["dut"]),
        "capture_cycles": int(d["capture_cycles"]),
        "clk_period_ns": float(d["clk_period_ns"]),
        "n_reg_bits": int(d["n_reg_bits"]),
        "n_comb_bits": int(d["n_comb_bits"]),
    }
    return d, meta


def do_plots(prefix, per_cycle, snr_curves, dut, secret_name):
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
        cyc_ax = np.arange(len(per_cycle[p]))
        ax.plot(cyc_ax, per_cycle[p], lw=1.4, marker="o", ms=3)
        ax.set_ylabel("MI bits (%s)" % p)
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.3)
    np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle(f"Per-Cycle Mutual Information for {dut} ({secret_name} as Secret)")
    fig.tight_layout()
    fig.savefig(prefix + "_mi.png", dpi=140)
    plt.close(fig)

    if snr_curves:
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for p in PROXIES:
            rows = [r for r in snr_curves[p] if np.isfinite(r["snr"])]
            if rows:
                ax.semilogx([r["snr"] for r in rows], [r["mi"] for r in rows],
                            "o-", label=p)
        ax.set_xlabel("SNR")
        ax.set_ylabel("MI, bits")
        ax.invert_xaxis()
        ax.grid(alpha=0.3, which="both")
        ax.legend()
        ax.set_title(
            f"Shannon Mutual Information vs Measurement SNR — "
            f"{dut} ({secret_name} as Secret)"
        )
        fig.tight_layout()
        fig.savefig(prefix + "_snr.png", dpi=140)
        plt.close(fig)
    print("[plot] wrote %s_{mi,snr}.png" % prefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--cycle", type=int, default=None,
                    help="cycle for the detailed report (default: argmax MI)")
    ap.add_argument("--snr", action="store_true",
                    help="MI vs SNR by Gaussian-mixture quadrature")
    ap.add_argument("--secret-name", default="Secret", help="name of the secret variable shown in plot titles")
    ap.add_argument("--snrs", type=float, nargs="*", default=None)
    ap.add_argument("--null", type=int, default=0,
                    help="permutation-null draws (sampled channels only)")
    ap.add_argument("--bins", type=int, default=None,
                    help="quantise the observable into this many bins")
    ap.add_argument("--plot", default=None)
    ap.add_argument("--csv", default=None)
    args = ap.parse_args()

    d, meta = load(args.npz)
    secret = d["secret_val"]
    # Group by context_id, not context_val: the value is a signed INT8 and
    # goes negative, which would fail a naive ">= 0 means present" test.
    # The id is always a non-negative enumeration index, with -1 reserved
    # for "this capture had no context dimension".
    context = d["context_id"]
    context_display = d["context_val"]
    T = meta["capture_cycles"]
    s_vals = np.unique(secret)
    has_ctx = bool(np.unique(context).size > 1 and not np.all(context == -1))

    counts = np.bincount(np.searchsorted(s_vals, secret))
    balanced = bool(np.all(counts == counts[0]))

    print("=" * 76)
    print("QIF  dut=%s" % meta["dut"])
    print("     %d traces, %d distinct secrets, %d cycles"
          % (secret.size, s_vals.size, T))
    print("     %d traces per secret, %s"
          % (counts[0], "balanced" if balanced else "UNBALANCED"))
    print("     secret range [%d, %d]   contexts marginalised over: %s"
          % (s_vals.min(), s_vals.max(),
             np.unique(context).size if has_ctx else "1 (single context)"))
    _ = context_display
    print("     H(S) = %.4f bits (uniform prior)" % np.log2(s_vals.size))
    print("=" * 76)

    if not balanced:
        print("\n  WARNING: trace counts per secret are not equal (min %d, max %d).\n"
              "  The channel is SAMPLED, not exact. Bias correction and the\n"
              "  permutation null apply -- run with --null." % (counts.min(), counts.max()))

    per_cycle, rows = {}, []
    print("\nPER-CYCLE MUTUAL INFORMATION (bits)")
    print("  cycle  " + "".join("%-24s" % p for p in PROXIES))
    for p in PROXIES:
        P = d[p].astype(np.float64)
        chans = qc.build_per_cycle(secret, P, secret_space=s_vals,
                                   n_bins=args.bins,
                                   expect_per_secret=int(counts[0]),
                                   proxy=p)
        per_cycle[p] = [qm.shannon_mi(c.C) for c in chans]
        rows.append(chans)
    for t in range(T):
        cells = "".join("%-24s" % ("%.4f  [%s]" % (per_cycle[p][t],
                        "EXACT" if rows[i][t].exact else "SAMP"))
                        for i, p in enumerate(PROXIES))
        print("  %5d  %s" % (t, cells))

    # MARGINAL THREAT MODEL ONLY.
    #
    # The attacker is assumed to know neither the secret nor the public
    # context. Context therefore stays unconditioned and is marginalised
    # out of p(o|s), so its variation acts as algorithmic noise rather
    # than as information the adversary holds. This is the conservative,
    # weakest-attacker assumption and the one reported here.
    #
    # Note the capture still enumerates contexts exhaustively -- that is
    # what makes the marginalisation exact rather than sampled. The
    # contexts are integrated over, not conditioned on.
    print("\n  Threat model: MARGINAL -- attacker knows neither the secret\n"
          "  nor the context. Context is marginalised out, so its variation\n"
          "  acts as algorithmic noise. Contexts are still enumerated in the\n"
          "  capture, which is what makes this marginalisation exact.")

    best = {p: int(np.argmax(per_cycle[p])) for p in PROXIES}
    cyc = args.cycle if args.cycle is not None else best["P_tot"]
    print("\n  peak cycle: " + ", ".join("%s=%d" % (p, best[p]) for p in PROXIES))

    print("\nDETAILED MEASURES AT CYCLE %d" % cyc)
    detail = {}
    for i, p in enumerate(PROXIES):
        ch = rows[i][cyc]
        m = qm.all_measures(ch.C)
        detail[p] = m
        print("  %-8s MI=%7.4f  L_min=%7.4f  H_inf(S|O)=%7.4f  "
              "|O|=%3d  [%s]"
              % (p, m["MI"], m["L_min"], m["H_inf_S_given_O"],
                 m["n_observations"], "EXACT" if ch.exact else "SAMPLED"))
    print("\n  H_inf(S|O) is the effective bits of secret remaining after one\n"
          "  observation. H(S) = %.2f, so anything well below that is recovery."
          % np.log2(s_vals.size))

    snr_curves = {}
    if args.snr:
        snrs = args.snrs if args.snrs else DEFAULT_SNRS
        print("\nMUTUAL INFORMATION vs SNR (bits, semi-analytic)")
        print("  %-10s %s" % ("SNR", "".join("%-14s" % p for p in PROXIES)))
        for p in PROXIES:
            snr_curves[p] = qe.mi_vs_snr(secret, d[p][:, cyc].astype(float), snrs)
        for j, s in enumerate(snrs):
            cells = "".join("%-14.4f" % snr_curves[p][j]["mi"] for p in PROXIES)
            print("  %-10s %s" % ("inf" if not np.isfinite(s) else "%g" % s, cells))
        print("\n  Computed by quadrature over a Gaussian mixture with known\n"
              "  components, not estimated -- so these stay exact under noise.")

    if args.null:
        print("\nPERMUTATION NULL AT CYCLE %d (%d draws)" % (cyc, args.null))
        for p in PROXIES:
            r = qe.null_summary(secret, d[p][:, cyc], n_perm=args.null,
                                n_bins=args.bins)
            print("  %-8s plugin %6.4f | corrected %6.4f | bias %6.4f | "
                  "null p99 %6.4f | %s"
                  % (p, r["mi_plugin"], r["mi_corrected"], r["analytic_bias"],
                     r["null_p99"], "SIGNIFICANT" if r["significant"] else "not sig"))

    if args.plot:
        do_plots(
            args.plot,
            per_cycle,
            snr_curves,
            meta["dut"],
            args.secret_name
        )

    if args.csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["npz", "dut", "proxy", "cycle", "exact", "n_secrets",
                            "n_obs", "H_S", "MI", "L_min", "H_inf_S_given_O"])
            for i, p in enumerate(PROXIES):
                ch = rows[i][cyc]
                m = detail[p]
                w.writerow([args.npz, meta["dut"], p, cyc, int(ch.exact),
                            m["n_secrets"], m["n_observations"],
                            "%.4f" % m["H_prior"], "%.6f" % m["MI"],
                            "%.6f" % m["L_min"], "%.6f" % m["H_inf_S_given_O"]])
        print("[csv] appended to %s" % args.csv)

    print("\nTier 0 reminder: zero-delay RTL has no glitches, so these bounds\n"
          "are on the glitch-free channel. Tier 1 with SDF back-annotation can\n"
          "only increase them.")


if __name__ == "__main__":
    main()