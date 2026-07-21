"""Cross-match farm forensics: what actually predicts last-hits per lane-minute.

Usage: python tools/farm_drivers.py [glob]     (default: every console.*.log)

Built 21.07 to settle the cs-walk investigation. Reads every match log at once and
correlates per-side counter rates against lh/min, then prints a side x archetype 2x2.
Findings from the first run (19 matches, 38 side-rows) are quoted in the code below;
re-run it after a batch of matches rather than re-deriving the same table by hand.

Method notes, because two earlier diagnoses died on them:
  * Rates, never raw counts. A counter is normalised by minutes spent ALIVE and IN LANE
    (samples with |lane-axis| < 4000), so a short game or a long fountain trip cannot
    masquerade as a behaviour change.
  * Counters come from the largest periodic dump per side (they are cumulative), so a
    truncated dump cannot under-report.
  * Correlation is association only. cs-watchdog-step correlating -0.56 with lh/min does
    NOT mean the watchdog costs farm -- it fires BECAUSE farm stalled. Read the sign, then
    ask which way the arrow points before touching code.
"""
import glob
import math
import os
import re
import statistics
import sys

import scorecard as sc

SAMPLE = re.compile(
    r"AIB\[([RD])\] t=(\d+)s hp=(\d+)% gold=\d+ loc=(-?\d+),(-?\d+)"
    r"(?: enemy-dist=\d+)? lh=(\d+)")
# A counter dump is the one AIB line that is nothing but key=value pairs.
DUMP = re.compile(r"AIB\[([RD])\] ((?:[a-z0-9-]+=\d+ ){14,}[a-z0-9-]+=\d+)")

KEYS = (
    "cs-walk", "last-hit-urgent", "cs-wait", "cs-watchdog-step", "deny-act",
    "lane-line-fallback", "wave-watch", "fwd-position", "uphill-reposition",
    "visual-hold-creep", "visual-hold-lane", "anti-idle-enter", "idle",
    "creep-hit-react-atk", "hero-contact-atk", "kill-lock-chase", "harass-seek",
    "siege-commit-tower", "low-hp-creep",
    "recovery-regen", "regen-walk", "recover-xp", "recover-safe", "fountain-wait",
)
RECOVERY_LOAD = ("regen-walk", "recover-safe", "recover-xp", "recovery-regen", "fountain-wait")


def archetype(text, side):
    h = re.search(r"AIB\[%s\] harass=([0-9.]+)" % side, text)
    return {"0.90": "brawler", "0.55": "farmer", "0.85": "pusher"}.get(h.group(1), "?") if h else "?"


def corr(xs, ys):
    n = len(xs)
    if n < 4:
        return 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if sx == 0 or sy == 0:
        return 0.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sx * sy)


def rows_for(path):
    text = open(path, encoding="utf-8", errors="ignore").read()
    pts = {"R": [], "D": []}
    best = {"R": {}, "D": {}}
    for m in SAMPLE.finditer(text):
        pts[m.group(1)].append(tuple(int(m.group(i)) for i in (2, 3, 4, 5, 6)))
    for m in DUMP.finditer(text):
        d = {}
        for kv in m.group(2).split():
            k, v = kv.split("=")
            d[k] = int(v)
        if len(d) > len(best[m.group(1)]):
            best[m.group(1)] = d
    out = []
    for side in ("R", "D"):
        alive = [v for v in pts[side] if v[1] > 0]
        if len(alive) < 20:
            continue
        in_lane = [v for v in alive if abs((v[2] + v[3]) / math.sqrt(2)) < 4000]
        mins = len(in_lane) * 5 / 60.0          # samples land ~5s apart
        if mins < 2:
            continue
        c = best[side]
        # Drop pre-stack logs and aborted games: a side with no lh and no lane-line counter
        # is a different codebase (or a match that never laned), and mixing those in flattens
        # every correlation -- the 191-row unfiltered run reads hp<45 at -0.16 where the
        # 38-row current-stack run reads -0.50.
        if alive[-1][4] <= 0 or "lane-line-fallback" not in c:
            continue
        r = {
            "match": os.path.basename(path)[8:-4], "side": side,
            "arch": archetype(text, side), "mins": mins,
            "lh": alive[-1][4], "lhpm": alive[-1][4] / mins,
            "dead": 1 - len(alive) / max(len(pts[side]), 1),
            "hp<45": sum(1 for v in alive if v[1] < 45) / len(alive),
            "hp<25": sum(1 for v in alive if v[1] < 25) / len(alive),
        }
        for k in KEYS:
            r[k] = c.get(k, 0) / mins
        r["recovery_load"] = sum(r[k] for k in RECOVERY_LOAD)
        out.append(r)
    return out


def main(pattern=None):
    logs = sorted(glob.glob(pattern or str(sc.DOTA_LOG_DIR / "console.*.log")))
    rows = [r for p in logs for r in rows_for(p)]
    if len(rows) < 4:
        print("not enough side-matches (%d) -- widen the glob" % len(rows))
        return
    y = [r["lhpm"] for r in rows]
    print("side-matches=%d | lh/min median=%.2f range %.2f-%.2f"
          % (len(rows), statistics.median(y), min(y), max(y)))

    print("\n----- correlation with lh/min (association, not causation) -----")
    scored = sorted(((corr([r[k] for r in rows], y), k)
                     for k in list(KEYS) + ["dead", "hp<45", "hp<25", "recovery_load"]),
                    reverse=True)
    for c, k in scored:
        print("  %+.2f  %s" % (c, k))

    print("\n----- 2x2 side x archetype (medians) -----")
    print("  %-16s %3s %8s %10s %11s %8s" % ("cell", "n", "lh/min", "cs-walk/m", "recov_load", "hp<45"))
    for side in ("R", "D"):
        for arch in ("brawler", "farmer"):
            sub = [r for r in rows if r["side"] == side and r["arch"] == arch]
            if not sub:
                continue
            med = lambda k: statistics.median([r[k] for r in sub])
            print("  %-16s %3d %8.2f %10.1f %11.1f %7.0f%%"
                  % (side + "/" + arch, len(sub), med("lhpm"), med("cs-walk"),
                     med("recovery_load"), 100 * med("hp<45")))

    print("\n----- worst / best farm rows -----")
    for label, seq in (("worst", sorted(rows, key=lambda r: r["lhpm"])[:5]),
                       ("best", sorted(rows, key=lambda r: -r["lhpm"])[:5])):
        for r in seq:
            print("  %-5s %s %s %-8s lh/min=%.2f recov=%5.1f hp<45=%3.0f%% cs-walk=%5.1f dead=%.2f"
                  % (label, r["match"], r["side"], r["arch"], r["lhpm"], r["recovery_load"],
                     100 * r["hp<45"], r["cs-walk"], r["dead"]))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
