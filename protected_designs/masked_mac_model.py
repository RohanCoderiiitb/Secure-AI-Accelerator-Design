#!/usr/bin/env python3
"""
masked_mac_model.py  --  PHASE 1 golden model (weights-only masking)

Executable specification for the RTL written in Phases 2-4.  It answers,
with exact enumeration wherever the space allows, the questions that fix
the hardware design BEFORE any SystemVerilog is edited:

  A. Which additive-share representation is *exact* for the MAC / psum path,
     and how many bits (SHARE_W) does it need?
  B. Why the cheap 8-bit-share option is rejected (it is inexact AND the
     error term is a function of the secret).
  C. Why the 9-bit integer split is rejected (value of w1 leaks the weight).
  D. That wide-modulus shares have exactly zero single-share leakage.
  E. What residual leakage a CORRECT first-order scheme still shows on the
     project's summed-toggle proxy -- so Phase 6 gates are set against the
     right target (zero is NOT the right target for the summed proxy).
  F. A cycle-level model of one column (R rows, T tiles) with shares,
     including the mask_en=0 positive control.

Threat model: the WEIGHT is the secret; activations are public/attacker
known; one weight per PE; 2 additive shares: W = w0 + w1 (mod 2^SHARE_W).

Usage:  python3 masked_mac_model.py [--quick] [--out phase1_results.txt]
Pure numpy; no project imports (so it can be diffed against the RTL
testbench later).
"""
import argparse, sys, math
import numpy as np

N = 8                         # operand width of weight / activation
ACCW = 32                     # accumulator width in the existing RTL
LINES = []


def say(s=""):
    print(s)
    LINES.append(s)


# ----------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------
def sext(x, bits):
    """Interpret integer array x (any int dtype) as a signed `bits`-bit value."""
    x = np.asarray(x, dtype=np.int64) & ((1 << bits) - 1)
    return np.where(x >= (1 << (bits - 1)), x - (1 << bits), x)


def popcount(x):
    x = np.asarray(x, dtype=np.uint64)
    x = x - ((x >> np.uint64(1)) & np.uint64(0x5555555555555555))
    x = (x & np.uint64(0x3333333333333333)) + ((x >> np.uint64(2)) & np.uint64(0x3333333333333333))
    x = (x + (x >> np.uint64(4))) & np.uint64(0x0F0F0F0F0F0F0F0F)
    return ((x * np.uint64(0x0101010101010101)) >> np.uint64(56)).astype(np.int64)


def mi_from_counts(cnt):
    """Shannon MI (bits) of a (secrets x observations) count matrix,
    uniform prior over secrets (every row is renormalised)."""
    cnt = np.asarray(cnt, dtype=np.float64)
    K = cnt.shape[0]
    C = cnt / cnt.sum(axis=1, keepdims=True)
    po = C.mean(axis=0)
    nz = C > 0
    ratio = np.zeros_like(C)
    ratio[nz] = C[nz] / np.broadcast_to(po, C.shape)[nz]
    return float((C[nz] / K * np.log2(ratio[nz])).sum())


def counts_matrix(sec_idx, obs, K):
    """Joint counts from parallel arrays; observations remapped to 0..O-1."""
    uo, inv = np.unique(obs, return_inverse=True)
    cnt = np.zeros((K, uo.size), dtype=np.int64)
    np.add.at(cnt, (sec_idx, inv), 1)
    return cnt


def min_bits(rows, tiles=1):
    """Smallest signed modulus width that holds a column psum without wrap.
    One INT8 x INT8 product lies in [-16256, 16384]."""
    worst = rows * tiles * 16384
    return int(math.ceil(math.log2(worst + 1))) + 1


