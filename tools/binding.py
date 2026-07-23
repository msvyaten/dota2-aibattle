"""Does the config actually reach behaviour? Cross-match proof, per knob.

Usage:
  python tools/binding.py                 # test every binding against every log
  python tools/binding.py --knob harass_desire
  python tools/binding.py --unbound       # only knobs that are NOT proven

The gap this closes: every archetype claim in this project rests on watching
matches. Nothing anywhere shows that turning a dial moves a measurable number,
and for a product whose whole premise is "different prompt -> different player"
that is the load-bearing assumption. If a knob does not reach behaviour, the
model that set it did not play differently, and there is nothing to bet on.

Method, and why each part is there:

  * PER MINUTE, ALWAYS. Raw counters scale with match length: 8907379308 ran 13.7
    minutes and its raw anti-idle-lane "grew" 24 -> 28 against a 7.5-minute match
    while the actual rate fell 3.2 -> 2.0. Every metric here is normalised.

  * ONE ROW PER SIDE, NOT PER MATCH. Each match contributes two independent
    observations, and side is recorded so a Radiant/Dire asymmetry cannot be read
    as a config effect -- the trap that killed the cs-walk hypothesis over 133
    side-rows, where the "archetype effect" turned out to be which side the
    archetype happened to be sitting on.

  * DECLARED DIRECTION, DECLARED BEFORE THE DATA. Each binding states which way
    the metric must move. A correlation with the wrong sign is reported as
    CONTRADICTED, not quietly rendered as a weak result.

  * NO VARIANCE IS NOT A PASS. If every match set a knob to the same value, the
    binding is untestable and says so. Silence is the honest answer; the failure
    mode this guards against is a table of green ticks that only means we never
    varied anything.

A binding that reads UNBOUND is a finding to chase, not a number to publish:
either the knob is dead in the engine (creep_aggro_relief_hp is parsed,
validated, stored and read by nobody), or the metric chosen for it is the wrong
observable. Both have happened.
"""
import argparse
import glob
import math
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scorecard as sc

# Match id from which the current code lineage starts; older logs measure a different bot.
ERA_START = 8903952032
# Below this |r| a continuous binding is not considered demonstrated.
MIN_CORR = 0.30
# A discrete binding needs the groups to differ by at least this ratio of the pooled median.
MIN_SPLIT = 0.25
# Fewer rows than this and any result is noise.
MIN_ROWS = 6
# A dial tested across a narrower range than this is not tested. Without this the tool
# happily printed CONTRADICTED for farm_focus over a 0.70-0.72 spread on 8 rows -- a
# confident verdict from two decimal places of noise, which is worse than no verdict.
MIN_SPREAD = 0.15

# knob -> (kind, metric, direction, note)
#   kind      "dial" reads the numeric announce, "rule" reads the string announce
#   metric    counter name in the per-minute diag dump, or a derived key below
#   direction +1 the metric should RISE with the knob (or with the named rule value)
# The metric is the observable that knob is supposed to drive. Where a knob has
# several plausible observables the most direct one is used -- an indirect metric
# failing tells us nothing about the knob.
BINDINGS = [
    ("harass_desire",       "dial", "ability-harass",   +1, "harass pressure on the hero"),
    ("harass_desire",       "dial", "hero-contact-atk", +1, "auto-attacks on the hero"),
    # farm_focus is declared twice on purpose. The first line is what the dial's NAME and the
    # generator prompt promise; the second is what the code actually implements. Every consumer
    # of farm_focus is either a `< 0.25` boolean, rune creep-pressure, or `math.random() >
    # farm_focus` gating hero-seeking in combat.lua:316 -- no path reaches last-hitting at all.
    # Keeping both lines means the gap between promise and mechanism stays visible in the
    # output instead of being quietly redefined away once someone "fixes" the binding.
    ("farm_focus",          "dial", "lh_per_min",       +1, "PROMISED: last hits are the point of farming"),
    ("farm_focus",          "dial", "harass-seek",      -1, "IMPLEMENTED: it only gates hero-seeking, inversely"),
    ("forwardness",         "dial", "fwd-at-position",  +1, "how often it holds the forward spot"),
    ("retreat_caution",     "dial", "time_hp_low",      -1, "more caution -> less time under 45%"),
    ("ability_aggro",       "dial", "ability-harass",   +1, "same observable as harass, by design"),
    ("rune_control",        "dial", "bottle-rune",      +1, "rune contests"),
    ("execute_threshold",   "dial", "kill-lock-atk",    +1, "committing to a finishable enemy"),
    ("push_desire",         "dial", "siege-commit-tower", +1, "tower pressure"),
    ("defend_desire",       "dial", "siege-terminal-tower", +1, "weak binding, 1v1 has little to defend"),
    ("gank_desire",         "dial", "hero-prio-chase",  +1, "no ganks in 1v1; chase is the nearest thing"),

    ("creep_wave_priority", "rule", "cw-push",          "push",           "push must actually push"),
    ("creep_wave_priority", "rule", "anti-idle-creep",  "push",           "pre-registered 21.07: push re-enables the idle creep leg"),
    ("hero_priority",       "rule", "hero-prio-chase",  "always",         "always must chase more than default"),
    ("deny_policy",         "rule", "deny-act-atk",     "always",         "always must deny more"),
    ("pregame_behavior",    "rule", "pg-duel-trade",    "aggressive_mid", "aggressive_mid must trade before the horn"),
    ("tower_aggression",    "rule", "siege-commit-tower", "always",       "always must siege more"),
    ("dive_policy",         "rule", "no-dive",          "never",          "never must refuse dives more often"),
]

