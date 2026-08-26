#!/usr/bin/env python3
"""
adla.py -- Anderson-Darling Leakage Assessment.

Drop-in distributional alternative to Welch's t-test, operating on the
SAME fixed-vs-random dataset that tvla.py consumes. No re-simulation is
needed: ADLA is a different statistic on the same two populations.

WHY BOTHER, GIVEN TVLA ALREADY FIRES
------------------------------------
Welch's t compares MEANS. Two populations can have identical means and
still be trivially distinguishable if they differ in variance, skew, or
tail behaviour. That is precisely the regime a first-order masked design
lands in: masking equalises the first moment by construction, so TVLA
goes quiet while the distributions remain different.

Anderson-Darling compares the full empirical CDFs, weighted to be
sensitive in the tails:

    A^2 = n * integral [ (F_A(x) - F_B(x))^2 / (F(x)(1-F(x))) ] dF(x)

so it detects variance, bimodality and tail differences that a mean-based
test cannot see. On UNPROTECTED hardware both tests will scream, and ADLA
adds little; its value is (a) establishing the baseline correspondence now
so the masked comparison later is apples-to-apples, and (b) flagging
cycles where leakage is distributional rather than mean-shifted.

TIES ARE NOT A DETAIL HERE
--------------------------
Toggle counts are small integers. A capture window typically yields only
20-60 distinct values per cycle, so the pooled sample is dominated by
ties. The textbook Anderson-Darling formula assumes continuous data and
gives wrong values under ties. This module implements the Scholz &
Stephens (1987) midrank-corrected k-sample statistic, which handles ties
properly:

    A^2_akN = (N-1)/N * sum_i (1/n_i) * sum_j (l_j/N)
              * (N*M_ij - n_i*B_j)^2 / (B_j*(N-B_j) - N*l_j/4)

with midrank definitions B_j = (count below z_j) + l_j/2 and likewise
M_ij. Verified to <1e-13 against scipy.stats.anderson_ksamp(midrank=True)
across tied, untied, and unbalanced samples.

scipy is NOT used directly because it raises ValueError when the pooled
sample has a single distinct value -- which is exactly what a correct
noiseless RTL null dataset produces. That case is handled here as A^2 = 0.

THRESHOLDS
----------
There is no ADLA equivalent of the universal |t| > 4.5. The standardised
statistic's null distribution is not normal, and published critical value
tables stop around alpha = 0.001 -- far short of TVLA's 1e-5. Extrapolating
them is not defensible. This module therefore derives the threshold by
LABEL PERMUTATION on the actual data, which sidesteps both the tabulation
gap and the discreteness problem. Check the convention in your reference
[2] before quoting a fixed critical value in the paper.
"""

import numpy as np

DEFAULT_ALPHA = 1e-5


# ---------------------------------------------------------------------
# Core statistic
# ---------------------------------------------------------------------
def _ad_raw_1d(a, b):
    """Scholz-Stephens midrank-corrected raw A^2_akN for two samples."""
    nA, nB = a.size, b.size
    N = nA + nB
    z, l = np.unique(np.concatenate([a, b]), return_counts=True)
    if z.size < 2:
        # Pooled sample has one distinct value: the two populations are
        # identical and there is nothing to distinguish. Not an error.
        return 0.0

    sa, sb = np.sort(a), np.sort(b)
    MA_l = np.searchsorted(sa, z, "left").astype(np.float64)
    MA_r = np.searchsorted(sa, z, "right").astype(np.float64)
    MB_l = np.searchsorted(sb, z, "left").astype(np.float64)
    MB_r = np.searchsorted(sb, z, "right").astype(np.float64)

    MA = MA_l + (MA_r - MA_l) / 2.0          # midrank
    MB = MB_l + (MB_r - MB_l) / 2.0
    lj = l.astype(np.float64)
    B = np.cumsum(lj) - lj + lj / 2.0        # midrank

    den = B * (N - B) - N * lj / 4.0
    ok = den > 0
    if not ok.any():
        return 0.0

    tot = 0.0
    for n_i, M_i in ((nA, MA), (nB, MB)):
        num = lj[ok] * (N * M_i[ok] - n_i * B[ok]) ** 2
        tot += np.sum(num / den[ok]) / n_i
    return (N - 1.0) / N * tot / N


