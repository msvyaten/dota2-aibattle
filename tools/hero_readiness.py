#!/usr/bin/env python3
"""Print the current hero expansion readiness matrix."""

from __future__ import annotations

import argparse


HEROES = {
    "nevermore": {
        "unit": "npc_dota_hero_nevermore",
        "attack": "ranged",
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
        ],
    },
    "juggernaut": {
        "unit": "npc_dota_hero_juggernaut",
        "attack": "melee",
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
        ],
    },
}


def print_hero(name, data):
    print("%s (%s)" % (name, data["unit"]))
    print("  attack: %s" % data["attack"])
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
    args = parser.parse_args()

    names = [args.hero] if args.hero else sorted(HEROES)
    for i, name in enumerate(names):
        if i:
            print()
        print_hero(name, HEROES[name])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

