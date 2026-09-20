#!/usr/bin/env python3
"""Generate every number in the paper from the raw per-run CSVs.

Nothing in the results section is typed by hand: this script reads

  * results-<tag>.csv          one row per run, written by acceptance-batch.sh
  * handover-exposure.txt      per-run exposure measurement
  * a replug-baseline summary  the detached/re-attached comparison

and writes paper/data/results.tex, which main.tex \\input's. A missing input is
reported as "?" rather than silently omitted, so a half-finished campaign cannot
produce a paper that looks complete.

Usage:
  update-results.py --batch /run/usb-batch \
                    [--exposure paper/data/handover-exposure.txt] \
                    [--replug /run/usb-replug] \
                    [--out paper/data/results.tex]
  update-results.py <summary.csv>            # legacy single-file form
"""
from __future__ import annotations

import argparse
import csv
import math
from decimal import Decimal, ROUND_HALF_UP
import os
import re
import statistics
import sys
from functools import lru_cache


# --------------------------------------------------------------------------
# statistics
# --------------------------------------------------------------------------
def _betacf(a: float, b: float, x: float) -> float:
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1e-30 if abs(d) < 1e-30 else 1.0 / d
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1e-30 if abs(d) < 1e-30 else 1.0 / d
        c = 1.0 + aa / c
        c = 1e-30 if abs(c) < 1e-30 else c
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1e-30 if abs(d) < 1e-30 else 1.0 / d
        c = 1.0 + aa / c
        c = 1e-30 if abs(c) < 1e-30 else c
        de = d * c
        h *= de
        if abs(de - 1.0) < 1e-12:
            break
    return h


def _betai(a: float, b: float, x: float) -> float:
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)
    front = math.exp(-lbeta + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(a, b, x) / a
    return 1.0 - front * _betacf(b, a, 1.0 - x) / b


def _invert(p: float, a: float, b: float) -> float:
    lo, hi = 0.0, 1.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if _betai(a, b, mid) < p:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def clopper_pearson(k: int, n: int) -> tuple[float, float]:
    """Two-sided exact 95% interval."""
    low = 0.0 if k == 0 else _invert(0.025, k, n - k + 1)
    high = 1.0 if k == n else _invert(0.975, k + 1, n - k)
    return low, high


def bootstrap_median_ci(values: list[float], iters: int = 10000) -> tuple[float, float]:
    import random
    if not values:
        return (float("nan"), float("nan"))
    rng = random.Random(20260920)
    n = len(values)
    meds = []
    for _ in range(iters):
        s = sorted(values[rng.randrange(n)] for _ in range(n))
        meds.append(s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2]))
    meds.sort()
    return meds[int(0.025 * iters)], meds[int(0.975 * iters) - 1]


@lru_cache(maxsize=None)
def fisher_exact(a: int, b: int, c: int, d: int) -> float:
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


def fisher_power(n1: int, p1: float, n2: int, p2: float, alpha: float = 0.05) -> float:
    """Exact unconditional power of the two-sided Fisher exact test.

    Averages the rejection decision over every pair of binomial outcomes under
    the alternative, which is what "power" means here: the trials are not
    conditioned on the observed margins.
    """
    from math import comb

    def binom_pmf(k: int, n: int, p: float) -> float:
        if p <= 0.0:
            return 1.0 if k == 0 else 0.0
        if p >= 1.0:
            return 1.0 if k == n else 0.0
        return comb(n, k) * p ** k * (1 - p) ** (n - k)

    power = 0.0
    for a in range(n1 + 1):
        pa = binom_pmf(a, n1, p1)
        if pa == 0.0:
            continue
        for c in range(n2 + 1):
            pc = binom_pmf(c, n2, p2)
            if pc == 0.0:
                continue
            if fisher_exact(a, n1 - a, c, n2 - c) <= alpha:
                power += pa * pc
    return power


def n_for_power(target: float, p1: float, p2: float, alpha: float = 0.05,
                nmax: int = 200) -> str:
    """Smallest equal n per arm reaching `target` power, or '>nmax'."""
    for n in range(1, nmax + 1):
        if fisher_power(n, p1, n, p2, alpha) >= target:
            return str(n)
    return f">{nmax}"


