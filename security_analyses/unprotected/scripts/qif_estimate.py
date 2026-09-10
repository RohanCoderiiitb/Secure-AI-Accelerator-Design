#!/usr/bin/env python3
"""
qif_estimate.py -- estimation machinery for channels that cannot be
enumerated exhaustively.

Deliberately separate from qif_measures.py so the exact path can never
accidentally route through an estimator. Only sampled channels come here.

THE BIAS IS NOT SMALL
---------------------
Plug-in mutual information is biased UPWARD by roughly

    (m_so - m_s - m_o + 1) / (2 N ln 2)

With |S| = 256, around 40 distinct toggle counts and 2000 traces, that is
on the order of a full bit. Reported uncorrected, it is leakage that does
not exist. Miller-Madow is the minimum defensible correction.

Correction alone is not enough, because the correction is itself
approximate. The permutation null is what makes a number actionable:
shuffle the secret labels, recompute MI, repeat, and take an upper
percentile. Measured MI is only meaningful relative to that floor. This
is the same discipline that made the TVLA and ADLA null tests
trustworthy, and it answers the "no universal threshold" problem
directly -- the threshold is derived from the data.

NOISY CHANNELS ARE STILL SEMI-ANALYTIC
--------------------------------------
When Gaussian measurement noise is added, p(o|s) becomes a finite mixture
of Gaussians whose component means are the enumerated toggle counts and
whose weights are known exactly. MI then follows from 1-D quadrature over
o, with no estimator at all. gaussian_mixture_mi() does that, so the
MI-vs-SNR curve stays exact for the enumerable blocks.
"""

import numpy as np

import qif_measures as qm


# ---------------------------------------------------------------------
# Bias correction
# ---------------------------------------------------------------------
def miller_madow_entropy(counts):
    """Plug-in entropy plus the (m_hat - 1) / (2N) correction, in bits."""
    counts = np.asarray(counts, dtype=np.float64)
    N = counts.sum()
    if N <= 0:
        return 0.0
    p = counts[counts > 0] / N
    h = float(-np.sum(p * np.log2(p)))
    m_hat = int(np.sum(counts > 0))
    return h + (m_hat - 1) / (2.0 * N * np.log(2.0))


def mi_miller_madow(counts_2d):
    """
    Bias-corrected MI from a raw JOINT COUNT matrix (not a normalised
    channel -- the correction needs the sample sizes).

        I = H(S) + H(O) - H(S,O)

    with Miller-Madow applied to each entropy term.
    """
    J = np.asarray(counts_2d, dtype=np.float64)
    N = J.sum()
    if N <= 0:
        return 0.0
    h_s = miller_madow_entropy(J.sum(axis=1))
    h_o = miller_madow_entropy(J.sum(axis=0))
    h_so = miller_madow_entropy(J.ravel())
    return float(h_s + h_o - h_so)


def mi_plugin(counts_2d):
    """Uncorrected plug-in MI, for reporting the size of the correction."""
    J = np.asarray(counts_2d, dtype=np.float64)
    N = J.sum()
    if N <= 0:
        return 0.0
    p = J / N
    ps = p.sum(axis=1, keepdims=True)
    po = p.sum(axis=0, keepdims=True)
    nz = p > 0
    return float(np.sum(p[nz] * np.log2(p[nz] / (ps @ po)[nz])))


def analytic_bias(counts_2d):
    """Leading-order upward bias of the plug-in estimator, in bits."""
    J = np.asarray(counts_2d, dtype=np.float64)
    N = J.sum()
    if N <= 0:
        return 0.0
    m_so = int(np.sum(J > 0))
    m_s = int(np.sum(J.sum(axis=1) > 0))
    m_o = int(np.sum(J.sum(axis=0) > 0))
    return float((m_so - m_s - m_o + 1) / (2.0 * N * np.log(2.0)))


# ---------------------------------------------------------------------
# Permutation null
# ---------------------------------------------------------------------
def permutation_null(secret, obs, n_perm=300, seed=0, corrected=True,
                     n_bins=None):
    """
    Empirical null distribution of MI under label shuffling.

    Permuting the secret labels destroys any real dependence while leaving
    both marginals untouched, so the resulting MI values are draws from
    the true null for THIS dataset, including its discreteness and its
    sample size. Report measured MI against the p99 of this.
    """
    from qif_channel import quantise
    secret = np.asarray(secret)
    o_idx, o_vals = quantise(np.asarray(obs), n_bins)
    s_vals, s_idx = np.unique(secret, return_inverse=True)

    rng = np.random.default_rng(seed)
    vals = np.empty(n_perm, dtype=np.float64)
    perm = s_idx.copy()
    shape = (s_vals.size, o_vals.size)
    for i in range(n_perm):
        rng.shuffle(perm)
        J = np.zeros(shape, dtype=np.float64)
        np.add.at(J, (perm, o_idx), 1.0)
        vals[i] = mi_miller_madow(J) if corrected else mi_plugin(J)
    return vals


