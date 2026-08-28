from generate_playstyle import (
    _sanitize_style, _parse_llm_json, _load_system_prompt,
    write_playstyle_lua, DIAL_KEYS, RULE_VALUES,
)
from style_schema import ITEM_BUILD_HEROES

def test_schema_is_full_engine_surface():
    # 11 since 28.08: ability_aggro was retired. It gated only Style.AbilityHarass, whose
    # Shadow Fiend entries cast a no-target ability at a position and were rejected by the
    # server 293 times in a single match. The hero razes through the vendor hero file either
    # way, so the dial throttled nothing a player could see. A dial that reaches no behaviour
    # must not be model-facing -- that is this project's own invariant, applied to itself.
    assert len(DIAL_KEYS) == 11
    assert "ability_aggro" not in DIAL_KEYS
    assert len(RULE_VALUES) == 11

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
        "creep_wave_priority": "last_hit_only",
        "hero_priority": "always",
        "deny_policy": "never",
    }})
    assert s["rules"]["respawn_behavior"] == "tp_to_tower"
    assert s["rules"]["pregame_behavior"] == "aggressive_mid"
    assert s["rules"]["ability_timing"] == "save_for_execute"
    assert s["rules"]["creep_wave_priority"] == "last_hit_only"
    assert len(s["rules"]) == 10

def test_sanitize_drops_freeze_creep_wave_priority():
    # 28c3019 dropped "freeze" from RULE_VALUES because nothing implements it, but left this
    # test asserting the old behaviour -- it has been red ever since. Keep the case, invert
    # the expectation: a config carrying "freeze" does not freeze anything, it falls past the
    # last_hit_only guard in the anti-idle watchdog and attacks enemy creeps instead.
    s = _sanitize_style({"dials": {}, "rules": {"creep_wave_priority": "freeze"}})
    assert "creep_wave_priority" not in s["rules"]

def test_sanitize_handles_garbage_input():
    s = _sanitize_style("not a dict")
    assert set(s["dials"].keys()) == set(DIAL_KEYS)
    assert s["rules"] == {}

def test_parse_llm_json_strips_markdown_fences():
    raw = '```json\n{"dials": {"harass_desire": 0.8}, "rules": {}}\n```'
    parsed = _parse_llm_json(raw)
    assert parsed["dials"]["harass_desire"] == 0.8

def test_parse_llm_json_accepts_utf8_bom():
    parsed = _parse_llm_json('\ufeff{"dials": {}, "rules": {}}')
    assert parsed == {"dials": {}, "rules": {}}

def test_system_prompt_loads_as_utf8():
    prompt = _load_system_prompt()
    assert "AIBattle" in prompt
    assert "rune_control" in prompt

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


def test_item_build_keeps_known_heroes_and_drops_bad_names():
    # The runtime drops unknown item ids silently, so a typo that reaches the engine costs the
    # whole build and reports nothing. Filtering has to happen here, where it is visible.
    s = _sanitize_style({"dials": {}, "rules": {}, "item_build": {
        "npc_dota_hero_juggernaut": ["item_tango", "BAD", 7, "item_power_treads"],
        "npc_dota_hero_axe": ["item_blink"],
        "npc_dota_hero_nevermore": "not a list",
    }})
    assert s["item_build"] == {"npc_dota_hero_juggernaut": ["item_tango", "item_power_treads"]}


def test_item_build_absent_is_empty_not_missing():
    s = _sanitize_style({"dials": {}, "rules": {}})
    assert s["item_build"] == {}


def test_write_playstyle_lua_emits_item_build(tmp_path):
    out = tmp_path / "p.lua"
    write_playstyle_lua({"dials": {}, "rules": {}, "item_build": {
        "npc_dota_hero_juggernaut": ["item_tango", "item_power_treads"]}}, str(out))
    text = out.read_text()
    assert 'item_build = {' in text
    assert '["npc_dota_hero_juggernaut"] = { "item_tango", "item_power_treads" },' in text


def test_prompt_asks_for_a_build_for_every_rotation_hero():
    # A hero in the rotation with no entry in the prompt gets the vendor long-game build,
    # which is wrong for a match that ends around fifteen minutes.
    prompt = _load_system_prompt()
    for hero in ITEM_BUILD_HEROES:
        assert hero in prompt
