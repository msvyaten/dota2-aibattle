#!/usr/bin/env python3
"""Fail when the model-facing schema drifts across Python, Lua, prompt, or presets."""

from __future__ import annotations

import json
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


def prompt_examples(text):
    """Every worked example in the prompt, however it is wrapped.

    This used to be a single-line regex, so the moment the example was formatted one field
    group per line -- which is what makes it readable -- the check would have found nothing
    and reported green over an example it never opened. Brace matching does not care.
    """
    blocks = []
    for match in re.finditer(r'^\{"dials"', text, re.M):
        start, depth = match.start(), 0
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    block = text[start:i + 1]
                    # The shape skeleton at the top of the prompt starts the same way and is
                    # deliberately not JSON: it carries <0.0-1.0> and <word> placeholders so a
                    # model cannot copy values out of it. A real example never contains '<'.
                    if "<" not in block:
                        blocks.append(block)
                    break
    return blocks


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

    # The worked example is what the model actually imitates, so a stale one is worse than a
    # stale sentence. 28.08: ability_aggro was retired and the example still handed the model
    # twelve dials; nothing here noticed.
    for block in prompt_examples(prompt):
        try:
            example = json.loads(block)
        except ValueError as exc:
            problems.append(f"system prompt example is not valid JSON: {exc}")
            continue
        shown = set(example.get("dials", {}))
        if shown != set(DIAL_KEYS):
            problems.append(
                "system prompt example dials drifted: extra=%s missing=%s"
                % (sorted(shown - set(DIAL_KEYS)), sorted(set(DIAL_KEYS) - shown))
            )
        # The dial half of this test was written 28.08 and the rule half was not, so the
        # example went on showing ten rules of eleven -- tower_aggression missing -- while the
        # text beside it demanded the full set and this check reported green. Half a check on
        # the thing the model imitates is the same failure as half a counter on a fix.
        shown_rules = set(example.get("rules", {}))
        if shown_rules != set(RULE_VALUES):
            problems.append(
                "system prompt example rules drifted: extra=%s missing=%s"
                % (sorted(shown_rules - set(RULE_VALUES)), sorted(set(RULE_VALUES) - shown_rules))
            )

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
