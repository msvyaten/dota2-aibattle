"""Post-match frugal review: scorecard + this session's fix signatures in ONE command.

Usage: python tools/postmatch.py <matchid> [...]

Prints a compact report (no raw log dump) per the frugal-forensics rule: scorecard
verdict, then the specific signatures the current fixes are validated against, then
a jitter-key breakdown (which handler dominates) and an archetype contrast row.
Keep this the default post-match tool so a review costs ~20 lines, not a log dump.
"""
import re
import sys

import scorecard as sc  # tools/ is on sys.path when run as python tools/postmatch.py


def diag_max(text, side, key):
    """Max value of a cumulative 'key=N' diag counter for one side."""
    return sc.side_counter_max(text, side, key)


def occ(text, side, pat):
    """Count of AIB[side] lines matching a raw substring pattern."""
    return len(re.findall(r"AIB\[%s\][^']*%s" % (side, pat), text))


def last_stat(text, side, key):
    vals = re.findall(r"AIB\[%s\][^']*\b%s=(-?\d+)" % (side, re.escape(key)), text)
    return vals[-1] if vals else "?"


def last_time(text, side):
    vals = re.findall(r"AIB\[%s\] t=(\d+)s" % side, text)
    return vals[-1] if vals else "?"


def report(match_id):
    ok = sc.scorecard(match_id)
    path = sc.DOTA_LOG_DIR / ("console.%s.log" % match_id)
    if not path.exists():
        return ok
    text = path.read_text(encoding="utf-8", errors="ignore")

    print("----- watch: buy-escape + freeze (fix 9bb91a2) -----")
    for side in ("R", "D"):
        buycrit = diag_max(text, side, "recovery-buy-critical")
        stuck = occ(text, side, "reason=critical_stuck")
        budcap = occ(text, side, "reason=budget_cap")
        hold = diag_max(text, side, "critical-recover-hold")
        print("  [%s] recovery-buy-critical=%d critical_stuck=%d | budget_cap_blocks=%d | freeze critical-recover-hold=%d"
              % (side, buycrit, stuck, budcap, hold))

    print("----- jitter breakdown (which key dominates the sum) -----")
    for side in ("R", "D"):
        parts = " ".join("%s=%d" % (k, diag_max(text, side, k)) for k in sc.JITTER_KEYS)
        print("  [%s] %s" % (side, parts))

    print("----- archetype contrast (bind check: R vs D) -----")
    for side in ("R", "D"):
        print("  [%s] lh=%s dn=%s bottle_last=%s last_t=%ss"
              % (side, last_stat(text, side, "lh"), last_stat(text, side, "dn"),
                 last_stat(text, side, "bottle"), last_time(text, side)))
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    results = [report(m) for m in sys.argv[1:]]
    sys.exit(0 if all(results) else 1)