def ad_sigma(nA, nB):
    """Scholz-Stephens standardisation sigma for k=2 samples."""
    ns = np.array([nA, nB], dtype=np.float64)
    k = 2
    N = ns.sum()
    if N < 5:
        return np.nan
    H = np.sum(1.0 / ns)
    h = np.sum(1.0 / np.arange(1.0, N))
    # g = sum_{i<j} 1/((N-i)*j), computed without an O(N^2) Python loop
    g = 0.0
    for i in range(1, int(N) - 1):
        j = np.arange(i + 1, N)
        g += np.sum(1.0 / ((N - i) * j))

    a = (4 * g - 6) * (k - 1) + (10 - 6 * g) * H
    b = (2 * g - 4) * k ** 2 + 8 * h * k + (2 * g - 14 * h - 4) * H - 8 * h + 4 * g - 6
    c = (6 * h + 2 * g - 2) * k ** 2 + (4 * h - 4 * g + 6) * k + (2 * h - 6) * H + 4 * h
    d = (2 * h + 6) * k ** 2 - 4 * h * k
    var = (a * N ** 3 + b * N ** 2 + c * N + d) / ((N - 1) * (N - 2) * (N - 3))
    return np.sqrt(var) if var > 0 else np.nan


def ad_statistic(A, B, normalize=True):
    """
    Per-time-sample Anderson-Darling statistic between two populations.

    A : (nA, T) fixed group
    B : (nB, T) random group

    Returns length-T array. With normalize=True the Scholz-Stephens
    standardised form is returned (null mean 0, null sd 1), which is the
    version to compare across DUTs with different trace counts. The raw
    A^2 is returned otherwise.
    """
    A = np.asarray(A, dtype=np.float64)
    B = np.asarray(B, dtype=np.float64)
    if A.ndim == 1:
        A = A[:, None]
        B = B[:, None]
    nA, nB = A.shape[0], B.shape[0]
    T = A.shape[1]

    raw = np.empty(T, dtype=np.float64)
    for t in range(T):
        raw[t] = _ad_raw_1d(A[:, t], B[:, t])

    if not normalize:
        return raw
    sig = ad_sigma(nA, nB)
    if not np.isfinite(sig):
        return raw
    return (raw - 1.0) / sig


# ---------------------------------------------------------------------
# Permutation threshold
# ---------------------------------------------------------------------
def permutation_threshold(P, labels, alpha=DEFAULT_ALPHA, n_perm=500,
                          seed=0, normalize=True, max_stat=True):
    """
    Empirical critical value from label permutation.

    Permuting the group labels destroys any real fixed/random structure
    while preserving the marginal distribution of the traces exactly, so
    the resulting statistics are draws from the true null for THIS data --
    including its discreteness, which no published table accounts for.

    With max_stat=True the null is built on max_t |A^2(t)|, which controls
    the family-wise error rate across the whole capture window. That is
    the honest comparison for a "does this DUT leak anywhere" claim.

    Returns (threshold, null_maxima).
    """
    rng = np.random.default_rng(seed)
    lab = labels.copy()
    maxima = np.empty(n_perm, dtype=np.float64)
    for i in range(n_perm):
        rng.shuffle(lab)
        s = ad_statistic(P[lab == 0], P[lab == 1], normalize=normalize)
        maxima[i] = np.nanmax(s) if max_stat else np.nanmax(np.abs(s))

    q = 100.0 * (1.0 - alpha)
    if n_perm < 1.0 / alpha:
        # Cannot resolve alpha directly; extrapolate from the upper tail
        # with a Gumbel fit rather than silently returning the sample max.
        top = np.sort(maxima)[int(0.90 * n_perm):]
        loc = top.mean()
        scale = max(top.std(ddof=1), 1e-9)
        thr = loc - scale * np.log(-np.log(1.0 - alpha))
    else:
        thr = float(np.percentile(maxima, q))
    return float(thr), maxima


