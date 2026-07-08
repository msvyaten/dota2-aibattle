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


def recovery_owner_counts(text, side):
    lines = re.findall(r"AIB\[%s\][^']*intent=recovery-owner[^']*" % side, text)
    counts = {
        "total": len(lines),
        "critical": 0,
        "soft": 0,
        "caution": 0,
        "threat": 0,
    }
    for line in lines:
        for band in ("critical", "soft", "caution"):
            if "band=%s" % band in line:
                counts[band] += 1
        if "threat=true" in line:
            counts["threat"] += 1
    return counts


def report(match_id):
    ok = sc.scorecard(match_id)
    path = sc.DOTA_LOG_DIR / ("console.%s.log" % match_id)
    if not path.exists():
        return ok
    text = path.read_text(encoding="utf-8", errors="ignore")

    # Winner + config labels. Winner comes from the engine's "Winning team =" line
    # (same source as match_stats). Config guessed from the announce harass dial --
    # deaths must NOT be inferred from dg=-9x gold drops: those conflate ~100g
    # purchases with respawn losses (found 07.07 doing side-vs-config forensics).
    m = re.search(r"Winning team =\s*(\d)", text)
    win = {"0": "Radiant", "2": "Radiant", "1": "Dire", "3": "Dire"}.get(m.group(1), "?") if m else "?"
    def cfg(side):
        h = re.search(r"AIB\[%s\] harass=([0-9.]+)" % side, text)
        return {"0.90": "brawler", "0.55": "farmer", "0.85": "pusher"}.get(h.group(1), h.group(1)) if h else "?"
    print("----- outcome -----")
    print("  winner=%s | R=%s D=%s" % (win, cfg("R"), cfg("D")))

    print("----- watch: secure-LH + P3 owner episodes -----")
    for side in ("R", "D"):
        secure_lh = diag_max(text, side, "creep-hit-react-lh")
        secure_lh_intents = occ(text, side, "reason=secure_lh")
        owner = recovery_owner_counts(text, side)
        print("  [%s] creep-hit-react-lh=%d secure_lh_intents=%d | recovery-owner total=%d critical=%d soft=%d caution=%d threat=%d"
              % (side, secure_lh, secure_lh_intents, owner["total"], owner["critical"],
                 owner["soft"], owner["caution"], owner["threat"]))

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
