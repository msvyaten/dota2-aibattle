#!/usr/bin/env python3
"""AIBattle match log reader. Prints config + per-slot stats so we don't re-write ad-hoc
parsers every game (saves tokens).

Usage:
    python tools/match_stats.py <matchid> [<matchid> ...]
    python tools/match_stats.py --latest
    python tools/match_stats.py --live --latest

Looks for console.<id>.log under the Dota log dir (env DOTA_LOG_DIR overrides the default
Windows Steam path). Prints: AIB config chat lines, duration/winner, and per player slot:
KDA, last_hits/denies, hero_damage, tower_damage, teleports_used, damage dealt by type
(phys/mag/pure pre-reduction), items, and any 'AIB ...' diagnostic chat lines.
"""
import argparse, math, os, re, sys
from pathlib import Path

DEFAULT_DIR = r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota"
LOG_DIR = os.environ.get("DOTA_LOG_DIR", DEFAULT_DIR)
DOTA_BOTS_DIR = Path(os.environ.get(
    "DOTA_BOTS_DIR",
    r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots",
))

FIELDS = ["kills", "deaths", "last_hits", "denies", "hero_damage",
          "tower_damage", "teleports_used", "level"]

def live_build_sha():
    path = DOTA_BOTS_DIR / "FunLib" / "aibattle_build.lua"
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    m = re.search(r'sha\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None

def latest_match_id():
    root = Path(LOG_DIR)
    candidates = []
    for path in root.glob("console.*.log"):
        m = re.fullmatch(r"console\.(\d+)\.log", path.name)
        if m:
            candidates.append((path.stat().st_mtime, int(m.group(1))))
    if not candidates:
        return None
    return str(max(candidates)[1])

# Item ID -> short name (parsed from itembuilds broadcaster CSV)
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


DIAL_KEYS = ["harass", "farm", "exec", "retreat", "fwd", "abil", "rune", "gank", "push", "defend", "ward", "roshan", "dive", "heal"]

def extract_dials(cfg_lines):
    """Extract dial values from cfg announce lines, keyed by side R/D.
    Merges MSG1 (harass=) and MSG2 (defend=) for the same side.
    Value regex captures both floats (0.85) and strings (finish_only)."""
    dials = {}
    for line in cfg_lines:
        m = re.search(r"AIB\[([RD])\]", line)
        if m:
            side = m.group(1)
            if side not in dials:
                dials[side] = {}
            for k, v in re.findall(r"(\w[\w-]*)=([\w.]+)", line):
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

def extract_telemetry(text):
    """Parse periodic AIB location reports separately from action diagnostics."""
    telemetry = {"R": [], "D": []}
    pat = (r"AIB\[([RD])\]\s+t=([\d.]+)s\s+hp=([\d.]+)%\s+gold=(\d+)\s+"
           r"loc=([-\d.]+),([-\d.]+)(?:\s+enemy-dist=([\d.]+))?"
           r"(?:\s+lh=(-?\d+))?(?:\s+dn=(-?\d+))?(?:\s+dg=([+-]?\d+))?(?:\s+dlh=([+-]?\d+))?")
    for side, t, hp, gold, x, y, enemy_dist, lh, dn, dg, dlh in re.findall(pat, text):
        telemetry[side].append({
            "t": float(t),
            "hp": float(hp),
            "gold": int(gold),
            "loc": (float(x), float(y)),
            "enemy_dist": float(enemy_dist) if enemy_dist else None,
            "lh": int(lh) if lh else None,
            "dn": int(dn) if dn else None,
            "dg": int(dg) if dg else None,
            "dlh": int(dlh) if dlh else None,
        })
    for samples in telemetry.values():
        samples.sort(key=lambda p: p["t"])
    return telemetry

def extract_deaths(telemetry):
    """Death timestamps per side from hp->0 transitions (AIB telemetry, ~5s resolution)."""
    deaths = {"R": [], "D": []}
    for side, samples in telemetry.items():
        prev_alive = True
        for s in samples:
            alive = s["hp"] > 0
            if prev_alive and not alive:
                deaths[side].append(s["t"])
            prev_alive = alive
    return deaths


def format_flow(deaths, dur, kill_win, score):
    """One-line game narrative: first blood, per-side death times, kill score, end reason.

    Death timing comes from hp->0 telemetry; kill score is authoritative from the final
    stat dump. A kill that lands on the game-ending tick has no hp=0 sample, so per side we
    backfill any missing death with the end time (~dur) to keep timing and score consistent.
    """
    try:
        dur_f = float(dur)
    except (TypeError, ValueError):
        dur_f = None
    rk, rd, dk, dd = score  # R kills/deaths, D kills/deaths (authoritative)
    times = {"R": list(deaths.get("R", [])), "D": list(deaths.get("D", []))}
    for side, auth_deaths in (("R", rd), ("D", dd)):
        while auth_deaths is not None and len(times[side]) < auth_deaths and dur_f is not None:
            times[side].append(dur_f)  # death coincided with game end
    events = sorted((t, side) for side in times for t in times[side])
    if not events:
        return None
    fb_t, fb_loser = events[0]
    fb_winner = "R" if fb_loser == "D" else "D"
    parts = [f"first-blood {fb_winner}@{fb_t:.0f}s"]
    death_bits = [f"{side}@" + ",".join(f"{t:.0f}s" for t in times[side])
                  for side in ("R", "D") if times[side]]
    if death_bits:
        parts.append("deaths " + " ".join(death_bits))
    parts.append(f"kills R:{rk} D:{dk}")
    end_s = f"{dur_f:.0f}s" if dur_f is not None else f"{dur}s"
    parts.append(f"end {end_s} " + ("kill-win" if kill_win else "tower/other"))
    return " | ".join(parts)


def stationary_spans(samples, move_threshold=90.0, min_seconds=10.0):
    """Return spans where consecutive location samples barely moved."""
    spans = []
    start = None
    last = None
    prev = None
    for cur in samples:
        if prev is None:
            prev = cur
            continue
        dist = math.hypot(cur["loc"][0] - prev["loc"][0], cur["loc"][1] - prev["loc"][1])
        if dist < move_threshold:
            if start is None:
                start = prev
            last = cur
        else:
            if start is not None and last is not None and last["t"] - start["t"] >= min_seconds:
                spans.append((start, last))
            start = None
            last = None
        prev = cur
    if start is not None and last is not None and last["t"] - start["t"] >= min_seconds:
        spans.append((start, last))
    return spans

def farm_trace(samples, limit=14):
    """Compact real farm/economy trace from AIB telemetry, when available."""
    rich = [s for s in samples if s.get("lh") is not None or s.get("dg") is not None]
    if not rich:
        return None
    lh_vals = [s["lh"] for s in rich if s.get("lh") is not None and s["lh"] >= 0]
    dn_vals = [s["dn"] for s in rich if s.get("dn") is not None and s["dn"] >= 0]
    total_lh = (lh_vals[-1] - lh_vals[0]) if len(lh_vals) >= 2 else None
    total_dn = (dn_vals[-1] - dn_vals[0]) if len(dn_vals) >= 2 else None
    events = []
    for s in rich:
        dg = s.get("dg")
        dlh = s.get("dlh")
        if dg is None and dlh is None:
            continue
        if (dg is not None and abs(dg) >= 40) or (dlh is not None and dlh != 0):
            bits = []
            if dg is not None: bits.append(f"dg={dg:+d}")
            if dlh is not None: bits.append(f"dlh={dlh:+d}")
            if s.get("lh") is not None and s["lh"] >= 0: bits.append(f"lh={s['lh']}")
            events.append(f"{s['t']:.0f}s(" + ",".join(bits) + ")")
    more = f" +{len(events)-limit} more" if len(events) > limit else ""
    totals = []
    if total_lh is not None: totals.append(f"LHd={total_lh}")
    if total_dn is not None: totals.append(f"DNd={total_dn}")
    return " ".join(totals + events[:limit]) + more

def extract_intents(text):
    """Parse AIB intent lines: side/name count plus last key=value detail string."""
    intents = {}
    for side, name, body in re.findall(r"AIB\[([RD])\]\s+intent=([\w-]+)([^']*)", text):
        side_map = intents.setdefault(name, {})
        entry = side_map.setdefault(side, {"count": 0, "last": ""})
        entry["count"] += 1
        entry["last"] = body.strip()
    return intents

def extract_blocked(text):
    """Parse AIB blocked-intent lines: side/name/reason counts plus last detail."""
    blocked = {}
    for side, name, body in re.findall(r"AIB\[([RD])\]\s+blocked=([\w-]+)([^']*)", text):
        reason = "unknown"
        m_reason = re.search(r"\breason=([\w-]+)", body)
        if m_reason:
            reason = m_reason.group(1)
        side_map = blocked.setdefault(name, {})
        reason_map = side_map.setdefault(side, {})
        entry = reason_map.setdefault(reason, {"count": 0, "last": ""})
        entry["count"] += 1
        entry["last"] = body.strip()
    return blocked

def extract_builds(text):
    builds = {}
    for side, sha in re.findall(r"AIB\[([RD])\]\s+build=([\w.-]+)", text):
        builds[side] = sha
    return builds

def classify_event(body):
    if body.startswith("intent="):
        name = body.split(None, 1)[0].split("=", 1)[1]
        return f"intent:{name}"
    if body.startswith("blocked="):
        name = body.split(None, 1)[0].split("=", 1)[1]
        reason = re.search(r"\breason=([\w-]+)", body)
        return f"blocked:{name}/{reason.group(1) if reason else 'unknown'}"
    mt = re.search(r"\bt=([\d.]+)s\b.*\benemy-dist=([\d.]+)", body)
    if mt and float(mt.group(2)) < 700:
        return f"near-hero:{float(mt.group(2)):.0f}"
    pairs = re.findall(r"([\w-]+)=(\d+)", body)
    interesting = []
    for key, val in pairs:
        if key.startswith(("fwd", "anti-afk", "anti-idle", "hero", "creep", "cs-", "low-hp", "kill", "channel", "siege")):
            interesting.append(f"{key}={val}")
    if interesting:
        return ",".join(interesting[:4])
    return None

def extract_event_timeline(text, limit=22, window=None):
    # window=(lo,hi): keep every event in that second-range and skip the mid truncation,
    # so a focused look (e.g. a death window) doesn't get collapsed into "...+N".
    timeline = {"R": [], "D": []}
    last_t = {"R": None, "D": None}
    for line in text.splitlines():
        m = re.search(r"'AIB\[([RD])\]\s+([^']*)'", line)
        if not m:
            continue
        side, body = m.group(1), m.group(2)
        mt = re.search(r"\bt=([\d.]+)s\b", body)
        if mt:
            last_t[side] = float(mt.group(1))
        label = classify_event(body)
        if label is None:
            continue
        t = last_t[side]
        if window is not None and (t is None or t < window[0] or t > window[1]):
            continue
        stamp = f"{t:.0f}s" if t is not None else "?s"
        entry = f"{stamp}:{label}"
        if not timeline[side] or timeline[side][-1] != entry:
            timeline[side].append(entry)
    if window is not None:
        return timeline
    for side in timeline:
        if len(timeline[side]) > limit:
            head = timeline[side][:limit // 2]
            tail = timeline[side][-(limit // 2):]
            timeline[side] = head + [f"...+{len(timeline[side]) - len(head) - len(tail)}"] + tail
    return timeline

def extract_action_events(text):
    events = {"R": [], "D": []}
    last_t = {"R": None, "D": None}
    for line in text.splitlines():
        m = re.search(r"'AIB\[([RD])\]\s+([^']*)'", line)
        if not m:
            continue
        side, body = m.group(1), m.group(2)
        mt = re.search(r"\bt=([\d.]+)s\b", body)
        if mt:
            last_t[side] = float(mt.group(1))
        label = classify_event(body)
        if label is None or last_t[side] is None:
            continue
        events[side].append({"t": last_t[side], "label": label})
    return events

def span_actions(events, side, start_t, end_t):
    labels = []
    seen = set()
    for ev in events.get(side, []):
        if start_t <= ev["t"] <= end_t:
            label = ev["label"]
            if label not in seen:
                seen.add(label)
                labels.append(label)
    return labels[:5]

def parse(path, window=None):
    lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
    text = "\n".join(lines)
    telemetry = extract_telemetry(text)
    intents = extract_intents(text)
    blocked = extract_blocked(text)
    builds = extract_builds(text)
    timeline = extract_event_timeline(text, window=window)
    action_events = extract_action_events(text)
    # Pick up both MSG1 (harass=) and MSG2 (defend=) config announce lines.
    cfg = [l.split("localize: ", 1)[1] for l in lines
           if ("AIB[" in l) and (" harass=" in l or " defend=" in l)]
    # Diag: 'AIB[R] heal-item #5'. Aggregate per key -> {side: count}; new lines carry a
    # cumulative '#N' (keep the max), legacy lines (no '#') are counted by occurrence.
    # pg-loc lines: "AIB[R] pg-loc me=X,Y enm=X,Y dist=N range=N in-range=0/1"
    # Parsed separately; excluded from the generic diag counter below.
    pg_locs = []
    for side, body in re.findall(r"AIB\[([RD])\] (pg-loc .+)", text):
        m_me  = re.search(r"me=([-\d.]+),([-\d.]+)", body)
        m_enm = re.search(r"enm=([-\d.]+),([-\d.]+)", body)
        m_dst = re.search(r"dist=([\d.]+)", body)
        m_rng = re.search(r"range=([\d.]+)", body)
        m_ir  = re.search(r"in-range=(\d)", body)
        pg_locs.append({
            "side": side,
            "me":   (float(m_me.group(1)),  float(m_me.group(2)))  if m_me  else None,
            "enm":  (float(m_enm.group(1)), float(m_enm.group(2))) if m_enm else None,
            "dist": float(m_dst.group(1)) if m_dst else None,
            "range": float(m_rng.group(1)) if m_rng else None,
            "in_range": int(m_ir.group(1)) if m_ir else None,
            "no_enm": "no-enm" in body,
        })

    diag = {}
    _cfg_prefixes = ("harass=", "defend=")  # cfg announce start markers
    for side, body in re.findall(r"'AIB(\[[RD]\])?\s+([^']*)'", text):
        if any(body.startswith(p) for p in _cfg_prefixes):  # cfg line, not a diag
            continue
        if body.startswith("intent="):
            continue
        if body.startswith("blocked="):
            continue
        if body.startswith("build="):
            continue
        if body.startswith("t="):
            continue
        if body.startswith("pg-loc"):  # position log - handled above
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
    win = {"0": "Radiant", "1": "Dire", "2": "Radiant", "3": "Dire"}.get(_win_raw, _win_raw)
    items = [l.split("Items:", 1)[1].strip() for l in lines if "Items:" in l and "Player 0" in l]

    players, cur, dealt, received = [], {}, [], []
    for i, l in enumerate(lines):
        for k in FIELDS:
            m = re.search(r"\b" + k + r":\s*(-?\d+)", l)
            if m and "scaled" not in l:
                cur[k] = m.group(1)
        if "hero_damage_dealt {" in l and i + 1 < len(lines) and "pre_reduction" in lines[i + 1]:
            dealt.append(lines[i + 1].split("pre_reduction:")[1].strip())
        if "hero_damage_received {" in l and i + 1 < len(lines) and "pre_reduction" in lines[i + 1]:
            received.append(lines[i + 1].split("pre_reduction:")[1].strip())
        m = re.search(r"\bplayer_slot:\s*(\d+)", l)
        if m:
            cur["slot"] = m.group(1)
            players.append(cur)
            cur = {}
    return cfg, diag, dur, win, items, players, dealt, received, pg_locs, telemetry, intents, blocked, builds, timeline, action_events

def side_count(diag, key, side):
    return int(diag.get(key, {}).get(side, 0) or 0)

def alert_symptoms(diag, telemetry, intents, blocked, items, action_events):
    alerts = []
    for side in ["R", "D"]:
        samples = telemetry.get(side, [])
        if samples:
            close_samples = sum(1 for s in samples if s.get("enemy_dist") is not None and s["enemy_dist"] < 700)
            hero_actions = sum(side_count(diag, k, side) for k in [
                "harass-atk", "harass-seek", "hero-pass-atk", "hero-pass-chase",
                "hero-contact-atk", "hero-contact-chase",
                "hero-prio-always", "hero-prio-chase", "kill-priority",
            ])
            if close_samples >= 3 and hero_actions == 0:
                alerts.append(f"{side}: ignored-nearby-hero close_samples={close_samples} hero_actions=0")

            for start, end in stationary_spans(samples):
                hp_drop = start["hp"] - end["hp"]
                if hp_drop >= 8:
                    actions = span_actions(action_events, side, start["t"], end["t"])
                    if actions:
                        alerts.append(f"{side}: stationary-while-damaged-with-actions {start['t']:.0f}-{end['t']:.0f}s hp_drop={hp_drop:.0f}% actions=" + ",".join(actions))
                    else:
                        alerts.append(f"{side}: stationary-while-damaged-no-action {start['t']:.0f}-{end['t']:.0f}s hp_drop={hp_drop:.0f}%")
                    break

        creep_dmg = side_count(diag, "creep-dmg", side)
        creep_relief = sum(side_count(diag, k, side) for k in [
            "creep-aggro-back", "creep-aggro-hit", "creep-aggro-kite",
            "low-hp-creep",
        ])
        if creep_dmg > 0 and creep_relief == 0:
            alerts.append(f"{side}: creep-dmg-without-relief creep-dmg={creep_dmg}")

        enemy = "D" if side == "R" else "R"
        enemy_heals = sum(side_count(diag, k, enemy) for k in [
            "heal-item", "bottle-heal", "mana-clarity", "recovery-bottle",
        ])
        interrupts = sum(side_count(diag, k, side) for k in [
            "heal-interrupt-atk", "heal-interrupt-chase",
            "channel-interrupt-atk", "channel-interrupt-chase",
        ])
        interrupts += intents.get("channel-interrupt", {}).get(side, {}).get("count", 0)
        interrupts += intents.get("heal-interrupt", {}).get(side, {}).get("count", 0)
        if enemy_heals > 0 and interrupts == 0:
            alerts.append(f"{side}: enemy-healed-without-interrupt enemy_heals={enemy_heals}")

    for idx, item_ids in enumerate(items):
        side = "R" if idx == 0 else ("D" if idx == 1 else f"slot{idx}")
        names = decode_items(item_ids)
        if "bottle" in names:
            rune_moves = side_count(diag, "bottle-rune", side) + side_count(diag, "recovery-rune-bottle", side)
            if rune_moves == 0:
                alerts.append(f"{side}: bottle-no-rune-intent")

    return alerts

def verdicts(diag, telemetry):
    out = []
    old_fwd = sum(sum(side.values()) for key, side in diag.items()
                  if key in ("fwd-ahead", "fwd-fallback", "fwd-push", "fb-skip"))
    new_fwd = sum(sum(side.values()) for key, side in diag.items()
                  if key in ("fwd-position", "fwd-suppressed-hero", "fwd-suppressed-creep",
                             "fwd-suppressed-lowhp", "fwd-suppressed-tower"))
    if old_fwd > 100:
        out.append(f"legacy-forwardness-noise old_fwd={old_fwd}")
    if new_fwd > 0:
        out.append(f"new-forwardness-shape fwd_events={new_fwd}")
    for side in ["R", "D"]:
        close = sum(1 for s in telemetry.get(side, [])
                    if s.get("enemy_dist") is not None and s["enemy_dist"] < 700)
        hero = sum(side_count(diag, k, side) for k in [
            "hero-contact-atk", "hero-contact-chase", "hero-pass-atk", "hero-pass-chase",
            "harass-atk", "harass-seek", "anti-idle-combat",
        ])
        if close >= 3 and hero == 0:
            out.append(f"{side}: close-enemy-without-hero-action close_samples={close}")
    return out


def main():
    parser = argparse.ArgumentParser(description="Read AIBattle Dota console logs.")
    parser.add_argument("matchids", nargs="*", help="Match IDs to analyze")
    parser.add_argument("--latest", action="store_true", help="Analyze the newest console.<id>.log")
    parser.add_argument("--live", action="store_true", help="Print live deployed AIBattle build sha")
    parser.add_argument("--window", nargs=2, type=int, metavar=("START", "END"),
                        help="Show the full event timeline for seconds START..END (no mid truncation)")
    args = parser.parse_args()

    matchids = list(args.matchids)
    if args.latest:
        latest = latest_match_id()
        if latest is None:
            print(f"(no console.<id>.log files found in {LOG_DIR})")
            return 1
        if latest not in matchids:
            matchids.append(latest)

    live_sha = live_build_sha() if args.live else None
    if args.live:
        print(f"live_build: {live_sha or 'unknown'}")

    if not matchids:
        parser.print_help()
        return 0

    for mid in matchids:
        path = os.path.join(LOG_DIR, f"console.{mid}.log")
        print(f"\n===== {mid} =====")
        if not os.path.exists(path):
            print(f"  (not found: {path})")
            continue
        cfg, diag, dur, win, items, players, dealt, received, pg_locs, telemetry, intents, blocked, builds, timeline, action_events = parse(path, window=tuple(args.window) if args.window else None)
        if builds:
            print("  build:", " ".join(f"{s}={sha}" for s, sha in sorted(builds.items())))
            if live_sha:
                old = [f"{s}={sha}" for s, sha in sorted(builds.items()) if sha != live_sha]
                if old:
                    print("  build_mismatch_vs_live:", " ".join(old), f"live={live_sha}")
        for c in cfg:
            print("  cfg:", c)
        dials = extract_dials(cfg)
        if dials:
            print_dials(dials)
        dur_f = float(dur) if dur != "?" else None

        # game_s: actual DotaTime at game end, from location-report diag 't=N'.
        # The diag parser stores max value, so diag['t'][side] = last DotaTime seen.
        # duration from the log includes pregame (DotaTime<0 period), game_s does not.
        t_vals = diag.pop("t", {})  # remove from diag output - shown in duration line
        game_s = max(t_vals.values()) if t_vals else None
        last_ts = [samples[-1]["t"] for samples in telemetry.values() if samples]
        if last_ts:
            game_s = max(last_ts)
        pregame_s = round(dur_f - game_s) if (dur_f and game_s) else None

        if game_s:
            game_str = f"game={game_s}s"
            pre_str  = f"  pregame=~{pregame_s}s" if (pregame_s and pregame_s > 5) else ""
            print(f"  duration={dur}s ({game_str}{pre_str})  winner_team={win}")
        else:
            dur_min = dur_f / 60 if dur_f else None
            print(f"  duration={dur}s ({f'{dur_min:.1f}min' if dur_min else '?'})  winner_team={win}")

        # Per-minute rates use actual game time, not total duration.
        rate_min = game_s / 60 if game_s else (dur_f / 60 if dur_f else None)

        for key in sorted(diag):
            sides = " ".join(f"{s}#{n}" for s, n in sorted(diag[key].items()))
            print("  diag:", key, sides)
        for name in sorted(intents):
            chunks = []
            for side, entry in sorted(intents[name].items()):
                last = f" last({entry['last']})" if entry["last"] else ""
                chunks.append(f"{side}#{entry['count']}{last}")
            print("  intent:", name, " ".join(chunks))
        for name in sorted(blocked):
            chunks = []
            for side, reasons in sorted(blocked[name].items()):
                reason_bits = []
                for reason, entry in sorted(reasons.items()):
                    last = f" last({entry['last']})" if entry["last"] else ""
                    reason_bits.append(f"{reason}#{entry['count']}{last}")
                chunks.append(f"{side}[" + ", ".join(reason_bits) + "]")
            print("  blocked:", name, " ".join(chunks))
        alerts = alert_symptoms(diag, telemetry, intents, blocked, items, action_events)
        for alert in alerts:
            print("  alert:", alert)
        for verdict in verdicts(diag, telemetry):
            print("  verdict:", verdict)
        def _pk(idx, key):
            return int(players[idx].get(key) or 0) if idx < len(players) else 0
        score = (_pk(0, "kills"), _pk(0, "deaths"), _pk(1, "kills"), _pk(1, "deaths"))
        flow = format_flow(extract_deaths(telemetry), dur,
                           max((int(p.get('kills') or 0) for p in players), default=0) >= 2, score)
        if flow:
            print("  flow:", flow)
        for side in ["R", "D"]:
            if timeline.get(side):
                print(f"  timeline[{side}]: " + " | ".join(timeline[side]))
        for side in ["R", "D"]:
            ft = farm_trace(telemetry.get(side, []))
            if ft:
                print(f"  farmtrace[{side}]: {ft}")
        for side in ["R", "D"]:
            spans = stationary_spans(telemetry.get(side, []))
            if spans:
                shown = []
                for start, end in spans[:5]:
                    dur_span = end["t"] - start["t"]
                    shown.append(f"{start['t']:.0f}-{end['t']:.0f}s({dur_span:.0f}s)@{end['loc'][0]:.0f},{end['loc'][1]:.0f}")
                more = f" +{len(spans)-5} more" if len(spans) > 5 else ""
                print(f"  stationary[{side}]: " + "; ".join(shown) + more)
        if pg_locs:
            print(f"  pregame positions ({len(pg_locs)} snapshots, every ~3s):")
            for p in pg_locs:
                if p["no_enm"]:
                    print(f"    [{p['side']}] me={p['me']}  (no enemy in 1500 range)")
                else:
                    ir = p["in_range"]
                    flag = "IN-RANGE" if ir == 1 else "out-of-range"
                    print(f"    [{p['side']}] me={p['me']}  enm={p['enm']}"
                          f"  dist={p['dist']:.0f}  range={p['range']:.0f}  {flag}")
        max_kills = max((int(p.get('kills') or 0) for p in players), default=0)
        kill_win = max_kills >= 2  # game ended by kill condition (2-0, 2-1, 2-2)
        for idx, p in enumerate(players):
            dd = dealt[idx * 3:idx * 3 + 3]
            dr = received[idx * 3:idx * 3 + 3]
            it = items[idx] if idx < len(items) else "?"
            lh = p.get('last_hits')
            dn = p.get('denies')
            lh_min = f"{int(lh)/rate_min:.1f}/m" if lh and rate_min else "?"
            dn_min = f"{int(dn)/rate_min:.1f}/m" if dn and rate_min else "?"
            td = int(p.get('tower_damage') or 0)
            if 4200 <= td <= 4800 and kill_win:
                td_note = " [AUTO-DESTROYED: kill-win, not real tower dmg]"
            else:
                td_note = ""
            print(f"  slot{p.get('slot')}: "
                  f"K/D {p.get('kills')}/{p.get('deaths')} "
                  f"LH {lh}({lh_min}) DN {dn}({dn_min}) lvl {p.get('level')} | "
                  f"heroDmg {p.get('hero_damage')} towerDmg {td}{td_note} "
                  f"tp {p.get('teleports_used')} | dealt ph/mg/pu {dd} | rcvd ph/mg/pu {dr} | "
                  f"items {decode_items(it)}")


if __name__ == "__main__":
    sys.exit(main())
