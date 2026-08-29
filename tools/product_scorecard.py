#!/usr/bin/env python3
"""Product-facing AIBattle match gate.

This is deliberately stricter than scorecard.py. scorecard.py answers "did the bot
break"; this file answers "is this match worth showing/pricing".
"""

from __future__ import annotations

import argparse
import sys

import betting
import scorecard


THRESH = {
    "dead_tail_pct": 65.0,
    "max_bottle_empty_pct": 55,
    "min_first_event_s": 150.0,
    "min_lead_changes": 1,
    "min_mutual_low_s": 5.0,
}


def _fmt(value, suffix="", digits=1):
    if value is None:
        return "n/a"
    return f"{value:.{digits}f}{suffix}"


def _owned_bottle_empty_pct(text, side):
    import re

    samples = re.findall(r"AIB\[%s\][^']*bottle=(-?\d+)" % side, text)
    owned = [s for s in samples if s != "-1"]
    if not owned:
        return None
    return round(100.0 * sum(1 for s in owned if s == "0") / len(owned))


def product_gate(match_id):
    path = scorecard.DOTA_LOG_DIR / ("console.%s.log" % match_id)
    if not path.exists():
        print("[%s] log not found: %s" % (match_id, path))
        return False
    text = path.read_text(encoding="utf-8", errors="ignore")
    data = betting.analyse(text)
    if data is None:
        print("[%s] no paired AIB telemetry" % match_id)
        return False

    ok = True

    def check(name, value, limit, higher_is_bad=True, suffix="", digits=1):
        nonlocal ok
        if value is None:
            passed = False
        else:
            passed = value <= limit if higher_is_bad else value >= limit
        ok = ok and passed
        print("  %-24s %-6s value=%s limit=%s%s" % (
            name,
            "PASS" if passed else "FAIL",
            _fmt(value, suffix, digits),
            limit,
            suffix,
        ))

    bottle = {
        "R": _owned_bottle_empty_pct(text, "R"),
        "D": _owned_bottle_empty_pct(text, "D"),
    }
    max_bottle = max([v for v in bottle.values() if v is not None], default=None)
    mutual = ((data.get("state") or {}).get("mutual_low") or {}).get("seconds", 0.0)

    print("===== product gate %s =====" % match_id)
    print("  winner=%s method=%s duration=%.1fmin" % (
        data.get("winner") or "?",
        data.get("method") or "?",
        (data.get("duration") or 0.0) / 60.0,
    ))
    check("dead_tail", data.get("dead_tail"), THRESH["dead_tail_pct"], True, "%")
    check("bottle_empty_max", max_bottle, THRESH["max_bottle_empty_pct"], True, "%", 0)
    check("first_event_before", data.get("first_event"), THRESH["min_first_event_s"], True, "s", 0)
    check("lead_changes", data.get("lead_changes"), THRESH["min_lead_changes"], False, "", 0)
    check("mutual_low", mutual, THRESH["min_mutual_low_s"], False, "s")
    print("  bottle_empty_by_side     R=%s D=%s" % (
        _fmt(bottle["R"], "%", 0),
        _fmt(bottle["D"], "%", 0),
    ))
    print("  verdict: %s" % ("PRODUCT-READY" if ok else "WATCHLIST"))
    return ok


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("match_ids", nargs="+")
    args = parser.parse_args(argv)
    results = [product_gate(match_id) for match_id in args.match_ids]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

