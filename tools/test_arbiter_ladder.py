"""Contract tests for the tick-election score ladder.

The arbiter decides who owns a tick by sorting candidates on a single number, but that
number comes from three different places: `M.Score` in aibattle_laning_policy.lua, the
inline `tail(name, score, ...)` calls in mode_laning_generic.lua, and the `last-hit`
candidate, also inline. Nothing connected them, so a score could be edited in one file
while the reason it was chosen lived in another.

These tests read the real sources and assert the relationships the comments already claim.
They are static on purpose: `Arbiter.Run` is Lua and there is no Lua runtime in this
toolchain, but every invariant below is a property of the numbers and of the guards that
use them, not of a running match.

Evidence these exist to protect (five matches, 03.08-27.08): `fight` is the top empty
winner in 9 of 10 side-matches, and the scores it empties at are the LIVE fight scores
(78, 96, 98, 106, 114, 116, 124), never the 40 cap. Whatever else changes, the ladder's
own arithmetic has to stay honest.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "bots" / "FunLib" / "aibattle_laning_policy.lua"
ARBITER = ROOT / "bots" / "FunLib" / "aibattle_laning_arbiter.lua"
ORCHESTRATOR = ROOT / "bots" / "mode_laning_generic.lua"


def _read(path):
    return path.read_text(encoding="utf-8", errors="ignore")


def score_table():
    """`M.Score = { name = number, ... }` from the policy module."""
    text = _read(POLICY)
    start = text.index("M.Score = {")
    depth, i = 0, start + len("M.Score = ") - 1
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
    body = text[start:i]
    return {
        name: float(value)
        for name, value in re.findall(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(-?[\d.]+)\s*,", body, re.M)
    }


def tail_ladder():
    """`tail("name", score, "band", ...)` calls, in the order they are registered."""
    text = _read(ORCHESTRATOR)
    out = []
    for name, score, band in re.findall(
        r'^\s*tail\(\s*"([^"]+)"\s*,\s*([A-Za-z0-9_.]+)\s*,\s*"([^"]+)"', text, re.M
    ):
        try:
            out.append((name, float(score), band))
        except ValueError:
            out.append((name, None, band))  # computed at runtime, e.g. farmFocusScore
    return out


def last_hit_score():
    text = _read(ORCHESTRATOR)
    match = re.search(r'Candidate\(\s*"last-hit"\s*,\s*(\d+)', text)
    assert match, "the last-hit candidate is no longer registered inline"
    return float(match.group(1))


def hysteresis_bonus():
    text = _read(ARBITER)
    match = re.search(r"c\.priority\s*=\s*\(c\.priority or 0\)\s*\+\s*(\d+)", text)
    assert match, "winner hysteresis is no longer a flat bonus"
    return float(match.group(1))


def safe_cs_score():
    for name, score, _band in tail_ladder():
        if name == "safe-cs":
            assert score is not None, "safe-cs score must stay a literal, it is a calibration anchor"
            return score
    raise AssertionError("safe-cs is gone from the tail ladder")


# --------------------------------------------------------------------------------------


def test_no_action_caps_sit_below_safe_cs():
    """A desire with symptoms but no action must lose the tick to a securable last hit.

    This is the whole reason the caps are the numbers they are, and the two sides of the
    comparison live in different files.
    """
    scores = score_table()
    safe_cs = safe_cs_score()
    caps = {name: value for name, value in scores.items() if name.endswith("NoAction")}
    assert caps, "the no-action caps disappeared from M.Score"
    for name, value in caps.items():
        assert value < safe_cs, (
            f"{name}={value:g} must stay below tail(safe-cs)={safe_cs:g}; above it, a desire "
            f"that cannot act outbids farming and the bot idles instead of last-hitting"
        )


def test_capped_desires_are_excluded_from_winner_hysteresis():
    """cap + hysteresis would clear safe-cs, so the arbiter must refuse the bonus when capped."""
    scores = score_table()
    caps = [value for name, value in scores.items() if name.endswith("NoAction")]
    bonus = hysteresis_bonus()
    safe_cs = safe_cs_score()
    assert max(caps) + bonus > safe_cs, (
        "this test's premise is gone: caps plus hysteresis no longer clear safe-cs, so the "
        "guard below is no longer load-bearing and this test should be rewritten, not deleted"
    )
    arbiter = _read(ARBITER)
    assert "not c.capped" in arbiter, (
        f"a capped desire would reach {max(caps) + bonus:g} with the +{bonus:g} hysteresis "
        f"bonus and beat safe-cs={safe_cs:g} again; the arbiter must keep refusing the bonus "
        f"to capped candidates"
    )


def test_last_hit_outranks_every_desire_and_never_yields():
    """`last-hit` is the only candidate whose action always returns true, so it is absolute."""
    scores = score_table()
    live = {
        name: value
        for name, value in scores.items()
        if not name.endswith("NoAction") and value > 0 and not name.endswith(("Bonus", "Penalty", "Scale"))
    }
    top_desire = max(live.values())
    assert last_hit_score() > top_desire, (
        f"last-hit={last_hit_score():g} must outrank every desire (highest is {top_desire:g}); "
        f"it is scored as an override and its action can never decline the tick"
    )


def test_tail_ladder_is_strictly_descending():
    """Tail scores encode code order (P1-A). Registration order and score order must agree."""
    ladder = [(name, score) for name, score, _ in tail_ladder() if score is not None]
    assert len(ladder) > 10, "the tail ladder shrank unexpectedly; check the parser"
    for (prev_name, prev), (name, score) in zip(ladder, ladder[1:]):
        assert prev > score, (
            f"tail({prev_name})={prev:g} is registered before tail({name})={score:g} but does "
            f"not outrank it; the merged election relies on score order matching code order"
        )


def test_every_capped_desire_actually_clamps_its_score():
    """A cap that is never applied is decoration. Each one must reach a math.min in policy."""
    text = _read(POLICY)
    scores = score_table()
    for name in (n for n in scores if n.endswith("NoAction")):
        assert re.search(rf"math\.min\(\s*score\s*,\s*M\.Score\.{name}\s*\)", text), (
            f"M.Score.{name} is defined but never clamps a score; either apply it or drop it"
        )


def test_desire_and_tail_bands_do_not_overlap_by_accident():
    """The two score universes were merged, not unified. Keep the seam visible and deliberate."""
    ladder = [score for _n, score, _b in tail_ladder() if score is not None]
    scores = score_table()
    live_floor = min(
        value
        for name, value in scores.items()
        if name.endswith(("Base", "Healthy", "Danger", "Critical")) and value > 0
    )
    assert max(ladder) < live_floor, (
        f"the top tail score {max(ladder):g} now reaches into the live desire band "
        f"(floor {live_floor:g}); if that is intended, the ladder needs one shared constant "
        f"set rather than two"
    )


# --- owner contracts: what a candidate owes when it answers "yes, I acted" ---------------
#
# The ladder tests above are about the numbers. These are about the promise attached to them:
# `Arbiter.Run` stops at the first candidate whose action returns true, so a candidate that
# answers true without acting ends the tick for everyone below it. That is the one kind of
# empty ownership no counter can see -- `empty_action` is only logged for the desire band, and
# tail candidates are supposed to yield silently, so a lying tail owner is invisible twice over.
#
# 8972598364 is why these exist. wave-watch was given an action, the action's return was
# discarded, and the owner answered true either way; on screen that read as the bots walking
# back and forth, and the counter that should have shown it (`wave-watch-step`) was never
# emitted on the failing path.

SAFETY = ROOT / "bots" / "FunLib" / "aibattle_laning_safety.lua"
TRADE = ROOT / "bots" / "FunLib" / "aibattle_laning_trade.lua"
STYLE = ROOT / "bots" / "FunLib" / "aibattle_style.lua"

# AIB_MoveToAttackEdgeOf returns false WITHOUT emitting its diag key when there is no edge
# location to walk to. A caller that drops that return and answers true has claimed the tick for
# a move that never went out. These are the sites that still do it, by file. The number may fall
# and never rise: fix one and lower the count, do not raise it to make a commit pass.
DISCARDED_EDGE_RETURN_BUDGET = {
    "aibattle_laning_creeps.lua": 4,
    "aibattle_laning_siege.lua": 2,
    "aibattle_laning_safety.lua": 1,
}

_EDGE_CALL = re.compile(r"^\s*(?:ctx\.)?moveToAttackEdge\s*\(", re.M)


def discarded_edge_returns(path):
    """Calls to moveToAttackEdge whose return value nothing reads."""
    return len(_EDGE_CALL.findall(_read(path)))


def test_move_to_attack_edge_returns_are_not_discarded():
    """A discarded move return plus `return true` is a tick claimed for nothing."""
    lua = sorted((ROOT / "bots").rglob("aibattle_*.lua"))
    over = []
    for path in lua:
        found = discarded_edge_returns(path)
        budget = DISCARDED_EDGE_RETURN_BUDGET.get(path.name, 0)
        if found > budget:
            over.append(f"{path.name}: {found} discarded, budget {budget}")
    assert not over, (
        "moveToAttackEdge returns false without emitting its key when there is no edge to walk "
        "to, so its return has to be read before the owner answers true: " + "; ".join(over)
    )


def test_wave_watch_only_steps_at_a_creep_it_can_finish():
    """The stall branch must not walk at a healthy creep: the walk would not clear the stall."""
    text = _read(SAFETY)
    start = text.index("function M.WaveWatch(ctx)")
    body = text[start:text.index("\nend", text.index('"wave-watch-step"', start))]
    finishable_at = body.index("local finishable")
    step_at = body.index('"wave-watch-step"')
    assert finishable_at < step_at, "the step must be gated by `finishable`, not merely near it"
    guard = body[finishable_at:step_at]
    assert re.search(r"if\s+finishable\s+then", guard), (
        "wave-watch-step is reachable without `if finishable then`: walking at a full-HP creep "
        "produces no last hit, so the stall that triggered the walk is still true next tick and "
        "the branch re-fires -- 107 step orders against 18 attacks in 8972598364"
    )


def test_kill_lock_tower_veto_asks_the_dive_dial():
    """dive_policy has to reach behaviour; bare geometry must not outrank the dial."""
    text = _read(TRADE)
    start = text.index("function M.KillLock(ctx)")
    body = text[start:text.index("\nend\n", start)]
    veto = re.search(r"chaseIntoTower\(enemy\)[^\n]*\n?[^\n]*", body)
    assert veto is not None, "KillLock no longer consults chaseIntoTower at all"
    assert "MayDive" in veto.group(0), (
        "the tower veto in KillLock is bare geometry again: it refused a finish at ehp=10 in "
        "8972598364 while both configs set dive_policy=finish_only, which is exactly the dial "
        "that authorises it"
    )


def test_may_dive_keeps_the_engine_floors_under_the_dial():
    """The dial may licence a dive; it may not licence suicide."""
    text = _read(STYLE)
    start = text.index("function M.MayDive(bot)")
    body = text[start:text.index("\nend\n", start)]
    assert "hpDive < 0.30" in body, "the absolute 30% dive floor is gone"
    assert "GetHeroDeaths" in body and "0.40" in body, (
        "the post-death 40% floor is gone: in 1v1 a second death ends the game, so the floor "
        "has to outrank any dive_policy the config asks for"
    )


def test_fight_can_act_tests_terrain_in_the_contact_band():
    """The probe must not promise a swing the contact leg refuses on high ground."""
    text = _read(ORCHESTRATOR)
    start = text.index("local fightCanAct")
    body = text[start:text.index("local recoverCanAct", start)]
    band = re.search(r"<=\s*range\s*\+\s*80[^\n]*", body)
    assert band is not None, "the in-contact branch of fightCanAct is gone"
    assert "UphillMiss" in band.group(0), (
        "the `range + 80` branch of fightCanAct is back to a bare distance test; "
        "aibattle_laning_combat.lua refuses that exact shell when the enemy is uphill, so the "
        "probe would again win elections on a swing that cannot land"
    )
