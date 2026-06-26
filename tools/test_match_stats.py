"""Unit tests for the AIBattle analysis tooling (match_stats.py + check_all.py).

These tools are load-bearing -- every match is read through match_stats -- so the parsing
and summary helpers added for flow/window/bottle/lua-syntax are pinned here.

Run: python -m pytest tools/test_match_stats.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import match_stats as m
import check_all as c


def _tele(*lines):
    """Wrap AIB report bodies as console.log chat lines and parse to telemetry."""
    text = "\n".join(f"x 'AIB[{side}] {body}'" for side, body in lines)
    return m.extract_telemetry(text)


# --- extract_telemetry: bottle field is optional (backward compatible) ---

def test_telemetry_parses_bottle_when_present():
    tel = _tele(("R", "t=10s hp=80% gold=300 loc=-1,-2 lh=2 dn=0 dg=+8 dlh=+0 bottle=3"))
    assert tel["R"][0]["bottle"] == 3


def test_telemetry_bottle_absent_is_none_not_crash():
    tel = _tele(("R", "t=10s hp=80% gold=300 loc=-1,-2 lh=2 dn=0 dg=+8 dlh=+0"))
    assert tel["R"][0]["bottle"] is None


def test_telemetry_keeps_core_fields():
    tel = _tele(("D", "t=15s hp=55% gold=320 loc=100,-50 enemy-dist=400 lh=3 dn=1 dg=-5 dlh=+1 bottle=0"))
    s = tel["D"][0]
    assert (s["t"], s["hp"], s["gold"], s["loc"], s["enemy_dist"]) == (15.0, 55.0, 320, (100.0, -50.0), 400.0)
    assert (s["lh"], s["dn"], s["bottle"]) == (3, 1, 0)


# --- bottle_summary ---

def test_bottle_summary_counts_empty_fraction():
    tel = _tele(
        ("R", "t=10s hp=80% gold=1 loc=0,0 bottle=3"),
        ("R", "t=15s hp=60% gold=1 loc=0,0 bottle=0"),
        ("R", "t=20s hp=55% gold=1 loc=0,0 bottle=0"),
    )
    assert m.bottle_summary(tel["R"]) == "empty 2/3 samples (67%)"


def test_bottle_summary_none_without_data():
    tel = _tele(("R", "t=10s hp=80% gold=1 loc=0,0 lh=1 dn=0 dg=+0 dlh=+0"))
    assert m.bottle_summary(tel["R"]) is None


def test_bottle_summary_ignores_no_bottle_sentinel():
    # -1 means "no bottle owned" -- excluded from the sustain ratio entirely.
    tel = _tele(
        ("R", "t=10s hp=80% gold=1 loc=0,0 bottle=-1"),
        ("R", "t=15s hp=60% gold=1 loc=0,0 bottle=0"),
    )
    assert m.bottle_summary(tel["R"]) == "empty 1/1 samples (100%)"


# --- extract_deaths: hp -> 0 transitions ---

def test_extract_deaths_detects_transition_to_zero():
    tel = _tele(
        ("R", "t=10s hp=40% gold=1 loc=0,0"),
        ("R", "t=15s hp=0% gold=1 loc=0,0"),
        ("R", "t=20s hp=0% gold=1 loc=0,0"),   # still dead -> not a second death
        ("R", "t=25s hp=100% gold=1 loc=0,0"),  # respawn
        ("R", "t=30s hp=0% gold=1 loc=0,0"),   # died again
    )
    assert m.extract_deaths(tel)["R"] == [15.0, 30.0]


def test_extract_deaths_empty_when_never_dies():
    tel = _tele(("D", "t=10s hp=90% gold=1 loc=0,0"), ("D", "t=15s hp=50% gold=1 loc=0,0"))
    assert m.extract_deaths(tel)["D"] == []


# --- format_flow: authoritative score + game-end backfill + first blood ---

def test_format_flow_backfills_game_end_kill():
    # Telemetry caught only D@262 (the 542 kill landed on the final tick, no hp=0 sample),
    # but the stat dump says R got 2 kills / D got 1. Flow must reconcile to D@262,543.
    deaths = {"R": [294.0], "D": [262.0]}
    score = (2, 1, 1, 2)  # R kills, R deaths, D kills, D deaths
    flow = m.format_flow(deaths, "543", True, score)
    assert "kills R:2 D:1" in flow
    assert "D@262s,543s" in flow
    assert "R@294s" in flow
    assert "first-blood R@262s" in flow   # earliest death is D -> R drew first blood
    assert "end 543s kill-win" in flow


def test_format_flow_tower_win_when_not_kill_win():
    deaths = {"R": [663.0], "D": [793.0]}
    flow = m.format_flow(deaths, "878", False, (1, 1, 1, 1))
    assert "kills R:1 D:1" in flow
    assert "end 878s tower/other" in flow


def test_format_flow_none_when_no_deaths():
    assert m.format_flow({"R": [], "D": []}, "500", False, (0, 0, 0, 0)) is None


# --- extract_event_timeline: window keeps everything, default truncates ---

def _timeline_log(n):
    lines = []
    for i in range(n):
        t = (i + 1) * 5
        lines.append(f"x 'AIB[R] t={t}s hp=80% gold=1 loc=0,0'")
        lines.append(f"x 'AIB[R] intent=hero-contact dist=100 hp=80 reason=attackable_enemy'")
    return "\n".join(lines)


def test_timeline_window_filters_to_range_without_truncation():
    tl = m.extract_event_timeline(_timeline_log(40), window=(50, 70))
    assert tl["R"], "window should retain in-range events"
    assert not any("...+" in e for e in tl["R"])  # no mid truncation in window mode
    assert all(50 <= int(e.split("s:")[0]) <= 70 for e in tl["R"])


def test_timeline_default_truncates_long_runs():
    tl = m.extract_event_timeline(_timeline_log(40), limit=22)
    assert any("...+" in e for e in tl["R"])


# --- debug_tree: desire -> state -> action/block -> symptom hierarchy ---

def test_extract_intents_keeps_field_counts():
    text = "\n".join([
        "x 'AIB[R] intent=rune-result source=bottle-rune result=timeout age=30'",
        "x 'AIB[R] intent=rune-result source=bottle-rune result=timeout age=30'",
        "x 'AIB[R] intent=rune-result source=bottle-rune result=filled age=2'",
    ])
    intents = m.extract_intents(text)
    assert intents["rune-result"]["R"]["fields"]["result"] == {"timeout": 2, "filled": 1}


def test_debug_tree_groups_state_action_block_and_symptom():
    diag = {
        "pg-duel": {"R": 2},
        "bottle-rune": {"R": 1},
        "recovery-regen": {"R": 3},
        "siege-step": {"R": 4},
        "cs-walk": {"R": 5},
    }
    intents = {
        "state-prewave-duel": {"R": {"count": 1, "last": "", "fields": {}}},
        "state-rune-commit": {"R": {"count": 2, "last": "", "fields": {}}},
        "tower-opportunity": {
            "R": {"count": 2, "last": "", "fields": {"result": {"step": 2}}}
        },
    }
    blocked = {
        "siege": {"R": {"healing": {"count": 1, "last": ""}}},
        "bottle-rune": {"R": {"no_close_rune": {"count": 3, "last": ""}}},
    }
    alerts = ["R: ignored-nearby-hero close_samples=4 hero_actions=0"]
    lines = m.debug_tree_lines("R", diag, intents, blocked, alerts)
    joined = "\n".join(lines)
    assert "fight:" in joined and "state-prewave-duel=1" in joined and "pg-duel=2" in joined
    assert "rune:" in joined and "bottle-rune=1" in joined and "blocked[bottle-rune=3]" in joined
    assert "push:" in joined and "tower:step=2" in joined and "blocked[siege=1]" in joined


# --- fix_candidates: advisory auto-audit, not ground truth ---

def test_fix_candidates_flags_stationary_damage_without_action():
    tel = _tele(
        ("R", "t=10s hp=80% gold=1 loc=0,0 bottle=3"),
        ("R", "t=15s hp=72% gold=1 loc=10,5 bottle=3"),
        ("R", "t=20s hp=66% gold=1 loc=12,8 bottle=3"),
    )
    candidates = m.fix_candidates({}, tel, {}, {}, [], {"R": [], "D": []}, [])
    assert any(c["area"] == "visual-afk" and c["confidence"] == "high" for c in candidates)


def test_fix_candidates_flags_empty_bottle_with_rune_blocks():
    tel = _tele(
        ("D", "t=10s hp=80% gold=1 loc=0,0 bottle=0"),
        ("D", "t=15s hp=70% gold=1 loc=0,0 bottle=0"),
        ("D", "t=20s hp=65% gold=1 loc=0,0 bottle=1"),
        ("D", "t=25s hp=60% gold=1 loc=0,0 bottle=0"),
    )
    blocked = {
        "recovery-rune-bottle": {
            "D": {
                "stage_cooldown": {"count": 4, "last": ""},
                "no_close_rune": {"count": 2, "last": ""},
            }
        }
    }
    candidates = m.fix_candidates({}, tel, {}, blocked, [], {"R": [], "D": []}, [])
    assert any(c["side"] == "D" and c["area"] == "rune" and c["priority"] == 2 for c in candidates)


def test_fix_candidates_does_not_flag_empty_bottle_when_filled():
    tel = _tele(
        ("D", "t=10s hp=80% gold=1 loc=0,0 bottle=0"),
        ("D", "t=15s hp=70% gold=1 loc=0,0 bottle=0"),
        ("D", "t=20s hp=65% gold=1 loc=0,0 bottle=0"),
    )
    blocked = {"recovery-rune-bottle": {"D": {"stage_cooldown": {"count": 8, "last": ""}}}}
    intents = {"rune-result": {"D": {"count": 1, "last": "", "fields": {"result": {"filled": 1}}}}}
    candidates = m.fix_candidates({}, tel, intents, blocked, [], {"R": [], "D": []}, [])
    assert not any(c["area"] == "rune" for c in candidates)


def test_fix_candidates_flags_siege_without_hits():
    intents = {
        "tower-opportunity": {
            "R": {"count": 10, "last": "", "fields": {"result": {"step": 7, "blocked_tower": 3}}}
        }
    }
    candidates = m.fix_candidates({}, {"R": [], "D": []}, intents, {}, [], {"R": [], "D": []}, [])
    assert any(c["side"] == "R" and c["area"] == "siege" for c in candidates)


# --- check_all.lua_structure_problems ---

def test_lua_valid_code_has_no_problems():
    assert c.lua_structure_problems("local function f() if x then return 1 end end") == []


def test_lua_for_loop_balances():
    assert c.lua_structure_problems("for i=1,3 do print(i) end") == []


def test_lua_catches_missing_end():
    assert c.lua_structure_problems("local function f() if x then return 1 end") != []


def test_lua_catches_unbalanced_brace():
    assert any("{}" in p for p in c.lua_structure_problems("local t = { a=1, b=2 "))


def test_lua_keywords_in_strings_and_comments_ignored():
    src = 'local s = "end end function" -- if do end\nreturn s'
    assert c.lua_structure_problems(src) == []


def test_lua_long_string_brackets_ignored():
    src = "local s = [[ end function if ]] return s"
    assert c.lua_structure_problems(src) == []


def test_repo_bot_files_pass_structure_check():
    # The whole maintained set must stay structurally clean (zero false positives is the design).
    assert c.check_lua_syntax() is True
