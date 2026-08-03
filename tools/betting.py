#!/usr/bin/env python3
"""Betting-market analysis of AIBattle matches.

Companion to match_stats.py, deliberately non-overlapping:

    match_stats.py  -- engineering QA: did the bot work?
    betting.py      -- market layer: is there a market here, and how would you price it?

Everything is derived from the periodic AIB telemetry already emitted by
mode_laning_generic.lua (~5s per side), so this tool is read-only post-match
analysis: no Lua, no engine, no deploy.

    AIB[R] t=15s hp=55% gold=320 loc=100,-50 enemy-dist=400 lh=3 dn=1 dg=-5 dlh=+1 bottle=0

The one thing match_stats.py does not build is the LEAD CURVE: the R-minus-D
difference over time. It reads each side separately. Every metric here comes from
pairing the two streams.

Deliberately NOT duplicated from match_stats.py: winner/KDA/LH/DN/damage/items,
bottle economy, stationary spans, contact share, diag and intent profiles.

Per match
  decided_at        last moment the eventual leader was still contested
  dead_tail%        share of the match that ran after it was already decided
  lead_changes      sign flips of the gold lead
  amplitude         max lead each way and mean |lead| -- do live odds move at all?
  deficit_overcome  biggest hole the winner climbed out of
  first_event       first blood, or first big HP swing -- when the match gets going
  state markets     HP/level/lane-pressure curves, low-HP and kill-pressure windows

Per series (--series)
  totals line       duration distribution -> over/under market
  handicap line     final margin distribution -> spread market
  method split      how matches were won -> method market
  outcome spread    same-looking matches repeated = replay, not a contest
  in-play basis     empirical P(win | lead at minute N), accumulated across matches
  identity gate     frozen build + frozen strategy pair + mandatory side swap

Usage
  python tools/betting.py <log-or-matchid> [more ids ...]
  python tools/betting.py --series <id1> <id2> ...
"""

import hashlib
import os
import re
import statistics
import sys

from aibattle_log import DOTA_LOG_DIR, extract_telemetry

# A gold lead inside this band counts as "still contested", not a real lead.
LEAD_BAND_GOLD = 200
# Max time difference when pairing an R sample with a D sample.
PAIR_TOLERANCE_S = 3.0
# An HP drop this large between consecutive samples counts as a real exchange.
BIG_HP_SWING = 20.0
# A market-facing danger band. This is deliberately independent from a bot style:
# odds care that a hero is one short exchange from death, regardless of why its
# recovery policy did or did not react.
LOW_HP_PCT = 35.0
# 900 is the widest common laning combat scan. A low target outside it is not an
# immediate kill window; it is merely hurt somewhere else on the map.
KILL_PRESSURE_RANGE = 900.0
# Lead buckets for the in-play win-probability table.
LEAD_BUCKETS = [(-10**9, -800), (-800, -300), (-300, 300), (300, 800), (800, 10**9)]
BUCKET_LABELS = ["D +800", "D +300", "even", "R +300", "R +800"]
# A win-probability cell needs at least this many samples to mean anything.
MIN_CELL_SAMPLES = 3

# ---------------------------------------------------------------- parsing


