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
