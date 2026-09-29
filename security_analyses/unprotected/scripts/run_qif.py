#!/usr/bin/env python3
"""
run_qif.py -- driver: enumerated .npz -> quantitative leakage report.

    python3 qif_validate.py                       # ALWAYS first
    python3 run_qif.py --npz ../traces/qif_pe.npz --snr
    python3 run_qif.py --npz ../traces/qif_mult_wt.npz \
        --si --si-out ../out/specific_inf_outputs/qif_mult_wt \
        --si-snrs 100 10 1 0.1

CHANGES (SI extension, on top of the validated MI path -- MI outputs,
CSV columns and --plot are untouched):
  * fix: the SI profile plot used to pick its own peak cycle instead of
    the report cycle `cyc`, so the plot and the printed text could
    disagree. Both now use `cyc`.
  * --si now also writes one all-cycle heatmap (cycle x secret value,
    SI, P_tot) and records each secret's max-over-cycles SI (elementwise
    max, never summed across cycles) in the SI json/npz.
  * --si now also reports per-secret Bayes success succ(w) -- the
    probability a MAP attacker's guess equals w when S=w, ties split
    evenly -- next to SI in the report and in the SI json/npz.
  * new --si-snrs flag: per-secret SI under additive Gaussian noise,
    by quadrature over the same known Gaussian-mixture components used
    by qif_estimate.mi_vs_snr (no sampling), at the report cycle.
  * the SI report (text and json) now states the prior, the report
    cycle, EXACT/SAMPLED per proxy, that PE figures are conditional on
    psum_in = 0, and that zero-delay HD proxies have no glitches -- so
    SI values are a lower bound on gate-level leakage and an upper
    bound with respect to measurement noise.

Reports, per power proxy:
  * per-cycle MI  -- literally the "leaked bits per clock cycle" figure
  * L_min, H_inf(S|O)  -- one-guess vulnerability and bits remaining
  * three threat models when a context column is present
  * g-leakage vs tolerance eps -- the neural-network IP curve
  * MI vs SNR, computed semi-analytically rather than estimated
  * --si: per-secret Specific Information SI(w) and Bayes success
    succ(w), the per-cycle channels already built for the MI table,
    reused rather than rebuilt. Files (json/npz/png) are written under
    --si-out, kept separate from --plot so SI artifacts never land in
    the QIF output directory.
  * --si-snrs: per-secret SI under Gaussian measurement noise, exact by
    quadrature, at the report cycle.

Every number is tagged EXACT or SAMPLED. Exact means the input space was
enumerated exhaustively, the channel is the true channel, and the figure
is a bound. Never merge the two in one column without the tag.
"""

import argparse
import csv
import json
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


def do_si_plots(prefix, si_profile, mean_si, per_cycle, s_vals, dut, secret_name, cyc):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping SI plots")
        return
    os.makedirs(os.path.dirname(os.path.abspath(prefix)) or ".", exist_ok=True)

    # mean_SI vs cycle overlaid with MI: these are two independently computed
    # quantities that must coincide by construction (MI = E_W[SI(W)]).
    fig, axes = plt.subplots(len(PROXIES), 1, figsize=(9, 8), sharex=True)
    for ax, p in zip(np.atleast_1d(axes), PROXIES):
        cyc_ax = np.arange(len(mean_si[p]))
        ax.plot(cyc_ax, mean_si[p], lw=1.6, marker="o", ms=4, label="mean SI")
        ax.plot(cyc_ax, per_cycle[p], lw=1.0, ls="--", marker="x", ms=4, label="MI")
        ax.set_ylabel("bits (%s)" % p)
        ax.set_ylim(bottom=0)
        ax.grid(alpha=0.3)
        ax.legend(fontsize=8)
    np.atleast_1d(axes)[-1].set_xlabel("clock cycle within capture window")
    fig.suptitle(f"Mean Specific Information vs MI for {dut} ({secret_name} as Secret)")
    fig.tight_layout()
    fig.savefig(prefix + "_si_meancheck.png", dpi=140)
    plt.close(fig)

    # Per-secret SI profile at the report cycle `cyc` -- the SAME cycle as
    # the printed "PER-SECRET SI" section, so the plot and the text agree.
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(s_vals, si_profile["P_tot"][cyc], lw=1.0, marker=".", ms=3)
    ax.set_xlabel("secret value w")
    ax.set_ylabel("SI(w), bits")
    ax.grid(alpha=0.3)
    ax.set_title(f"Per-Secret Specific Information at cycle {cyc} (P_tot) -- "
                f"{dut} ({secret_name} as Secret)")
    fig.tight_layout()
    fig.savefig(prefix + "_si_profile.png", dpi=140)
    plt.close(fig)
    print("[plot] wrote %s_si_{meancheck,profile}.png" % prefix)