def pair_streams(telemetry, tolerance=PAIR_TOLERANCE_S):
    """Join R and D on nearest timestamp -> the lead curve.

    Leads are signed from Radiant's point of view: positive = Radiant ahead.
    """
    pairs, dire = [], telemetry["D"]
    if not dire:
        return pairs
    # `front` is measured from each side's own fountain, so raw R-D contains map
    # geometry and two different wave origins. Compare movement from each side's
    # first observed front instead: positive means Radiant's wave advanced farther
    # than Dire's, negative means Dire pressure.
    front_r0 = next((s["front"] for s in telemetry["R"] if s.get("front") is not None and s["front"] >= 0), None)
    front_d0 = next((s["front"] for s in dire if s.get("front") is not None and s["front"] >= 0), None)
    for r in telemetry["R"]:
        d = min(dire, key=lambda s: abs(s["t"] - r["t"]))
        if abs(d["t"] - r["t"]) > tolerance:
            continue
        lh_lead = None
        if r["lh"] is not None and d["lh"] is not None:
            lh_lead = r["lh"] - d["lh"]
        level_lead = None
        if r.get("lvl") is not None and d.get("lvl") is not None and r["lvl"] >= 0 and d["lvl"] >= 0:
            level_lead = r["lvl"] - d["lvl"]
        lane_pressure = None
        if (front_r0 is not None and front_d0 is not None
                and r.get("front") is not None and d.get("front") is not None
                and r["front"] >= 0 and d["front"] >= 0):
            lane_pressure = (r["front"] - front_r0) - (d["front"] - front_d0)
        distances = [x for x in (r.get("enemy_dist"), d.get("enemy_dist")) if x is not None]
        pairs.append({
            "t": r["t"],
            # Advantage, not wallet contents -- see extract_telemetry. The key keeps its
            # name so every downstream metric (decided_at, amplitude, in-play table)
            # switches over with it.
            "gold_lead": r["earned"] - d["earned"],
            "cash_lead": r["gold"] - d["gold"],
            "lh_lead": lh_lead,
            "hp_r": r["hp"],
            "hp_d": d["hp"],
            "hp_lead": r["hp"] - d["hp"],
            "level_lead": level_lead,
            "lane_pressure": lane_pressure,
            "contact_dist": min(distances) if distances else None,
        })
    return pairs


def deaths_from_hp(telemetry):
    """Death timestamps per side, from hp -> 0 transitions in the telemetry."""
    deaths = {"R": [], "D": []}
    for side, samples in telemetry.items():
        was_alive = True
        for s in samples:
            if s["hp"] <= 0.5 and was_alive:
                deaths[side].append(s["t"])
                was_alive = False
            elif s["hp"] > 5:
                was_alive = True
    return deaths


# ---------------------------------------------------------------- lead curve

def _leader(lead, band=LEAD_BAND_GOLD):
    """-1 / 0 / +1, where 0 means inside the contested band."""
    if lead > band:
        return 1
    if lead < -band:
        return -1
    return 0


def decided_point(pairs, band=LEAD_BAND_GOLD):
    """When the match stopped being contested -> (decided_at, dead_tail_pct)."""
    if not pairs:
        return None, None
    end_t = pairs[-1]["t"]
    final = _leader(pairs[-1]["gold_lead"], band)
    if final == 0:
        # Ended inside the contested band, so there is no eventual leader to trace back to.
        # This used to return (end_t, 0.0), which reads as "contested to the final second" and
        # is indistinguishable from a genuine nail-biter -- 8925526609 finished at -167 gold
        # against a 200 band and printed decided_at=996s dead_tail=0.0%, off which I told the
        # user the match was undecided throughout. It was not: lead_changes=0 and D peaked at
        # +764, so one side led the whole way and the gap merely closed at the end.
        # None makes the caller say "n/a" instead of inventing a verdict.
        return None, None
    decided_at = pairs[0]["t"]
    for p in pairs:
        if _leader(p["gold_lead"], band) != final:
            decided_at = p["t"]
    dead_tail = (end_t - decided_at) / end_t * 100 if end_t > 0 else 0.0
    return decided_at, dead_tail


def lead_changes(pairs, band=LEAD_BAND_GOLD):
    """Sign flips of the gold lead, ignoring moves inside the contested band."""
    changes, previous = 0, 0
    for p in pairs:
        side = _leader(p["gold_lead"], band)
        if side == 0:
            continue
        if previous and side != previous:
            changes += 1
        previous = side
    return changes


def amplitude(pairs):
    """How far the lead swings.

    A lead can swing widely without ever crossing zero: no sign flip, but live odds
    should still move. Amplitude is what tells you whether an in-play market breathes.
    """
    if not pairs:
        return None
    leads = [p["gold_lead"] for p in pairs]
    return {
        "max_r": max(0, max(leads)),
        "max_d": max(0, -min(leads)),
        "mean_abs": statistics.mean(abs(x) for x in leads),
    }


def _curve_summary(pairs, key):
    """Signed R-minus-D summary for an optional paired telemetry field."""
    values = [p[key] for p in pairs if p.get(key) is not None]
    if not values:
        return None
    return {
        "final": values[-1],
        "max_r": max(0, max(values)),
        "max_d": max(0, -min(values)),
        "mean": statistics.mean(values),
        "mean_abs": statistics.mean(abs(v) for v in values),
        "samples": len(values),
    }


