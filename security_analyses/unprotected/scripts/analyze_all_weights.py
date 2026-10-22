#!/usr/bin/env python3
"""
analyze_all_weights.py -- cumulative leakage of ALL 25 weights of the
5x5 systolic array from the random-trace run of tb_qif_systolic.sv.

WHY A BRACKET, NOT ONE NUMBER
-----------------------------
With all 25 weights secret the secret space is 2^200. Every trace has a
different secret, so an enumerated channel matrix p(o|s) has one sample
per row and plug-in I(S;O) collapses to H(O) whatever the true leakage
is. That number is meaningless, so it is never computed here.

What CAN be measured soundly, because the 25 weights are iid by
construction (independent draws from the testbench PRNG):

  chain rule:    I(W1..W25 ; O) = sum_i I(Wi ; O | W1..W(i-1))
  independence:  I(Wi ; O | W<i) >= I(Wi ; O)        (Wi indep. of W<i)
  =>  LOWER BOUND   I(W ; O)  >=  sum_i I(Wi ; O)
      UPPER BOUND   I(W ; O)  <=  H(O)

for a single observation O (one cycle of one toggle-count proxy), with
the activations and the other weights marginalised out.

Every quantity is computed on a quantile-binned copy of O. Coarsening
O can only lose information (data-processing inequality), so all
numbers are statements about the binned observable and the true
leakage through the unbinned observable is at least as large. Binning
is what keeps the estimator usable: with 256 secret values and ~1700
distinct raw observations the plug-in MI is dominated by estimator
bias (see qif_estimate.py's header).

BIAS HANDLING
-------------
Per weight and per cycle, secret labels are permuted n_perm times and
the MI recomputed. The null MEAN is subtracted (bias-corrected excess),
and a weight only counts toward the lower bound if its plug-in MI
exceeds the null 99th percentile at that cycle. Everything else
contributes 0, which keeps the lower bound conservative.

LIMITS OF THE BRACKET (read before quoting a number)
----------------------------------------------------
* Sum-of-marginals can be far below the true joint leakage when many
  weights contribute redundantly to the same scalar (see --selftest
  scenario A, where it recovers well under a sixth of the truth).
* H(O) is a ceiling on any scalar observation, not an estimate of
  leakage; here O also depends on the marginalised activations.
* Both ends describe ONE scalar toggle-count sample per cycle, with
  unknown activations. An attacker who knows the activations, or who
  measures per-PE power, gets more.
"""
import argparse
import math
import sys

import numpy as np

ROWS = COLS = 5
NW = ROWS * COLS


# ----------------------------------------------------------------------
# information-theoretic helpers (counts in, bits out)
# ----------------------------------------------------------------------
def mi_counts(J):
    N = J.sum()
    if N <= 0:
        return 0.0
    p = J / N
    ps = p.sum(axis=1, keepdims=True)
    po = p.sum(axis=0, keepdims=True)
    nz = p > 0
    return float(np.sum(p[nz] * np.log2(p[nz] / (ps @ po)[nz])))


def entropy_counts(c, mm=True):
    c = np.asarray(c, dtype=np.float64)
    N = c.sum()
    if N <= 0:
        return 0.0
    p = c[c > 0] / N
    h = float(-np.sum(p * np.log2(p)))
    if mm:
        h += (int(np.sum(c > 0)) - 1) / (2.0 * N * math.log(2.0))
    return h


def quantile_bin(x, n_bins):
    """Equal-mass bins; <= n_bins bins when x has ties/few distinct values."""
    x = np.asarray(x)
    edges = np.unique(np.quantile(x, np.linspace(0, 1, n_bins + 1)[1:-1]))
    return np.searchsorted(edges, x, side="right")


