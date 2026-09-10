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
