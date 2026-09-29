#!/usr/bin/env python3
"""
qif_validate.py -- analytic gate for the QIF measures.

QIF is easy to implement plausibly and wrongly. Every function in
qif_measures.py is checked here against a channel whose answer is known
in closed form. Run this BEFORE any RTL touches the pipeline, and re-run
it after any edit to qif_measures.py.

    python3 qif_validate.py

The headline check is the Hamming-weight channel. For a uniform 8-bit
secret, HW(S) is Binomial(8, 1/2), and

    H(HW) = -sum_k C(8,k)/256 * log2( C(8,k)/256 ) = 2.544213... bits

Since HW is a deterministic function of S, I(S;HW) = H(HW) exactly. If
this returns anything but 2.5442, nothing downstream is trustworthy and
there is no point running a single simulation.
"""

import math
import sys

import numpy as np

import qif_estimate as qe
import qif_measures as qm

TOL = 1e-9


def _det_channel(fvals, n_out=None):
    """Deterministic channel from a list f(s) of observation indices."""
    fvals = np.asarray(fvals, dtype=int)
    n_s = fvals.size
    n_o = int(fvals.max()) + 1 if n_out is None else n_out
    C = np.zeros((n_s, n_o), dtype=np.float64)
    C[np.arange(n_s), fvals] = 1.0
    return C


# ---------------------------------------------------------------------
# Reference channels
# ---------------------------------------------------------------------
def case_identity(n=256):
    """O = S. Everything leaks: MI = L_min = log2 n."""
    C = np.eye(n)
    exp = math.log2(n)
    return "identity (n=%d)" % n, C, {"MI": exp, "L_min": exp,
                                      "H_inf_S_given_O": 0.0}


def case_constant(n=256):
    """O = const. Nothing leaks."""
    C = np.zeros((n, 1))
    C[:, 0] = 1.0
    return "constant (n=%d)" % n, C, {"MI": 0.0, "L_min": 0.0,
                                      "H_inf_S_given_O": math.log2(n)}


def case_hamming_weight(width=8):
    """
    O = HW(S) for uniform width-bit S.

    Deterministic, so MI = H(O) = H(Binomial(width, 1/2)).
    For width=8 this is 2.5442127... bits.
    """
    n = 1 << width
    hw = np.array([bin(s).count("1") for s in range(n)])
    C = _det_channel(hw, n_out=width + 1)
    counts = np.array([math.comb(width, k) for k in range(width + 1)],
                      dtype=np.float64)
    p = counts / counts.sum()
    h = float(-np.sum(p * np.log2(p)))
    # Posterior vulnerability of a deterministic channel = |range| / n,
    # so L_min = log2(number of distinct observations).
    lmin = math.log2(width + 1)
    return ("hamming weight (width=%d)" % width, C,
            {"MI": h, "L_min": lmin})


def case_bsc(p=0.11):
    """Binary symmetric channel. I = 1 - h(p)."""
    C = np.array([[1 - p, p], [p, 1 - p]], dtype=np.float64)
    h = -(p * math.log2(p) + (1 - p) * math.log2(1 - p))
    # posterior vulnerability = max(p, 1-p); prior = 1/2
    lmin = math.log2(max(p, 1 - p) / 0.5)
    return "binary symmetric (p=%.3f)" % p, C, {"MI": 1.0 - h, "L_min": lmin}


def case_lsb_drop(width=8, drop=3):
    """
    O = S >> drop. Deterministic many-to-one.
    MI = L_min = width - drop bits exactly.
    """
    n = 1 << width
    f = np.arange(n) >> drop
    C = _det_channel(f)
    exp = float(width - drop)
    return ("drop %d LSBs (width=%d)" % (drop, width), C,
            {"MI": exp, "L_min": exp})