# --------------------------------------------------------------------------
# input
# --------------------------------------------------------------------------
def read_runs(path: str) -> list[dict]:
    """Read one results-<tag>.csv written by acceptance-batch.sh."""
    if not path or not os.path.exists(path):
        return []
    out = []
    for r in csv.DictReader(open(path)):
        r["pass"] = r.get("verdict") == "PASS" or r.get("ok") in ("True", "true")
        out.append(r)
    return out


class Arm:
    def __init__(self, tag: str, rows: list[dict]):
        self.tag = tag
        self.rows = rows

    @property
    def n(self) -> int:
        return len(self.rows)

    @property
    def k(self) -> int:
        return sum(1 for r in self.rows if r["pass"])

    def nums(self, key: str) -> list[float]:
        vals = []
        for r in self.rows:
            v = r.get(key)
            if v not in (None, "", "n/a"):
                try:
                    vals.append(float(v))
                except ValueError:
                    pass
        return vals

    def ints(self, key: str) -> list[int]:
        return [int(v) for v in self.nums(key)]

    def ci(self) -> tuple[float, float]:
        return clopper_pearson(self.k, self.n) if self.n else (float("nan"), float("nan"))

    def lo(self) -> str:
        return f"{min(self.nums('downtime_ms')):.0f}" if self.nums("downtime_ms") else "?"

    def med(self, key: str, fmt: str = "{:.1f}") -> str:
        # statistics.median returns the exact mean of the two middle values, which
        # for 26.05 is 26.049999999999997 in binary; format() then truncates to
        # 26.0 where conventional rounding gives 26.1. Round half up.
        v = self.nums(key)
        if not v:
            return "?"
        m = statistics.median(v)
        return fmt.format(float(Decimal(str(round(m, 6))).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)))

    def hi(self, key: str, fmt: str = "{:.0f}") -> str:
        v = self.nums(key)
        return fmt.format(max(v)) if v else "?"

    def lo_of(self, key: str, fmt: str = "{:.0f}") -> str:
        v = self.nums(key)
        return fmt.format(min(v)) if v else "?"