DERIVED = ("lh_per_min", "time_hp_low")


def side_rows(path):
    """One row per side: its config, its per-minute metrics. Nothing cross-side."""
    text = path.read_text(encoding="utf-8", errors="ignore") if hasattr(path, "read_text") \
        else open(path, encoding="utf-8", errors="ignore").read()
    ts = [int(m) for m in re.findall(r"AIB\[[RD]\] t=(\d+)s", text)]
    if not ts or max(ts) < 60:
        return []
    mins = max(ts) / 60.0
    build = re.search(r"AIB\[[RD]\] build=(\S+?)'", text)
    rows = []
    for side in ("R", "D"):
        d = re.search(r"AIB\[%s\] harass=([\d.]+) farm=([\d.]+) fwd=([\d.]+) abil=([\d.]+) "
                      r"rune=([\d.]+) retreat=([\d.]+) exec=([\d.]+) gank=([\d.]+) push=([\d.]+)"
                      % side, text)
        r2 = re.search(r"AIB\[%s\] defend=([\d.]+) ward=[\d.]+ roshan=[\d.]+ dive=(\S+) heal=\S+ "
                       r"abil=\S+ cw=(\S+) at=(\S+) pgb=(\S+) ta=(\S+)" % side, text)
        if d is None or r2 is None:
            continue
        cfg = {
            "harass_desire": float(d.group(1)), "farm_focus": float(d.group(2)),
            "forwardness": float(d.group(3)), "ability_aggro": float(d.group(4)),
            "rune_control": float(d.group(5)), "retreat_caution": float(d.group(6)),
            "execute_threshold": float(d.group(7)), "gank_desire": float(d.group(8)),
            "push_desire": float(d.group(9)), "defend_desire": float(r2.group(1)),
            "dive_policy": r2.group(2), "creep_wave_priority": r2.group(3),
            "ability_timing": r2.group(4), "pregame_behavior": r2.group(5),
            "tower_aggression": r2.group(6).rstrip("'"),
        }
        # hero_priority / deny_policy only exist in the announce from 62040ea onward.
        r3 = re.search(r"AIB\[%s\] hero=(\S+) deny=(\S+) lowhp=(\S+) respawn=(\S+)" % side, text)
        if r3:
            cfg["hero_priority"] = r3.group(1)
            cfg["deny_policy"] = r3.group(2)

        met = {}
        for m in re.finditer(r"AIB\[%s\] ([^']*?=\d+[^']*)'" % side, text):
            body = m.group(1)
            if body.count("=") < 13:
                continue
            for kv in body.split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    if v.isdigit():
                        met[k] = max(met.get(k, 0), int(v))
        met = {k: v / mins for k, v in met.items()}

        hp = [int(v) for v in re.findall(r"AIB\[%s\] t=\d+s hp=(\d+)%%" % side, text)]
        alive = [v for v in hp if v > 0]
        met["time_hp_low"] = (100.0 * sum(1 for v in alive if v < 45) / len(alive)) if alive else None
        lh = re.findall(r"AIB\[%s\][^']* lh=(\d+)" % side, text)
        met["lh_per_min"] = (int(lh[-1]) / mins) if lh else None

        rows.append({"side": side, "cfg": cfg, "met": met, "mins": mins,
                     "build": build.group(1) if build else "?"})
    return rows


