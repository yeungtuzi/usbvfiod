#!/usr/bin/env python3
"""Summarise a batch of demo logs into a CSV and a pass-rate confidence interval.

Kept separate from acceptance-batch.sh so that a running batch is never edited.
Reads every *.log in the batch directory, derives the per-run metrics from the
demo's own output, and prints aggregate statistics.

Usage: summarize-batch.py <batch-dir> [glob]
"""
from __future__ import annotations

import glob
import math
import os
import re
import statistics
import sys

PATTERNS = {
    "downtime_ms": re.compile(r"downtime of (\d+)ms"),
    "copy_s": re.compile(r"^copy duration\s+:\s+([\d.]+)", re.M),
    "spans": re.compile(r"^spans migration\s+:\s+(\w+)", re.M),
    "md5": re.compile(r"^md5 verdict\s+:\s+(\S+)", re.M),
    "late_enum": re.compile(r"^enumerations after migration\s+:\s+(-?\d+)", re.M),
    "late_err": re.compile(r"^reset/error lines after migr\.\s*:\s+(-?\d+)", re.M),
    "kicks": re.compile(r"^interrupt lines installed\s+:\s+(\d+)", re.M),
    "stale": re.compile(r"^stale teardowns ignored\s+:\s+(\d+)", re.M),
    "verdict": re.compile(r"^VERDICT\s+:\s+(\w+)", re.M),
    "ctrl_md5": re.compile(r"^md5 \(copy\)\s+:\s+([0-9a-f]{32})", re.M),
    "ctrl_expected": re.compile(r"^expected\s+:\s+([0-9a-f]{32})", re.M),
    "ctrl_spans": re.compile(r"CONTROL RESULT", re.M),
}


def grab(pattern: re.Pattern, text: str) -> str:
    """First capture group if the pattern has one, else the whole match.

    The control marker ("CONTROL RESULT") is used as a presence test and has no
    group; assuming every pattern had one crashed the summariser on the control
    batch.
    """
    m = pattern.search(text)
    if not m:
        return ""
    return m.group(1) if pattern.groups else (m.group(0) or "")


def clopper_pearson(k: int, n: int) -> tuple[float, float]:
    """Exact 95% interval via bisection on the regularised incomplete beta."""
    def betacf(a: float, b: float, x: float) -> float:
        qab, qap, qam = a + b, a + 1.0, a - 1.0
        c, d = 1.0, 1.0 - qab * x / qap
        if abs(d) < 1e-30:
            d = 1e-30
        d = 1.0 / d
        h = d
        for m in range(1, 300):
            m2 = 2 * m
            aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1.0 + aa * d
            if abs(d) < 1e-30:
                d = 1e-30
            c = 1.0 + aa / c
            if abs(c) < 1e-30:
                c = 1e-30
            d = 1.0 / d
            h *= d * c
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1.0 + aa * d
            if abs(d) < 1e-30:
                d = 1e-30
            c = 1.0 + aa / c
            if abs(c) < 1e-30:
                c = 1e-30
            d = 1.0 / d
            de = d * c
            h *= de
            if abs(de - 1.0) < 1e-12:
                break
        return h

    def betai(a: float, b: float, x: float) -> float:
        if x <= 0.0:
            return 0.0
        if x >= 1.0:
            return 1.0
        lbeta = math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)
        front = math.exp(-lbeta + a * math.log(x) + b * math.log(1.0 - x))
        if x < (a + 1.0) / (a + b + 2.0):
            return front * betacf(a, b, x) / a
        return 1.0 - front * betacf(b, a, 1.0 - x) / b

    def invert(p: float, a: float, b: float) -> float:
        lo, hi = 0.0, 1.0
        for _ in range(200):
            mid = (lo + hi) / 2
            if betai(a, b, mid) < p:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2

    low = 0.0 if k == 0 else invert(0.025, k, n - k + 1)
    high = 1.0 if k == n else invert(0.975, k + 1, n - k)
    return low, high