# ----------------------------------------------------------------------
# A. exactness of the wide-modulus share representation
# ----------------------------------------------------------------------
def exp_A(rng, n_trials, rows=5):
    say("=" * 74)
    say("A. EXACTNESS of additive shares mod 2^M  (random W, a, r; extremes forced in)")
    say("   column of %d rows, single tile; true value = sum_r a_r * W_r" % rows)
    say("   min bits: 1 product = %d, %d-row column = %d, %d rows x 64 tiles = %d"
        % (min_bits(1), rows, min_bits(rows), rows, min_bits(rows, 64)))
    say("   %-5s %-12s %-s" % ("M", "mismatches", "verdict"))
    W = rng.integers(-128, 128, (n_trials, rows))
    a = rng.integers(-128, 128, (n_trials, rows))
    W[:4] = -128; a[:4] = -128          # worst-case positive product 16384
    W[4:8] = 127; a[4:8] = -128         # worst-case negative product
    true = (a * W).sum(axis=1)
    out = {}
    for M in (8, 12, 16, 17, 18, 20, 24, 32):
        mask = (1 << M) - 1
        r = rng.integers(0, 1 << M, (n_trials, rows), dtype=np.int64)
        w0 = r
        w1 = (W - r) & mask
        p0 = ((a * w0) & mask).sum(axis=1) & mask
        p1 = ((a * w1) & mask).sum(axis=1) & mask
        rec = sext((p0 + p1) & mask, M)
        bad = int(np.sum(rec != true))
        need = min_bits(rows)
        verdict = "EXACT" if bad == 0 else "WRAPS (M < %d)" % need
        if bad == 0 and M < need:
            verdict = "exact on this sample, but M < %d is NOT safe" % need
        say("   %-5d %-12d %s" % (M, bad, verdict))
        out[M] = bad
    assert out[18] == 0 and out[32] == 0 and out[8] > 0, "exactness expectation violated"
    say("   => shares must be modulo 2^SHARE_W with SHARE_W >= %d for a %d-row column;"
        % (min_bits(rows), rows))
    say("      the RTL accumulator modulus (ACCW=32) is the safe default.")
    return out


# ----------------------------------------------------------------------
# B. naive 8-bit shares: inexact, and the error term leaks W
# ----------------------------------------------------------------------
def exp_B():
    say("\n" + "=" * 74)
    say("B. NAIVE 8-bit shares (w0+w1 = W mod 256, products taken in 32 bits)")
    Ws = np.arange(-128, 128)
    r = np.arange(256)
    Wg, rg = np.meshgrid(Ws, r, indexing="ij")
    s0 = sext(rg, 8)
    s1 = sext((Wg - rg) & 0xFF, 8)
    k = (s0 + s1 - Wg) // 256            # carry-correction: value in {-1,0,1}
    assert np.all((s0 + s1 - Wg) % 256 == 0)
    frac = float(np.mean(k != 0))
    say("   a*(s0+s1) differs from a*W by 256*a*k, k in {-1,0,1}")
    say("   fraction of (W, r) pairs with k != 0 : %.4f  (inexact => unusable)" % frac)
    cnt = np.zeros((256, 3), dtype=np.int64)
    for i in range(256):
        for kv in (-1, 0, 1):
            cnt[i, kv + 1] = int(np.sum(k[i] == kv))
    mi = mi_from_counts(cnt)
    say("   exact I(W ; k) over uniform r         : %.4f bits" % mi)
    say("   => the correction needed to make it exact is itself a function of the")
    say("      secret.  Rejected: 8-bit shares cannot be repaired without leaking.")
    return frac, mi


# ----------------------------------------------------------------------
# C. 9-bit integer split
# ----------------------------------------------------------------------
def exp_C():
    say("\n" + "=" * 74)
    say("C. INTEGER split  w0 = r (INT8 uniform),  w1 = W - r  (9-bit, exact over Z)")
    Ws = np.arange(-128, 128)
    rs = np.arange(-128, 128)
    Wg, rg = np.meshgrid(Ws, rs, indexing="ij")
    w1 = Wg - rg                                   # [-255, 255]
    cnt = np.zeros((256, 511), dtype=np.int64)
    for i in range(256):
        cnt[i] = np.bincount(w1[i] + 255, minlength=511)
    mi_val = mi_from_counts(cnt)
    hw9 = popcount(w1 & 0x1FF)
    cnt2 = np.zeros((256, 10), dtype=np.int64)
    for i in range(256):
        cnt2[i] = np.bincount(hw9[i], minlength=10)
    mi_hw = mi_from_counts(cnt2)
    say("   exact I(W ; w1)        : %.4f bits   (value of the second share)" % mi_val)
    say("   exact I(W ; HW(w1))    : %.4f bits   (its 9-bit Hamming weight)" % mi_hw)
    say("   => w1 is triangular, not uniform; its value alone leaks ~%.1f bits of W." % mi_val)
    say("      Rejected: a first-order scheme must have I(W; single share) = 0.")
    return mi_val, mi_hw


