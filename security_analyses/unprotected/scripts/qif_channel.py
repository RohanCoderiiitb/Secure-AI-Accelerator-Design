#!/usr/bin/env python3
"""
qif_channel.py -- build p(o|s) from enumerated simulation traces.

Turns the (secret, context, observable) arrays produced by the capture
layer into channel matrices that qif_measures.py can consume.

THE EXACTNESS FLAG IS THE POINT OF THIS MODULE
----------------------------------------------
A channel is EXACT when every secret in the declared secret space was
simulated the full number of times the enumeration schedule promised. In
zero-delay RTL the map from inputs to toggle count is deterministic, so
an exhaustively enumerated channel is the TRUE channel, not an estimate
of it, and the resulting MI carries no estimator bias whatsoever.

A channel is SAMPLED when the context space had to be subsampled. Then
p(o|s) is an estimate and everything downstream inherits estimator bias,
which qif_estimate.py corrects and bounds.

That distinction is the difference between reporting a bound and
reporting a guess, so it is tracked per channel and propagated all the
way to the output CSV. Never merge exact and sampled numbers into one
column without the flag.

THREAT MODEL: MARGINAL ONLY
---------------------------
The observable depends on the full input state, O = f(S, K), where K is
public context. The attacker is assumed to know NEITHER the secret nor
the context, so K is marginalised out of p(o|s) rather than conditioned
on, and its variation acts as algorithmic noise. This is the
conservative, weakest-attacker assumption.

Marginalising still REQUIRES the context to be enumerated in the
capture: I(S;O) integrates K out, so complete coverage is what makes the
integration exact rather than sampled. Contexts are summed into the same
channel rows, never split across them.

build_conditional() is retained for diagnostics only -- nothing in the
reporting path calls it. Conditioning on K would describe a stronger
attacker and is deliberately out of scope.
"""

import numpy as np


class Channel:
    """A channel matrix plus the provenance needed to interpret it."""

    __slots__ = ("C", "secret_values", "obs_values", "exact", "n_traces",
                 "context_id", "cycle", "proxy", "note")

    def __init__(self, C, secret_values, obs_values, exact, n_traces,
                 context_id=None, cycle=None, proxy=None, note=""):
        self.C = C
        self.secret_values = np.asarray(secret_values)
        self.obs_values = np.asarray(obs_values)
        self.exact = bool(exact)
        self.n_traces = int(n_traces)
        self.context_id = context_id
        self.cycle = cycle
        self.proxy = proxy
        self.note = note

    def __repr__(self):
        return ("Channel(%dx%d, %s, n=%d, cycle=%s, proxy=%s)"
                % (self.C.shape[0], self.C.shape[1],
                   "EXACT" if self.exact else "SAMPLED",
                   self.n_traces, self.cycle, self.proxy))


# ---------------------------------------------------------------------
# Observable preparation
# ---------------------------------------------------------------------
def quantise(obs, n_bins=None):
    """
    Map observations to contiguous integer indices.

    Toggle counts are already small non-negative integers, so the default
    is an identity relabelling that preserves every distinct value. Only
    pass n_bins when the observable is continuous (noise has been added)
    -- binning a discrete observable throws away resolution for nothing.
    """
    obs = np.asarray(obs)
    if n_bins is None:
        vals, idx = np.unique(obs, return_inverse=True)
        return idx, vals
    lo, hi = float(obs.min()), float(obs.max())
    if hi <= lo:
        return np.zeros(obs.size, dtype=int), np.array([lo])
    edges = np.linspace(lo, hi, n_bins + 1)
    idx = np.clip(np.digitize(obs, edges[1:-1]), 0, n_bins - 1)
    centres = 0.5 * (edges[:-1] + edges[1:])
    return idx, centres


