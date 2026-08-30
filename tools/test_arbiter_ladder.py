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

WHAT GREEN HERE DOES NOT MEAN. Nothing in this file runs the bot. These are text assertions
over Lua source: they can prove that `KillLock` still names `MayDive`, never that the bot
dives correctly. A guard rewritten with the condition inverted passes every test below. On
29.08 the whole suite was green while the bots visibly walked back and forth on screen, and
the two real defects that day were found by a person watching the match and by reading a diff
by hand -- the tests found neither. Their job is narrow and worth stating plainly: stop a
decision we already paid a match to learn from being deleted silently by the next refactor.
That is a ratchet against re-loss, not a safety net, and the count is not a quality metric --
a test nobody has broken on purpose is decoration. Break it, watch it go red, then keep it.

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

def anchor(text, needle, what, start=0):
    """Index of `needle`, or a readable failure saying which anchor moved.

    `str.index` raises ValueError('substring not found'), which tells the next reader nothing
    about which file, which anchor, or what to do -- and these tests anchor on real Lua, so a
    rename is the expected way for them to break. Probed by renaming `finishable` to `canKill`:
    the suite crashed instead of failing, and the traceback named neither the test's subject nor
    the fix.
    """
    at = text.find(needle, start)
    assert at >= 0, (
        f"anchor {needle!r} is gone from {what}. If it was renamed, update this test to the new "
        f"name; if the code around it was restructured, check the invariant still holds before "
        f"re-anchoring -- that is the whole point of the test."
    )
    return at


SAFETY = ROOT / "bots" / "FunLib" / "aibattle_laning_safety.lua"
TRADE = ROOT / "bots" / "FunLib" / "aibattle_laning_trade.lua"
STYLE = ROOT / "bots" / "FunLib" / "aibattle_style.lua"
RUNES = ROOT / "bots" / "FunLib" / "aibattle_runes.lua"
SURVIVE = ROOT / "bots" / "FunLib" / "aibattle_survive.lua"

# AIB_MoveToAttackEdgeOf returns false WITHOUT emitting its diag key when there is no edge
# location to walk to. A caller that drops that return and answers true has claimed the tick for
# a move that never went out. These are the sites that still do it, by file. The number may fall
# and never rise: fix one and lower the count, do not raise it to make a commit pass.
# Emptied 29.08, the day after it was recorded: creeps (the local wrapper and its three
# callers), siege (siege-step, siege-hold-step) and safety (cs-watchdog-step) all read the
# answer now. The budget stays as a dict rather than a bare zero so the next one that appears
# is written down where it can be paid off, not argued about.
DISCARDED_EDGE_RETURN_BUDGET = {}

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
    start = anchor(text, "function M.WaveWatch(ctx)", "aibattle_laning_safety.lua")
    step_key = anchor(text, '"wave-watch-step"', "M.WaveWatch", start)
    body = text[start:anchor(text, "\nend", "M.WaveWatch", step_key)]
    finishable_at = anchor(body, "local finishable", "M.WaveWatch")
    step_at = anchor(body, '"wave-watch-step"', "M.WaveWatch")
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
    start = anchor(text, "function M.KillLock(ctx)", "aibattle_laning_trade.lua")
    body = text[start:anchor(text, "\nend\n", "M.KillLock", start)]
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
    start = anchor(text, "function M.MayDive(bot)", "aibattle_style.lua")
    body = text[start:anchor(text, "\nend\n", "M.MayDive", start)]
    assert "hpDive < 0.30" in body, "the absolute 30% dive floor is gone"
    assert "GetHeroDeaths" in body and "0.40" in body, (
        "the post-death 40% floor is gone: in 1v1 a second death ends the game, so the floor "
        "has to outrank any dive_policy the config asks for"
    )


def test_a_staged_rune_trip_can_still_be_called_off():
    """Departure gates are not enough: the walk and the wait have to re-ask."""
    text = _read(RUNES)
    start = anchor(text, "function M.SeekBottleRune", "aibattle_runes.lua")
    follow_at = anchor(text, '"stage_follow"', "M.SeekBottleRune", start)
    dist_at = anchor(text, "local followDist", "M.SeekBottleRune", start)
    assert dist_at < follow_at, "the stage follow/hold block moved; re-anchor before trusting this"
    guard = text[dist_at:follow_at]
    missing = [name for name in ("tripUnsafe(", "spotRaceLost(") if name not in guard]
    assert not missing, (
        "the staged rune trip re-issues its walk with no survival test again (missing "
        + ", ".join(missing) + "). In 8974058954 t=468-484 that made the trip a promise the "
        "bot could not take back: it left the lane at 35% hp for a rune 2161u away and "
        "stage_follow/stage_hold kept walking until it died standing at the spot"
    )


def test_every_rune_departure_asks_the_same_survival_question():
    """Two departures, one predicate -- the stage path used to ask one gate of three."""
    text = _read(RUNES)
    start = anchor(text, "function M.SeekBottleRune", "aibattle_runes.lua")
    body = text[start:]
    assert body.count("tripUnsafe(bot,") >= 3, (
        "a rune departure or continuation stopped asking tripUnsafe. The direct commit, the "
        "stage departure and the stage hold must all ask it, or the cheapest path to a rune "
        "becomes the one with the fewest safety gates"
    )
    for leg in ("route_unsafe", "enemy_near", "hero_damage"):
        assert leg in text[:start], (
            f"the {leg} test left tripUnsafe and is inline again -- that is how the stage path "
            "ended up with one gate of three"
        )


def test_the_heal_escape_fires_before_the_bot_is_already_dying():
    """Both saving guards keep one escape; it must not shrink back to a bare 30% floor."""
    text = _read(SURVIVE)
    start = anchor(text, "local function stockHealConsumable", "aibattle_survive.lua")
    body = text[start:anchor(text, '\treturn "bought"', "stockHealConsumable", start)]
    escape = re.search(r"local criticalStuck =[^\n]*(?:\n\s+and[^\n]*)*", body)
    assert escape is not None, "the criticalStuck escape is gone from stockHealConsumable"
    assert "underFire" in escape.group(0), (
        "the escape past budget_cap and bottle-gold-protect is a bare HP floor again. A salve "
        "first allowed at 30% is allowed after the trade that decides the fight: 8974086880 "
        "t=152-168, Dire died from 100% in sixteen seconds holding 413 gold"
    )
    assert "savingIsClose" in body, (
        "the escape stopped asking whether saving is about to pay off, so it now overrides the "
        "bottle at any gold -- that is the early flask re-buy loop the original cap prevented"
    )


def test_fight_can_act_tests_terrain_in_the_contact_band():
    """The probe must not promise a swing the contact leg refuses on high ground."""
    text = _read(ORCHESTRATOR)
    start = anchor(text, "local fightCanAct", "mode_laning_generic.lua")
    body = text[start:anchor(text, "local recoverCanAct", "the fightCanAct block", start)]
    band = re.search(r"<=\s*range\s*\+\s*80[^\n]*", body)
    assert band is not None, "the in-contact branch of fightCanAct is gone"
    assert "UphillMiss" in band.group(0), (
        "the `range + 80` branch of fightCanAct is back to a bare distance test; "
        "aibattle_laning_combat.lua refuses that exact shell when the enemy is uphill, so the "
        "probe would again win elections on a swing that cannot land"
    )
