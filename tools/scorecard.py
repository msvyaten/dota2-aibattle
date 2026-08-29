"""Watchability scorecard: one-command match acceptance.

Usage: python tools/scorecard.py <matchid> [...]
PASS/FAIL per metric from the console log; process rule: a match that passes the
scorecard is ACCEPTED and the fix_candidate list is not worked through.
"""
import re
import sys

from aibattle_log import DOTA_LOG_DIR

# diag counters whose per-match MAX approximates movement churn (jitter proxy)
#
# `low-hp-nudge` and `low-hp-back` were in this tuple and are emitted by nothing: neither string
# exists anywhere under bots/, in any form, concatenated or otherwise. They read 0 in every match
# ever measured, and that zero was never evidence of calm -- it was the absence of a key. Removed
# rather than kept as decoration; the numbers do not move, because they were always 0.
#
# What is left is thin, and 8972598364 is the proof: jitter/min read 3.4 for Radiant, a
# comfortable PASS against the limit of 8, in the match where the user watched the bots walk back
# and forth and `wave-watch-step` fired 107 times (~16/min). None of the owners that actually
# issue movement -- wave-watch, cs-watchdog, siege, creep-aggro, the chases, the anti-idle legs --
# is counted here. So a PASS on this line means "the two things we watch stayed quiet", not "the
# bot moved sanely", and the eye has beaten this metric twice.
#
# Not widened before a match on purpose: the 8/min threshold is calibrated against this narrow
# set, and adding the real movers without recalibrating would fail every match on arrival. The
# next match gives the per-key movement census to calibrate from.
JITTER_KEYS = ("uphill-reposition",)
# SPECS 3.10 step 2 (20.07): lane-line-fallback left the raw JITTER_KEYS -- its running
# counter counted every re-issue of the SAME legitimate walk (~9x inflation: two matches
# on f77b66b measured lane-line raw 160-207 -> 6-24 real episodes). It is replaced by the
# transition-only lane-line-episode Intent, counted by OCCURRENCE below. Threshold dropped
# 12 -> 8/min to match the now-honest scale (observed 2.1-3.1/min; a genuine oscillation
# flipping dest every ~2s would still read ~30/min). uphill-reposition stays raw for now
# (low, ~0.5-1.8/min); episode-ify it too if it ever dominates.
JITTER_EPISODE_KEYS = ("lane-line-episode",)

THRESH = {
    "runtime_errors": 0,
    "aib_err": 0,
    "empty_per_min": 13,      # per side; was absolute 80 calibrated on ~6-min games --
                              # first long game (8903988046, 16.5 min) false-FAILed at
                              # comparable per-min rates (same lesson as raw jitter)
    "jitter_per_min": 8,      # per side; episode-honest scale (SPECS 3.10 step 2), was 12
    "bottle_empty_pct": 50,   # per side
}


def game_minutes(text):
    """Game length in minutes from the last DotaTime seen in a location report.
    jitter is raw event counts, so it scales with duration -- a 10-min game logs
    ~2.5x a 4-min game for identical behavior. Normalizing per minute makes the
    metric comparable across games (found 07.07: a long game 'regressed' purely
    on duration)."""
    ts = [int(m) for m in re.findall(r"AIB\[[RD]\] t=(\d+)s", text)]
    return max(ts) / 60.0 if ts and max(ts) > 0 else None


def side_counter_max(text, side, key):
    """Highest value of a cumulative diag counter, read ONLY from counter-dump lines.

    The old version matched `key=N` anywhere on any AIB line for that side, which is not the
    same question. `execute` is a real diag counter (aibattle_style.lua:1201) AND a field in
    the fight-desire intent string -- `state-desire-fight base=78 execute=20 dist=327` -- where
    20 is the execute bonus in the score, printed every time the desire is evaluated. postmatch
    reported execute=20 for both sides in three consecutive matches while the actual counter sat
    at 2-3, and that number was being read as evidence about finishing.

    Two guards. A dump line is an AIB line carrying neither `intent=` nor `blocked=` -- those
    two prefixes cover every structured line that is not a counter dump. And the key needs a
    left boundary that is not a word character or a hyphen, so `creep-hit-react-atk` cannot
    answer a query for `atk`.
    """
    pat = re.compile(r"(?<![\w-])%s=(\d+)" % re.escape(key))
    best = 0
    for line in re.findall(r"AIB\[%s\][^']*" % side, text):
        if "intent=" in line or "blocked=" in line:
            continue
        for m in pat.finditer(line):
            v = int(m.group(1))
            if v > best:
                best = v
    return best


def scorecard(match_id):
    path = DOTA_LOG_DIR / ("console.%s.log" % match_id)
    if not path.exists():
        print("[%s] log not found: %s" % (match_id, path))
        return False
    text = path.read_text(encoding="utf-8", errors="ignore")
    ok = True

    def check(name, value, limit, higher_is_bad=True):
        nonlocal ok
        passed = value <= limit if higher_is_bad else value >= limit
        if not passed:
            ok = False
        print("  %-28s %-6s value=%s limit=%s" % (name, "PASS" if passed else "FAIL", value, limit))

    mins = game_minutes(text)
    print("===== scorecard %s  (%s) =====" % (match_id, ("%.1f min" % mins) if mins else "duration ?"))
    check("runtime_errors", text.count("Script Runtime Error"), THRESH["runtime_errors"])
    check("aib_err", text.count("AIB ERR"), THRESH["aib_err"])
    for side in ("R", "D"):
        empty = len(re.findall(r"AIB\[%s\][^']*empty_action" % side, text))
        if mins:
            check("empty/min[%s]" % side, round(empty / mins, 1), THRESH["empty_per_min"])
            print("  %-28s (raw empty_action=%d over %.1f min)" % ("", empty, mins))
        else:
            print("  %-28s %-6s (no duration; raw empty_action=%d)" % ("empty/min[%s]" % side, "N/A", empty))
        jitter = sum(side_counter_max(text, side, k) for k in JITTER_KEYS)
        jitter += sum(len(re.findall(r"AIB\[%s\][^']*%s" % (side, re.escape(k)), text))
                      for k in JITTER_EPISODE_KEYS)
        if mins:
            per_min = round(jitter / mins, 1)
            check("jitter/min[%s]" % side, per_min, THRESH["jitter_per_min"])
            print("  %-28s (jitter_sum=%d [episodes] over %.1f min)" % ("", jitter, mins))
        else:
            print("  %-28s %-6s (no duration; raw jitter_sum=%d)" % ("jitter/min[%s]" % side, "N/A", jitter))
        samples = re.findall(r"AIB\[%s\][^']*bottle=(-?\d+)" % side, text)
        # bottle=-1 means no bottle owned; count only owned-bottle samples
        owned = [s for s in samples if s != "-1"]
        if owned:
            pct = round(100.0 * sum(1 for s in owned if s == "0") / len(owned))
            check("bottle_empty_pct[%s]" % side, pct, THRESH["bottle_empty_pct"])
        else:
            print("  %-28s %-6s (no bottle all match)" % ("bottle_empty_pct[%s]" % side, "N/A"))
    print("  verdict: %s" % ("ACCEPTED" if ok else "NOT ACCEPTED"))
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    results = [scorecard(m) for m in sys.argv[1:]]
    sys.exit(0 if all(results) else 1)
