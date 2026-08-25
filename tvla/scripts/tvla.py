#!/usr/bin/env python3
"""
tvla.py -- Welch's t-test leakage assessment on power-proxy traces.

Implements the fixed-vs-random test from the proposal:

        t = (mu_F - mu_R) / sqrt( s_F^2/n_F + s_R^2/n_R )

evaluated independently at every time sample, with the |t| > 4.5
detection threshold. 4.5 corresponds to a two-tailed p < 1e-5 and is
the conventional Goodwill et al. threshold; note it is a per-sample
threshold, so with T samples the family-wise false-positive rate is
approximately T * 1e-5. Use --bonferroni to raise the threshold
accordingly, which matters once T gets into the hundreds.

Three things here are not optional decoration:

1. NOISE INJECTION. An RTL toggle count is a noiseless observable. Real
   measurements are not. Without added noise, TTD collapses to a handful
   of traces and the number is meaningless. TTD is reported as a
   FUNCTION OF SNR, never as a single figure.

2. THE NULL TEST. Fixed-vs-fixed must be run through this exact same
   code path and must stay below threshold. If it does not, the
   detection is an artefact of the capture infrastructure, not of the
   design. Never report a fixed-vs-random result whose matching null
   test was not run.

3. HALF-SPLIT CONFIRMATION. A sample is only accepted as leaking if
   both independent halves of the dataset exceed threshold there with
   the same sign. This suppresses the isolated per-sample excursions
   that a raw max|t| criterion happily reports as leakage.
"""

import numpy as np

THRESHOLD = 4.5


# ---------------------------------------------------------------------
# Core statistic
# ---------------------------------------------------------------------
def welch_t(A, B):
    """
    Per-sample Welch t-statistic between two trace populations.

    A : (nA, T) fixed group
    B : (nB, T) random group
    returns (t, dof), each length T.
    """
    A = np.asarray(A, dtype=np.float64)
    B = np.asarray(B, dtype=np.float64)
    nA, nB = A.shape[0], B.shape[0]
    if nA < 2 or nB < 2:
        raise ValueError("need >= 2 traces per group")

    mA, mB = A.mean(0), B.mean(0)
    vA = A.var(0, ddof=1)
    vB = B.var(0, ddof=1)

    sA, sB = vA / nA, vB / nB
    denom = np.sqrt(sA + sB)

    t = np.zeros_like(denom)
    nz = denom > 0
    t[nz] = (mA[nz] - mB[nz]) / denom[nz]
    # Samples with zero variance in both groups and equal means carry no
    # information; leave t = 0 rather than propagating a NaN.

    with np.errstate(divide="ignore", invalid="ignore"):
        dof = np.where(
            nz,
            (sA + sB) ** 2 / (sA ** 2 / (nA - 1) + sB ** 2 / (nB - 1)),
            np.inf,
        )
    return t, dof


def threshold_for(T, bonferroni=False, base=THRESHOLD):
    """Per-sample 4.5, or a Bonferroni-corrected equivalent across T samples."""
    if not bonferroni:
        return base
    from scipy.stats import norm
    alpha = 1e-5 / max(T, 1)
    return float(abs(norm.ppf(alpha / 2.0)))


# ---------------------------------------------------------------------
# Noise
# ---------------------------------------------------------------------
def signal_power(P):
    """
    Mean over time samples of the across-trace variance. This is the
    data-dependent component -- the part an attacker can actually use --
    not the total variance of the trace, which is dominated by the
    deterministic cycle-to-cycle shape.
    """
    return float(np.mean(P.var(axis=0, ddof=1)))


def add_noise(P, snr, rng):
    """
    Additive white Gaussian noise at a specified SNR, where

        SNR = mean_t Var_traces[P] / sigma_n^2

    snr = None or np.inf leaves the traces untouched.
    """
    if snr is None or not np.isfinite(snr):
        return P
    sp = signal_power(P)
    if sp <= 0:
        return P
    sigma = np.sqrt(sp / snr)
    return P + rng.normal(0.0, sigma, size=P.shape)


# ---------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------
def detect(P, labels, thr=THRESHOLD, half_split=True):
    """
    Run the t-test and return a dict of results.

    labels : 0 = fixed, 1 = random
    """
    F = P[labels == 0]
    R = P[labels == 1]
    t, dof = welch_t(F, R)
    T = t.shape[0]

    leaking = np.abs(t) > thr

    if half_split and F.shape[0] >= 4 and R.shape[0] >= 4:
        fh, rh = F.shape[0] // 2, R.shape[0] // 2
        t1, _ = welch_t(F[:fh], R[:rh])
        t2, _ = welch_t(F[fh:], R[rh:])
        confirmed = (np.abs(t1) > thr) & (np.abs(t2) > thr) & (np.sign(t1) == np.sign(t2))
    else:
        confirmed = leaking.copy()

    return {
        "t": t,
        "dof": dof,
        "threshold": thr,
        "max_abs_t": float(np.max(np.abs(t))),
        "argmax_cycle": int(np.argmax(np.abs(t))),
        "n_samples": T,
        "n_leaking": int(leaking.sum()),
        "n_confirmed": int(confirmed.sum()),
        "leaking_cycles": np.flatnonzero(leaking).tolist(),
        "confirmed_cycles": np.flatnonzero(confirmed).tolist(),
        "n_fixed": int(F.shape[0]),
        "n_random": int(R.shape[0]),
        "detected": bool(confirmed.any()),
    }


