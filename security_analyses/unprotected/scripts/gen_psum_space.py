#!/usr/bin/env python3
"""
gen_psum_space.py -- exhaustive secret space for SECRET=psum on the
centre PE of the 5x5 array.

The partial sum entering the centre PE (row 2, col 2) in one tile is

    w[0][2]*a0 + w[1][2]*a1        (INT8 weights and activations)

so it lies in [-32512, 32768]. Not every integer in that range is a sum
of two INT8 products: only the reachable values are part of the secret
space -- enumerating unreachable ones would put probability mass on
states the hardware never occupies.

Writes one 32-bit two's-complement hex value per line, ascending, for
$readmemh in tb_qif_array_centre.sv.

    python3 gen_psum_space.py --rows-above 2 --out ../build/psum_space.hex
"""
import argparse
import os

import numpy as np


def reachable_sums(rows_above, width=8):
    v = np.arange(-(1 << (width - 1)), 1 << (width - 1))
    prods = np.unique(np.outer(v, v))
    lo, hi = int(prods.min()), int(prods.max())
    ind = np.zeros(hi - lo + 1, dtype=np.int64)
    ind[prods - lo] = 1
    acc, off = np.array([1], dtype=np.int64), 0
    for _ in range(rows_above):
        acc = np.minimum(np.convolve(acc, ind), 1)
        off += lo
    return np.nonzero(acc)[0] + off


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows-above", type=int, default=2,
                    help="PEs above the target PE in its column (2 for the 5x5 centre)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    vals = reachable_sums(args.rows_above)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w") as fh:
        for x in vals.tolist():
            fh.write("%08x\n" % (x & 0xFFFFFFFF))
    span = int(vals.max() - vals.min() + 1)
    print("[psum] %d reachable values in [%d, %d] (%d unreachable in that range) -> %s"
          % (vals.size, vals.min(), vals.max(), span - vals.size, args.out))


if __name__ == "__main__":
    main()
