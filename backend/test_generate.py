import pytest
from generate_playstyle import (
    _sanitize_style, _parse_llm_json, write_playstyle_lua, DIAL_KEYS, RULE_VALUES,
)

def test_schema_is_full_engine_surface():
    assert len(DIAL_KEYS) == 12
    assert len(RULE_VALUES) == 10

def test_sanitize_clamps_dials_into_range():
    s = _sanitize_style({"dials": {"harass_desire": 1.7, "farm_focus": -0.4}, "rules": {}})
    assert s["dials"]["harass_desire"] == 1.0
    assert s["dials"]["farm_focus"] == 0.0

def test_sanitize_fills_missing_dials_with_baseline():
    s = _sanitize_style({"dials": {"harass_desire": 0.9}, "rules": {}})
    assert set(s["dials"].keys()) == set(DIAL_KEYS)
    assert s["dials"]["forwardness"] == 0.5
    assert s["dials"]["execute_threshold"] == 0.5
    assert s["dials"]["roshan_desire"] == 0.5

def test_sanitize_omits_unknown_rule_value():
    s = _sanitize_style({"dials": {}, "rules": {"respawn_behavior": "blink_dagger"}})
    assert "respawn_behavior" not in s["rules"]

def test_sanitize_omits_unknown_rule_key():
    s = _sanitize_style({"dials": {}, "rules": {"made_up_rule": "always"}})
    assert "made_up_rule" not in s["rules"]

def test_sanitize_accepts_valid_rules():
    s = _sanitize_style({"dials": {}, "rules": {
        "respawn_behavior": "tp_to_tower",
        "pregame_behavior": "aggressive_mid",
        "dive_policy": "finish_only",
        "low_hp_behavior": "regen_lane",
        "healing_style": "active",
        "ability_usage": "aggressive",
        "ability_timing": "save_for_execute",
        "creep_wave_priority": "freeze",
        "hero_priority": "always",
        "deny_policy": "never",
    }})
    assert s["rules"]["respawn_behavior"] == "tp_to_tower"
    assert s["rules"]["pregame_behavior"] == "aggressive_mid"
    assert s["rules"]["ability_timing"] == "save_for_execute"
    assert s["rules"]["creep_wave_priority"] == "freeze"
    assert len(s["rules"]) == 10

def test_sanitize_handles_garbage_input():
    s = _sanitize_style("not a dict")
    assert set(s["dials"].keys()) == set(DIAL_KEYS)
    assert s["rules"] == {}

def test_parse_llm_json_strips_markdown_fences():
    raw = '```json\n{"dials": {"harass_desire": 0.8}, "rules": {}}\n```'
    parsed = _parse_llm_json(raw)
    assert parsed["dials"]["harass_desire"] == 0.8

def test_write_playstyle_lua_creates_nested_file(tmp_path):
    style = {"dials": {"harass_desire": 0.8, "execute_threshold": 0.42},
             "rules": {"respawn_behavior": "tp_to_tower", "hero_priority": "always"}}
    out = tmp_path / "playstyle_radiant.lua"
    write_playstyle_lua(style, str(out))
    content = out.read_text()
    assert "dials = {" in content
    assert "rules = {" in content
    assert "harass_desire" in content
    assert "0.80" in content
    assert "execute_threshold" in content
    assert "0.42" in content
    assert '"tp_to_tower"' in content
    assert '"always"' in content
    assert content.strip().startswith("return {")
    assert content.strip().endswith("}")

def test_write_playstyle_lua_omits_unspecified_rules(tmp_path):
    style = {"dials": {}, "rules": {"hero_priority": "never"}}
    out = tmp_path / "playstyle_dire.lua"
    write_playstyle_lua(style, str(out))
    content = out.read_text()
    assert "hero_priority" in content
    assert "respawn_behavior" not in content
    assert "dive_policy" not in content
