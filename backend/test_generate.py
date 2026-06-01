import pytest
from generate_playstyle import (
    _sanitize_style, _parse_llm_json, write_playstyle_lua, DIAL_KEYS,
)

def test_sanitize_clamps_dials_into_range():
    s = _sanitize_style({"dials": {"harass_desire": 1.7, "farm_focus": -0.4}, "rules": {}})
    assert s["dials"]["harass_desire"] == 1.0
    assert s["dials"]["farm_focus"] == 0.0

def test_sanitize_fills_missing_dials_with_baseline():
    s = _sanitize_style({"dials": {"harass_desire": 0.9}, "rules": {}})
    assert set(s["dials"].keys()) == set(DIAL_KEYS)
    assert s["dials"]["forwardness"] == 0.5

def test_sanitize_rejects_unknown_respawn_value():
    s = _sanitize_style({"dials": {}, "rules": {"respawn_behavior": "blink_dagger"}})
    assert s["rules"]["respawn_behavior"] == "walk_back"

def test_sanitize_accepts_valid_respawn_value():
    s = _sanitize_style({"dials": {}, "rules": {"respawn_behavior": "tp_to_tower"}})
    assert s["rules"]["respawn_behavior"] == "tp_to_tower"

def test_sanitize_handles_garbage_input():
    s = _sanitize_style("not a dict")
    assert set(s["dials"].keys()) == set(DIAL_KEYS)
    assert s["rules"]["respawn_behavior"] == "walk_back"

def test_parse_llm_json_strips_markdown_fences():
    raw = '```json\n{"dials": {"harass_desire": 0.8}, "rules": {}}\n```'
    parsed = _parse_llm_json(raw)
    assert parsed["dials"]["harass_desire"] == 0.8

def test_write_playstyle_lua_creates_nested_file(tmp_path):
    style = {"dials": {"harass_desire": 0.8}, "rules": {"respawn_behavior": "tp_to_tower"}}
    out = tmp_path / "playstyle_radiant.lua"
    write_playstyle_lua(style, str(out))
    content = out.read_text()
    assert "dials = {" in content
    assert "rules = {" in content
    assert "harass_desire" in content
    assert "0.80" in content
    assert '"tp_to_tower"' in content
    assert content.strip().startswith("return {")
    assert content.strip().endswith("}")