# ----------------------------------------------------------------------
# D. wide shares: single-share leakage is exactly zero
# ----------------------------------------------------------------------
def exp_D():
    say("\n" + "=" * 74)
    say("D. WIDE shares mod 2^M: single-share leakage (exact enumeration)")
    say("   %-4s %-34s %s" % ("M", "I(W; HW(w1))  I(W; HW(w0))", "I(W; w1) [M<=12]"))
    res = {}
    for M in (8, 10, 12):
        mask = (1 << M) - 1
        Ws = np.arange(-128, 128)
        rs = np.arange(1 << M, dtype=np.int64)
        w1 = (Ws[:, None] - rs[None, :]) & mask
        hw1 = popcount(w1)
        hw0 = popcount(np.broadcast_to(rs, w1.shape))
        c1 = np.stack([np.bincount(hw1[i], minlength=M + 1) for i in range(256)])
        c0 = np.stack([np.bincount(hw0[i], minlength=M + 1) for i in range(256)])
        cv = np.stack([np.bincount(w1[i], minlength=1 << M) for i in range(256)])
        m1, m0, mv = mi_from_counts(c1), mi_from_counts(c0), mi_from_counts(cv)
        say("   %-4d %-34s %.6f" % (M, "%.6f      %.6f" % (m1, m0), mv))
        res[M] = (m1, m0, mv)
        assert abs(m1) < 1e-9 and abs(m0) < 1e-9 and abs(mv) < 1e-9
    say("   => exactly 0 in every case: each share alone is uniform and independent of W.")
    return res


# ----------------------------------------------------------------------
# E. what a CORRECT first-order scheme still leaks on a SUMMED proxy
# ----------------------------------------------------------------------
def exp_E(rng, quick):
    say("\n" + "=" * 74)
    say("E. RESIDUAL on the project's SUMMED-toggle proxy (correct 1st-order scheme)")
    say("   The pipeline sums activity of all dumped nets, i.e. HW(w0)+HW(w1) etc.")
    say("   Marginals are W-independent, so MEANS are flat; the JOINT is not, so")
    say("   VARIANCE (and any bivariate/2nd-order statistic) depends on W.")
    say("")
    say("   observable o_sw = HW(w0)+HW(w1)   (stored shares), exact enumeration")
    say("   %-4s %-22s %-24s %-s" % ("M", "max|E[o|W]-M| (mean)", "Var[o|W] min..max", "I(W;o) bits"))
    res = {}
    for M in ((8, 10, 12) if quick else (8, 10, 12, 14)):
        mask = (1 << M) - 1
        Ws = np.arange(-128, 128)
        rs = np.arange(1 << M, dtype=np.int64)
        w1 = (Ws[:, None] - rs[None, :]) & mask
        o = popcount(w1) + popcount(np.broadcast_to(rs, w1.shape))
        mean = o.mean(axis=1)
        var = o.var(axis=1)
        cnt = np.stack([np.bincount(o[i], minlength=2 * M + 1) for i in range(256)])
        mi = mi_from_counts(cnt)
        say("   %-4d %-22.2e %-24s %.5f"
            % (M, float(np.max(np.abs(mean - M))), "%.4f .. %.4f" % (var.min(), var.max()), mi))
        res[M] = mi
        assert np.max(np.abs(mean - M)) < 1e-9, "first-order mean must be flat"
    say("")
    say("   observable o_sp = HW(a*w0 mod 2^M) + HW(a*w1 mod 2^M), a uniform INT8")
    say("   (product-level activity: the quantity the compute-window proxy sees),")
    say("   Monte-Carlo; null = same-size sample drawn from the POOLED marginal")
    say("   %-4s %-30s %-14s %-14s" % ("M", "range of E[o|W] (noise-only ~5.7 se)", "I(W;o) plug-in", "indep. null"))
    per = 20000 if quick else 60000
    res_sp = {}
    for M in (12, 16):
        mask = (1 << M) - 1
        cnt = np.zeros((256, 2 * M + 1), dtype=np.int64)
        means = np.zeros(256)
        for i, Wv in enumerate(range(-128, 128)):
            a = rng.integers(-128, 128, per)
            r = rng.integers(0, 1 << M, per, dtype=np.int64)
            p0 = (a * r) & mask
            p1 = (a * ((Wv - r) & mask)) & mask
            o = popcount(p0) + popcount(p1)
            cnt[i] = np.bincount(o, minlength=2 * M + 1)
            means[i] = o.mean()
        mi = mi_from_counts(cnt)
        pooled = cnt.sum(axis=0) / cnt.sum()
        null_cnt = np.stack([rng.multinomial(per, pooled) for _ in range(256)])
        null = mi_from_counts(null_cnt)
        se = math.sqrt(float(np.mean(
            [(cnt[i] * (np.arange(2 * M + 1) - means[i]) ** 2).sum() / per for i in range(256)])) / per)
        say("   %-4d %-30s %-14.5f %-14.5f"
            % (M, "%.4f  (se %.4f)" % (means.max() - means.min(), se), mi, null))
        res_sp[M] = (mi, null)
    # apples-to-apples reference: the SAME product-level observable, UNMASKED
    M = 16
    mask = (1 << M) - 1
    cnt_u = np.zeros((256, M + 1), dtype=np.int64)
    for i, Wv in enumerate(range(-128, 128)):
        a = rng.integers(-128, 128, per)
        cnt_u[i] = np.bincount(popcount((a * Wv) & mask), minlength=M + 1)
    mi_unmasked = mi_from_counts(cnt_u)
    say("   reference, UNMASKED, same observable HW(a*W mod 2^16): I(W;o) = %.5f bit"
        % mi_unmasked)
    say("   => on this product-level proxy masking cuts MI by ~%.0fx (model prediction,"
        % (mi_unmasked / max(res_sp[16][0] - res_sp[16][1], 1e-9)))
    say("      NOT a measurement of the RTL; the RTL measurement is Phase 6).")
    say("")
    say("   Reading (two DIFFERENT observables -- do not conflate them):")
    say("   * o_sw (summed Hamming weight of the two STORED shares) keeps ~0.2 bit")
    say("     of I(W;o).  This is inherent to any 2-share scheme.  It only matters for")
    say("     HW-of-state observation and for the weight-LOAD phase; during a compute")
    say("     window the share registers are stationary, so the project's P_reg/P_comb")
    say("     toggle proxies do not see it (P_hw is stored by vcd_power but no driver uses it).")
    say("   * o_sp (product-level activity) is what the compute window exposes: flat")
    say("     mean (range is within sampling noise) and a small residual MI (above).")
    say("     Phase 6 compares the RTL against THIS residual, not against zero.")
    say("   Gates: 1st-order TVLA (means) must show no detection; ADLA / 2nd-order TVLA /")
    say("   QIF may show this small residual.")
    return res