def _sample_spans(pairs):
    """Attach a bounded duration to each periodic sample.

    Telemetry is normally ~5s apart. A missing log chunk must not turn one active
    sample into a minute-long betting window, so gaps are capped at twice the
    median observed cadence. The final sample has no known lifetime and contributes
    zero seconds rather than inventing time beyond the end of the log.
    """
    if not pairs:
        return []
    gaps = [b["t"] - a["t"] for a, b in zip(pairs, pairs[1:]) if b["t"] > a["t"]]
    cadence = statistics.median(gaps) if gaps else 5.0
    cap = max(2.0 * cadence, 1.0)
    spans = []
    for i, p in enumerate(pairs):
        raw = pairs[i + 1]["t"] - p["t"] if i + 1 < len(pairs) else 0.0
        spans.append((p, max(0.0, min(raw, cap))))
    return spans


def _window_stats(spans, predicate):
    seconds = 0.0
    episodes = 0
    first = None
    active = False
    for p, duration in spans:
        on = bool(predicate(p))
        if on:
            seconds += duration
            if not active:
                episodes += 1
                if first is None:
                    first = p["t"]
        active = on
    return {"seconds": seconds, "episodes": episodes, "first": first}


def state_markets(pairs):
    """Market signals that unspent-gold advantage cannot represent.

    These are descriptive state variables, not a hand-tuned win-probability model.
    They start accumulating the inputs needed for one: health danger, actionable
    kill pressure, level advantage, and wave pressure.
    """
    spans = _sample_spans(pairs)
    duration = sum(dt for _, dt in spans)

    def low(side):
        return lambda p: p[f"hp_{side.lower()}"] <= LOW_HP_PCT

    def kill_pressure(side):
        own = "hp_r" if side == "R" else "hp_d"
        foe = "hp_d" if side == "R" else "hp_r"
        return lambda p: (p.get("contact_dist") is not None
                          and p["contact_dist"] <= KILL_PRESSURE_RANGE
                          and p[foe] <= LOW_HP_PCT
                          and p[own] > p[foe])

    return {
        "duration": duration,
        "hp": _curve_summary(pairs, "hp_lead"),
        "level": _curve_summary(pairs, "level_lead"),
        "lane": _curve_summary(pairs, "lane_pressure"),
        "low_hp": {side: _window_stats(spans, low(side)) for side in ("R", "D")},
        "kill_pressure": {side: _window_stats(spans, kill_pressure(side)) for side in ("R", "D")},
        "mutual_low": _window_stats(spans, lambda p: p["hp_r"] <= LOW_HP_PCT and p["hp_d"] <= LOW_HP_PCT),
    }


def deficit_overcome(pairs, winner):
    """Biggest hole the eventual winner climbed out of.

    If the trailing side never wins, in-play odds collapse to 1.0 after the first
    real lead and there is no market left to trade.
    """
    if not pairs or winner not in ("R", "D"):
        return None
    leads = [p["gold_lead"] for p in pairs]
    worst = -min(leads) if winner == "R" else max(leads)
    return max(0, worst)


def first_event(pairs, deaths):
    """First blood, or the first big HP exchange -- when the match gets going."""
    candidates = [t for side in deaths for t in deaths[side]]
    for key in ("hp_r", "hp_d"):
        series = [(p["t"], p[key]) for p in pairs]
        for (_, a), (tb, b) in zip(series, series[1:]):
            if a - b >= BIG_HP_SWING:
                candidates.append(tb)
                break
    return min(candidates) if candidates else None


def signout_result(text):
    """Authoritative K/D from the end-of-match signout block. Team 0 = Radiant.

    Telemetry cannot be trusted for deaths: the bot's Think does not run while it is
    dead, so hp=0 samples are emitted only sometimes. Both matches replayed on 23.07
    were won by kills and hp-transition counting saw R=1 D=0 and R=1 D=1 -- so the
    method-of-victory market line read "tower/last-hits" on 2 of 2 kill wins. The
    signout block is written once per match and is exact; hp transitions stay as the
    fallback for a log that was cut before signout.
    """
    kda = re.findall(r"KDA: (\d+) / (\d+) / \d+", text)
    if len(kda) < 2:
        return None
    return {"R": {"k": int(kda[0][0]), "d": int(kda[0][1])},
            "D": {"k": int(kda[1][0]), "d": int(kda[1][1])}}


