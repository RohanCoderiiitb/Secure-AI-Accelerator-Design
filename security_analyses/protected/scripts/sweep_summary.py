#!/usr/bin/env python3
"""Cross-size summary of the array-size sweep (collect + plot).

  collect --metrics M.csv --acc protected --size 4 --t1 s1.csv --t2 s2.csv --adla sa.csv
      append one row per test for this (design, size) to M.csv
  plot    --metrics M.csv --outdir DIR [--n N]
      write the summary PNGs into DIR

Statistic plotted: P_tot (total toggle proxy). ADLA is normalised to its own
permutation threshold so that 1.0 means "detection threshold" for ADLA, just
as 4.5 does for |t|.
"""
import argparse
import csv
import os

TESTS = [("tvla1", "1st-order TVLA", "max |t|", 4.5),
         ("tvla2", "2nd-order TVLA", "max |t|", 4.5),
         ("adla",  "ADLA",           "max $A^2$ / threshold", 1.0)]
COL = {"unprotected": "#c0392b", "protected": "#1f77b4"}
LAB = {"unprotected": "Unprotected", "protected": "Protected (wmask_shared)"}
PROXY = "P_tot"


def rows_of(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def collect(a):
    out = []
    for r in rows_of(a.t1):
        if r["proxy"] == PROXY:
            out.append(("tvla1", float(r["max_abs_t"]), int(r["n_leaking"]), int(r["cycles"])))
    for r in rows_of(a.t2):
        if r["proxy"] == PROXY and r["order"] == "2":
            out.append(("tvla2", float(r["max_abs_t"]), int(r["n_leaking"]), int(r["cycles"])))
    for r in rows_of(a.adla):
        if r["proxy"] == PROXY:
            out.append(("adla", float(r["max_A2"]) / float(r["threshold"]),
                        int(r["n_leaking"]), int(r["cycles"])))
    new = not os.path.exists(a.metrics)
    with open(a.metrics, "a", newline="") as fh:
        w = csv.writer(fh)
        if new:
            w.writerow(["acc", "size", "test", "stat", "n_leaking", "cycles"])
        for t, s, n, c in out:
            w.writerow([a.acc, a.size, t, "%.6g" % s, n, c])


def load(path):
    d = {}
    for r in rows_of(path):
        d.setdefault((r["test"], r["acc"]), {})[int(r["size"])] = (
            float(r["stat"]), int(r["n_leaking"]), int(r["cycles"]))
    return d


def plot(a):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    d = load(a.metrics)
    sizes = sorted({s for v in d.values() for s in v})
    xt = [str(s) + "x" + str(s) for s in sizes]
    sub = "  (N=%s traces per run, %s proxy)" % (a.n, PROXY) if a.n else ""
    os.makedirs(a.outdir, exist_ok=True)

    # ---- 1. max statistic vs array size ----
    fig, axes = plt.subplots(1, 3, figsize=(14, 4.4))
    for ax, (key, name, yl, thr) in zip(axes, TESTS):
        for acc in ("unprotected", "protected"):
            v = d.get((key, acc), {})
            xs = [s for s in sizes if s in v]
            ax.plot(xs, [max(v[s][0], 1e-3) for s in xs], "o-", color=COL[acc],
                    lw=1.8, label=LAB[acc])
        ax.axhline(thr, color="k", ls="--", lw=1.0, label="detection threshold")
        ax.set_yscale("log")
        ax.set_xticks(sizes); ax.set_xticklabels(xt)
        ax.set_xlabel("systolic array size"); ax.set_ylabel(yl)
        ax.set_title(name); ax.grid(alpha=0.3, which="both")
    axes[0].legend(fontsize=8)
    fig.suptitle("Peak leakage statistic vs systolic array size" + sub)
    fig.tight_layout()
    fig.savefig(os.path.join(a.outdir, "summary_peak_statistic_vs_array_size.png"), dpi=200)
    plt.close(fig)

    # ---- 2. fraction of leaking cycles vs array size ----
    fig, axes = plt.subplots(1, 3, figsize=(14, 4.4), sharey=True)
    w = 0.38
    for ax, (key, name, _, _) in zip(axes, TESTS):
        for k, acc in enumerate(("unprotected", "protected")):
            v = d.get((key, acc), {})
            xs = np.array([i for i, s in enumerate(sizes) if s in v])
            ys = [100.0 * v[sizes[i]][1] / v[sizes[i]][2] for i in xs]
            ax.bar(xs + (k - 0.5) * w, ys, w, color=COL[acc], label=LAB[acc])
        ax.set_xticks(range(len(sizes))); ax.set_xticklabels(xt)
        ax.set_xlabel("systolic array size"); ax.set_ylim(0, 105)
        ax.set_title(name); ax.grid(alpha=0.3, axis="y")
    axes[0].set_ylabel("% of capture cycles above threshold")
    axes[0].legend(fontsize=8, loc="center left")
    fig.suptitle("Fraction of leaking clock cycles vs systolic array size" + sub)
    fig.tight_layout()
    fig.savefig(os.path.join(a.outdir, "summary_leaking_cycles_vs_array_size.png"), dpi=200)
    plt.close(fig)

    # ---- 3. leakage reduction factor (unprotected / protected) ----
    fig, ax = plt.subplots(figsize=(7, 4.6))
    for (key, name, _, _), mk in zip(TESTS, "osD"):
        u, p = d.get((key, "unprotected"), {}), d.get((key, "protected"), {})
        xs = [s for s in sizes if s in u and s in p]
        ax.plot(xs, [u[s][0] / max(p[s][0], 1e-3) for s in xs], mk + "-", lw=1.8, label=name)
    ax.axhline(1.0, color="k", ls="--", lw=1.0)
    ax.set_yscale("log")
    ax.set_xticks(sizes); ax.set_xticklabels(xt)
    ax.set_xlabel("systolic array size")
    ax.set_ylabel("peak statistic: unprotected / protected")
    ax.grid(alpha=0.3, which="both"); ax.legend(fontsize=8)
    ax.set_title("Leakage reduction from weight masking" + sub, fontsize=10)
    fig.tight_layout()
    fig.savefig(os.path.join(a.outdir, "summary_leakage_reduction_vs_array_size.png"), dpi=200)
    plt.close(fig)
    print("[plot] wrote 3 summary PNGs to %s" % a.outdir)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    c = sp.add_parser("collect")
    c.add_argument("--metrics", required=True); c.add_argument("--acc", required=True)
    c.add_argument("--size", required=True, type=int)
    c.add_argument("--t1", required=True); c.add_argument("--t2", required=True)
    c.add_argument("--adla", required=True)
    p = sp.add_parser("plot")
    p.add_argument("--metrics", required=True); p.add_argument("--outdir", required=True)
    p.add_argument("--n", default="")
    a = ap.parse_args()
    collect(a) if a.cmd == "collect" else plot(a)