# ---------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------
def detect(P, labels, thr=None, alpha=DEFAULT_ALPHA, n_perm=500, seed=0,
           half_split=True, normalize=True):
    """
    Run ADLA and return a result dict shaped like tvla.detect() so the two
    can be reported side by side.
    """
    F = P[labels == 0]
    R = P[labels == 1]
    s = ad_statistic(F, R, normalize=normalize)
    T = s.shape[0]

    null_maxima = None
    if thr is None:
        thr, null_maxima = permutation_threshold(
            P, labels, alpha=alpha, n_perm=n_perm, seed=seed,
            normalize=normalize)

    leaking = s > thr

    if half_split and F.shape[0] >= 8 and R.shape[0] >= 8:
        fh, rh = F.shape[0] // 2, R.shape[0] // 2
        # The null distribution of max A^2 depends on the sample size and on
        # the tie structure, so a critical value derived at n cannot be
        # reused at n/2. Recompute it on each half, at the same alpha.
        h1 = np.vstack([F[:fh], R[:rh]])
        l1 = np.concatenate([np.zeros(fh, np.int8), np.ones(rh, np.int8)])
        h2 = np.vstack([F[fh:], R[rh:]])
        l2 = np.concatenate([np.zeros(F.shape[0] - fh, np.int8),
                             np.ones(R.shape[0] - rh, np.int8)])
        nperm_h = max(n_perm // 2, 100)
        thr1, _ = permutation_threshold(h1, l1, alpha=alpha, n_perm=nperm_h,
                                        seed=seed + 101, normalize=normalize)
        thr2, _ = permutation_threshold(h2, l2, alpha=alpha, n_perm=nperm_h,
                                        seed=seed + 202, normalize=normalize)
        s1 = ad_statistic(F[:fh], R[:rh], normalize=normalize)
        s2 = ad_statistic(F[fh:], R[rh:], normalize=normalize)
        confirmed = (s1 > thr1) & (s2 > thr2)
    else:
        confirmed = leaking.copy()

    # A correct noiseless RTL null gives one distinct pooled value per
    # sample, hence A^2 = 0 everywhere. Flag it rather than calling it a
    # pass by accident.
    degenerate = bool(np.all(P.var(axis=0, ddof=1) == 0))

    return {
        "stat": s,
        "threshold": float(thr),
        "alpha": alpha,
        "max_stat": float(np.nanmax(s)),
        "argmax_cycle": int(np.nanargmax(s)),
        "n_samples": T,
        "n_leaking": int(leaking.sum()),
        "n_confirmed": int(confirmed.sum()),
        "leaking_cycles": np.flatnonzero(leaking).tolist(),
        "confirmed_cycles": np.flatnonzero(confirmed).tolist(),
        "n_fixed": int(F.shape[0]),
        "n_random": int(R.shape[0]),
        "detected": bool(confirmed.any()),
        "degenerate": degenerate,
        "null_maxima": null_maxima,
    }


def null_check(P, labels, alpha=DEFAULT_ALPHA, n_perm=500, seed=0,
               normalize=True):
    """Assess a fixed-vs-fixed dataset with ADLA."""
    res = detect(P, labels, alpha=alpha, n_perm=n_perm, seed=seed,
                 half_split=False, normalize=normalize)
    res["pass"] = res["max_stat"] <= res["threshold"]
    return res


# ---------------------------------------------------------------------
# Traces to detection
# ---------------------------------------------------------------------
def ttd(P, labels, snr=None, alpha=DEFAULT_ALPHA, n_grid=None, repeats=15,
        quantile=0.5, seed=0, n_perm=200, add_noise=None):
    """
    ADLA traces-to-detection, structured exactly like tvla.ttd so the two
    curves are directly comparable.

    The permutation threshold is recomputed at each subset size, because a
    critical value derived at n=1000 does not apply at n=50.
    """
    rng = np.random.default_rng(seed)
    nmax = min(int((labels == 0).sum()), int((labels == 1).sum()))
    if n_grid is None:
        n_grid = sorted(set(int(x) for x in
                            np.unique(np.geomspace(10, nmax, num=12).astype(int))
                            if x >= 8))

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
            if add_noise is not None and snr is not None:
                sub = add_noise(sub, snr, rng)
            res = detect(sub, lab, alpha=alpha, n_perm=n_perm,
                         seed=int(rng.integers(1 << 30)), half_split=True)
            hits += int(res["detected"])
        rate = hits / repeats
        curve.append((int(n), float(rate)))
        if found is None and rate >= quantile:
            found = int(n)
    return found, curve


# ---------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------
def format_report(name, res):
    return ("  %-8s max A2 = %9.2f at cycle %-3d  "
            "(%d/%d samples > %.2f, %d confirmed by half-split)"
            % (name, res["max_stat"], res["argmax_cycle"],
               res["n_leaking"], res["n_samples"], res["threshold"],
               res["n_confirmed"]))


def compare_with_tvla(ad_res, t_res, thr_t=4.5):
    """
    Cycle-by-cycle agreement between ADLA and TVLA.

    The interesting cell is ADLA-only: a cycle where the distributions
    differ but the means do not. On unprotected hardware that cell is
    usually near-empty; once masking is applied it is the whole result.
    """
    a = ad_res["stat"] > ad_res["threshold"]
    t = np.abs(t_res["t"]) > thr_t
    return {
        "both": np.flatnonzero(a & t).tolist(),
        "adla_only": np.flatnonzero(a & ~t).tolist(),
        "tvla_only": np.flatnonzero(~a & t).tolist(),
        "neither": np.flatnonzero(~a & ~t).tolist(),
    }


def stat_profile_ascii(s, thr, width=52):
    """Compact per-cycle bar chart of the AD statistic."""
    a = np.maximum(s, 0.0)
    hi = max(np.nanmax(a), thr * 1.2, 1e-9)
    out = []
    for i, v in enumerate(a):
        n = int(round(width * v / hi))
        mark = "#" if v > thr else "-"
        out.append("    cyc %3d | %-*s %9.2f%s"
                   % (i, width, mark * n, v, "  <== " if v > thr else ""))
    return "\n".join(out)