# ---------------------------------------------------------------------
# g-leakage checks
# ---------------------------------------------------------------------
def check_gain_functions():
    """
    Two properties that must hold by construction:

      1. gain_identity reproduces min-entropy leakage exactly.
      2. gain_tolerance with eps large enough to cover the whole space
         gives zero leakage -- if every guess is already correct, an
         observation cannot help.
    """
    rows = []
    vals = np.arange(-128, 128)
    n = vals.size
    rng = np.random.default_rng(0)
    C = qm.normalise_channel(rng.random((n, 40)) + 0.01)

    l_min = qm.min_entropy_leakage(C)
    l_id = qm.g_leakage(C, qm.gain_identity(vals))
    rows.append(("gain_identity == L_min", l_id, l_min, abs(l_id - l_min) < 1e-9))

    l_wide = qm.g_leakage(C, qm.gain_tolerance(vals, 1000))
    rows.append(("gain_tolerance(inf) == 0", l_wide, 0.0, abs(l_wide) < 1e-9))

    # Monotonicity: wider tolerance can never leak more than exact match.
    l0 = qm.g_leakage(C, qm.gain_tolerance(vals, 0))
    l4 = qm.g_leakage(C, qm.gain_tolerance(vals, 4))
    rows.append(("L_g(eps=4) <= L_g(eps=0)", l4, l0, l4 <= l0 + 1e-9))
    return rows


def check_specific_information():
    """
    Five checks on qm.specific_information() / qm.mean_specific_information(),
    matching the SI requirements: no-leakage gives SI=0 everywhere, a
    perfectly revealing channel gives SI=log2|S| everywhere, the
    prior-weighted mean of SI equals MI, pointwise terms may be negative
    while SI itself stays non-negative, and a prior degenerate onto one
    secret trivially zeroes that secret's SI (a prior artifact, not
    evidence of zero physical leakage).
    """
    rows = []

    # TEST 1 -- no leakage: P(O|W=w) = P(O) for every w => SI(w) = 0 for all w.
    _, C, _ = case_constant(n=256)
    si = qm.specific_information(C)
    ok1 = bool(np.max(np.abs(si)) < 1e-9)
    rows.append(("SI no-leakage: max|SI(w)|", float(np.max(np.abs(si))), 0.0, ok1))

    # TEST 2 -- perfectly revealing channel: every secret -> unique
    # observation => SI(w) = log2(|secret space|) for every w (uniform prior).
    _, C, _ = case_identity(n=256)
    si = qm.specific_information(C)
    want = math.log2(256)
    ok2 = bool(np.all(np.abs(si - want) < 1e-9))
    rows.append(("SI perfectly-revealing: min SI(w)", float(np.min(si)), want, ok2))
    rows.append(("SI perfectly-revealing: max SI(w)", float(np.max(si)), want, ok2))

    # TEST 3 -- MI equivalence: sum_w pi(w) SI(w) == MI, on a generic channel.
    rng = np.random.default_rng(3)
    n = 64
    Cr = qm.normalise_channel(rng.random((n, 20)) + 0.01)
    mi = qm.shannon_mi(Cr)
    mean_si = qm.mean_specific_information(Cr)
    ok3 = abs(mean_si - mi) < 1e-9
    rows.append(("SI mean == MI (random 64x20 channel)", mean_si, mi, ok3))

    # TEST 4 -- pointwise information may be negative; SI(w) itself must not
    # be. A row flatter than the marginal (e.g. near-uniform) necessarily
    # produces negative log2(C[w,o]/P(o)) terms for the observations it
    # under-weights relative to the marginal.
    Csk = np.array([
        [0.90, 0.05, 0.05],
        [0.05, 0.90, 0.05],
        [0.05, 0.05, 0.90],
        [0.34, 0.33, 0.33],
    ], dtype=np.float64)
    pw = qm.pointwise_information(Csk)
    finite = np.isfinite(pw)
    has_negative = bool(np.any(pw[finite] < 0.0))
    si4 = qm.specific_information(Csk)
    all_nonneg = bool(np.all(si4 >= -1e-9))
    rows.append(("SI pointwise terms include a negative value (not abs'd)",
                float(has_negative), 1.0, has_negative))
    rows.append(("SI(w) stays non-negative despite negative pointwise terms",
                float(np.min(si4)), 0.0, all_nonneg))

    # TEST 5 -- fixed-secret degeneracy: if P(O) is built with a prior
    # concentrated on one secret w0, P(O) collapses to P(O|w0) and
    # SI(w0) = 0. Documented as an artifact of a degenerate prior, NOT as
    # evidence that w0 has no physical leakage -- P(O) must be built from
    # the complete secret space (see marginal_observation()) for SI to be
    # meaningful, which run_qif.py always does.
    rng2 = np.random.default_rng(11)
    Cd = qm.normalise_channel(rng2.random((8, 12)) + 0.01)
    w0 = 3
    prior_deg = np.zeros(8)
    prior_deg[w0] = 1.0
    si_deg = qm.specific_information(Cd, prior_deg)
    ok5 = abs(si_deg[w0]) < 1e-9
    rows.append(("SI fixed-secret degeneracy: SI(w0) under one-hot prior",
                float(si_deg[w0]), 0.0, ok5))

    return rows