# ----------------------------------------------------------------------
# F. cycle-level column model with shares (+ mask_en = 0 control)
# ----------------------------------------------------------------------
def column_masked(Wcol, acts, M, mask_en, rng):
    """Model one PE column the way the RTL will: per-PE shares loaded at
    wt_load, psum0/psum1 chains, recombination at the south port."""
    mask = (1 << M) - 1
    R = len(Wcol)
    r = rng.integers(0, 1 << M, R, dtype=np.int64) if mask_en else np.zeros(R, np.int64)
    w0 = r
    w1 = (Wcol - r) & mask                       # sext(W) - r  mod 2^M
    ps0 = np.zeros(acts.shape[0], dtype=np.int64)
    ps1 = np.zeros(acts.shape[0], dtype=np.int64)
    for row in range(R):                          # north -> south chain
        ps0 = (ps0 + acts[:, row] * w0[row]) & mask
        ps1 = (ps1 + acts[:, row] * w1[row]) & mask
    return ps0, ps1, sext((ps0 + ps1) & mask, M)


def exp_F(rng, rows=5, vecs=2000, M=ACCW):
    say("\n" + "=" * 74)
    say("F. CYCLE-LEVEL column model, R=%d rows, SHARE_W=%d" % (rows, M))
    bad = 0
    leak_off = 0
    for trial in range(400):
        Wcol = rng.integers(-128, 128, rows)
        acts = rng.integers(-128, 128, (vecs // 20, rows))
        ref = (acts * Wcol[None, :]).sum(axis=1)
        p0, p1, rec = column_masked(Wcol, acts, M, True, rng)
        bad += int(np.sum(rec != ref))
        q0, q1, rec0 = column_masked(Wcol, acts, M, False, rng)
        bad += int(np.sum(rec0 != ref))
        leak_off += int(np.sum(q0 != 0))          # share 0 must be all-zero when masks off
    say("   400 random columns x %d vectors: recombination mismatches = %d" % (vecs // 20, bad))
    say("   mask_en=0 positive control: share-0 chain nonzero count = %d (must be 0)" % leak_off)
    assert bad == 0 and leak_off == 0
    say("   => golden behaviour: psum0+psum1 == unmasked psum for every mask value;")
    say("      mask_en=0 collapses to the unmasked datapath (w0=0, w1=W).")


# ----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    say("PHASE 1 GOLDEN MODEL  (seed=%d%s)" % (args.seed, ", quick" if args.quick else ""))
    exp_A(rng, 200000 if args.quick else 1000000)
    exp_B()
    exp_C()
    exp_D()
    exp_E(rng, args.quick)
    exp_F(rng)
    say("\nALL GOLDEN-MODEL ASSERTIONS PASSED")
    if args.out:
        with open(args.out, "w") as fh:
            fh.write("\n".join(LINES) + "\n")


if __name__ == "__main__":
    main()
