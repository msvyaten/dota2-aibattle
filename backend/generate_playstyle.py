import os
import re
import json
import argparse

try:
    from .style_schema import DIAL_KEYS, RULE_VALUES
except ImportError:
    from style_schema import DIAL_KEYS, RULE_VALUES

MODEL = os.environ.get("AIBATTLE_OPENAI_MODEL", "gpt-5.5")

# Full engine schema. Contract-checked against bots/FunLib/aibattle_style.lua.
# ward_desire / roshan_desire: KEPT. They are inert in 1v1 mid -- verified, not assumed:
# ward-place is 0 across the last five matches, neither canonical item_build has a ward,
# and 1v1 mid has no Roshan. They were briefly removed on 21.07 and that was WRONG: the
# schema describes the engine, which also runs 5v5, where both are real forks. The right
# handling is to keep them expressible and tell the LLM they do nothing in 1v1 -- see the
# system prompt. Do not delete them again on 1v1 evidence alone.
# A rule absent from the LLM answer is omitted so the engine applies its own default.
DEFAULT_DIAL = 0.5

_client = None

def _get_client():
    global _client
    if _client is None:
        # Imported here, not at module scope: the --*-json path is the one we actually use
        # (the user runs the system prompt in an LLM UI and hands the JSON back), and it must
        # work with no API key and no openai package installed.
        from openai import OpenAI
        _client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    return _client

def _load_system_prompt():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "system_prompt.txt"), "r", encoding="utf-8") as f:
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
    text = (raw_text or "").lstrip("\ufeff").strip()
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

def _load_style_arg(value: str) -> dict:
    """A style given as JSON: a path to a .json file, or the JSON text itself.

    This is the primary path. The system prompt is run by hand in an LLM UI and the answer
    is pasted back here, so no API key is involved. It deliberately goes through the SAME
    _parse_llm_json + _sanitize_style as the API path, so a hand-carried answer is clamped,
    filtered and defaulted identically -- an invalid rule value is dropped here exactly as it
    would be there, rather than reaching the engine and silently falling back.
    """
    if os.path.isfile(value):
        with open(value, "r", encoding="utf-8") as f:
            value = f.read()
    return _sanitize_style(_parse_llm_json(value))


def main():
    parser = argparse.ArgumentParser(description="Generate playstyle configs for Dota 2 AIBattle")
    parser.add_argument("--radiant", help="Natural language prompt for Radiant bot (calls the API)")
    parser.add_argument("--dire", help="Natural language prompt for Dire bot (calls the API)")
    parser.add_argument("--radiant-json", help="LLM answer for Radiant: .json path or JSON text (no API key needed)")
    parser.add_argument("--dire-json", help="LLM answer for Dire: .json path or JSON text (no API key needed)")
    parser.add_argument("--output-dir", default=".", help="Directory to write playstyle_radiant.lua and playstyle_dire.lua")
    args = parser.parse_args()

    if bool(args.radiant_json) != bool(args.dire_json):
        parser.error("--radiant-json and --dire-json must be given together")
    if not args.radiant_json and not (args.radiant and args.dire):
        parser.error("give either --radiant-json/--dire-json (offline) or --radiant/--dire (API)")

    if args.radiant_json:
        radiant_style = _load_style_arg(args.radiant_json)
        dire_style    = _load_style_arg(args.dire_json)
    else:
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
