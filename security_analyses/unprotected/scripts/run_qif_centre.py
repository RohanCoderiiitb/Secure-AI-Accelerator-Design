#!/usr/bin/env python3
"""
run_qif_centre.py -- QIF on the CENTRE PE of the 5x5 systolic array.

    python3 qif_validate.py                                # ALWAYS first
    python3 run_qif_centre.py --npz ../traces/qif_centre_wt_b32.npz \
        --bins 32 --secret-name Weight \
        --plot ../out/qif_outputs/qif_centre_wt_b32 \
        --csv  ../out/qif_outputs/qif_centre_summary.csv

WHY THE CENTRE PE
-----------------
The full array cannot be enumerated: 25 INT8 weights is 2^200 cases. The
centre PE (row 2, col 2) receives its activation from a west neighbour
and its partial sum from a north neighbour. Its weight, its incoming
activation, or its incoming partial sum is the secret (raw value, whole
secret space); everything else in the array is random plaintext.

PIPELINE
--------
  3. leakage extraction  L(t): per-cycle power proxy of the centre PE
  4. equal-frequency binning into B bins (B = 32 or 64)
  5. joint matrix        P(S, L_binned)
  6. MI                  I(S;L), entropy sum
  7. convergence curve   shuffle the traces, MI on 10%, 20%, ... 100%

PI's suggestion, run alongside the convergence curve:
  null test              shuffle the secret labels against the traces and
                         recompute MI. A correct estimator returns about
                         zero; whatever it returns is the bias floor the
                         real MI is reported against.

TRACE COUNT
-----------
Each bin should hold at least 100-200 traces of every secret class:
N >= n_classes x B x 100. The report prints whether the run meets it.
"""

import argparse
import csv
import os

import numpy as np

import qif_estimate as qe

PROXIES = ("P_reg", "P_comb", "P_tot")
FRACTIONS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
MIN_PER_BIN_CLASS = 100


def load(path):
    d = np.load(path, allow_pickle=False)
    if "secret_val" not in d.files or np.all(d["secret_val"] == -1):
        raise SystemExit("%s has no secret column -- re-run the centre-PE "
                         "QIF testbench." % path)
    return d, str(d["dut"]), int(d["capture_cycles"])


def do_plots(prefix, mi, null, conv, cyc, dut, secret_name, n_bins):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping plots")
        return
    os.makedirs(os.path.dirname(os.path.abspath(prefix)) or ".", exist_ok=True)

    # Step 6: MI per cycle, with the null-test result (bias floor).
    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    for ax, p in zip(axes, PROXIES):
        t = np.arange(len(mi[p]))
        ax.plot(t, mi[p], lw=1.4, marker="o", ms=3, label="MI")
        ax.plot(t, null[p], lw=1.0, ls="--", marker="x", ms=4,
                label="null test (shuffled labels) = bias floor")
        ax.set_ylabel("MI bits (%s)" % p)
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8)
    axes[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle("Per-Cycle MI, centre PE, B=%d -- %s (%s as Secret)"
                 % (n_bins, dut, secret_name))
    fig.tight_layout()
    fig.savefig(prefix + "_mi.png", dpi=140)
    plt.close(fig)

    # Step 7: convergence curve.
    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    for ax, p in zip(axes, PROXIES):
        ax.plot([c[1] for c in conv[p]], [c[2] for c in conv[p]],
                lw=1.4, marker="o", ms=4)
        ax.set_ylabel("MI bits (%s)" % p)
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.3)
    axes[-1].set_xlabel("number of traces")
    fig.suptitle("MI Convergence at cycle %d, centre PE, B=%d -- %s (%s as Secret)"
                 % (cyc, n_bins, dut, secret_name))
    fig.tight_layout()
    fig.savefig(prefix + "_convergence.png", dpi=140)
    plt.close(fig)
    print("[plot] wrote %s_{mi,convergence}.png" % prefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--bins", type=int, default=32,
                    help="equal-frequency bins B (32 or 64)")
    ap.add_argument("--secret-name", default="Secret")
    ap.add_argument("--plot", default=None)
    ap.add_argument("--csv", default=None)
    args = ap.parse_args()

    d, dut, T = load(args.npz)
    secret = d["secret_val"]
    s_vals, counts = np.unique(secret, return_counts=True)
    N, K, B = secret.size, s_vals.size, args.bins
    per_bin_class = counts.min() / float(B)

    print("=" * 76)
    print("CENTRE-PE QIF  dut=%s" % dut)
    print("  %d traces, %d secret values in [%d, %d], %d cycles"
          % (N, K, s_vals.min(), s_vals.max(), T))
    print("  equal-frequency bins B = %d  (%d traces per bin)" % (B, N // B))
    print("  traces per bin per class: %.1f  (rule: >= %d, needs N >= %d)  [%s]"
          % (per_bin_class, MIN_PER_BIN_CLASS, K * B * MIN_PER_BIN_CLASS,
             "OK" if per_bin_class >= MIN_PER_BIN_CLASS else "BELOW RULE"))
    print("=" * 76)

    mi = {p: [] for p in PROXIES}
    null = {p: [] for p in PROXIES}
    for p in PROXIES:
        P = d[p].astype(np.float64)
        for t in range(T):
            mi[p].append(qe.binned_mi(secret, P[:, t], B))
            null[p].append(qe.null_test(secret, P[:, t], B))

    print("\nPER-CYCLE MI (bits)  --  MI / null test (bias floor)")
    print("  cycle  " + "".join("%-24s" % p for p in PROXIES))
    for t in range(T):
        print("  %5d  %s" % (t, "".join("%-24s" % ("%.4f / %.4f"
                                         % (mi[p][t], null[p][t]))
                                         for p in PROXIES)))

    best = {p: int(np.argmax(mi[p])) for p in PROXIES}
    cyc = best["P_tot"]
    print("\n  peak cycle: " + ", ".join("%s=%d" % (p, best[p]) for p in PROXIES))

    conv = {p: qe.convergence_curve(secret, d[p][:, cyc].astype(np.float64),
                                    B, FRACTIONS) for p in PROXIES}
    print("\nCONVERGENCE CURVE AT CYCLE %d (shuffled traces, growing subsets)" % cyc)
    print("  %-6s %-10s " % ("frac", "N") + "".join("%-12s" % p for p in PROXIES))
    for j, f in enumerate(FRACTIONS):
        print("  %-6.1f %-10d %s" % (f, conv["P_tot"][j][1],
              "".join("%-12.4f" % conv[p][j][2] for p in PROXIES)))

    if args.plot:
        do_plots(args.plot, mi, null, conv, cyc, dut, args.secret_name, B)
        conv_csv = args.plot + "_convergence.csv"
        with open(conv_csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["proxy", "cycle", "fraction", "n_traces", "MI"])
            for p in PROXIES:
                for f, n, v in conv[p]:
                    w.writerow([p, cyc, "%.1f" % f, n, "%.6f" % v])
        print("[csv] wrote %s" % conv_csv)

    if args.csv:
        new = not os.path.exists(args.csv)
        with open(args.csv, "a", newline="") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(["npz", "dut", "secret", "proxy", "cycle", "bins",
                            "n_traces", "n_secrets", "traces_per_bin_per_class",
                            "MI", "null_test_bias_floor"])
            for p in PROXIES:
                w.writerow([args.npz, dut, args.secret_name, p, cyc, B, N, K,
                            "%.1f" % per_bin_class, "%.6f" % mi[p][cyc],
                            "%.6f" % null[p][cyc]])
        print("[csv] appended to %s" % args.csv)


if __name__ == "__main__":
    main()
