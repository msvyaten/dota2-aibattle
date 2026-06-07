#!/usr/bin/env python3
"""
parse_itembuilds.py — read Valve's default_*.txt item build files for a list of heroes
and output a Lua `item_build` block ready to paste into playstyle_*.lua.

Usage:
    python tools/parse_itembuilds.py axe crystal_maiden dark_seer lion
    python tools/parse_itembuilds.py --all          # print all 129 heroes
    python tools/parse_itembuilds.py --list         # list available hero names

The output is a Lua snippet, e.g.:
    item_build = {
        npc_dota_hero_axe = {
            "item_tango", "item_tango", "item_branches", "item_quelling_blade", "item_flask",
            "item_phase_boots", "item_magic_stick", "item_ring_of_health",
            "item_blink", "item_vanguard",
            "item_blade_mail", "item_crimson_guard", "item_heart", "item_black_king_bar",
            -- situational: item_force_staff, item_pipe, item_shivas_guard
        },
    }
"""

import sys
import os
import re
from pathlib import Path

ITEMBUILDS_DIR = Path(
    r"C:/Program Files (x86)/Steam/steamapps/common/dota 2 beta/game/dota/itembuilds"
)

SECTION_ORDER = [
    "#DOTA_Item_Build_Starting_Items",
    "#DOTA_Item_Build_Early_Game",
    "#DOTA_Item_Build_Mid_Items",
    "#DOTA_Item_Build_Late_Items",
]
SITUATIONAL_SECTION = "#DOTA_Item_Build_Other_Items"


def parse_kv_items(text: str) -> dict[str, list[str]]:
    """Parse Valve KeyValues item build file, return dict section→[items]."""
    sections: dict[str, list[str]] = {}
    current_section = None
    depth = 0

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Section header (quoted key)
        if stripped.startswith('"') and stripped.endswith('"') and stripped.count('"') == 2:
            key = stripped.strip('"')
            if key in (SECTION_ORDER + [SITUATIONAL_SECTION]):
                current_section = key
                sections[current_section] = []
        elif stripped == '{':
            depth += 1
        elif stripped == '}':
            depth -= 1
            if depth <= 1:
                current_section = None
        else:
            # item line: "item"  "item_xxx"
            m = re.match(r'"item"\s+"(item_\w+)"', stripped)
            if m and current_section is not None:
                sections[current_section].append(m.group(1))

    return sections


def load_hero(hero_name: str) -> tuple[str, dict] | None:
    """Load and parse build for a hero. hero_name = 'axe' or 'npc_dota_hero_axe'."""
    short = hero_name.replace("npc_dota_hero_", "")
    full = f"npc_dota_hero_{short}"
    path = ITEMBUILDS_DIR / f"default_{short}.txt"
    if not path.exists():
        print(f"[WARN] Not found: {path}", file=sys.stderr)
        return None
    text = path.read_text(encoding="utf-8")
    sections = parse_kv_items(text)
    return full, sections


def format_lua_block(builds: list[tuple[str, dict]]) -> str:
    """Format builds as a Lua item_build table."""
    lines = ["item_build = {"]
    for full_name, sections in builds:
        lines.append(f"    {full_name} = {{")
        # Core items (starting → early → mid → late) in order
        core_items: list[str] = []
        for sec in SECTION_ORDER:
            core_items.extend(sections.get(sec, []))
        # Situational (comment only)
        situ = sections.get(SITUATIONAL_SECTION, [])

        if core_items:
            # Format in groups matching sections, with inline comments
            group_sizes = [
                len(sections.get(SECTION_ORDER[0], [])),
                len(sections.get(SECTION_ORDER[1], [])),
                len(sections.get(SECTION_ORDER[2], [])),
                len(sections.get(SECTION_ORDER[3], [])),
            ]
            labels = ["-- starting", "-- early", "-- core", "-- late"]
            idx = 0
            for size, label in zip(group_sizes, labels):
                if size == 0:
                    continue
                group = core_items[idx:idx + size]
                quoted = ", ".join(f'"{it}"' for it in group)
                lines.append(f"        {quoted},  {label}")
                idx += size

        if situ:
            quoted_situ = ", ".join(situ)
            lines.append(f"        -- situational: {quoted_situ}")

        lines.append("    },")
    lines.append("}")
    return "\n".join(lines)


def list_heroes() -> list[str]:
    names = []
    for f in sorted(ITEMBUILDS_DIR.glob("default_*.txt")):
        names.append(f.stem.replace("default_", ""))
    return names


def main():
    args = sys.argv[1:]
    if not args or "--help" in args or "-h" in args:
        print(__doc__)
        sys.exit(0)

    if "--list" in args:
        for h in list_heroes():
            print(h)
        sys.exit(0)

    if "--all" in args:
        heroes = list_heroes()
    else:
        heroes = args

    builds = []
    for h in heroes:
        result = load_hero(h)
        if result:
            builds.append(result)

    if not builds:
        print("No valid heroes found.", file=sys.stderr)
        sys.exit(1)

    print(format_lua_block(builds))


if __name__ == "__main__":
    main()