def do_si_heatmap(prefix, si_profile, s_vals, dut, secret_name):
    """
    All-cycle view: one heatmap of SI(w) over (cycle, secret value) for
    P_tot. This is a view of the same si_profile array reported in the
    json/npz -- cycles are never summed, only laid out on an axis.
    """
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available, skipping SI heatmap")
        return
    os.makedirs(os.path.dirname(os.path.abspath(prefix)) or ".", exist_ok=True)

    data = si_profile["P_tot"]              # (T, n_secrets)
    T = data.shape[0]
    fig, ax = plt.subplots(figsize=(9, max(3.5, 0.35 * T)))
    im = ax.imshow(data, aspect="auto", origin="lower", cmap="viridis",
                   extent=[s_vals.min() - 0.5, s_vals.max() + 0.5, -0.5, T - 0.5])
    ax.set_xlabel("secret value w")
    ax.set_ylabel("clock cycle")
    ax.set_title(f"Specific Information across all cycles (P_tot) -- "
                f"{dut} ({secret_name} as Secret)")
    fig.colorbar(im, ax=ax, label="SI(w), bits")
    fig.tight_layout()
    fig.savefig(prefix + "_si_heatmap.png", dpi=140)
    plt.close(fig)
    print("[plot] wrote %s_si_heatmap.png" % prefix)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--cycle", type=int, default=None,
                    help="cycle for the detailed report (default: argmax MI)")
    ap.add_argument("--snr", action="store_true",
                    help="MI vs SNR by Gaussian-mixture quadrature")
    ap.add_argument("--si", action="store_true",
                    help="per-secret Specific Information SI(w) = D_KL(P(O|W=w)||P(O)), "
                         "per cycle per proxy, reusing the channels built for the MI table")
    ap.add_argument("--si-out", default=None,
                    help="path prefix for SI outputs (json/npz/png), e.g. "
                         "../out/specific_inf_outputs/qif_mult_wt -- kept separate "
                         "from --plot so SI artifacts never land in the QIF output "
                         "directory. Required for --si to write files; without it "
                         "--si only prints the report to stdout.")
    ap.add_argument("--si-snrs", type=float, nargs="*", default=None,
                    help="requires --si; per-secret SI under additive Gaussian noise "
                         "at the report cycle, computed by quadrature over the known "
                         "Gaussian-mixture components (no sampling), for each given "
                         "SNR, e.g. 100 10 1 0.1")
    ap.add_argument("--secret-name", default="Secret", help="name of the secret variable shown in plot titles")
    ap.add_argument("--snrs", type=float, nargs="*", default=None)
    ap.add_argument("--null", type=int, default=0,
                    help="permutation-null draws (sampled channels only)")
    ap.add_argument("--bins", type=int, default=None,
                    help="quantise the observable into this many bins")
    ap.add_argument("--plot", default=None)
    ap.add_argument("--csv", default=None)
    args = ap.parse_args()
    if args.si_snrs is not None and not args.si:
        ap.error("--si-snrs requires --si")

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

    if args.si:
        # Reuses the per-cycle channels already built for the MI table above
        # (`rows`) -- no channel is rebuilt for SI or for Bayes success.
        prior = qm.uniform_prior(s_vals.size)
        si_profile = {p: np.zeros((T, s_vals.size)) for p in PROXIES}
        succ_profile = {p: np.zeros((T, s_vals.size)) for p in PROXIES}
        mean_si = {p: np.zeros(T) for p in PROXIES}
        for i, p in enumerate(PROXIES):
            for t in range(T):
                C = rows[i][t].C
                si = qm.specific_information(C, prior)
                si_profile[p][t] = si
                succ_profile[p][t] = qm.bayes_success(C, prior)
                mean_si[p][t] = float(np.sum(prior * si))

        exact_at_cyc = {p: bool(rows[i][cyc].exact) for i, p in enumerate(PROXIES)}
        pe_conditional = "processing_element" in meta["dut"].lower()

        print("\n" + "=" * 76)
        print("SPECIFIC INFORMATION  SI(w) = D_KL( P(O|W=w) || P(O) ), bits")
        print("  P(O|W=w) : conditional observation distribution at each cycle,\n"
              "             from the same channel C[w,o] used for MI above.\n"
              "  P(O)     : sum_w pi(w) P(o|w), built across the COMPLETE secret\n"
              "             space -- never from a single fixed secret.\n"
              "  prior    : uniform, pi(w) = 1/%d over %d secrets in [%d, %d]\n"
              "  cycle    : report cycle = %d (pass --cycle to override)\n"
              "  channel  : %s"
              % (s_vals.size, s_vals.size, s_vals.min(), s_vals.max(), cyc,
                 ", ".join("%s=%s" % (p, "EXACT" if exact_at_cyc[p] else "SAMPLED")
                           for p in PROXIES)))
        if pe_conditional:
            print("  note     : PE figures are conditional on psum_in = 0 (see\n"
                  "             tb_qif_pe.sv) -- the partial-sum contribution is\n"
                  "             not enumerated by this capture.")
        print("  note     : zero-delay Hamming-distance proxies have no glitches,\n"
              "             so these values are a LOWER BOUND on gate-level leakage\n"
              "             and an UPPER BOUND with respect to measurement noise.")
        print("=" * 76)

        print("\nPER-CYCLE MEAN SI vs MI (bits) -- equal by construction: "
              "MI = E_W[SI(W)]")
        print("  cycle  " + "".join("%-28s" % p for p in PROXIES))
        max_diff = 0.0
        for t in range(T):
            cells = []
            for p in PROXIES:
                diff = abs(mean_si[p][t] - per_cycle[p][t])
                max_diff = max(max_diff, diff)
                cells.append("%-28s" % ("SI=%.4f MI=%.4f" % (mean_si[p][t], per_cycle[p][t])))
            print("  %5d  %s" % (t, "".join(cells)))
        max_diff = float(max_diff)
        validated = bool(max_diff < 1e-6)
        print("\n  max |mean_SI - MI| over all cycles/proxies: %.3e  [%s]"
              % (max_diff, "VALIDATED" if validated else "MISMATCH -- investigate"))

        # Per-secret max-over-cycles SI: an elementwise max per secret across
        # the cycle axis, NOT a sum -- SI at different cycles is not additive.
        max_over_cycles_si = {p: si_profile[p].max(axis=0) for p in PROXIES}

        si_cyc = si_profile["P_tot"][cyc]
        succ_cyc = succ_profile["P_tot"][cyc]
        i_max, i_min = int(np.argmax(si_cyc)), int(np.argmin(si_cyc))
        j_max, j_min = int(np.argmax(succ_cyc)), int(np.argmin(succ_cyc))
        mean_succ_cyc = float(np.sum(prior * succ_cyc))
        v_post_cyc = qm.posterior_vulnerability(rows[PROXIES.index("P_tot")][cyc].C, prior)
        succ_diff = abs(mean_succ_cyc - v_post_cyc)
        succ_validated = bool(succ_diff < 1e-6)

        print("\nPER-SECRET SI AND BAYES SUCCESS AT CYCLE %d (P_tot)" % cyc)
        print("  SI(w)   : specific information, bits (this section)")
        print("  succ(w) : Pr[MAP guess == w | S=w], ties split evenly -- "
              "identifiability, not information")
        print("  max SI(w)   = %.4f bits at w = %-6d  (succ(w) = %.4f)"
              % (si_cyc[i_max], s_vals[i_max], succ_cyc[i_max]))
        print("  min SI(w)   = %.4f bits at w = %-6d  (succ(w) = %.4f)"
              % (si_cyc[i_min], s_vals[i_min], succ_cyc[i_min]))
        print("  max succ(w) = %.4f     at w = %-6d  (SI(w) = %.4f bits)"
              % (succ_cyc[j_max], s_vals[j_max], si_cyc[j_max]))
        print("  min succ(w) = %.4f     at w = %-6d  (SI(w) = %.4f bits)"
              % (succ_cyc[j_min], s_vals[j_min], si_cyc[j_min]))
        print("  mean SI     = %.4f bits (== MI = %.4f bits)"
              % (mean_si["P_tot"][cyc], per_cycle["P_tot"][cyc]))
        print("  mean succ   = %.4f (== posterior Bayes vulnerability V1(pi>C) = "
              "%.4f)  [%s]"
              % (mean_succ_cyc, v_post_cyc,
                 "VALIDATED" if succ_validated else "MISMATCH -- investigate"))

        noise_records = []
        if args.si_snrs:
            print("\n" + "=" * 76)
            print("PER-SECRET SI UNDER GAUSSIAN NOISE (quadrature, no sampling)")
            print("  at cycle %d; sigma from SNR via signal power = across-trace\n"
                  "  variance of the noiseless proxy (same convention as --snr)."
                  % cyc)
            print("=" * 76)
            for p in PROXIES:
                obs_cyc = d[p][:, cyc].astype(np.float64)
                sp = float(np.var(obs_cyc, ddof=1))
                print("\n  proxy=%s" % p)
                print("  %-10s %-12s %-12s %-12s %-12s %s"
                      % ("SNR", "mean_SI", "MI(quad)", "|diff|", "check", ""))
                for snr in args.si_snrs:
                    sigma = 0.0 if not np.isfinite(snr) else float(np.sqrt(sp / snr))
                    si_noisy = qe.gaussian_mixture_si(secret, obs_cyc, sigma, prior)
                    mi_check = qe.gaussian_mixture_mi(secret, obs_cyc, sigma, prior)
                    mean_si_noisy = float(np.sum(prior * si_noisy))
                    diff = abs(mean_si_noisy - mi_check)
                    ok = diff < 1e-9
                    a, b = int(np.argmax(si_noisy)), int(np.argmin(si_noisy))
                    print("  %-10s %-12.6f %-12.6f %-12.2e %-12s"
                          % ("%g" % snr, mean_si_noisy, mi_check, diff,
                             "OK" if ok else "MISMATCH"))
                    noise_records.append({
                        "proxy": p, "snr": float(snr), "sigma": sigma,
                        "mean_SI": mean_si_noisy, "MI_quadrature": mi_check,
                        "abs_diff": diff, "validated": bool(ok),
                        "max_SI": float(si_noisy[a]), "max_SI_secret": int(s_vals[a]),
                        "min_SI": float(si_noisy[b]), "min_SI_secret": int(s_vals[b]),
                        "per_secret_SI": si_noisy.tolist(),
                    })
            print("\n  Computed by quadrature over the same known Gaussian-mixture\n"
                  "  components as qif_estimate.mi_vs_snr -- no sampling, no bias.")

        if args.si_out:
            os.makedirs(os.path.dirname(os.path.abspath(args.si_out)) or ".", exist_ok=True)

            npz_payload = dict(
                secret_values=s_vals, prior=prior,
                **{"SI_%s" % p: si_profile[p] for p in PROXIES},
                **{"succ_%s" % p: succ_profile[p] for p in PROXIES},
                **{"max_over_cycles_SI_%s" % p: max_over_cycles_si[p] for p in PROXIES},
                **{"mean_SI_%s" % p: mean_si[p] for p in PROXIES},
                **{"MI_%s" % p: np.asarray(per_cycle[p]) for p in PROXIES},
            )
            if args.si_snrs:
                npz_payload["si_snrs"] = np.asarray(args.si_snrs, dtype=np.float64)
                for p in PROXIES:
                    npz_payload["SI_noise_%s" % p] = np.array(
                        [r["per_secret_SI"] for r in noise_records if r["proxy"] == p],
                        dtype=np.float64)
            npz_path = args.si_out + "_si.npz"
            np.savez(npz_path, **npz_payload)
            print("\n[si] wrote %s" % npz_path)

            per_cycle_records = []
            for i, p in enumerate(PROXIES):
                for t in range(T):
                    si = si_profile[p][t]
                    succ = succ_profile[p][t]
                    a, b = int(np.argmax(si)), int(np.argmin(si))
                    per_cycle_records.append({
                        "proxy": p, "cycle": t, "exact": bool(rows[i][t].exact),
                        "mean_SI": float(mean_si[p][t]), "MI": float(per_cycle[p][t]),
                        "max_SI": float(si[a]), "max_SI_secret": int(s_vals[a]),
                        "min_SI": float(si[b]), "min_SI_secret": int(s_vals[b]),
                        "mean_succ": float(np.sum(prior * succ)),
                    })
            max_over_cycles_summary = {}
            for p in PROXIES:
                arr = max_over_cycles_si[p]
                a = int(np.argmax(arr))
                max_over_cycles_summary[p] = {
                    "max_SI": float(arr[a]), "max_SI_secret": int(s_vals[a]),
                    "per_secret": arr.tolist(),
                }
            report = {
                "npz": args.npz, "dut": meta["dut"],
                "metric": "Specific Information (SI) and Bayes success (succ)",
                "definition": "SI(w) = D_KL(P(O|W=w) || P(O)) = "
                               "sum_o P(o|w) * log2(P(o|w)/P(o)), bits. "
                               "Pointwise terms may be negative; SI(w) itself "
                               "is a KL divergence and is >= 0. "
                               "succ(w) = Pr[MAP guess == w | S=w], ties split "
                               "evenly, in [0,1] -- see qm.bayes_success.",
                "secret_space": {"n_secrets": int(s_vals.size),
                                 "min": int(s_vals.min()), "max": int(s_vals.max())},
                "prior": "uniform, pi(w) = 1/%d" % s_vals.size,
                "observation_definition": "per-cycle power proxy (%s); one channel "
                                           "C[w,o]=P(o|w) per clock cycle from "
                                           "qif_channel.build_per_cycle, shared with "
                                           "the MI computation" % ", ".join(PROXIES),
                "report_cycle": cyc,
                "channel_exactness_at_report_cycle": exact_at_cyc,
                "caveats": {
                    "pe_conditional_on_psum_in_zero": pe_conditional,
                    "zero_delay_hd_proxies_have_no_glitches": True,
                    "interpretation": "Zero-delay Hamming-distance proxies contain "
                                       "no glitches, so these SI values are a lower "
                                       "bound on gate-level leakage and an upper "
                                       "bound with respect to measurement noise.",
                },
                "per_cycle": per_cycle_records,
                "max_over_cycles": max_over_cycles_summary,
                "summary": {
                    "peak_cycle": cyc,
                    "max_SI": float(si_cyc[i_max]), "max_SI_secret": int(s_vals[i_max]),
                    "min_SI": float(si_cyc[i_min]), "min_SI_secret": int(s_vals[i_min]),
                    "mean_SI_at_peak_cycle": float(mean_si["P_tot"][cyc]),
                    "MI_at_peak_cycle": float(per_cycle["P_tot"][cyc]),
                    "max_succ": float(succ_cyc[j_max]), "max_succ_secret": int(s_vals[j_max]),
                    "min_succ": float(succ_cyc[j_min]), "min_succ_secret": int(s_vals[j_min]),
                    "mean_succ_at_peak_cycle": mean_succ_cyc,
                    "posterior_vulnerability_at_peak_cycle": v_post_cyc,
                },
                "validation": {
                    "mean_SI_equals_MI": validated,
                    "max_abs_diff_over_all_cycles_and_proxies": max_diff,
                    "mean_succ_equals_posterior_vulnerability": succ_validated,
                    "succ_abs_diff_at_peak_cycle": succ_diff,
                    "tolerance": 1e-6,
                },
            }
            if noise_records:
                report["noise"] = [
                    {k: v for k, v in r.items() if k != "per_secret_SI"}
                    for r in noise_records
                ]
            json_path = args.si_out + "_si.json"
            with open(json_path, "w") as fh:
                json.dump(report, fh, indent=2)
            print("[si] wrote %s" % json_path)

            do_si_plots(args.si_out, si_profile, mean_si, per_cycle, s_vals,
                        meta["dut"], args.secret_name, cyc)
            do_si_heatmap(args.si_out, si_profile, s_vals, meta["dut"], args.secret_name)

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