# ---------------------------------------------------------------------
# Channel construction
# ---------------------------------------------------------------------
def build(secret, obs, secret_space=None, n_bins=None, expect_per_secret=None,
          cycle=None, proxy=None, context_id=None):
    """
    Build one channel from paired (secret, observable) samples.

    secret            length-N array of secret values
    obs               length-N array of observations at one time sample
    secret_space      declared secret values; defaults to those observed.
                      Pass it explicitly so a secret that was enumerated
                      but never produced a trace shows up as a missing
                      row rather than silently shrinking the space.
    expect_per_secret how many traces each secret should have. When given,
                      the channel is marked EXACT only if every secret hit
                      exactly that count.
    """
    secret = np.asarray(secret)
    obs = np.asarray(obs)
    if secret.shape[0] != obs.shape[0]:
        raise ValueError("secret and obs length mismatch: %d vs %d"
                         % (secret.shape[0], obs.shape[0]))

    s_vals = np.unique(secret) if secret_space is None else np.asarray(secret_space)
    s_index = {v: i for i, v in enumerate(s_vals.tolist())}
    o_idx, o_vals = quantise(obs, n_bins)

    n_s, n_o = s_vals.size, o_vals.size
    counts = np.zeros((n_s, n_o), dtype=np.float64)

    rows = np.array([s_index.get(v, -1) for v in secret.tolist()])
    keep = rows >= 0
    np.add.at(counts, (rows[keep], o_idx[keep]), 1.0)

    per_secret = counts.sum(axis=1)
    missing = int(np.sum(per_secret == 0))
    if missing:
        raise ValueError("%d of %d secrets have no traces -- the enumeration "
                         "did not complete" % (missing, n_s))

    if expect_per_secret is None:
        exact = bool(np.all(per_secret == per_secret[0]))
        note = ("balanced, %d traces per secret" % int(per_secret[0])
                if exact else "unbalanced trace counts per secret")
    else:
        exact = bool(np.all(per_secret == expect_per_secret))
        note = ("exhaustive, %d per secret" % expect_per_secret if exact
                else "incomplete: min %d, max %d, expected %d"
                     % (per_secret.min(), per_secret.max(), expect_per_secret))

    C = counts / per_secret[:, None]
    return Channel(C, s_vals, o_vals, exact, secret.shape[0],
                   context_id=context_id, cycle=cycle, proxy=proxy, note=note)


def build_per_cycle(secret, P, secret_space=None, n_bins=None,
                    expect_per_secret=None, proxy=None):
    """
    One channel per clock cycle from an (N, T) power matrix.

    The per-cycle profile is the reportable form: it is literally the
    'leaked bits per clock cycle' figure, and it plots alongside the |t|
    and A^2 profiles from the first-order tests.
    """
    P = np.asarray(P)
    return [build(secret, P[:, t], secret_space=secret_space, n_bins=n_bins,
                  expect_per_secret=expect_per_secret, cycle=t, proxy=proxy)
            for t in range(P.shape[1])]


# ---------------------------------------------------------------------
# Threat models
# ---------------------------------------------------------------------
def build_conditional(secret, context, P, cycle, secret_space=None,
                      n_bins=None, proxy=None, min_per_secret=1):
    """
    One exact channel per enumerated context value.

    Returns a list of Channel, one per context k with complete coverage of
    the secret space. Contexts with incomplete coverage are dropped and
    reported, rather than silently producing a ragged channel.
    """
    secret = np.asarray(secret)
    context = np.asarray(context)
    P = np.asarray(P)
    s_vals = np.unique(secret) if secret_space is None else np.asarray(secret_space)

    out, dropped = [], 0
    for k in np.unique(context):
        m = context == k
        if np.unique(secret[m]).size != s_vals.size:
            dropped += 1
            continue
        cnt = np.bincount(np.searchsorted(s_vals, secret[m]),
                          minlength=s_vals.size)
        out.append(build(secret[m], P[m, cycle], secret_space=s_vals,
                         n_bins=n_bins, expect_per_secret=int(cnt.min()),
                         cycle=cycle, proxy=proxy, context_id=int(k)))
    return out, dropped


def marginal_channel(secret, P, cycle, secret_space=None, n_bins=None,
                     proxy=None):
    """
    I(S;O) with context marginalised -- the weakest-attacker model.

    Exact only if the context space was itself enumerated exhaustively.
    For the 5x5 array it never is, so this channel is marked SAMPLED and
    its MI must go through the bias correction in qif_estimate.py.
    """
    ch = build(secret, P[:, cycle], secret_space=secret_space, n_bins=n_bins,
               cycle=cycle, proxy=proxy)
    ch.note += " | context marginalised"
    return ch