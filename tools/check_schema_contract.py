#!/usr/bin/env python3
"""Fail when the model-facing schema drifts across Python, Lua, prompt, or presets."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from style_schema import DIAL_KEYS, RULE_VALUES  # noqa: E402


LUA_RULE_TABLES = {
    "respawn_behavior": "RESPAWN_VALUES",
    "pregame_behavior": "PREGAME_VALUES",
    "dive_policy": "DIVE_VALUES",
    "low_hp_behavior": "LOW_HP_VALUES",
    "healing_style": "HEALING_STYLE_VALUES",
    "ability_usage": "ABILITY_USAGE_VALUES",
    "ability_timing": "ABILITY_TIMING_VALUES",
    "creep_wave_priority": "CREEP_WAVE_PRIORITY_VALUES",
    "hero_priority": "HERO_PRIORITY_VALUES",
    "deny_policy": "DENY_POLICY_VALUES",
    "tower_aggression": "TOWER_AGGRESSION_VALUES",
}


def table_body(text, name):
    code = re.sub(r"--[^\n]*", "", text)
    match = re.search(rf"local\s+{re.escape(name)}\s*=\s*\{{(.*?)\}}", code, re.S)
    return match.group(1) if match else None


def lua_keys(body):
    return set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=", body or ""))


def config_keys(text, section):
    code = re.sub(r"--[^\n]*", "", text)
    match = re.search(rf"\b{section}\s*=\s*\{{(.*?)\}}", code, re.S)
    return lua_keys(match.group(1) if match else "")


def main():
    problems = []
    style = (ROOT / "bots/FunLib/aibattle_style.lua").read_text(encoding="utf-8")
    prompt = (ROOT / "backend/system_prompt.txt").read_text(encoding="utf-8")

    runtime_dials = lua_keys(table_body(style, "DEFAULT_DIALS"))
    if runtime_dials != set(DIAL_KEYS):
        problems.append(
            "dial mismatch python-vs-lua: missing=%s extra=%s"
            % (sorted(set(DIAL_KEYS) - runtime_dials), sorted(runtime_dials - set(DIAL_KEYS)))
        )

    for rule, expected in RULE_VALUES.items():
        runtime = lua_keys(table_body(style, LUA_RULE_TABLES[rule]))
        missing = set(expected) - runtime
        if missing:
            problems.append(f"rule {rule}: generator values absent from Lua: {sorted(missing)}")

    for key in (*DIAL_KEYS, *RULE_VALUES):
        if key not in prompt:
            problems.append(f"system prompt does not describe {key}")
    for rule, values in RULE_VALUES.items():
        for value in values:
            if value not in prompt:
                problems.append(f"system prompt omits {rule} value {value}")

    allowed_dials = set(DIAL_KEYS)
    allowed_rules = set(RULE_VALUES)
    for path in sorted((ROOT / "bots/Customize").glob("canonical_*.lua")):
        unknown_dials = config_keys(path.read_text(encoding="utf-8"), "dials") - allowed_dials
        unknown_rules = config_keys(path.read_text(encoding="utf-8"), "rules") - allowed_rules
        if unknown_dials:
            problems.append(f"{path.name}: unknown dials {sorted(unknown_dials)}")
        if unknown_rules:
            problems.append(f"{path.name}: rules outside model schema {sorted(unknown_rules)}")

    if problems:
        for problem in problems:
            print(f"[fail] {problem}")
        return 1
    print(f"[ok] schema contract: {len(DIAL_KEYS)} dials, {len(RULE_VALUES)} rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