def infer_winner(pairs, deaths, result=None):
    """Winner and how it was won. Prefers the signout block over hp transitions."""
    kills = result or {s: {"d": len(deaths[s])} for s in ("R", "D")}
    if kills["D"]["d"] >= 2:
        return "R", "kills"
    if kills["R"]["d"] >= 2:
        return "D", "kills"
    if not pairs:
        return None, "unknown"
    final = pairs[-1]["gold_lead"]
    winner = "R" if final > 0 else "D" if final < 0 else None
    return winner, "tower/last-hits (see match_stats)"


def strategy_fingerprints(text):
    """Stable IDs for the two announced LLM strategies.

    The announce is the canonical runtime config, unlike the mutable files on disk.
    Hashing its three lines keeps series output compact while still detecting one
    changed dial or rule. Old logs without a complete announce remain supported.
    """
    rows = {"R": {}, "D": {}}
    pattern = re.compile(r"AIB\[([RD])\]\s+((?:harass|defend|hero)=[^']+)")
    for side, body in pattern.findall(text):
        body = " ".join(body.split())
        rows[side][body.split("=", 1)[0]] = body
    result = {}
    for side in ("R", "D"):
        if not all(k in rows[side] for k in ("harass", "defend", "hero")):
            result[side] = None
            continue
        canonical = "\n".join(rows[side][k] for k in ("harass", "defend", "hero"))
        result[side] = hashlib.sha1(canonical.encode("utf-8")).hexdigest()[:8]
    return result


# ---------------------------------------------------------------- per match

def analyse(text):
    telemetry = extract_telemetry(text)
    pairs = pair_streams(telemetry)
    if not pairs:
        return None
    deaths = deaths_from_hp(telemetry)
    result = signout_result(text)
    winner, method = infer_winner(pairs, deaths, result)
    decided_at, dead_tail = decided_point(pairs)
    final = pairs[-1]
    build = re.search(r"AIB\[[RD]\] build=(\S+?)'", text)
    return {
        "build": build.group(1) if build else None,
        "deaths_official": {s: result[s]["d"] for s in ("R", "D")} if result else None,
        "samples": len(pairs),
        "duration": final["t"],
        "winner": winner,
        "method": method,
        "decided_at": decided_at,
        "dead_tail": dead_tail,
        "lead_changes": lead_changes(pairs),
        "amplitude": amplitude(pairs),
        "deficit_overcome": deficit_overcome(pairs, winner),
        "first_event": first_event(pairs, deaths),
        "state": state_markets(pairs),
        "strategies": strategy_fingerprints(text),
        "final_gold_lead": final["gold_lead"],
        "final_lh_lead": final["lh_lead"],
        "deaths": {k: len(v) for k, v in deaths.items()},
        "pairs": pairs,
    }


# ---------------------------------------------------------------- reporting

def _fmt(v, suffix="", nd=1):
    return "n/a" if v is None else f"{v:.{nd}f}{suffix}"


def _share(seconds, total):
    return None if not total else seconds / total * 100.0