def check_bayes_success():
    """
    Two checks on qm.bayes_success():

      1. Prior-weighted mean of succ(w) equals posterior_vulnerability(C, pi)
         exactly, on a generic random channel -- the identity the function's
         docstring claims (a tied group's mass splits evenly and sums back
         to max_s J[s,o]).
      2. On the closed-form Hamming-weight channel, succ(w) = 1/C(8, HW(w))
         for every secret w: HW(w) has C(8,HW(w)) secrets tied on the same
         observation and equal prior mass, and the true secret's channel row
         is a point mass on that observation.
    """
    rows = []

    rng = np.random.default_rng(13)
    n = 40
    C = qm.normalise_channel(rng.random((n, 15)) + 0.01)
    succ = qm.bayes_success(C)
    pi = qm.uniform_prior(n)
    mean_succ = float(np.sum(pi * succ))
    v_post = qm.posterior_vulnerability(C)
    ok1 = abs(mean_succ - v_post) < 1e-9
    rows.append(("mean succ(w) == posterior_vulnerability (random 40x15 channel)",
                mean_succ, v_post, ok1))

    width = 8
    n8 = 1 << width
    hw = np.array([bin(s).count("1") for s in range(n8)])
    C_hw = _det_channel(hw, n_out=width + 1)
    succ_hw = qm.bayes_success(C_hw)
    want_hw = np.array([1.0 / math.comb(width, k) for k in hw], dtype=np.float64)
    diff_hw = float(np.max(np.abs(succ_hw - want_hw)))
    ok2 = bool(diff_hw < 1e-9)
    rows.append(("HW channel: max |succ(w) - 1/C(8,HW(w))|", diff_hw, 0.0, ok2))

    return rows


def check_gaussian_mixture_si():
    """
    qe.gaussian_mixture_si() must average, under the prior, to
    qe.gaussian_mixture_mi() -- both integrate the identical mixture
    components, so this is the noisy-channel analogue of the SI/MI
    consistency check above. Exercised at several SNRs on a small
    synthetic multi-trace-per-secret dataset, matching the shape of a real
    capture (many traces per secret at one cycle).
    """
    rows = []
    rng = np.random.default_rng(5)
    n_s, per = 12, 30
    secret = np.repeat(np.arange(n_s), per)
    obs = secret.astype(np.float64) * 2.0 + rng.integers(0, 3, size=secret.size)
    pi = qm.uniform_prior(n_s)

    for snr in (100.0, 10.0, 1.0, 0.1):
        sp = float(np.var(obs, ddof=1))
        sigma = float(np.sqrt(sp / snr))
        si = qe.gaussian_mixture_si(secret, obs, sigma, pi)
        mi = qe.gaussian_mixture_mi(secret, obs, sigma, pi)
        mean_si = float(np.sum(pi * si))
        ok = abs(mean_si - mi) < 1e-9
        rows.append(("mean gaussian_mixture_si == gaussian_mixture_mi (SNR=%g)" % snr,
                    mean_si, mi, ok))
    return rows


