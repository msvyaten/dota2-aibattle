import os
import re
import json
import argparse
from openai import OpenAI

MODEL = "gpt-5.5"  # current flagship (June 2026). Switch to "gpt-5.4-mini" for cheaper runs.

# Full engine schema. Must stay in sync with bots/FunLib/aibattle_style.lua whitelists.
DIAL_KEYS = (
    "harass_desire", "farm_focus", "forwardness", "retreat_caution",
    "rune_control", "execute_threshold", "ability_aggro", "gank_desire",
    "push_desire", "defend_desire", "ward_desire", "roshan_desire",
)
# rule -> allowed values. A rule absent from the LLM answer is OMITTED from the
# output config so the engine falls back to its own default for that rule.
# Audited against the engine 21.07 (docs/PROMPT_DRIFT.md section E): every value listed
# here must be branched on somewhere in bots/ AND behave the way the prompt describes it.
RULE_VALUES = {
    "respawn_behavior":    ("tp_to_tower", "tp_to_lane", "walk_back"),
    # "default" = passive prewave (hold own highground, never advance to trade). It was
    # missing here AND from the engine's PREGAME_VALUES, so the generator could not express
    # a passive prewave at all -- every non-cowardly prompt landed on aggressive_mid, which
    # is exactly the "stands in the river taking poke before creeps" symptom.
    "pregame_behavior":    ("safe_tower", "aggressive_mid", "jungle_pressure", "default"),
    "dive_policy":         ("never", "finish_only", "when_grouped", "when_ahead", "always"),
    "low_hp_behavior":     ("tp_fountain", "run_to_tower", "fight_back", "regen_lane", "walk_fountain"),
    "healing_style":       ("active", "default", "never"),
    # "basic" removed: style.lua:343 silently rewrites it to "default" (backward compat), so
    # offering it as a distinct choice just means the LLM picks a value that does nothing.
    "ability_usage":       ("aggressive", "default"),
    "ability_timing":      ("on_cooldown", "save_for_execute", "harass_only"),
    # "freeze" removed: NOT implemented. The engine branches on cwp only for "push" and
    # "last_hit_only"; freeze falls past the last_hit_only guard in the anti-idle watchdog
    # (style.lua:705) and ATTACKS enemy creeps -- the opposite of "never touch enemy creeps".
    # Re-add only once freeze is actually gated at those sites.
    "creep_wave_priority": ("push", "last_hit_only"),
    "hero_priority":       ("always", "default", "never"),
    "deny_policy":         ("always", "default", "never"),
    "tower_aggression":    ("always", "default", "never"),
}
DEFAULT_DIAL = 0.5

_client = None

def _get_client():
    global _client
    if _client is None:
        _client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    return _client

def _load_system_prompt():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "system_prompt.txt"), "r") as f:
        return f.read()

def _clamp01(x):
    """Coerce to float in [0,1]; return None if not a number."""
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v

def _sanitize_style(raw: dict) -> dict:
    """Guardrails: clamp dials into 0-1 (missing -> 0.5), whitelist rules (unknown -> default)."""
    raw = raw if isinstance(raw, dict) else {}
    raw_dials = raw.get("dials") if isinstance(raw.get("dials"), dict) else {}
    dials = {}
    for k in DIAL_KEYS:
        v = _clamp01(raw_dials.get(k))
        dials[k] = v if v is not None else DEFAULT_DIAL

    raw_rules = raw.get("rules") if isinstance(raw.get("rules"), dict) else {}
    rules = {}
    for k, allowed in RULE_VALUES.items():
        v = raw_rules.get(k)
        if v in allowed:
            rules[k] = v
        # invalid or missing -> omit; the engine applies its own default

    return {"dials": dials, "rules": rules}

def _parse_llm_json(raw_text: str) -> dict:
    """Extract a JSON object from the LLM response (tolerates ```json fences)."""
    text = (raw_text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    return json.loads(text)

def prompt_to_style(prompt: str) -> dict:
    """Call the LLM with a natural language prompt, return a sanitized nested style dict."""
    messages = [
        {"role": "system", "content": _load_system_prompt()},
        {"role": "user", "content": prompt},
    ]
    try:
        response = _get_client().chat.completions.create(
            model=MODEL, messages=messages, temperature=0,
        )
    except Exception:
        # some newer models only accept the default temperature
        response = _get_client().chat.completions.create(model=MODEL, messages=messages)
    raw = _parse_llm_json(response.choices[0].message.content)
    return _sanitize_style(raw)

def _lua_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return f"{v:.2f}"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return f'"{v}"'
    raise TypeError(f"Unsupported type: {type(v)}")

def write_playstyle_lua(style: dict, output_path: str) -> None:
    """Write a sanitized nested style dict to a Lua return table file (dials + rules)."""
    style = _sanitize_style(style)
    lines = ["return {", "    dials = {"]
    for k in DIAL_KEYS:
        lines.append(f"        {k:<17} = {_lua_value(style['dials'][k])},")
    lines.append("    },")
    lines.append("    rules = {")
    for k in RULE_VALUES:
        if k in style["rules"]:
            lines.append(f"        {k:<19} = {_lua_value(style['rules'][k])},")
    lines.append("    },")
    lines.append("}")
    with open(output_path, "w") as f:
        f.write("\n".join(lines) + "\n")

def main():
    parser = argparse.ArgumentParser(description="Generate playstyle configs for Dota 2 AIBattle")
    parser.add_argument("--radiant", required=True, help="Natural language prompt for Radiant bot")
    parser.add_argument("--dire", required=True, help="Natural language prompt for Dire bot")
    parser.add_argument("--output-dir", default=".", help="Directory to write playstyle_radiant.lua and playstyle_dire.lua")
    args = parser.parse_args()

    radiant_style = prompt_to_style(args.radiant)
    dire_style    = prompt_to_style(args.dire)

    radiant_path = os.path.join(args.output_dir, "playstyle_radiant.lua")
    dire_path    = os.path.join(args.output_dir, "playstyle_dire.lua")

    write_playstyle_lua(radiant_style, radiant_path)
    write_playstyle_lua(dire_style, dire_path)

    print(f"Radiant: {radiant_style}")
    print(f"  -> {radiant_path}")
    print(f"Dire: {dire_style}")
    print(f"  -> {dire_path}")

if __name__ == "__main__":
    main()