# ----------------------------------------------------------------------
# core analysis
# ----------------------------------------------------------------------
def analyse_proxy(P, W, n_bins=32, n_perm=100, seed=0, secrets_per_weight=256):
    """
    P : (N, T) toggle counts for one proxy.  W : (N, 25) int8 weights.
    Returns dict of arrays indexed [weight, cycle] / [cycle].
    """
    N, T = P.shape
    rng = np.random.default_rng(seed)
    live = [t for t in range(T) if np.ptp(P[:, t]) > 0]

    obs = {t: quantile_bin(P[:, t], n_bins) for t in live}
    nb = {t: int(obs[t].max()) + 1 for t in live}
    S = secrets_per_weight

    mi = np.zeros((NW, T))
    null_mean = np.zeros((NW, T))
    null_p99 = np.zeros((NW, T))

    for k in range(NW):
        s = W[:, k].astype(np.int64) + 128
        for t in live:
            J = np.bincount(s * nb[t] + obs[t], minlength=S * nb[t]).reshape(S, nb[t])
            mi[k, t] = mi_counts(J)
        nul = np.zeros((n_perm, T))
        for i in range(n_perm):
            sp = rng.permutation(s)
            for t in live:
                J = np.bincount(sp * nb[t] + obs[t], minlength=S * nb[t]).reshape(S, nb[t])
                nul[i, t] = mi_counts(J)
        null_mean[k] = nul.mean(axis=0)
        null_p99[k] = np.percentile(nul, 99, axis=0)

    excess = mi - null_mean
    sig = mi > null_p99
    for t in range(T):
        if t not in live:
            sig[:, t] = False
            excess[:, t] = 0.0

    lower = np.sum(np.where(sig, excess, 0.0), axis=0)

    h_bin = np.zeros(T)
    h_fine = np.zeros(T)
    for t in live:
        h_bin[t] = entropy_counts(np.bincount(obs[t]))
        _, cnt = np.unique(P[:, t], return_counts=True)
        h_fine[t] = entropy_counts(cnt)

    return dict(mi=mi, excess=excess, sig=sig, null_mean=null_mean,
                null_p99=null_p99, lower=lower, h_bin=h_bin, h_fine=h_fine,
                live=live, n_bins=n_bins, n=N)


def report(name, r, out=sys.stdout):
    T = len(r["lower"])
    w = lambda s="": print(s, file=out)
    w("=" * 78)
    w("PROXY %s   (N=%d traces, %d quantile bins, 25 weights x 8 bits = 200 bits)"
      % (name, r["n"], r["n_bins"]))
    w("=" * 78)
    w("  cycle | #sig weights | LOWER sum(I(wi;O)) | CEIL H(O_binned) | CEIL H(O_raw)")
    for t in range(T):
        if t not in r["live"]:
            w("  %5d |      -       |         -          |        -         |      -" % t)
            continue
        w("  %5d | %8d     | %12.4f bits | %11.4f bits | %9.4f bits"
          % (t, int(r["sig"][:, t].sum()), r["lower"][t], r["h_bin"][t], r["h_fine"][t]))
    tb = int(np.argmax(r["lower"]))
    w()
    w("  best cycle for the lower bound: %d" % tb)
    w("  CUMULATIVE LEAKAGE through one observation at cycle %d (binned observable):" % tb)
    w("     lower bound  : %8.4f bits  (%5.2f%% of 200)   [sum of significant per-weight MI]"
      % (r["lower"][tb], 100 * r["lower"][tb] / 200.0))
    w("     upper bound  : %8.4f bits  (binned H(O));  raw-observable ceiling %.4f bits"
      % (r["h_bin"][tb], r["h_fine"][tb]))
    w()
    w("  per-weight bias-corrected MI at cycle %d (bits; * = above null p99, else shown 0):" % tb)
    w("            " + "".join("   col%d  " % c for c in range(COLS)))
    for rr in range(ROWS):
        cells = []
        for c in range(COLS):
            k = rr * COLS + c
            v = r["excess"][k, tb] if r["sig"][k, tb] else 0.0
            cells.append("%6.3f%s " % (v, "*" if r["sig"][k, tb] else " "))
        w("   row%d    " % rr + " ".join(cells))
    w()
    return tb


# ----------------------------------------------------------------------
# self-test with analytically known answers
# ----------------------------------------------------------------------
def _binom_entropy(n):
    p = np.array([math.comb(n, k) for k in range(n + 1)], dtype=np.float64)
    p /= p.sum()
    return float(-np.sum(p[p > 0] * np.log2(p[p > 0])))


