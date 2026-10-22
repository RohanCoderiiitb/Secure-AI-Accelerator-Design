#!/usr/bin/env python3
"""
Regenerate every random byte tb_qif_systolic.sv drew, from the seed alone.
Draw order per trace (30 draws): secret(w00), context(a0), w[r][c] in
row-major order skipping (0,0) [24 draws], then a[1..4] [4 draws].
Returns W (n,5,5) int8 and A (n,5) int8.
"""
import numpy as np
M = (1 << 64) - 1
ROWS = COLS = 5

def replay(n_traces, seed=1):
    x = (88172645463325252 + seed) & M
    def draw():
        nonlocal x
        x ^= x >> 12
        x ^= (x << 25) & M
        x ^= x >> 27
        r = (x * 2685821657736338717) & M
        v = (r >> 33) & 0xFF
        return v - 256 if v > 127 else v
    W = np.zeros((n_traces, ROWS, COLS), dtype=np.int16)
    A = np.zeros((n_traces, ROWS), dtype=np.int16)
    for i in range(n_traces):
        W[i, 0, 0] = draw()
        A[i, 0] = draw()
        for r in range(ROWS):
            for c in range(COLS):
                if not (r == 0 and c == 0):
                    W[i, r, c] = draw()
        for r in range(1, ROWS):
            A[i, r] = draw()
    return W.astype(np.int8), A.astype(np.int8)

if __name__ == "__main__":
    import csv, sys
    meta = sys.argv[1]
    rows = [r for r in csv.reader(l for l in open(meta) if not l.startswith('#'))]
    h = rows[0]; d = rows[1:]
    sv = np.array([int(r[h.index('secret_val')]) for r in d])
    cv = np.array([int(r[h.index('context_val')]) for r in d])
    W, A = replay(len(d), seed=1)
    print("traces checked:", len(d))
    print("w[0][0] replay == meta secret_val :", bool(np.all(W[:,0,0] == sv)))
    print("a[0]    replay == meta context_val:", bool(np.all(A[:,0]   == cv)))
