import os
import re
import json
import argparse
from openai import OpenAI

MODEL = "gpt-5.5"  # current flagship (June 2026). Switch to "gpt-5.4-mini" for cheaper runs.

DIAL_KEYS = (
    "harass_desire", "farm_focus", "forwardness",
    "ability_aggro", "rune_control", "retreat_caution",
)
RESPAWN_VALUES = ("tp_to_tower", "tp_to_lane", "walk_back")
DEFAULT_DIAL = 0.5
DEFAULT_RESPAWN = "walk_back"

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
    rb = raw_rules.get("respawn_behavior")
    respawn = rb if rb in RESPAWN_VALUES else DEFAULT_RESPAWN

    return {"dials": dials, "rules": {"respawn_behavior": respawn}}

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
        lines.append(f"        {k:<15} = {_lua_value(style['dials'][k])},")
    lines.append("    },")
    lines.append("    rules = {")
    lines.append(f'        respawn_behavior = {_lua_value(style["rules"]["respawn_behavior"])},')
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