def selftest(n=100000, n_bins=32, n_perm=100):
    print("SELF-TEST: synthetic observables with analytically known leakage")
    rng = np.random.default_rng(123)
    W = rng.integers(-128, 128, size=(n, NW)).astype(np.int8)
    hw = np.array([bin(v & 0xFF).count("1") for v in range(256)])
    HW = hw[(W.astype(np.int16) & 0xFF)]            # (n, 25) Hamming weights
    ok = True

    for label, active in (("A: all 25 weights add HW(w) to O", 25),
                          ("B: only weights 0..11 add HW(w) to O", 12)):
        O = HW[:, :active].sum(axis=1).astype(np.float64)[:, None]
        per = _binom_entropy(8 * active) - _binom_entropy(8 * (active - 1))
        joint = _binom_entropy(8 * active)
        r = analyse_proxy(O, W, n_bins=n_bins, n_perm=n_perm, seed=1)
        got_act = r["excess"][:active, 0]
        got_dead = r["sig"][active:, 0]
        print("\n  scenario %s" % label)
        print("    true per-active-weight I(wi;O)      : %.4f bits" % per)
        print("    estimated (binned, bias-corrected)  : mean %.4f  min %.4f  max %.4f"
              % (got_act.mean(), got_act.min(), got_act.max()))
        print("    true sum of marginals / true joint  : %.4f / %.4f bits  (joint = H(O) here)"
              % (active * per, joint))
        print("    estimated lower / binned ceiling    : %.4f / %.4f bits"
              % (r["lower"][0], r["h_bin"][0]))
        if active < NW:
            fp = int(got_dead.sum())
            print("    inactive weights flagged significant: %d of %d (expect ~1%% false alarms)"
                  % (fp, NW - active))
            ok &= fp <= 2
        ok &= abs(got_act.mean() - per) < 0.02
        ok &= int(r["sig"][:active, 0].sum()) >= active - 1
        ok &= r["lower"][0] <= joint + 0.05 and r["lower"][0] <= r["h_bin"][0] + 0.05
        ok &= abs(r["h_fine"][0] - joint) < 0.05
    print("\n  SELF-TEST %s" % ("PASS" if ok else "FAIL"))
    return ok


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", help="npz from vcd_power.py for the tb_qif_systolic run")
    ap.add_argument("--proxy", nargs="+", default=["P_tot"],
                    help="P_reg P_comb P_tot (default P_tot)")
    ap.add_argument("--seed", type=int, default=None,
                    help="testbench +SEED= (default: read from npz)")
    ap.add_argument("--start", type=int, default=0,
                    help="qif_idx of the first trace in this npz (for +RESUME= chunks)")
    ap.add_argument("--bins", type=int, default=32)
    ap.add_argument("--perms", type=int, default=100)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        sys.exit(0 if selftest(n_bins=a.bins, n_perm=a.perms) else 1)
    if not a.npz:
        ap.error("--npz required (or --selftest)")

    from replay_weights import replay

    d = np.load(a.npz, allow_pickle=True)
    n = len(d["secret_val"])
    seed = a.seed if a.seed is not None else int(d["seed"])
    print("replaying %d traces (start index %d) from seed %d ..." % (n, a.start, seed))
    Wall, _ = replay(a.start + n, seed=seed)
    W = Wall[a.start:].reshape(n, NW)

    if not np.array_equal(W[:, 0].astype(int), d["secret_val"].astype(int)):
        sys.exit("ALIGNMENT FAILED: replayed w[0][0] != npz secret_val. Wrong --seed/--start, "
                 "or the testbench version differs. Refusing to analyse mismatched data.")
    print("alignment verified: replayed w[0][0] matches all %d logged secret values\n" % n)

    for name in a.proxy:
        r = analyse_proxy(np.asarray(d[name], dtype=np.float64), W,
                          n_bins=a.bins, n_perm=a.perms)
        report(name, r)


if __name__ == "__main__":
    main()