def corr(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = statistics.mean(xs), statistics.mean(ys)
    sx, sy = statistics.pstdev(xs), statistics.pstdev(ys)
    if sx == 0 or sy == 0:
        return None
    return sum((xs[i] - mx) * (ys[i] - my) for i in range(n)) / n / (sx * sy)


def test_dial(rows, knob, metric, direction):
    pairs = [(r["cfg"][knob], r["met"].get(metric))
             for r in rows if knob in r["cfg"] and r["met"].get(metric) is not None]
    if len(pairs) < MIN_ROWS:
        return "NO DATA", "rows=%d" % len(pairs)
    xs = [p[0] for p in pairs]
    if len(set(xs)) < 2:
        return "NO VARIANCE", "every row set it to %.2f (n=%d)" % (xs[0], len(xs))
    if max(xs) - min(xs) < MIN_SPREAD:
        return "NO VARIANCE", "spread only %.2f-%.2f (n=%d), too narrow to test" % (
            min(xs), max(xs), len(pairs))
    r = corr(xs, [p[1] for p in pairs])
    if r is None:
        return "NO VARIANCE", "metric constant (n=%d)" % len(pairs)
    detail = "r=%+.2f n=%d spread=%.2f-%.2f" % (r, len(pairs), min(xs), max(xs))
    if r * direction >= MIN_CORR:
        return "BOUND", detail
    if r * direction <= -MIN_CORR:
        return "CONTRADICTED", detail
    return "UNBOUND", detail


def test_rule(rows, knob, metric, value):
    pairs = [(r["cfg"].get(knob), r["met"].get(metric))
             for r in rows if r["cfg"].get(knob) is not None and r["met"].get(metric) is not None]
    if len(pairs) < MIN_ROWS:
        return "NO DATA", "rows=%d" % len(pairs)
    on = [p[1] for p in pairs if p[0] == value]
    off = [p[1] for p in pairs if p[0] != value]
    if not on or not off:
        which = "never set to %r" % value if not on else "always set to %r" % value
        return "NO VARIANCE", "%s (n=%d)" % (which, len(pairs))
    mon, moff = statistics.median(on), statistics.median(off)
    pooled = statistics.median([p[1] for p in pairs]) or 1.0
    detail = "%s=%.2f other=%.2f n=%d/%d" % (value, mon, moff, len(on), len(off))
    if pooled == 0:
        return ("BOUND", detail) if mon > moff else ("UNBOUND", detail + " (both zero)")
    delta = (mon - moff) / abs(pooled)
    if delta >= MIN_SPLIT:
        return "BOUND", detail
    if delta <= -MIN_SPLIT:
        return "CONTRADICTED", detail
    return "UNBOUND", detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--knob")
    ap.add_argument("--unbound", action="store_true")
    ap.add_argument("--since", type=int, default=ERA_START,
                    help="only matches with id >= this; use it to pin one code lineage")
    args = ap.parse_args()

    rows = []
    for p in glob.glob(os.path.join(str(sc.DOTA_LOG_DIR), "console.*.log")):
        mid = os.path.basename(p)[8:-4]
        if not mid.isdigit() or int(mid) < args.since:
            continue
        rows.extend(side_rows(p))
    builds = sorted({r["build"] for r in rows})
    print("side-rows: %d (from %d matches, id >= %d)"
          % (len(rows), len(rows) // 2, args.since))
    print("builds present: %d -- %s" % (len(builds), ", ".join(builds)))
    if len(builds) > 3:
        # Learned the hard way on the first run of this tool: it reported
        # creep_wave_priority="push" -> anti-idle-creep as CONTRADICTED, with the
        # non-push group 100x higher. The whole effect was that antiIdleCreep had no
        # cwp gate before C.1, so every pre-gate build piled counts onto last_hit_only
        # rows. The knob was fine; the sample was 22 different bots. A code change that
        # happens to land alongside a config change is indistinguishable from the config
        # doing the work, and that is the failure this warning exists for.
        print()
        print("!! %d builds in one sample. Bindings measured across different bot code are" % len(builds))
        print("!! confounded: a code change that shipped alongside a config change reads as")
        print("!! the config doing the work. Re-run with --since <first match of one build>")
        print("!! before treating any verdict below as evidence.")
    print()
    hdr = "%-22s %-22s %-13s %s" % ("knob", "metric", "verdict", "evidence")
    print(hdr); print("-" * (len(hdr) + 22))
    counts = {}
    for knob, kind, metric, direction, note in BINDINGS:
        if args.knob and knob != args.knob:
            continue
        if kind == "dial":
            verdict, detail = test_dial(rows, knob, metric, direction)
        else:
            verdict, detail = test_rule(rows, knob, metric, direction)
        counts[verdict] = counts.get(verdict, 0) + 1
        if args.unbound and verdict in ("BOUND", "NO DATA"):
            continue
        print("%-22s %-22s %-13s %s" % (knob, metric, verdict, detail))
        if verdict in ("UNBOUND", "CONTRADICTED"):
            print("%-22s %-22s %-13s   ^ expected: %s" % ("", "", "", note))
    print()
    print("summary: " + ", ".join("%s=%d" % kv for kv in sorted(counts.items())))
    print("BOUND        the knob demonstrably moves its metric")
    print("UNBOUND      it varied and the metric did not follow -- chase this")
    print("CONTRADICTED it moved the metric the WRONG way -- chase this first")
    print("NO VARIANCE  never varied across these matches; untestable, not a pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