def check_invariants():
    """
    Structural properties that must hold for any channel:
      MI <= H(S),  L_min <= log2|S|,  MI <= L_min is NOT generally true,
      H(S|O) = H(S) - MI,  H_inf(S|O) = log2|S| - L_min.
    """
    rng = np.random.default_rng(7)
    n = 64
    C = qm.normalise_channel(rng.random((n, 25)) + 0.01)
    hs = math.log2(n)
    mi = qm.shannon_mi(C)
    lmin = qm.min_entropy_leakage(C)
    hso = qm.conditional_entropy_secret(C)
    hinf = qm.conditional_min_entropy(C)
    return [
        ("MI <= H(S)", mi, hs, mi <= hs + 1e-9),
        ("L_min <= log2|S|", lmin, hs, lmin <= hs + 1e-9),
        ("H(S|O) == H(S) - MI", hso, hs - mi, abs(hso - (hs - mi)) < 1e-9),
        ("H_inf(S|O) == log2|S| - L_min", hinf, hs - lmin,
         abs(hinf - (hs - lmin)) < 1e-9),
    ]


# ---------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------
def main():
    print("=" * 74)
    print("QIF ANALYTIC VALIDATION")
    print("=" * 74)
    ok = True

    print("\nCLOSED-FORM CHANNELS")
    for fn in (case_identity, case_constant, case_hamming_weight,
               case_bsc, case_lsb_drop):
        name, C, expected = fn()
        got = qm.all_measures(C)
        for k, want in expected.items():
            have = got[k]
            good = abs(have - want) < 1e-6
            ok &= good
            print("  %-32s %-18s got %12.7f  want %12.7f  [%s]"
                  % (name, k, have, want, "OK" if good else "FAIL"))
        # mean_SI must equal MI for every channel, not just the ones with an
        # explicit expectation above -- this is the SI/MI consistency check.
        good = abs(got["mean_SI"] - got["MI"]) < 1e-6
        ok &= good
        print("  %-32s %-18s got %12.7f  want %12.7f  [%s]"
              % (name, "mean_SI==MI", got["mean_SI"], got["MI"], "OK" if good else "FAIL"))

    print("\nSPECIFIC INFORMATION (SI)")
    for name, have, want, good in check_specific_information():
        ok &= good
        print("  %-56s got %12.7f  ref %12.7f  [%s]"
              % (name, have, want, "OK" if good else "FAIL"))

    print("\nBAYES SUCCESS (IDENTIFIABILITY)")
    for name, have, want, good in check_bayes_success():
        ok &= good
        print("  %-56s got %12.7f  ref %12.7f  [%s]"
              % (name, have, want, "OK" if good else "FAIL"))

    print("\nGAUSSIAN-NOISE SI (qif_estimate.gaussian_mixture_si)")
    for name, have, want, good in check_gaussian_mixture_si():
        ok &= good
        print("  %-56s got %12.7f  ref %12.7f  [%s]"
              % (name, have, want, "OK" if good else "FAIL"))

    print("\nGAIN FUNCTIONS")
    for name, have, want, good in check_gain_functions():
        ok &= good
        print("  %-32s got %12.7f  ref %12.7f  [%s]"
              % (name, have, want, "OK" if good else "FAIL"))

    print("\nINVARIANTS")
    for name, have, want, good in check_invariants():
        ok &= good
        print("  %-32s got %12.7f  ref %12.7f  [%s]"
              % (name, have, want, "OK" if good else "FAIL"))

    print("\n" + "=" * 74)
    if ok:
        print("PASS -- measures agree with closed form. Safe to run on RTL data.")
    else:
        print("FAIL -- do NOT run the pipeline until this passes.")
    print("=" * 74)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