def bootstrap_median_ci(values: list[float], iters: int = 10000) -> tuple[float, float]:
    """95% percentile bootstrap interval for the median (deterministic seed)."""
    import random
    if not values:
        return (float("nan"), float("nan"))
    rng = random.Random(20260920)
    n = len(values)
    meds = []
    for _ in range(iters):
        sample = [values[rng.randrange(n)] for _ in range(n)]
        sample.sort()
        meds.append(sample[n // 2] if n % 2 else 0.5 * (sample[n // 2 - 1] + sample[n // 2]))
    meds.sort()
    return meds[int(0.025 * iters)], meds[int(0.975 * iters) - 1]


def fisher_exact(a: int, b: int, c: int, d: int) -> float:
    """Two-sided Fisher exact p for the 2x2 table [[a,b],[c,d]]."""
    from math import comb
    n = a + b + c + d
    r1, c1 = a + b, a + c
    def prob(x: int) -> float:
        return comb(r1, x) * comb(n - r1, c1 - x) / comb(n, c1)
    obs = prob(a)
    total = 0.0
    for x in range(max(0, c1 - (n - r1)), min(r1, c1) + 1):
        px = prob(x)
        if px <= obs + 1e-12:
            total += px
    return min(1.0, total)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    batch = sys.argv[1]
    pattern = sys.argv[2] if len(sys.argv) > 2 else "*.log"

    rows = []
    skipped = []
    for path in sorted(glob.glob(os.path.join(batch, pattern))):
        text = open(path, errors="replace").read()
        tag = os.path.basename(path).rsplit("-", 1)[0]
        # a run that has not printed a verdict yet is still in progress: counting
        # it as a failure would make a live campaign look worse than it is
        if "VERDICT" not in text and "CONTROL RESULT" not in text:
            skipped.append(os.path.basename(path))
            continue
        m = {k: grab(p, text) for k, p in PATTERNS.items()}
        control = bool(m["ctrl_spans"])
        if control:
            ok = m["ctrl_md5"] != "" and m["ctrl_md5"] == m["ctrl_expected"]
        else:
            ok = m["verdict"] == "PASS"
        rows.append({
            "run": os.path.basename(path),
            "tag": tag,
            "control": control,
            "downtime_ms": m["downtime_ms"],
            "copy_s": m["copy_s"],
            "spans": m["spans"],
            "md5": m["md5"],
            "late_enum": m["late_enum"],
            "late_err": m["late_err"],
            "kicks": m["kicks"],
            "stale": m["stale"],
            "ok": ok,
        })

    if skipped:
        print(f"(skipped {len(skipped)} incomplete run(s): {', '.join(skipped[:4])})")
    if not rows:
        print(f"no logs matched {pattern} in {batch}")
        return 1

    out = os.path.join(batch, "summary.csv")
    with open(out, "w") as fh:
        cols = ["run", "tag", "control", "ok", "downtime_ms", "copy_s", "spans",
                "md5", "late_enum", "late_err", "kicks", "stale"]
        fh.write(",".join(cols) + "\n")
        for r in rows:
            fh.write(",".join(str(r[c]) for c in cols) + "\n")

    for tag in sorted({r["tag"] for r in rows}):
        sub = [r for r in rows if r["tag"] == tag]
        k, n = sum(r["ok"] for r in sub), len(sub)
        lo, hi = clopper_pearson(k, n)
        dt = [float(r["downtime_ms"]) for r in sub if r["downtime_ms"]]
        cp = [float(r["copy_s"]) for r in sub if r["copy_s"]]
        print(f"=== {tag}: {k}/{n} passed ===")
        print(f"  pass proportion      : {k/n:.3f}   95% Clopper-Pearson [{lo:.3f}, {hi:.3f}]")
        if k == n:
            print(f"  upper bound on failure rate (rule of three): <= {3/n:.3f}")
        if dt:
            lo_dt, hi_dt = bootstrap_median_ci(dt)
            print(f"  downtime ms          : min {min(dt):.0f} / median {statistics.median(dt):.1f} / max {max(dt):.0f}"
                  f"   (bootstrap 95% median CI [{lo_dt:.0f}, {hi_dt:.0f}])")
        if cp:
            print(f"  copy s               : min {min(cp):.1f} / median {statistics.median(cp):.1f} / max {max(cp):.1f}")
        kicks = [int(r["kicks"]) for r in sub if r["kicks"]]
        stale = [int(r["stale"]) for r in sub if r["stale"]]
        if kicks:
            print(f"  interrupt lines installed per run: min {min(kicks)} / max {max(kicks)}")
        if stale:
            print(f"  stale teardowns ignored per run  : min {min(stale)} / max {max(stale)}")

    arms = [t for t in sorted({r["tag"] for r in rows}) if not all(r["control"] for r in rows if r["tag"] == t)]
    if len(arms) == 2:
        a = [r for r in rows if r["tag"] == arms[0]]
        b = [r for r in rows if r["tag"] == arms[1]]
        ka, kb = sum(r["ok"] for r in a), sum(r["ok"] for r in b)
        p = fisher_exact(ka, len(a) - ka, kb, len(b) - kb)
        print(f"\nFisher exact ({arms[0]} vs {arms[1]}): {ka}/{len(a)} vs {kb}/{len(b)}, two-sided p = {p:.4f}")

    print(f"\nsummary csv: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