def null_summary(secret, obs, n_perm=300, seed=0, n_bins=None):
    """Measured MI, the null floor, and the excess above it."""
    from qif_channel import quantise
    o_idx, o_vals = quantise(np.asarray(obs), n_bins)
    s_vals, s_idx = np.unique(np.asarray(secret), return_inverse=True)
    J = np.zeros((s_vals.size, o_vals.size), dtype=np.float64)
    np.add.at(J, (s_idx, o_idx), 1.0)

    mi_c = mi_miller_madow(J)
    mi_p = mi_plugin(J)
    null = permutation_null(secret, obs, n_perm=n_perm, seed=seed,
                            n_bins=n_bins)
    p99 = float(np.percentile(null, 99))
    return {
        "mi_plugin": mi_p,
        "mi_corrected": mi_c,
        "analytic_bias": analytic_bias(J),
        "null_p50": float(np.percentile(null, 50)),
        "null_p99": p99,
        "excess_over_null": mi_c - p99,
        "significant": bool(mi_c > p99),
        "n_traces": int(J.sum()),
    }


# ---------------------------------------------------------------------
# Noisy channel, computed rather than estimated
# ---------------------------------------------------------------------
def gaussian_mixture_mi(secret, obs, sigma, prior=None, n_grid=2048):
    """
    Exact I(S;O + N) for additive Gaussian noise of std sigma.

    Given s, the noiseless observable takes finitely many values with
    known weights, so p(o|s) is a finite Gaussian mixture with known
    components. MI is then a 1-D integral evaluated by quadrature -- no
    sampling, no estimator, no bias. This keeps the MI-vs-SNR curve exact
    for every block whose input space was enumerated.
    """
    secret = np.asarray(secret)
    obs = np.asarray(obs, dtype=np.float64)
    s_vals = np.unique(secret)
    n_s = s_vals.size
    pi = np.full(n_s, 1.0 / n_s) if prior is None else np.asarray(prior, float)

    from qif_channel import build
    if sigma <= 0:
        return qm.shannon_mi(build(secret, obs).C, pi)

    # The quadrature grid must resolve the Gaussian components. With a
    # fixed grid and a small sigma the components become needles that fall
    # between grid points and the integral silently collapses toward zero.
    # Require at least ~4 points per sigma; if that needs an unreasonable
    # grid, sigma is negligible against the spacing of the discrete
    # observable and the noiseless channel is the correct answer anyway.
    lo = obs.min() - 6.0 * sigma
    hi = obs.max() + 6.0 * sigma
    # Resolve the components (>=4 points per sigma), but bound the grid:
    # n_s * n_grid floats must stay in memory. When sigma is so small that
    # resolving it would need a huge grid, the components no longer overlap
    # and the noiseless channel is the correct answer anyway.
    MAX_CELLS = 20_000_000
    max_grid = max(4096, MAX_CELLS // max(n_s, 1))
    need = int(np.ceil((hi - lo) / (sigma / 4.0))) + 1
    if need > max_grid:
        return qm.shannon_mi(build(secret, obs).C, pi)
    n_grid = int(max(n_grid, need))

    grid = np.linspace(lo, hi, n_grid)
    dx = grid[1] - grid[0]
    inv = 1.0 / (sigma * np.sqrt(2.0 * np.pi))

    p_o_given_s = np.empty((n_s, n_grid), dtype=np.float64)
    for i, s in enumerate(s_vals):
        comp = obs[secret == s]
        d = (grid[None, :] - comp[:, None]) / sigma
        p_o_given_s[i] = inv * np.exp(-0.5 * d * d).mean(axis=0)

    p_o = pi @ p_o_given_s
    # Guard the integrand. Far from every mixture component the Gaussians
    # underflow to exactly zero, so p_o can be 0 there while the eager
    # numpy division would still produce inf/nan before any where() runs.
    # Divide only where the numerator is positive.
    mask = p_o_given_s > 0
    ratio = np.ones_like(p_o_given_s)
    np.divide(p_o_given_s, np.where(p_o > 0, p_o, 1.0)[None, :],
              out=ratio, where=mask)
    ratio = np.where(ratio > 0, ratio, 1.0)
    integ = np.where(mask, p_o_given_s * np.log2(ratio), 0.0)
    mi = float(np.sum(pi[:, None] * integ) * dx)
    if not np.isfinite(mi):
        return qm.shannon_mi(build(secret, obs).C, pi)
    return max(mi, 0.0)


def mi_vs_snr(secret, obs, snrs, prior=None, n_grid=2048):
    """
    MI as a function of measurement SNR, using the same SNR definition as
    tvla.add_noise: signal power is the across-trace variance of the
    noiseless observable.

    A single MI figure at infinite SNR is an upper bound nobody achieves.
    This curve is the reportable form, exactly as TTD-vs-SNR was for TVLA.
    """
    obs = np.asarray(obs, dtype=np.float64)
    sp = float(np.var(obs, ddof=1))
    out = []
    for s in snrs:
        sigma = 0.0 if (s is None or not np.isfinite(s)) else np.sqrt(sp / s)
        out.append({"snr": s, "sigma": sigma,
                    "mi": gaussian_mixture_mi(secret, obs, sigma, prior,
                                              n_grid)})
    return out
