#!/usr/bin/env python3
"""
qif_measures.py -- information-theoretic leakage measures on a channel.

Pure functions over an explicit channel matrix. No estimation logic lives
here: everything in this module is exact given its inputs, which is what
makes it testable against closed-form answers (see qif_validate.py).
Estimator machinery is deliberately quarantined in qif_estimate.py so the
exact path can never accidentally route through it.

CHANNEL REPRESENTATION
----------------------
    C[s, o] = p(o | s)      rows sum to 1
    prior[s] = pi(s)        defaults to uniform
    J[s, o] = pi(s) C[s, o] joint

WHY MORE THAN ONE MEASURE
-------------------------
Shannon MI is an AVERAGE reduction in uncertainty. Smith (2009) showed
that averaging can be badly misleading for confidentiality: two channels
can carry identical MI while one hands the attacker the secret on the
first guess and the other does not. Bayes vulnerability and min-entropy
leakage measure exactly that one-guess probability, and g-leakage
generalises to partial or approximate guesses.

For an AI accelerator the g-leakage generalisation is not a refinement,
it is the point. Exact-match min-entropy asks "can the attacker recover
w exactly?" -- but an attacker who recovers every weight to within a
couple of LSB has a functionally equivalent clone of the model. The
tolerance gain function below measures that directly, and no
mean-based test (TVLA, ADLA) can express it at all.

MEASURES
--------
    I(S;O)      Shannon mutual information, bits
    V1(pi)      prior Bayes vulnerability, max_s pi(s)
    V1(pi > C)  posterior Bayes vulnerability, sum_o max_s J[s,o]
    L_mult      multiplicative Bayes leakage V1(pi>C)/V1(pi)
    L_min       min-entropy leakage, log2(L_mult)
    H_inf(S|O)  conditional min-entropy, -log2 V1(pi>C)   "bits remaining"
    L_g         g-leakage for a gain function g(w, s)

For a uniform prior, L_min also equals the channel's min-capacity (the
maximum of min-entropy leakage over all priors), so the uniform-prior
number is simultaneously the worst-case-over-priors bound. Worth stating
explicitly when reporting: it means the figure cannot be argued down by
claiming a more favourable weight distribution.
"""

import numpy as np

EPS = 1e-300


# ---------------------------------------------------------------------
# Channel hygiene
# ---------------------------------------------------------------------
def normalise_channel(C):
    """Row-normalise a count or probability matrix into a valid channel."""
    C = np.asarray(C, dtype=np.float64)
    if C.ndim != 2:
        raise ValueError("channel must be 2-D, got shape %r" % (C.shape,))
    rs = C.sum(axis=1, keepdims=True)
    if np.any(rs <= 0):
        bad = int(np.sum(rs <= 0))
        raise ValueError("%d secret row(s) have zero total mass -- those "
                         "secrets were never simulated" % bad)
    return C / rs


def uniform_prior(n):
    return np.full(n, 1.0 / n, dtype=np.float64)


def joint(C, prior=None):
    C = np.asarray(C, dtype=np.float64)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    if pi.shape[0] != C.shape[0]:
        raise ValueError("prior length %d != channel rows %d"
                         % (pi.shape[0], C.shape[0]))
    return C * pi[:, None]


# ---------------------------------------------------------------------
# Entropy and mutual information
# ---------------------------------------------------------------------
def entropy(p):
    """Shannon entropy in bits of a probability vector."""
    p = np.asarray(p, dtype=np.float64)
    p = p[p > 0]
    return float(-np.sum(p * np.log2(p)))


def shannon_mi(C, prior=None):
    """
    I(S;O) in bits.

    Computed as H(O) - H(O|S) rather than from the joint directly: the
    two are algebraically identical but this form makes the deterministic
    case self-evident. When the channel is deterministic every row is a
    point mass, H(O|S) = 0, and I(S;O) collapses to H(O) exactly. That is
    the Tier 0 situation for every block whose input space is enumerable.
    """
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    p_o = pi @ C                                  # marginal over observations
    h_o = entropy(p_o)
    h_o_given_s = float(np.sum(pi * np.array([entropy(row) for row in C])))
    # MI is non-negative by definition. Note max(-0.0, 0.0) returns -0.0 in
    # Python because the two compare equal, so the test has to be explicit
    # for a fully drained cycle to print as a clean 0.0000.
    v = h_o - h_o_given_s
    return v if v > 0.0 else 0.0


def conditional_entropy_secret(C, prior=None):
    """H(S|O) in bits -- the uncertainty an attacker has left."""
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    return entropy(pi) - shannon_mi(C, pi)


# ---------------------------------------------------------------------
# Bayes vulnerability and min-entropy leakage
# ---------------------------------------------------------------------
def prior_vulnerability(prior=None, n=None):
    if prior is None:
        if n is None:
            raise ValueError("give prior or n")
        return 1.0 / n
    return float(np.max(np.asarray(prior, dtype=np.float64)))