def report_one(label, m):
    print(f"\n=== {label} ===")
    print(f"  duration          {m['duration']:.0f}s ({m['duration']/60:.1f} min), {m['samples']} paired samples")
    d = m["deaths_official"] or m["deaths"]
    src = "" if m["deaths_official"] else " (from hp, no signout block)"
    print(f"  winner            {m['winner'] or '?'} by {m['method']}  "
          f"(deaths R={d['R']} D={d['D']}){src}")
    print(f"  first_event       {_fmt(m['first_event'], 's', 0)}   <- earlier is better, the match gets going")
    print(f"  decided_at        {_fmt(m['decided_at'], 's', 0)}   <- later is better, tension holds")
    print(f"  dead_tail         {_fmt(m['dead_tail'], '%')}   <- share of match already decided")
    print(f"  lead_changes      {m['lead_changes']}")
    a = m["amplitude"]
    if a:
        print(f"  amplitude         R peak +{a['max_r']}, D peak +{a['max_d']}, mean |lead| {a['mean_abs']:.0f}")
        print(f"                    <- wide swings move live odds even with no lead change")
    print(f"  deficit_overcome  {_fmt(m['deficit_overcome'], ' gold', 0)}   <- 0 means the underdog never came back")
    margin = f"gold {m['final_gold_lead']:+d}"
    if m["final_lh_lead"] is not None:
        margin += f", lh {m['final_lh_lead']:+d}"
    print(f"  final margin      {margin}")
    strategies = m.get("strategies") or {}
    if strategies.get("R") or strategies.get("D"):
        print(f"  strategies        R={strategies.get('R') or '?'} D={strategies.get('D') or '?'}")

    state = m.get("state") or {}
    print("\n  state markets")
    hp = state.get("hp")
    if hp:
        print(f"    hp advantage    final {hp['final']:+.0f}pp, R peak +{hp['max_r']:.0f}, "
              f"D peak +{hp['max_d']:.0f}, mean |edge| {hp['mean_abs']:.0f}pp")
    level = state.get("level")
    if level:
        print(f"    level advantage final {level['final']:+.0f}, R peak +{level['max_r']:.0f}, "
              f"D peak +{level['max_d']:.0f}")
    else:
        print("    level advantage n/a (old telemetry)")
    lane = state.get("lane")
    if lane:
        print(f"    lane pressure   final {lane['final']:+.0f}, R peak +{lane['max_r']:.0f}, "
              f"D peak +{lane['max_d']:.0f}, mean {lane['mean']:+.0f}")
    else:
        print("    lane pressure   n/a (old telemetry)")

    total = state.get("duration") or 0.0
    low = state.get("low_hp") or {}
    kp = state.get("kill_pressure") or {}
    for side in ("R", "D"):
        low_side = low.get(side, {"seconds": 0.0, "episodes": 0})
        kp_side = kp.get(side, {"seconds": 0.0, "episodes": 0, "first": None})
        print(f"    [{side}] low HP       {low_side['seconds']:.0f}s "
              f"({_fmt(_share(low_side['seconds'], total), '%')}) in {low_side['episodes']} windows; "
              f"kill pressure {kp_side['seconds']:.0f}s/{kp_side['episodes']} windows, "
              f"first {_fmt(kp_side.get('first'), 's', 0)}")
    mutual = state.get("mutual_low") or {"seconds": 0.0, "episodes": 0}
    print(f"    mutual low      {mutual['seconds']:.0f}s in {mutual['episodes']} windows"
          "   <- live comeback/kill volatility")


def _line(values, nd=0):
    return (f"min {min(values):.{nd}f}  median {statistics.median(values):.{nd}f}  "
            f"max {max(values):.{nd}f}")


def check_frozen_build(results):
    """A series is only a series if every match ran the same bot.

    This is the one corruption that leaves no trace in the numbers: matches on
    different builds aggregate into clean-looking market lines for a player that
    never existed. Everything else in a botched series is visible by eye; this is not.
    Refuse rather than warn -- a warning above 40 lines of output gets scrolled past.
    """
    builds = {}
    for label, m in results:
        builds.setdefault(m.get("build") or "unknown", []).append(label)
    if len(builds) <= 1:
        return True
    print("\nREFUSED: these matches did not run the same bot build.\n")
    for sha, labels in sorted(builds.items()):
        print("  %-10s %s" % (sha, ", ".join(labels)))
    print("\nA betting series requires frozen code -- market lines across builds price")
    print("a player that never existed. Re-run the series, or pass only one build's ids.")
    return False


