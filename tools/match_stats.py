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

# Item ID → short name (parsed from itembuilds broadcaster CSV)
ITEM_NAMES = {
    1:"blink",2:"blades_atk",3:"broadsword",4:"chainmail",5:"claymore",6:"helm_iron",
    7:"javelin",8:"mithril_hammer",9:"platemail",10:"quarterstaff",11:"quelling",
    12:"ring_prot",13:"gauntlets",14:"slippers",15:"mantle",16:"branches",
    17:"belt_str",18:"boots_agi",19:"robe",21:"ogre_axe",22:"blade_agi",
    23:"staff_int",24:"ultimate_orb",25:"gloves",26:"lifesteal",27:"ring_regen",
    28:"sobi_mask",29:"boots",30:"gem",31:"cloak",32:"talisman_evasion",
    34:"magic_stick",36:"magic_wand",37:"ghost",38:"clarity",39:"flask",
    40:"dust",41:"bottle",42:"obs_ward",43:"sentry",44:"tango",45:"courier",
    46:"tp",48:"travel_boots",50:"phase_boots",51:"demon_edge",52:"eagle",
    53:"reaver",54:"relic",55:"hyperstone",56:"ring_health",57:"void_stone",
    58:"mystic_staff",59:"energy_boost",60:"point_boost",61:"vitality_boost",
    63:"power_treads",65:"hand_midas",67:"oblivion_staff",73:"bracer",
    75:"wraith_band",77:"null_talisman",79:"mekansm",81:"vladmir",
    86:"buckler",88:"ring_basilius",90:"pipe",92:"urn",94:"headdress",
    96:"sheepstick",98:"orchid",100:"cyclone",102:"force_staff",104:"dagon",
    106:"necro",108:"aghs",110:"refresher",112:"assault",114:"heart",
    116:"bkb",119:"shivas",121:"bloodstone",123:"linken",125:"vanguard",
    127:"blade_mail",129:"soul_boost",131:"hood",133:"rapier",135:"mkb",
    137:"radiance",139:"butterfly",141:"daedalus",143:"basher",145:"bfury",
    147:"manta",149:"crystalys",151:"armlet",152:"shadow_blade",154:"sny",
    156:"satanic",158:"mjollnir",160:"skadi",162:"sange",164:"helm_dom",
    166:"maelstrom",168:"deso",170:"yasha",172:"mom",174:"diffusal",
    176:"ethereal",178:"soul_ring",180:"arcane_boots",181:"orb_venom",
    182:"stout",185:"drums",187:"medallion",188:"smoke",190:"veil",
    206:"rod_atos",208:"abyssal",210:"halberd",214:"tranquil",
    215:"shadow_amulet",216:"mango",223:"meteor_hammer",225:"nullifier",
    226:"lotus_orb",229:"solar_crest",231:"guardian_greaves",232:"aether_lens",
    235:"octarine",236:"dragon_lance",237:"faerie_fire",240:"blight_stone",
    242:"crimson_guard",244:"wind_lace",247:"moon_shard",249:"silver_edge",
    250:"bloodthorn",252:"echo_sabre",254:"glimmer",256:"aeon_disk",
    257:"tome",259:"kaya",263:"hurricane_pike",265:"infused_drop",267:"spirit_vessel",
}

def decode_items(id_str):
    """Convert comma-separated item ID string to readable names."""
    parts = []
    for x in id_str.split(","):
        x = x.strip()
        try:
            id_ = int(x)
            parts.append(ITEM_NAMES.get(id_, f"#{id_}") if id_ != -1 else "-")
        except ValueError:
            parts.append(x)
    return " ".join(parts)


DIAL_KEYS = ["harass", "farm", "lane", "exec", "retreat", "fwd", "abil", "rune", "gank", "push", "defend", "ward", "roshan"]

def extract_dials(cfg_lines):
    """Extract dial values from cfg announce lines, keyed by side R/D."""
    dials = {}
    for line in cfg_lines:
        m = re.search(r"AIB\[([RD])\]", line)
        if m:
            side = m.group(1)
            if side not in dials:
                dials[side] = {}
                for k, v in re.findall(r"(\w[\w-]*)=([\d.]+)", line):
                    dials[side][k] = v
    return dials

def print_dials(dials):
    """Print a compact R vs D dial comparison table."""
    keys = [k for k in DIAL_KEYS if any(k in d for d in dials.values())]
    if not keys:
        return
    header = "  dial:   " + "  ".join(f"{k:>7}" for k in keys)
    print(header)
    for side in ["R", "D"]:
        if side not in dials:
            continue
        row = "  [" + side + "]:    " + "  ".join(f"{dials[side].get(k, '-'):>7}" for k in keys)
        print(row)

def parse(path):
    lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
    text = "\n".join(lines)
    cfg = [l.split("localize: ", 1)[1] for l in lines if " harass=" in l]
    # Diag: 'AIB[R] heal-item #5'. Aggregate per key -> {side: count}; new lines carry a
    # cumulative '#N' (keep the max), legacy lines (no '#') are counted by occurrence.
    diag = {}
    for side, body in re.findall(r"'AIB(\[[RD]\])?\s+([^']*)'", text):
        if body.startswith("harass="):  # cfg announce always starts with harass=
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
    _win_raw = next((l.split("Winning team =", 1)[1].strip() for l in lines if "Winning team =" in l), "?")
    win = {"0": "Radiant", "2": "Dire"}.get(_win_raw, _win_raw)
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
        dials = extract_dials(cfg)
        if dials:
            print_dials(dials)
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
                  f"tp {p.get('teleports_used')} | dealt ph/mg/pu {dd} | "
                  f"items {decode_items(it)}")


if __name__ == "__main__":
    main()