def posterior_vulnerability(C, prior=None):
    """V1(pi > C) = sum_o max_s J[s,o]."""
    J = joint(normalise_channel(C), prior)
    return float(np.sum(np.max(J, axis=0)))


def min_entropy_leakage(C, prior=None):
    """
    L_min = log2( V1(pi>C) / V1(pi) ), bits.

    For a deterministic channel with uniform prior this reduces exactly to
    log2 of the number of distinct reachable observations.
    """
    C = normalise_channel(C)
    v_post = posterior_vulnerability(C, prior)
    v_pri = prior_vulnerability(prior, n=C.shape[0])
    return float(np.log2(max(v_post, EPS) / max(v_pri, EPS)))


def conditional_min_entropy(C, prior=None):
    """H_inf(S|O) = -log2 V1(pi>C). Reads as 'effective bits remaining'."""
    return float(-np.log2(max(posterior_vulnerability(C, prior), EPS)))


# ---------------------------------------------------------------------
# Specific information (per-secret KL divergence)
# ---------------------------------------------------------------------
def marginal_observation(C, prior=None):
    """P(o) = sum_w pi(w) C[w,o], the attacker's reference/prior distribution
    over observations when the secret is unknown."""
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    return pi @ C


def pointwise_information(C, prior=None):
    """
    log2( P(o|w) / P(o) ) for every (w, o), the pointwise information that a
    single observation o carries about a particular secret w.

    These terms are signed -- they must NOT be abs()'d, and the caller must
    not clip them. Two conventions apply at the boundary:

      * P(o|w) == 0            -> nan (undefined; contributes 0 to SI, since
                                   that observation never occurs given w).
      * P(o|w) > 0, P(o) == 0  -> +inf, the mathematically correct KL
                                   divergence at a point the reference
                                   distribution assigns no mass. This can
                                   only happen when pi(w) == 0 for some w
                                   with C[w,o] > 0 (a degenerate/zero prior);
                                   under any prior with full support this
                                   cannot occur, since P(o) >= pi(w)*P(o|w).
    """
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    p_o = marginal_observation(C, pi)
    p_o_bcast = np.broadcast_to(p_o[None, :], C.shape)

    out = np.full(C.shape, np.nan, dtype=np.float64)
    pos = C > 0
    finite = pos & (p_o_bcast > 0)
    diverge = pos & (p_o_bcast <= 0)
    out[finite] = np.log2(C[finite] / p_o_bcast[finite])
    out[diverge] = np.inf
    return out


def specific_information(C, prior=None):
    """
    SI(w) = D_KL( P(O|W=w) || P(O) ) for every secret w, in bits.

        SI(w) = sum_o P(o|w) * log2( P(o|w) / P(o) )

    where P(o) = sum_w pi(w) P(o|w) is built from the SAME channel across
    the complete secret space (never from a single fixed secret -- see
    marginal_observation()). Individual pointwise terms may be negative;
    SI(w) itself is a KL divergence and is >= 0 up to floating-point
    precision (or +inf at a zero-prior degeneracy, see pointwise_information).
    """
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    pw = pointwise_information(C, pi)
    pos = C > 0
    terms = np.zeros_like(C)
    terms[pos] = C[pos] * pw[pos]
    return np.sum(terms, axis=1)


def mean_specific_information(C, prior=None):
    """
    E_{W~pi}[SI(W)] = sum_w pi(w) SI(w), in bits.

    Algebraically identical to shannon_mi(C, prior) -- MI is the
    prior-weighted average of the per-secret KL divergence to the marginal.
    Comparing the two independently computed quantities is the standard
    consistency check for this module (see qif_validate.py).
    """
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    si = specific_information(C, pi)
    # 0 * inf must read as 0 here: a secret the prior assigns no mass to
    # contributes nothing to the average regardless of its (possibly
    # infinite) individual SI.
    contrib = np.where(pi > 0, pi * si, 0.0)
    return float(np.sum(contrib))


