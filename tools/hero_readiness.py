#!/usr/bin/env python3
"""Print the current hero expansion readiness matrix, and audit the code behind it.

The matrix used to be prose only, so "do not hardcode one hero into generic lane logic" was a
promise nobody could check. `--audit` checks it: it finds combat spacing written as a bare
distance instead of one derived from `bot:GetAttackRange()`, and says which heroes that breaks.

A constant is not automatically wrong. Rune pickup radius, creep-pack geometry and ability
ranges are the same for every hero, and a site that says so in a `-- hero-agnostic: <why>`
comment on the line above is accepted. Everything else is counted against a budget that may
fall and must never rise, the same contract the silent-refusal ratchet uses.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


HEROES = {
    "nevermore": {
        "unit": "npc_dota_hero_nevermore",
        "attack": "ranged",
        "attack_range": 500,
        "status": "primary 1v1 target",
        "covered": [
            "ranged spacing",
            "vendor Shadowraze ownership",
            "Requiem execute path",
            "bottle/rune mid economy",
        ],
        "risks": [
            "ability pressure can still win with nothing castable",
            "bottle empty windows still damage recovery quality",
            "ranged lane-line positioning still needs product validation",
            "four awareness floors (820-1100) sit above range+offset even at 500,"
            " so this hero is already being read at a fixed radius -- see --audit",
        ],
    },
    "juggernaut": {
        "unit": "npc_dota_hero_juggernaut",
        "attack": "melee",
        "attack_range": 150,
        "status": "exploratory melee target",
        "covered": [
            "Blade Fury harass entry",
            "Omnislash execute entry",
            "enemy healing ward retargeting",
        ],
        "risks": [
            "melee approach to healing ward is not owned yet",
            "melee last-hit positioning can walk into creep packs",
            "sustain/ward/fountain decisions need hero-specific review",
            "aggroStep is computed from a 420 floor a melee hero cannot reach"
            " (aibattle_laning_safety.lua): the step it derives neither drops creep"
            " aggro nor keeps the last hit -- see --audit",
            "fightReach is a flat 1200, eight times melee attack range, so the fight"
            " candidate registers from where it cannot act (mode_laning_generic.lua)",
        ],
    },
}


ROOT = Path(__file__).resolve().parent.parent
SCAN = sorted((ROOT / "bots" / "FunLib").glob("aibattle_*.lua")) + [ROOT / "bots" / "mode_laning_generic.lua"]

COMBAT = re.compile(r"enemy|hero|creep|target|melee|pack|spacing|harass|chase|trade|duel", re.I)
SPACING = re.compile(r"[Dd]ist|Distance|radius|range", re.I)
MAPPY = re.compile(r"fountain|rune|lane_?front|LaneFront|tower|tp_|shop|courier|Roshan|ward", re.I)
# `botAttackRange`, `GetAttackRange()` and a local `range` being added to all count as
# derived. `max_range = 700` does not: an ability reach is a property of the ability.
RANGED = re.compile(r"attackrange|attackdamage|(?<![\w_])range\s*[+-]", re.I)
# Ability definitions carry their own reach and are not spacing decisions.
ABILITY_DEF = re.compile(r"name\s*=\s*\"")
FLOOR = re.compile(r"math\.max\(\s*(\d{3,4})\s*,")
NUMBER = re.compile(r"(?<![\w.])(\d{3,4})(?![\w.])")
EXEMPT = "hero-agnostic:"

# Sites carrying no attack-range term at all, or a floor that hides it. Falls, never rises.
SPACING_DEBT_BUDGET = 16


def audit_sites():
    """Return (absolute, floored) spacing sites, each (file, line, numbers, text)."""
    absolute, floored = [], []
    for path in SCAN:
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, raw in enumerate(lines):
            text = raw.strip()
            if text.startswith("--") or not COMBAT.search(text) or MAPPY.search(text):
                continue
            if ABILITY_DEF.search(text):
                continue
            if not SPACING.search(text):
                continue
            if any(EXEMPT in lines[j] for j in range(max(0, i - 2), i)):
                continue
            nums = [int(n) for n in NUMBER.findall(text) if 150 <= int(n) <= 1500]
            if not nums:
                continue
            entry = (path.name, i + 1, nums, text[:96])
            if not RANGED.search(text):
                absolute.append(entry)
            else:
                floor = FLOOR.search(text)
                if floor:
                    floored.append((path.name, i + 1, [int(floor.group(1))], text[:96]))
    return absolute, floored


def print_audit():
    absolute, floored = audit_sites()
    print("=== combat spacing not derived from attack range ===")
    print("no attack-range term at all: %d" % len(absolute))
    for name, line, nums, text in absolute:
        print("  %s:%d  %s" % (name, line, text))
    print()
    print("attack-range term present but a floor can hide it: %d" % len(floored))
    for name, line, nums, text in floored:
        binding = [h for h, d in sorted(HEROES.items())
                   if d.get("attack_range") is not None and d["attack_range"] < nums[0]]
        who = ", ".join(binding) if binding else "nobody at present"
        print("  %s:%d  floor %d binds for: %s" % (name, line, nums[0], who))
        print("      %s" % text)
    print()
    total = len(absolute) + len(floored)
    print("total %d, budget %d" % (total, SPACING_DEBT_BUDGET))
    print("Annotate a site that is genuinely the same for every hero with a"
          " `-- hero-agnostic: <why>` comment above it and it leaves this list.")
    return total


def print_hero(name, data):
    print("%s (%s)" % (name, data["unit"]))
    print("  attack: %s (range %s)" % (data["attack"], data.get("attack_range", "?")))
    print("  status: %s" % data["status"])
    print("  covered:")
    for item in data["covered"]:
        print("    - %s" % item)
    print("  risks:")
    for item in data["risks"]:
        print("    - %s" % item)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hero", nargs="?", choices=sorted(HEROES), help="show one hero only")
    parser.add_argument("--audit", action="store_true", help="list spacing not derived from attack range")
    parser.add_argument("--check", action="store_true", help="fail if the spacing debt has risen")
    args = parser.parse_args()

    if args.check:
        absolute, floored = audit_sites()
        total = len(absolute) + len(floored)
        if total > SPACING_DEBT_BUDGET:
            print("[fail] hero spacing debt rose: %d > %d" % (total, SPACING_DEBT_BUDGET))
            print("       run: python tools/hero_readiness.py --audit")
            return 1
        print("[ok] hero spacing debt: %d (budget %d)" % (total, SPACING_DEBT_BUDGET))
        return 0

    if args.audit:
        print_audit()
        return 0

    names = [args.hero] if args.hero else sorted(HEROES)
    for i, name in enumerate(names):
        if i:
            print()
        print_hero(name, HEROES[name])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