# ---------------------------------------------------------------------
# Traces to detection
# ---------------------------------------------------------------------
def ttd(P, labels, snr=None, thr=THRESHOLD, n_grid=None, repeats=20,
        quantile=0.5, seed=0, half_split=True):
    """
    Smallest per-group trace count at which leakage is detected.

    For each candidate n, `repeats` independent random subsets of n
    traces per group are drawn, the test is run on each, and the result
    is the `quantile` of the per-repeat detection outcome. A single
    subset gives a number that swings by 2-3x between reruns, which is
    why this is not done with one draw.

    Returns (ttd, curve) where curve is a list of (n, detection_rate).
    None means no detection at the largest n available.
    """
    rng = np.random.default_rng(seed)
    nF = int((labels == 0).sum())
    nR = int((labels == 1).sum())
    nmax = min(nF, nR)

    if n_grid is None:
        n_grid = sorted(set(
            int(x) for x in np.unique(np.geomspace(10, nmax, num=18).astype(int))
            if x >= 5
        ))

    idxF = np.flatnonzero(labels == 0)
    idxR = np.flatnonzero(labels == 1)

    curve = []
    found = None
    for n in n_grid:
        if n > nmax:
            break
        hits = 0
        for _ in range(repeats):
            fs = rng.choice(idxF, size=n, replace=False)
            rs = rng.choice(idxR, size=n, replace=False)
            sub = np.vstack([P[fs], P[rs]])
            lab = np.concatenate([np.zeros(n, np.int8), np.ones(n, np.int8)])
            sub = add_noise(sub, snr, rng)
            res = detect(sub, lab, thr=thr, half_split=half_split)
            hits += int(res["detected"])
        rate = hits / repeats
        curve.append((int(n), float(rate)))
        if found is None and rate >= quantile:
            found = int(n)
    return found, curve


def ttd_vs_snr(P, labels, snrs, thr=THRESHOLD, repeats=20, seed=0,
               half_split=True):
    """TTD as a function of SNR. This is the reportable form."""
    out = []
    for i, s in enumerate(snrs):
        n, curve = ttd(P, labels, snr=s, thr=thr, repeats=repeats,
                       seed=seed + i, half_split=half_split)
        out.append({"snr": s, "ttd": n, "curve": curve})
    return out


# ---------------------------------------------------------------------
# Null test
# ---------------------------------------------------------------------
def null_check(P, labels, thr=THRESHOLD, seed=0, n_shuffle=0):
    """
    Assess a fixed-vs-fixed dataset.

    Passing means: max|t| stays under the threshold, and the fraction of
    samples above it is consistent with the nominal 1e-5 per-sample false
    positive rate.

    n_shuffle > 0 additionally runs label permutations on the same data,
    which gives an empirical null distribution of max|t|. That is a
    stronger check than the single as-recorded split, and it is the one
    to use when the null test is borderline.
    """
    res = detect(P, labels, thr=thr, half_split=False)
    T = res["n_samples"]
    res["expected_false_positives"] = T * 1e-5
    res["pass"] = res["max_abs_t"] <= thr

    # In noiseless RTL a correct null dataset has *identically zero*
    # across-trace variance: the same inputs into a deterministic model
    # give the same toggle counts every time. That degenerate t = 0 is
    # not a weak result, it is the strongest possible statement that the
    # inter-trace flush is complete and that no state carries over from
    # whatever trace happened to precede this one. If the flush were too
    # short, fixed traces would differ according to their predecessor and
    # the variance would be non-zero.
    #
    # It does, however, mean the t-test itself has not been exercised.
    # Re-run with noise injected to get a non-degenerate check.
    res["zero_variance"] = bool(np.all(P.var(axis=0, ddof=1) == 0))

    if n_shuffle > 0:
        rng = np.random.default_rng(seed)
        maxima = np.empty(n_shuffle)
        lab = labels.copy()
        for i in range(n_shuffle):
            rng.shuffle(lab)
            t, _ = welch_t(P[lab == 0], P[lab == 1])
            maxima[i] = np.max(np.abs(t))
        res["perm_max_abs_t_p95"] = float(np.percentile(maxima, 95))
        res["perm_max_abs_t_p99"] = float(np.percentile(maxima, 99))
        res["perm_exceedance"] = float(np.mean(maxima > thr))
    return res


# ---------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------
def format_report(name, res):
    lines = []
    lines.append("  %-8s max|t| = %8.2f at cycle %-3d  "
                 "(%d/%d samples > %.2f, %d confirmed by half-split)"
                 % (name, res["max_abs_t"], res["argmax_cycle"],
                    res["n_leaking"], res["n_samples"], res["threshold"],
                    res["n_confirmed"]))
    return "\n".join(lines)


def t_profile_ascii(t, thr=THRESHOLD, width=56):
    """Compact per-cycle |t| bar chart for terminal output."""
    a = np.abs(t)
    hi = max(a.max(), thr * 1.2)
    out = []
    for i, v in enumerate(a):
        n = int(round(width * v / hi))
        mark = "#" if v > thr else "-"
        out.append("    cyc %3d | %-*s %7.2f%s"
                   % (i, width, mark * n, v, "  <== " if v > thr else ""))
    return "\n".join(out)