# ---------------------------------------------------------------------
# Per-secret identifiability (Bayes success)
# ---------------------------------------------------------------------
def bayes_success(C, prior=None):
    """
    succ(w) = Pr[ MAP guess == w | S = w ], ties split evenly, bits in [0, 1].

    The attacker's guessing strategy is fixed independently of the true
    secret: at each observation o, guess uniformly among the s that
    maximise the posterior mass J[s,o] = pi(s) P(o|s). succ(w) is then the
    probability, conditioned on S=w, that this fixed strategy outputs w --
    the per-secret refinement of posterior_vulnerability().

    The prior-weighted mean of succ(w) equals posterior_vulnerability(C, pi)
    exactly: a tied group of k secrets at observation o each take 1/k of
    that group's (equal) posterior mass, and summing back over the group
    recovers max_s J[s,o]; summing over o then gives V1(pi>C). Verified in
    qif_validate.py, along with the closed-form Hamming-weight case
    succ(w) = 1/C(8, HW(w)).
    """
    C = normalise_channel(C)
    pi = uniform_prior(C.shape[0]) if prior is None else np.asarray(prior, float)
    J = joint(C, pi)
    col_max = np.max(J, axis=0)
    is_argmax = np.isclose(J, col_max[None, :], rtol=1e-9, atol=1e-15)
    ties = is_argmax.sum(axis=0).astype(np.float64)
    weight = np.where(is_argmax, 1.0 / ties[None, :], 0.0)
    return np.sum(C * weight, axis=1)


# ---------------------------------------------------------------------
# g-leakage
# ---------------------------------------------------------------------
def g_vulnerability(C, gain, prior=None):
    """
    Posterior g-vulnerability:  V_g = sum_o max_w sum_s J[s,o] g(w,s).

    gain : (|W|, |S|) matrix of g(w, s) in [0, 1].
    """
    C = normalise_channel(C)
    J = joint(C, prior)
    G = np.asarray(gain, dtype=np.float64)
    if G.shape[1] != C.shape[0]:
        raise ValueError("gain has %d secret columns, channel has %d rows"
                         % (G.shape[1], C.shape[0]))
    # For each observation o: max over guesses w of sum_s J[s,o] g[w,s]
    return float(np.sum(np.max(G @ J, axis=0)))


def prior_g_vulnerability(gain, prior=None):
    G = np.asarray(gain, dtype=np.float64)
    pi = uniform_prior(G.shape[1]) if prior is None else np.asarray(prior, float)
    return float(np.max(G @ pi))


def g_leakage(C, gain, prior=None):
    """L_g = log2( V_g(pi>C) / V_g(pi) ), bits."""
    v_post = g_vulnerability(C, gain, prior)
    v_pri = prior_g_vulnerability(gain, prior)
    return float(np.log2(max(v_post, EPS) / max(v_pri, EPS)))


# ---------------------------------------------------------------------
# Gain functions
# ---------------------------------------------------------------------
def gain_identity(values):
    """Exact match. Recovers min-entropy leakage."""
    n = len(values)
    return np.eye(n, dtype=np.float64)


def gain_tolerance(values, eps):
    """
    g(w,s) = 1 iff |w - s| <= eps.

    THE measure for neural-network IP. An adversary who recovers every
    weight to within a few LSB owns a functionally equivalent model, so
    exact-match leakage understates the threat. Sweeping eps gives a
    leakage-versus-tolerance curve that no mean-based test can produce.
    """
    v = np.asarray(values, dtype=np.float64)
    return (np.abs(v[:, None] - v[None, :]) <= eps).astype(np.float64)


def gain_bit(values, k):
    """
    g(w,s) = 1 iff bit k of w equals bit k of s.

    Per-bit leakage, directly comparable to CPA key-bit recovery, which
    puts QIF and CPA on the same axis.
    """
    b = np.array([(int(x) >> k) & 1 for x in values])
    return (b[:, None] == b[None, :]).astype(np.float64)


def gain_sign(values):
    """g(w,s) = 1 iff sign(w) == sign(s). One bit; the ReLU oracle."""
    s = np.sign(np.asarray(values, dtype=np.float64))
    return (s[:, None] == s[None, :]).astype(np.float64)


# ---------------------------------------------------------------------
# Convenience bundle
# ---------------------------------------------------------------------
def all_measures(C, prior=None, values=None, width=8, eps_grid=(0, 1, 2, 4, 8)):
    """Every scalar measure for one channel, as a flat dict of bits."""
    C = normalise_channel(C)
    n = C.shape[0]
    out = {
        "n_secrets": int(n),
        "n_observations": int(C.shape[1]),
        "H_prior": entropy(uniform_prior(n) if prior is None else prior),
        "MI": shannon_mi(C, prior),
        "mean_SI": mean_specific_information(C, prior),
        "H_S_given_O": conditional_entropy_secret(C, prior),
        "L_min": min_entropy_leakage(C, prior),
        "H_inf_S_given_O": conditional_min_entropy(C, prior),
        "V1_post": posterior_vulnerability(C, prior),
    }
    if values is not None:
        vals = np.asarray(values)
        out["L_g_sign"] = g_leakage(C, gain_sign(vals), prior)
        for e in eps_grid:
            out["L_g_eps%d" % e] = g_leakage(C, gain_tolerance(vals, e), prior)
        for k in range(min(width, 8)):
            out["L_g_bit%d" % k] = g_leakage(C, gain_bit(vals, k), prior)
    return out
