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
