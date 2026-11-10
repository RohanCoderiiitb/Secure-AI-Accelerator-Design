#!/usr/bin/env python3
"""Capture-window check: the power proxy must be back at idle at the end of
every captured trace.

Reads the .npz written by vcd_power.py and fails (exit 1) if, in ANY trace,
the last IDLE captured cycles (default 3) show any activity in the dumped
scope (P_tot = register Hamming distance + combinational toggles). A
non-zero value there means the window was cut while the design was still
working on the trace, i.e. leakage after the window would be missed.

Usage: check_capture_idle.py --npz traces/x.npz [--idle 3] [--tol 0]
"""
import argparse
import sys

import numpy as np


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--npz", required=True)
    ap.add_argument("--idle", type=int, default=3, help="trailing cycles that must be idle")
    ap.add_argument("--tol", type=float, default=0.0, help="allowed toggles per idle cycle")
    a = ap.parse_args()

    d = np.load(a.npz, allow_pickle=True)
    P = d["P_tot"]
    ntr, ncyc = P.shape
    tail = P[:, -a.idle:]
    busy = tail.max(axis=1) > a.tol
    mean = P.mean(axis=0)
    last_active = int(np.nonzero(mean > a.tol)[0].max()) if (mean > a.tol).any() else -1
    print(f"[idle-check] {a.npz}: {ntr} traces x {ncyc} cycles (dut={d['dut']})")
    print("[idle-check] mean activity, last 6 cycles: "
          + " ".join(f"{v:.1f}" for v in mean[-6:]))
    print(f"[idle-check] last cycle with activity (mean over traces): {last_active}")
    if busy.any():
        print(f"[idle-check] FAIL: {int(busy.sum())} of {ntr} traces still active in the last "
              f"{a.idle} captured cycles -- enlarge the capture window")
        sys.exit(1)
    print(f"[idle-check] PASS: every trace idle in its last {a.idle} captured cycles")


if __name__ == "__main__":
    main()