def need(cond: bool, msg: str) -> None:
    if not cond:
        print(f"WARNING: {msg}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="?", help="legacy: a single summary.csv")
    ap.add_argument("--batch", default="/run/usb-batch")
    ap.add_argument("--exposure")
    ap.add_argument("--exposure-prefix", default="debug-",
                    help="only exposure rows for runs whose name starts with this "
                         "prefix are used (default: the acceptance arm)")
    ap.add_argument("--inject", default="/run/usb-inject")
    ap.add_argument("--replug", default="/run/usb-replug")
    ap.add_argument("--out", default="paper/data/results.tex")
    args = ap.parse_args()

    if args.csv and not os.path.exists(os.path.join(args.batch, "results-debug.csv")):
        args.batch = os.path.dirname(args.csv) or "."

    def arm(tag: str) -> Arm:
        return Arm(tag, read_runs(os.path.join(args.batch, f"results-{tag}.csv")))

    debug = arm("debug")
    control = arm("control")
    release = arm("release")
    kickoff = arm("kickoff")
    need(debug.n > 0, f"no debug arm in {args.batch}/results-debug.csv")
    need(control.n > 0, "no control arm")
    need(release.n > 0, "no release arm")
    need(kickoff.n > 0, "no kick-off arm")

    inj = {}
    for tag in ("baseline", "window", "window-loss", "winlong-on", "winlong-off",
                "guard-off"):
        inj[tag] = Arm(tag, read_runs(os.path.join(args.inject, f"results-{tag}.csv")))

    replug_runs = sorted(
        d for d in (os.listdir(args.replug) if os.path.isdir(args.replug) else [])
        if d.isdigit()
    )

    n, k = debug.n, debug.k
    if n == 0:
        # No acceptance arm in --batch (e.g. the attachment is missing). Emit the
        # ? placeholders the README promises instead of dividing by zero.
        need(False, f"no acceptance arm in {args.batch}; emitting placeholders")
    lo, hi = debug.ci() if n else (float("nan"), float("nan"))
    dt = debug.nums("downtime_ms")
    cp = debug.nums("copy_s")
    ks, st = debug.ints("kicks"), debug.ints("stale")

    L: list[str] = [
        "% GENERATED by paper/update-results.py -- do not edit by hand.",
        f"% batch: {os.path.basename(os.path.normpath(args.batch))}",
        "",
        "% ---- acceptance: debug build, migration ----",
        f"\\newcommand{{\\TotalRuns}}{{{n}}}",
        f"\\newcommand{{\\PassCount}}{{{k}}}",
        f"\\newcommand{{\\DowntimeMin}}{{{debug.lo_of('downtime_ms')}}}",
        f"\\newcommand{{\\DowntimeMedian}}{{{debug.med('downtime_ms')}}}",
        f"\\newcommand{{\\DowntimeMax}}{{{debug.hi('downtime_ms')}}}",
        f"\\newcommand{{\\DowntimeMedianCILow}}{{{f'{bootstrap_median_ci(dt)[0]:.0f}' if dt else '?'}}}",
        f"\\newcommand{{\\DowntimeMedianCIHigh}}{{{f'{bootstrap_median_ci(dt)[1]:.0f}' if dt else '?'}}}",
        f"\\newcommand{{\\CopyMin}}{{{debug.lo_of('copy_s', '{:.1f}')}}}",
        f"\\newcommand{{\\CopyMedian}}{{{debug.med('copy_s')}}}",
        f"\\newcommand{{\\CopyMax}}{{{debug.hi('copy_s', '{:.1f}')}}}",
        f"\\newcommand{{\\CILow}}{{{f'{lo:.2f}' if n else '?'}}}",
        f"\\newcommand{{\\CIHigh}}{{{f'{hi:.2f}' if n else '?'}}}",
        f"\\newcommand{{\\FailUpper}}{{{f'{1 - 0.05 ** (1 / n):.2f}' if (n and k == n) else 'n/a'}}}",
        f"\\newcommand{{\\PassLowerOneSided}}{{{f'{0.05 ** (1 / n):.2f}' if (n and k == n) else 'n/a'}}}",
        f"\\newcommand{{\\KickMin}}{{{min(ks) if ks else '?'}}}",
        f"\\newcommand{{\\KickMax}}{{{max(ks) if ks else '?'}}}",
        f"\\newcommand{{\\StaleMin}}{{{min(st) if st else '?'}}}",
        f"\\newcommand{{\\StaleMax}}{{{max(st) if st else '?'}}}",
        "",
        "% ---- control: no migration ----",
        f"\\newcommand{{\\ControlRuns}}{{{control.n}}}",
        f"\\newcommand{{\\ControlPass}}{{{control.k}}}",
        f"\\newcommand{{\\ControlCopyMedian}}{{{control.med('copy_s')}}}",
        "",
        "% ---- release build, migration ----",
        f"\\newcommand{{\\ReleaseRuns}}{{{release.n}}}",
        f"\\newcommand{{\\ReleasePass}}{{{release.k}}}",
        f"\\newcommand{{\\ReleaseCopyMedian}}{{{release.med('copy_s')}}}",
        f"\\newcommand{{\\ReleaseDowntimeMedian}}{{{release.med('downtime_ms')}}}",
        "",
        "% ---- kick disabled (negative control) ----",
        f"\\newcommand{{\\KickOffRuns}}{{{kickoff.n}}}",
        f"\\newcommand{{\\KickOffPass}}{{{kickoff.k}}}",
        f"\\newcommand{{\\KickOffCopyMedian}}{{{kickoff.med('copy_s')}}}",
        "",
    ]

    # Fisher between the debug arm (fixed) and the kick-off arm, and between the
    # debug arm and the naive replug baseline if both are complete.
    if debug.n and kickoff.n:
        p = fisher_exact(debug.k, debug.n - debug.k, kickoff.k, kickoff.n - kickoff.k)
        L.append(f"\\newcommand{{\\FisherKick}}{{{p:.3f}}}" if p >= 0.001
                 else f"\\newcommand{{\\FisherKick}}{{$<$0.001}}")
    else:
        L.append("\\newcommand{\\FisherKick}{?}")
    if debug.n and control.n:
        p = fisher_exact(debug.k, debug.n - debug.k, control.k, control.n - control.k)
        L.append(f"\\newcommand{{\\FisherControl}}{{{p:.3f}}}")
    else:
        L.append("\\newcommand{\\FisherControl}{?}")
    if debug.n and inj["guard-off"].n:
        a = inj["guard-off"]
        p = fisher_exact(debug.k, debug.n - debug.k, a.k, a.n - a.k)
        L.append(f"\\newcommand{{\\FisherGuard}}{{{f'{p:.4f}' if p >= 0.0001 else '$<$0.0001'}}}")
    else:
        L.append("\\newcommand{\\FisherGuard}{?}")
    # The pre-fix arm is historical: five runs, one of which stalled. It is
    # written down here rather than in the prose so the comparison against the
    # current acceptance arm is recomputed whenever n changes.
    pre_pass, pre_fail = 4, 1
    if debug.n:
        p = fisher_exact(debug.k, debug.n - debug.k, pre_pass, pre_fail)
        L.append(f"\\newcommand{{\\FisherPreFix}}{{{p:.2f}}}")
    else:
        L.append("\\newcommand{\\FisherPreFix}{?}")

    # ---- power, so the Threats section can quote a real analysis ----
    if debug.n and kickoff.n:
        p_off = (kickoff.n - kickoff.k) / kickoff.n
        p_on = (debug.n - debug.k) / debug.n
        power = fisher_power(debug.n, p_on, kickoff.n, p_off)
        L += [
            "% ---- exact unconditional power of the Fisher comparisons ----",
            f"\\newcommand{{\\PowerKickNatural}}{{{power:.3f}}}",
            f"\\newcommand{{\\NKickForEighty}}"
            f"{{{n_for_power(0.80, p_on, p_off)}}}",
        ]
    else:
        L += ["\\newcommand{\\PowerKickNatural}{?}",
              "\\newcommand{\\NKickForEighty}{?}"]
    w, wl = inj["window"], inj["window-loss"]
    if w.n and wl.n:
        pw = fisher_exact(w.k, w.n - w.k, wl.k, wl.n - wl.k)
        L.append(f"\\newcommand{{\\FisherWindow}}{{{pw:.3f}}}")
    else:
        L.append("\\newcommand{\\FisherWindow}{?}")
    a, b = inj["winlong-on"], inj["winlong-off"]
    if a.n and b.n:
        pw = fisher_exact(a.k, a.n - a.k, b.k, b.n - b.k)
        L += [
            f"\\newcommand{{\\FisherWinLong}}{{{f'{pw:.4f}' if pw >= 0.0001 else '$<$0.0001'}}}",
            # power under a deliberately imperfect effect: the kick-enabled arm
            # is not perfect and the kick-disabled arm occasionally recovers
            f"\\newcommand{{\\PowerWinLong}}{{{fisher_power(a.n, 0.05, b.n, 0.80):.2f}}}",
            f"\\newcommand{{\\NPowerWinLong}}{{{n_for_power(0.80, 0.05, 0.80)}}}",
        ]
    else:
        L += ["\\newcommand{\\FisherWinLong}{?}",
              "\\newcommand{\\PowerWinLong}{?}",
              "\\newcommand{\\NPowerWinLong}{?}"]
    L.append("")

    # ---- hand-over exposure ----
    rows_exp: list[tuple[int, float]] = []
    if args.exposure and os.path.exists(args.exposure):
        for line in open(args.exposure):
            parts = line.split()
            # Only the acceptance arm is reported; an archive's exposure file
            # also contains the control/release/kick-off arms, whose windows
            # would otherwise be pooled into the macros.
            if len(parts) >= 8 and parts[1].isdigit() \
                    and parts[0].startswith(args.exposure_prefix):
                try:
                    # columns: run lower epoch upper events win_lo win_ep win_up
                    rows_exp.append((int(parts[1]), int(parts[2]), int(parts[3]),
                                     float(parts[5]), float(parts[6]), float(parts[7])))
                except (ValueError, IndexError):
                    pass
        if rows_exp:
            lowers = [r[0] for r in rows_exp]
            epochs = [r[1] for r in rows_exp]
            uppers = [r[2] for r in rows_exp]
            win_lo = [r[3] for r in rows_exp]
            win_ep = [r[4] for r in rows_exp]
            win_up = [r[5] for r in rows_exp]

            def cnt(vals: list[int]) -> tuple[int, int]:
                return sum(1 for v in vals if v > 0), sum(vals)

            lo_runs, lo_tot = cnt(lowers)
            ep_runs, ep_tot = cnt(epochs)
            up_runs, up_tot = cnt(uppers)
            L += [
                "% ---- hand-over exposure. lower = anchored on CH's own clock",
                "% (its Enabling/Disabling IRQ events tied to usbvfiod's wall clock);",
                "% epoch = anchored on the harness's migration.epoch; upper = anchored",
                "% at the raw harness epoch (recorded before ch-remote is launched). truth is",
                "% between lower and epoch.",
                f"\\newcommand{{\\ExposureWindowMin}}{{{min(win_lo):.1f}}}",
                f"\\newcommand{{\\ExposureWindowMax}}{{{max(win_lo):.1f}}}",
                f"\\newcommand{{\\ExposureRuns}}{{{lo_runs}}}",
                f"\\newcommand{{\\ExposureCompletions}}{{{lo_tot}}}",
                f"\\newcommand{{\\ExposureWorst}}{{{max(lowers)}}}",
                f"\\newcommand{{\\ExposureRate}}{{{100.0 * lo_runs / len(rows_exp):.0f}}}",
                f"\\newcommand{{\\ExposureEpochRuns}}{{{ep_runs}}}",
                f"\\newcommand{{\\ExposureEpochCompletions}}{{{ep_tot}}}",
                f"\\newcommand{{\\ExposureEpochWindowMin}}{{{min(win_ep):.1f}}}",
                f"\\newcommand{{\\ExposureEpochWindowMax}}{{{max(win_ep):.1f}}}",
                f"\\newcommand{{\\ExposureUpperRuns}}{{{up_runs}}}",
                f"\\newcommand{{\\ExposureUpperCompletions}}{{{up_tot}}}",
                f"\\newcommand{{\\ExposureUpperRate}}{{{100.0 * up_runs / len(rows_exp):.0f}}}",
                f"\\newcommand{{\\ExposureUpperWindowMax}}{{{max(win_up):.1f}}}",
                f"\\newcommand{{\\ExposureMeasured}}{{{len(rows_exp)}}}",
                "",
            ]
            mm = re.search(r"min copy margin after switchover\s*:\s*([\d.]+)", open(args.exposure).read())
            L.append(f"\\newcommand{{\\SpanMarginMin}}{{{mm.group(1) if mm else '?'}}}")
            L.append("")
    else:
        need(False, f"no exposure file at {args.exposure}; exposure macros omitted")

    # ---- fault injection ----
    L.append("% ---- fault injection arms ----")
    for tag, macro in (("baseline", "InjBaseline"), ("window", "InjWindow"),
                       ("window-loss", "InjWindowLoss"),
                       ("winlong-on", "InjWinLongOn"),
                       ("winlong-off", "InjWinLongOff"),
                       ("guard-off", "InjGuard")):
        a = inj[tag]
        if a.n:
            L += [f"\\newcommand{{\\{macro}Pass}}{{{a.k}}}",
                  f"\\newcommand{{\\{macro}N}}{{{a.n}}}"]
        else:
            need(False, f"no injection arm {tag} in {args.inject}")
            L += [f"\\newcommand{{\\{macro}Pass}}{{?}}",
                  f"\\newcommand{{\\{macro}N}}{{?}}"]
    L.append("")

    # ---- replug baseline ----
    rp = []
    rp_csv = os.path.join(args.replug, "replug.csv")
    if os.path.exists(rp_csv):
        for r in csv.DictReader(open(rp_csv)):
            if r.get("complete") == "True":
                rp.append(r)
    if replug_runs:
        L.append(f"\\newcommand{{\\ReplugRuns}}{{{len(replug_runs)}}}")
    else:
        need(False, f"no replug-baseline runs in {args.replug}")
        L.append("\\newcommand{\\ReplugRuns}{?}")
    if rp:
        def mx(key: str) -> str:
            vals = [int(r[key]) for r in rp if r.get(key, "").lstrip("-").isdigit()]
            return str(max(vals)) if vals else "?"
        ok = sum(1 for r in rp if r.get("ok") == "True")
        digest_ok = sum(1 for r in rp if r.get("md5_match") == "True")
        L += [
            f"\\newcommand{{\\ReplugOk}}{{{ok}}}",
            f"\\newcommand{{\\ReplugDigestMatch}}{{{digest_ok}}}",
            f"\\newcommand{{\\ReplugReenumMax}}{{{mx('reenum')}}}",
            f"\\newcommand{{\\ReplugResetsMax}}{{{mx('resets')}}}",
            f"\\newcommand{{\\ReplugIOErrMax}}{{{mx('io_errors')}}}",
        ]
    else:
        for m in ("ReplugOk", "ReplugDigestMatch", "ReplugReenumMax",
                  "ReplugResetsMax", "ReplugIOErrMax"):
            L.append(f"\\newcommand{{\\{m}}}{{?}}")
    L.append("")

    # ---- per-run table body (debug arm) ----
    body = ["% table body: one row per acceptance run", "\\midrule"]
    for i, r in enumerate(debug.rows, 1):
        spans = "yes" if r.get("spans") == "YES" else "no"
        md5 = "match" if r.get("md5") == "MATCH" else "mismatch"
        body.append(f"{i} & {r.get('downtime_ms') or '?'} & {r.get('copy_s') or '?'} & "
                    f"{spans} & {md5} / {r.get('late_enum') or '?'} \\\\")
    body.append("\\bottomrule")
    L += ["\\newcommand{\\ResultsTableBody}{%", *body, "}", ""]

    # ---- arm comparison table body ----
    def row(label: str, a: Arm, note: str) -> str:
        if not a.n:
            return f"{label} & ? & ? & ? & ? \\\\"
        dt = a.nums("downtime_ms")
        dtxt = (f"{min(dt):.0f}--{max(dt):.0f}" if dt else "n/a")
        ci = a.ci()
        return (f"{label} & {a.k}/{a.n} & {a.med('copy_s')} & "
                f"{dtxt} & {note} \\\\")

    L += ["\\newcommand{\\ArmsTableBody}{%", "\\midrule",
          row("Debug, migration", debug, "---"),
          row("Release, migration", release, "---"),
          row("Debug, no migration", control, "checksum only"),
          row("Debug, kick disabled", kickoff,
              f"$p=\\FisherKick$"),
          "\\bottomrule", "}", ""]

    # ---- injection table body ----
    def injrow(label: str, tag: str, expect: str) -> str:
        a = inj[tag]
        got = f"{a.k}/{a.n}" if a.n else "?"
        return f"{label} & {expect} & {got} \\\\"

    L += ["\\newcommand{\\InjectionTableBody}{%", "\\midrule",
          injrow("Hooks dormant", "baseline", "pass"),
          injrow("500\\,ms window, kick on", "window", "pass"),
          injrow("500\\,ms window, kick off", "window-loss", "fail"),
          injrow("5\\,s window, kick on", "winlong-on", "pass"),
          injrow("5\\,s window, kick off", "winlong-off", "fail"),
          injrow("Owner guard off", "guard-off", "fail"),
          "\\bottomrule", "}", ""]

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as fh:
        fh.write("\n".join(L) + "\n")
    print(f"wrote {args.out}")

    # ---- figure data ----
    # Resolve runs.dat next to --out, not against the CWD: the Makefile runs
    # this script from paper/, and a hardcoded "paper/data/runs.dat" made
    # `make data` die with FileNotFoundError after writing results.tex.
    runs_dat = os.path.join(os.path.dirname(args.out) or ".", "runs.dat")
    with open(runs_dat, "w") as fh:
        for i, r in enumerate(debug.rows, 1):
            fh.write(f"{i} {r.get('downtime_ms') or 0} {r.get('copy_s') or 0}\n")
    print(f"  rewrote {runs_dat}")

    # ---- console summary ----
    def show(name: str, a: Arm) -> None:
        if not a.n:
            print(f"  {name:<22} (no data)")
            return
        ci = a.ci()
        print(f"  {name:<22} {a.k}/{a.n} pass  CP95=[{ci[0]:.2f},{ci[1]:.2f}]  "
              f"copy med {a.med('copy_s')}s  downtime {a.lo_of('downtime_ms')}-{a.hi('downtime_ms')}ms")

    show("debug/migration", debug)
    show("release/migration", release)
    show("control/no-migration", control)
    show("kick-off", kickoff)
    for tag in ("baseline", "window", "window-loss", "winlong-on", "winlong-off",
                "guard-off"):
        show(f"inject:{tag}", inj[tag])
    print(f"  exposure (CH-clock lower / harness epoch / raw epoch): "
          f"{sum(1 for r in rows_exp if r[0] > 0)}/{sum(1 for r in rows_exp if r[1] > 0)}/"
          f"{sum(1 for r in rows_exp if r[2] > 0)} of {len(rows_exp)} runs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