def series_config_status(results):
    """Validate one frozen strategy matchup and its side swap."""
    orientations = []
    unknown = []
    for label, m in results:
        strategies = m.get("strategies") or {}
        r, d = strategies.get("R"), strategies.get("D")
        if r is None or d is None:
            unknown.append(label)
        else:
            orientations.append((r, d))
    if unknown:
        return {"ok": True, "known": False, "unknown": unknown, "swapped": None, "pair": None}
    matchups = {tuple(sorted(pair)) for pair in orientations}
    if len(matchups) != 1:
        return {"ok": False, "known": True, "reason": "config_changed",
                "matchups": sorted(matchups), "swapped": False, "pair": None}
    pair = next(iter(matchups))
    mirrored = pair[0] == pair[1]
    swapped = mirrored or ((pair[0], pair[1]) in orientations and (pair[1], pair[0]) in orientations)
    # A one-match preview has no market line yet, so report the pending swap without refusing it.
    ok = swapped or len(results) < 2
    return {"ok": ok, "known": True, "reason": None if ok else "missing_side_swap",
            "swapped": swapped, "pair": pair, "orientations": orientations}


def check_frozen_config(results):
    status = series_config_status(results)
    if not status["known"]:
        print("\nWARNING: strategy announce missing in: " + ", ".join(status["unknown"]))
        print("Config freeze and side swap cannot be verified for this legacy series.")
        return True
    if status["ok"]:
        pair = status.get("pair")
        if pair is not None:
            swap = "mirrored strategy" if pair[0] == pair[1] else ("side swap verified" if status["swapped"] else "side swap pending")
            print(f"  strategy matchup         {pair[0]} vs {pair[1]} ({swap})")
        return True
    print("\nREFUSED: strategy configs are not a valid betting series.\n")
    if status.get("reason") == "missing_side_swap":
        a, b = status["pair"]
        print(f"  {a} vs {b} was played on only one orientation.")
        print("  Run the same matchup with Radiant/Dire swapped before pricing it.")
    else:
        print("  More than one strategy matchup was found:")
        for pair in status.get("matchups", []):
            print("  " + " vs ".join(pair))
        print("  Freeze both configs; dial changes start a new series.")
    return False


def report_series(results):
    if not check_frozen_build(results):
        return
    if not check_frozen_config(results):
        return
    print("\n=== series ===")
    header = (f"{'match':<13}{'win':>5}{'dur':>7}{'1st ev':>8}{'decided':>9}"
              f"{'dead%':>7}{'flips':>6}{'comeback':>10}{'margin':>9}")
    print(header)
    print("-" * len(header))
    for label, m in results:
        print(f"{label:<13}{m['winner'] or '?':>5}{m['duration']:>6.0f}s"
              f"{_fmt(m['first_event'], 's', 0):>8}{_fmt(m['decided_at'], 's', 0):>9}"
              f"{_fmt(m['dead_tail']):>7}{m['lead_changes']:>6}"
              f"{_fmt(m['deficit_overcome'], '', 0):>10}{m['final_gold_lead']:>+9d}")

    if len(results) < 2:
        return
    metrics = [m for _, m in results]

    print("\n--- market lines ---")
    durations = [m["duration"] / 60 for m in metrics]
    print(f"  totals (duration, min)   {_line(durations, 1)}")
    print(f"    -> over/under line at {statistics.median(durations):.1f} min")

    margins = [abs(m["final_gold_lead"]) for m in metrics]
    print(f"  handicap (final gold)    {_line(margins)}")
    print(f"    -> spread line at {statistics.median(margins):.0f} gold")

    methods = {}
    for m in metrics:
        methods[m["method"]] = methods.get(m["method"], 0) + 1
    print("  method of victory        " + ", ".join(f"{k}: {v}" for k, v in methods.items()))

    wins = {}
    for m in metrics:
        wins[m["winner"] or "?"] = wins.get(m["winner"] or "?", 0) + 1
    print("  winners                  " + ", ".join(f"{k}: {v}" for k, v in wins.items()))

    print("\n--- replay check (low spread on every row = same match repeated) ---")
    for key, label, nd in (("duration", "duration", 0),
                           ("decided_at", "decided_at", 0),
                           ("first_event", "first_event", 0),
                           ("final_gold_lead", "final margin", 0)):
        values = [m[key] for m in metrics if m.get(key) is not None]
        if len(values) < 2:
            continue
        print(f"  {label:<14} spread {max(values)-min(values):>6.{nd}f}   sd {statistics.stdev(values):>6.{nd}f}")

    comebacks = [m["deficit_overcome"] for m in metrics if m["deficit_overcome"] is not None]
    if comebacks:
        print(f"\n  biggest comeback in series: {max(comebacks):.0f} gold")
        if max(comebacks) < LEAD_BAND_GOLD:
            print("    WARNING: nobody ever came back -> live market dies at the first real lead")

    print("\n--- state-market spread ---")
    for side in ("R", "D"):
        low_shares = []
        pressure_seconds = []
        pressure_episodes = 0
        for m in metrics:
            state = m.get("state") or {}
            total = state.get("duration") or 0.0
            low = (state.get("low_hp") or {}).get(side)
            kp = (state.get("kill_pressure") or {}).get(side)
            if low is not None and total > 0:
                low_shares.append(_share(low["seconds"], total))
            if kp is not None:
                pressure_seconds.append(kp["seconds"])
                pressure_episodes += kp["episodes"]
        if low_shares:
            print(f"  [{side}] low-HP share       {_line(low_shares, 1)}%")
        if pressure_seconds:
            print(f"      kill-pressure sec  {_line(pressure_seconds, 0)}; episodes total {pressure_episodes}")

    level_finals = [m["state"]["level"]["final"] for m in metrics
                    if (m.get("state") or {}).get("level") is not None]
    lane_means = [m["state"]["lane"]["mean"] for m in metrics
                  if (m.get("state") or {}).get("lane") is not None]
    mutual_seconds = [m["state"]["mutual_low"]["seconds"] for m in metrics
                      if (m.get("state") or {}).get("mutual_low") is not None]
    if level_finals:
        print(f"  final level lead R-D  {_line(level_finals, 0)}")
    if lane_means:
        print(f"  mean lane pressure    {_line(lane_means, 0)}")
    if mutual_seconds:
        print(f"  mutual-low seconds    {_line(mutual_seconds, 0)}")

    inplay_table(metrics)


