#!/usr/bin/env python3
"""AIBattle match log reader. Prints config + per-slot stats so we don't re-write ad-hoc
parsers every game (saves tokens).

Usage:
    python tools/match_stats.py <matchid> [<matchid> ...]

Looks for console.<id>.log under the Dota log dir (env DOTA_LOG_DIR overrides the default
Windows Steam path). Prints: AIB config chat lines, duration/winner, and per player slot:
KDA, last_hits/denies, hero_damage, tower_damage, teleports_used, damage dealt by type
(phys/mag/pure pre-reduction), items, and any 'AIB ...' diagnostic chat lines.
"""
import os, re, sys

DEFAULT_DIR = r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota"
LOG_DIR = os.environ.get("DOTA_LOG_DIR", DEFAULT_DIR)

FIELDS = ["kills", "deaths", "last_hits", "denies", "hero_damage",
          "tower_damage", "teleports_used", "level"]


def parse(path):
    lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
    text = "\n".join(lines)
    cfg = [l.split("localize: ", 1)[1] for l in lines if "harass=" in l]
    # Diag: 'AIB[R] heal-item #5'. Aggregate per key -> {side: count}; new lines carry a
    # cumulative '#N' (keep the max), legacy lines (no '#') are counted by occurrence.
    diag = {}
    for side, body in re.findall(r"'AIB(\[[RD]\])?\s+([^']*)'", text):
        if "harass=" in body:  # that's the cfg announce, not a diag
            continue
        s = side.strip("[]") or "?"
        pairs = re.findall(r"([\w-]+)=(\d+)", body)  # combined format 'anti-afk=15 heal-item=7'
        if pairs:
            for key, val in pairs:
                d = diag.setdefault(key, {})
                d[s] = max(d.get(s, 0), int(val))
        else:  # legacy: '<key> #N' (cumulative) or bare '<key>' (one occurrence)
            m = re.search(r"#(\d+)$", body)
            key = (body[:m.start()] if m else body).strip()
            if key:
                d = diag.setdefault(key, {})
                d[s] = max(d.get(s, 0), int(m.group(1))) if m else d.get(s, 0) + 1
    dur = next((m.group(1) for l in lines for m in [re.search(r"duration = ([\d.]+)", l)] if m), "?")
    win = next((l.split("Winning team =", 1)[1].strip() for l in lines if "Winning team =" in l), "?")
    items = [l.split("Items:", 1)[1].strip() for l in lines if "Items:" in l and "Player 0" in l]

    players, cur, dealt = [], {}, []
    for i, l in enumerate(lines):
        for k in FIELDS:
            m = re.search(r"\b" + k + r":\s*(-?\d+)", l)
            if m and "scaled" not in l:
                cur[k] = m.group(1)
        if "hero_damage_dealt {" in l and i + 1 < len(lines) and "pre_reduction" in lines[i + 1]:
            dealt.append(lines[i + 1].split("pre_reduction:")[1].strip())
        m = re.search(r"\bplayer_slot:\s*(\d+)", l)
        if m:
            cur["slot"] = m.group(1)
            players.append(cur)
            cur = {}
    return cfg, diag, dur, win, items, players, dealt


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    for mid in sys.argv[1:]:
        path = os.path.join(LOG_DIR, f"console.{mid}.log")
        print(f"\n===== {mid} =====")
        if not os.path.exists(path):
            print(f"  (not found: {path})")
            continue
        cfg, diag, dur, win, items, players, dealt = parse(path)
        for c in cfg:
            print("  cfg:", c)
        print(f"  duration={dur}  winner_team={win}")
        for key in sorted(diag):
            sides = " ".join(f"{s}#{n}" for s, n in sorted(diag[key].items()))
            print("  diag:", key, sides)
        for idx, p in enumerate(players):
            dd = dealt[idx * 3:idx * 3 + 3]
            it = items[idx] if idx < len(items) else "?"
            print(f"  slot{p.get('slot')}: "
                  f"K/D {p.get('kills')}/{p.get('deaths')} "
                  f"LH {p.get('last_hits')} DN {p.get('denies')} lvl {p.get('level')} | "
                  f"heroDmg {p.get('hero_damage')} towerDmg {p.get('tower_damage')} "
                  f"tp {p.get('teleports_used')} | dealt ph/mg/pu {dd} | items {it}")


if __name__ == "__main__":
    main()