def inplay_table(metrics):
    """Empirical P(R wins | gold lead at minute N) -- the in-play pricing basis.

    Six matches will not fit a model; roughly 25-30 are needed before the cells are
    worth quoting. Collecting from day one avoids replaying the series later.
    """
    cells = {}
    for m in metrics:
        if m["winner"] not in ("R", "D"):
            continue
        for p in m["pairs"]:
            minute = int(p["t"] // 60)
            for i, (lo, hi) in enumerate(LEAD_BUCKETS):
                if lo <= p["gold_lead"] < hi:
                    won, total = cells.get((minute, i), (0, 0))
                    cells[(minute, i)] = (won + (m["winner"] == "R"), total + 1)
                    break
    if not cells:
        return
    minutes = sorted({k[0] for k in cells})
    print("\n--- in-play basis: P(R wins | lead at minute) ---")
    print("    (needs ~25-30 matches to price on; shown now to start accumulating)")
    print("  min  " + "".join(f"{lbl:>10}" for lbl in BUCKET_LABELS))
    for minute in minutes:
        row = f"  {minute:>3}  "
        for i in range(len(LEAD_BUCKETS)):
            won, total = cells.get((minute, i), (0, 0))
            row += f"{'-':>10}" if total < MIN_CELL_SAMPLES else f"{won/total*100:>8.0f}%{'':>1}"
        print(row)


# ---------------------------------------------------------------- entry

def find_log(arg):
    """Accept a path or a bare match id; search the usual places."""
    if os.path.isfile(arg):
        return arg
    name = arg if arg.startswith("console.") else f"console.{arg}.log"
    roots = [".", "logs", os.environ.get("AIB_LOGDIR", ""), str(DOTA_LOG_DIR)]
    for root in roots:
        if root and os.path.isfile(os.path.join(root, name)):
            return os.path.join(root, name)
    return None


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    series = argv[0] == "--series"
    targets = argv[1:] if series else argv
    if not targets:
        print("no match given")
        return 1

    results = []
    for target in targets:
        path = find_log(target)
        if path is None:
            print(f"log not found: {target}", file=sys.stderr)
            continue
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            metrics = analyse(fh.read())
        if metrics is None:
            print(f"no paired telemetry in {path}", file=sys.stderr)
            continue
        results.append((os.path.basename(path).replace("console.", "").replace(".log", ""), metrics))

    if not results:
        return 1
    if series:
        report_series(results)
    else:
        for label, metrics in results:
            report_one(label, metrics)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
