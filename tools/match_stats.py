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

from aibattle_log import DOTA_LOG_DIR, extract_telemetry, latest_match_id, live_build_sha

LOG_DIR = str(DOTA_LOG_DIR)

FIELDS = ["kills", "deaths", "last_hits", "denies", "hero_damage",
          "tower_damage", "teleports_used", "level"]

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

def bottle_summary(samples):
    """Sustain visibility: how much of the game the bot sat on an empty bottle.

    Only present in logs from builds that emit bottle= telemetry; returns None otherwise.
    """
    vals = [s["bottle"] for s in samples if s.get("bottle") is not None and s["bottle"] >= 0]
    if not vals:
        return None
    empty = sum(1 for v in vals if v == 0)
    return f"empty {empty}/{len(vals)} samples ({100 * empty / len(vals):.0f}%)"


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
        entry = side_map.setdefault(side, {"count": 0, "last": "", "fields": {}})
        entry["count"] += 1
        entry["last"] = body.strip()
        for key, val in re.findall(r"\b([\w-]+)=([^\s]+)", body):
            field = entry["fields"].setdefault(key, {})
            field[val] = field.get(val, 0) + 1
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
        if name == "top-arbiter":
            winner = re.search(r"\bwinner=([^\s:]+)", body)
            if winner:
                return f"arbiter:{winner.group(1)}"
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

def intent_count(intents, name, side):
    return int(intents.get(name, {}).get(side, {}).get("count", 0) or 0)

def intent_field_counts(intents, name, side, field):
    return intents.get(name, {}).get(side, {}).get("fields", {}).get(field, {})

def intent_family_counts(intents, side):
    counts = {}
    for side_map in intents.values():
        entry = side_map.get(side)
        if not entry:
            continue
        for family, n in entry.get("fields", {}).get("family", {}).items():
            counts[family] = counts.get(family, 0) + n
    return counts

def blocked_reason_counts(blocked, name, side):
    reasons = blocked.get(name, {}).get(side, {})
    return {reason: entry.get("count", 0) for reason, entry in reasons.items()}

def _side_counts(source, keys, side):
    out = {}
    for key in keys:
        n = side_count(source, key, side)
        if n:
            out[key] = n
    return out

def _intent_counts(intents, keys, side):
    out = {}
    for key in keys:
        n = intent_count(intents, key, side)
        if n:
            out[key] = n
    return out

def _blocked_counts(blocked, keys, side):
    out = {}
    for key in keys:
        total = sum(blocked_reason_counts(blocked, key, side).values())
        if total:
            out[key] = total
    return out

def _fmt_counts(counts, limit=5):
    if not counts:
        return ""
    pairs = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    bits = [f"{k}={v}" for k, v in pairs[:limit]]
    if len(pairs) > limit:
        bits.append(f"+{len(pairs) - limit}")
    return " ".join(bits)

def _side_symptoms(alerts, side, needles):
    prefix = f"{side}: "
    out = []
    for alert in alerts:
        if not alert.startswith(prefix):
            continue
        body = alert[len(prefix):]
        if any(n in body for n in needles):
            out.append(body.split()[0])
    return out

def debug_tree_lines(side, diag, intents, blocked, alerts):
    """Build desire -> state -> action/block -> symptom summaries for one side."""
    tree = []

    fight_states = _intent_counts(intents, ["state-prewave-duel"], side)
    fight_actions = _side_counts(diag, [
        "pg-duel", "pg-duel-uphill", "pg-duel-step",
        "pg-duel-approach", "pg-duel-trade", "pg-duel-space", "pg-duel-disengage",
        "prewave-duel", "prewave-duel-uphill", "prewave-duel-step",
        "prewave-duel-approach", "prewave-duel-trade", "prewave-duel-space", "prewave-duel-disengage",
        "ability-harass", "execute", "execute-approach",
        "hero-contact-atk", "hero-contact-chase", "hero-pass-atk", "hero-pass-chase",
        "kill-lock-atk", "channel-interrupt-atk", "channel-interrupt-chase",
    ], side)
    fight_actions.update(_intent_counts(intents, [
        "hero-contact", "kill-lock", "channel-interrupt", "heal-interrupt",
    ], side))
    fight_blocks = _blocked_counts(blocked, [
        "prewave-duel", "hero-contact", "hero-prio-chase",
        "ability-pressure", "kill-lock", "channel-interrupt",
    ], side)
    fight_symptoms = _side_symptoms(alerts, side, [
        "ignored-nearby-hero", "enemy-healed-without-interrupt",
    ])
    _append_tree_line(tree, "fight", fight_states, fight_actions, fight_blocks, fight_symptoms)

    rune_states = _intent_counts(intents, ["state-rune-commit"], side)
    rune_actions = _side_counts(diag, [
        "bottle-rune", "recovery-rune-bottle", "recovery-rune",
    ], side)
    rune_actions.update(_intent_counts(intents, [
        "bottle-rune", "recovery-rune-bottle", "rune-result",
    ], side))
    rune_blocks = _blocked_counts(blocked, ["bottle-rune", "recovery-rune-bottle"], side)
    rune_results = {f"result:{k}": v for k, v in intent_field_counts(intents, "rune-result", side, "result").items()}
    rune_actions.update(rune_results)
    rune_symptoms = _side_symptoms(alerts, side, ["bottle-no-rune-intent"])
    _append_tree_line(tree, "rune", rune_states, rune_actions, rune_blocks, rune_symptoms)

    recover_states = _intent_counts(intents, ["state-recover-xp", "state-recover-safe"], side)
    recover_actions = _side_counts(diag, [
        "recover-xp", "recover-safe", "regen-walk",
        "recovery-bottle", "recovery-flask", "recovery-regen", "recovery-wait",
        "recovery-tango", "recovery-buy", "recovery-tp", "recovery-walk",
        "bottle-heal", "tango-heal", "heal-item", "mana-clarity",
        "low-hp-back", "low-hp-nudge", "low-hp-safe-step", "low-hp-watch-step",
        "fountain-bottle", "fountain-stabilize", "fountain-wait",
    ], side)
    recover_actions.update(_intent_counts(intents, ["recovery-plan"], side))
    recover_blocks = _blocked_counts(blocked, ["recovery-buy"], side)
    recover_symptoms = _side_symptoms(alerts, side, ["stationary-while-damaged"])
    _append_tree_line(tree, "recover", recover_states, recover_actions, recover_blocks, recover_symptoms)

    push_states = _intent_counts(intents, ["state-siege-window"], side)
    push_actions = _side_counts(diag, [
        "cw-push", "siege-creep", "siege-tower", "siege-step",
        "siege-wave-tower", "siege-wave-step",
        "siege-commit-tower", "siege-commit-step",
    ], side)
    push_actions.update({f"tower:{k}": v for k, v in intent_field_counts(intents, "tower-opportunity", side, "result").items()})
    push_blocks = _blocked_counts(blocked, ["siege"], side)
    _append_tree_line(tree, "push", push_states, push_actions, push_blocks, [])

    lane_states = {}
    lane_actions = _side_counts(diag, [
        "cs-inrange", "cs-wait", "cs-wait-release", "cs-walk",
        "cs-watchdog-atk", "cs-watchdog-step", "deny-act",
        "creep-dmg", "creep-aggro-back", "creep-aggro-hit",
        "creep-hit-react-atk", "creep-hit-react-kite", "creep-hit-react-step",
        "creep-hit-react-force-atk", "creep-hit-react-back",
        "fwd-position", "fwd-at-position", "fwd-hold",
        "fwd-suppressed-hero", "fwd-suppressed-creep", "fwd-suppressed-lowhp",
        "visual-hold",
    ], side)
    lane_actions.update(_intent_counts(intents, [
        "cs-watchdog", "creep-aggro", "creep-hit-react", "arbiter",
    ], side))
    lane_blocks = _blocked_counts(blocked, [
        "cs-watchdog", "creep-hit-react", "visual-hold",
    ], side)
    lane_symptoms = _side_symptoms(alerts, side, ["creep-dmg-without-relief"])
    _append_tree_line(tree, "lane", lane_states, lane_actions, lane_blocks, lane_symptoms)

    return tree

def _append_tree_line(tree, name, states, actions, blocks, symptoms):
    parts = []
    s = _fmt_counts(states, 4)
    a = _fmt_counts(actions, 6)
    b = _fmt_counts(blocks, 4)
    if s:
        parts.append(f"state[{s}]")
    if a:
        parts.append(f"action[{a}]")
    if b:
        parts.append(f"blocked[{b}]")
    if symptoms:
        parts.append("symptom[" + " ".join(symptoms[:4]) + "]")
    if parts:
        tree.append(f"    {name}: " + " ".join(parts))

def print_debug_tree(diag, intents, blocked, alerts):
    for side in ["R", "D"]:
        lines = debug_tree_lines(side, diag, intents, blocked, alerts)
        if lines:
            print(f"  debug_tree[{side}]:")
            for line in lines:
                print(line)

def print_state_metrics(diag, intents):
    for side in ["R", "D"]:
        parts = []
        for label, name in [
            ("prewave", "state-prewave-duel"),
            ("rune", "state-rune-commit"),
            ("siege", "state-siege-window"),
            ("recover_xp", "state-recover-xp"),
            ("recover_safe", "state-recover-safe"),
        ]:
            n = intent_count(intents, name, side)
            if n:
                parts.append(f"{label}={n}")
        xp = side_count(diag, "recover-xp", side)
        safe = side_count(diag, "recover-safe", side)
        if xp or safe:
            total = xp + safe
            pct = 100 * xp / total if total else 0
            parts.append(f"xp_recovery={xp}/{total}({pct:.0f}%)")
        if parts:
            print(f"  states[{side}]: " + " ".join(parts))

def print_tower_opportunities(diag, intents, blocked):
    for side in ["R", "D"]:
        result_counts = intent_field_counts(intents, "tower-opportunity", side, "result")
        if result_counts:
            hit = result_counts.get("hit", 0)
            step = result_counts.get("step", 0)
            blocked_n = sum(n for k, n in result_counts.items() if k.startswith("blocked"))
            total = hit + step + blocked_n
            if total:
                print(f"  tower_opp[{side}]: hit={hit} step={step} blocked={blocked_n} total={total}")
            continue

        hit = sum(side_count(diag, k, side) for k in [
            "siege-commit-tower", "siege-wave-tower", "siege-tower",
        ])
        step = sum(side_count(diag, k, side) for k in [
            "siege-commit-step", "siege-wave-step", "siege-step",
        ])
        blocked_n = sum(entry.get("count", 0)
                        for entry in blocked.get("siege", {}).get(side, {}).values())
        total = hit + step + blocked_n
        if total:
            print(f"  tower_opp[{side}]: hit={hit} step={step} blocked={blocked_n} total={total}")


def arbiter_winner_counts(intents, side):
    out = {}
    for raw, n in intent_field_counts(intents, "top-arbiter", side, "winner").items():
        name = raw.split(":", 1)[0]
        if name:
            out[name] = out.get(name, 0) + n
    return out


def desire_state_counts(intents, side):
    prefix = "state-desire-"
    out = {}
    for name, by_side in intents.items():
        if not name.startswith(prefix):
            continue
        entry = by_side.get(side)
        if entry:
            out[name[len(prefix):]] = entry.get("count", 0)
    return out


def arbiter_empty_actions(blocked, side):
    return blocked_reason_counts(blocked, "top-arbiter", side).get("empty_action", 0)


def desire_loop_counts(action_events, side):
    seq = []
    last = None
    for ev in action_events.get(side, []):
        label = ev.get("label", "")
        if not label.startswith("arbiter:"):
            continue
        name = label.split(":", 1)[1]
        if name == last:
            continue
        seq.append(name)
        last = name

    loops = {}
    for i in range(len(seq) - 2):
        a, b, c = seq[i], seq[i + 1], seq[i + 2]
        if a == c and a != b:
            key = f"{a}->{b}->{a}"
            loops[key] = loops.get(key, 0) + 1
    return loops


def print_arbiter_metrics(intents, blocked, action_events):
    for side in ["R", "D"]:
        winners = arbiter_winner_counts(intents, side)
        states = desire_state_counts(intents, side)
        loops = desire_loop_counts(action_events, side)
        empty = arbiter_empty_actions(blocked, side)
        if not winners and not states and not loops and not empty:
            continue
        parts = []
        if winners:
            parts.append("winner " + _fmt_counts(winners, 5))
        if states:
            parts.append("state " + _fmt_counts(states, 5))
        if loops:
            parts.append("loops " + _fmt_counts(loops, 3))
        if empty:
            parts.append(f"empty_action={empty}")
        print(f"  arbiter[{side}]: " + " | ".join(parts))

def _add_candidate(candidates, priority, side, area, confidence, issue, evidence, recommendation):
    candidates.append({
        "priority": priority,
        "side": side,
        "area": area,
        "confidence": confidence,
        "issue": issue,
        "evidence": evidence,
        "recommendation": recommendation,
    })


def _empty_bottle_ratio(samples):
    vals = [s["bottle"] for s in samples if s.get("bottle") is not None and s["bottle"] >= 0]
    if not vals:
        return None
    return sum(1 for v in vals if v == 0), len(vals)


def fix_candidates(diag, telemetry, intents, blocked, items, action_events, players, game_s=None):
    """Conservative advisory audit.

    These lines are not ground truth and never imply an automatic code change. They surface
    suspicious patterns with evidence so the next human/Codex pass can inspect the exact owner.
    """
    candidates = []
    for side in ["R", "D"]:
        samples = telemetry.get(side, [])
        arb_winners = arbiter_winner_counts(intents, side)
        arb_total = sum(arb_winners.values())
        arb_empty = arbiter_empty_actions(blocked, side)
        for start, end in stationary_spans(samples):
            hp_drop = start["hp"] - end["hp"]
            if hp_drop < 8:
                continue
            actions = span_actions(action_events, side, start["t"], end["t"])
            if actions:
                _add_candidate(
                    candidates, 1, side, "visual-afk", "medium",
                    "stationary while taking damage, but code kept issuing actions",
                    f"{start['t']:.0f}-{end['t']:.0f}s hp_drop={hp_drop:.0f}% actions={','.join(actions[:4])}",
                    "inspect tick-owner/action ownership inside this window; likely a movement/action is being overwritten or visually ineffective",
                )
            else:
                _add_candidate(
                    candidates, 1, side, "visual-afk", "high",
                    "stationary while taking damage with no classified action",
                    f"{start['t']:.0f}-{end['t']:.0f}s hp_drop={hp_drop:.0f}% loc={end['loc'][0]:.0f},{end['loc'][1]:.0f}",
                    "add/verify a high-priority damage response before hold/recovery fallbacks consume the tick",
                )
            break

        close_samples = sum(1 for s in samples if s.get("enemy_dist") is not None and s["enemy_dist"] < 700)
        hero_actions = sum(side_count(diag, k, side) for k in [
            "harass-atk", "harass-seek", "hero-pass-atk", "hero-pass-chase",
            "hero-contact-atk", "hero-contact-chase", "hero-prio-always",
            "hero-prio-chase", "kill-priority",
        ])
        creep_work = sum(side_count(diag, k, side) for k in [
            "cs-inrange", "cs-wait", "cs-walk", "deny-act",
            "creep-hit-react-atk", "creep-aggro-hit", "cw-push",
        ])
        if close_samples >= 5 and hero_actions <= 1:
            _add_candidate(
                candidates, 1, side, "fight", "high",
                "enemy nearby but almost no hero action",
                f"close_samples={close_samples} hero_actions={hero_actions}",
                "inspect hero-contact/chase gates and lane_work blockers before changing strategy dials",
            )

        recover_wins = arb_winners.get("recover", 0)
        if arb_total >= 8 and recover_wins / arb_total >= 0.55 and (close_samples >= 5 or creep_work >= 8):
            _add_candidate(
                candidates, 2, side, "arbiter", "medium",
                "recover desire dominated while lane work or enemy contact existed",
                f"recover={recover_wins}/{arb_total} close_samples={close_samples} creep_work={creep_work}",
                "inspect recovery score/yield rules before adding another AFK fallback; recover may be winning too broadly",
            )

        ratio = _empty_bottle_ratio(samples)
        if ratio is not None:
            empty, total = ratio
            pct = empty / total if total else 0
            rune_blocks = {}
            for name in ("bottle-rune", "recovery-rune-bottle"):
                for reason, n in blocked_reason_counts(blocked, name, side).items():
                    rune_blocks[reason] = rune_blocks.get(reason, 0) + n
            stage_cd = rune_blocks.get("stage_cooldown", 0)
            no_close = rune_blocks.get("no_close_rune", 0)
            filled = intent_field_counts(intents, "rune-result", side, "result").get("filled", 0)
            if pct >= 0.70 and (stage_cd + no_close) >= 5 and filled == 0:
                _add_candidate(
                    candidates, 2, side, "rune", "high",
                    "bottle stayed empty while rune attempts were blocked",
                    f"empty={empty}/{total}({pct:.0%}) stage_cooldown={stage_cd} no_close_rune={no_close} filled=0",
                    "inspect rune staging leash/cooldown; consider emergency override only when water rune is reachable in mid corridor",
                )

        result_counts = intent_field_counts(intents, "tower-opportunity", side, "result")
        if result_counts:
            hit = result_counts.get("hit", 0)
            step = result_counts.get("step", 0)
            blocked_n = sum(n for k, n in result_counts.items() if k.startswith("blocked"))
        else:
            hit = sum(side_count(diag, k, side) for k in [
                "siege-commit-tower", "siege-wave-tower", "siege-tower",
            ])
            step = sum(side_count(diag, k, side) for k in [
                "siege-commit-step", "siege-wave-step", "siege-step",
            ])
            blocked_n = sum(entry.get("count", 0)
                            for entry in blocked.get("siege", {}).get(side, {}).values())
        total_tower = hit + step + blocked_n
        if total_tower >= 8 and hit == 0 and (step + blocked_n) >= 8:
            _add_candidate(
                candidates, 2, side, "siege", "medium",
                "tower opportunities did not become tower hits",
                f"hit={hit} step={step} blocked={blocked_n}",
                "inspect siege owner: allied tank, tower range, and competing recovery/rune/fwd owners during push windows",
            )

        siege_wins = arb_winners.get("siege", 0)
        if siege_wins >= 3 and hit == 0 and (step + blocked_n) >= 3:
            _add_candidate(
                candidates, 2, side, "arbiter", "medium",
                "siege desire won but did not produce tower hits",
                f"siege_wins={siege_wins} tower_hit={hit} step={step} blocked={blocked_n}",
                "inspect siege action result and competing tower safety gates; the top desire is correct but the action may be ineffective",
            )

        power_wins = arb_winners.get("power-rune", 0)
        power_hero_or_tower = sum(side_count(diag, k, side) for k in [
            "rune-pressure-atk", "rune-pressure-chase", "rune-pressure-tower",
            "rune-pressure-tower-step", "rune-pressure-ability", "ability-harass",
        ])
        power_creep = side_count(diag, "rune-pressure-creep", side)
        if power_wins >= 3 and power_hero_or_tower == 0 and power_creep > 0:
            _add_candidate(
                candidates, 2, side, "arbiter", "medium",
                "power-rune desire won but only produced creep pressure",
                f"power_wins={power_wins} hero_tower_actions=0 creep_actions={power_creep}",
                "inspect RunePowerPressure target selection; DD/Haste should usually convert into hero or tower pressure when safe",
            )

        safety_wins = arb_winners.get("safety", 0)
        creep_dmg = side_count(diag, "creep-dmg", side)
        worst_stationary_drop = 0
        for start, end in stationary_spans(samples):
            worst_stationary_drop = max(worst_stationary_drop, start["hp"] - end["hp"])
        if safety_wins >= 5 and (worst_stationary_drop >= 8 or creep_dmg >= 5):
            _add_candidate(
                candidates, 1, side, "arbiter", "medium",
                "safety desire won repeatedly while damage symptoms remained",
                f"safety_wins={safety_wins} stationary_hp_drop={worst_stationary_drop:.0f}% creep_dmg={creep_dmg}",
                "inspect safety action effectiveness and action overwrites; a winning safety desire must visibly move, attack, or disengage",
            )

        if arb_empty >= 3:
            _add_candidate(
                candidates, 2, side, "arbiter", "high",
                "top arbiter winner returned no action",
                f"empty_action={arb_empty} winners={_fmt_counts(arb_winners, 5) or '-'}",
                "fix the winning candidate action contract so it returns false before consuming the tick when it cannot act",
            )

        fwd_events = sum(side_count(diag, k, side) for k in [
            "fwd-position", "fwd-at-position", "fwd-hold",
            "fwd-suppressed-hero", "fwd-suppressed-creep",
            "fwd-suppressed-lowhp", "fwd-suppressed-tower",
        ])
        if fwd_events >= 120:
            _add_candidate(
                candidates, 3, side, "positioning", "medium",
                "forwardness/positioning is still very noisy",
                f"fwd_events={fwd_events}",
                "sample tick-owner around jitter windows; forwardness should yield to creep/hero/tower owners, not be the main activity",
            )

    if players:
        try:
            total_kills = sum(int(p.get("kills") or 0) for p in players[:2])
            hero_damage = [int(p.get("hero_damage") or 0) for p in players[:2]]
        except ValueError:
            total_kills = 0
            hero_damage = []
        if game_s is not None and game_s >= 600 and total_kills <= 1:
            _add_candidate(
                candidates, 3, "ALL", "watchability", "medium",
                "long match with low kill count",
                f"game={game_s:.0f}s kills={total_kills} hero_damage={hero_damage}",
                "treat as config-sensitive: verify chase/execute gates first, then tune matchup aggression if gates are healthy",
            )

    priority_order = {1: 0, 2: 1, 3: 2}
    return sorted(candidates, key=lambda c: (priority_order.get(c["priority"], 99), c["side"], c["area"], c["issue"]))


def print_fix_candidates(candidates, limit=8):
    if not candidates:
        return
    for c in candidates[:limit]:
        print(
            f"  fix_candidate:P{c['priority']}[{c['side']}] "
            f"area={c['area']} confidence={c['confidence']} "
            f"issue=\"{c['issue']}\" evidence=\"{c['evidence']}\" "
            f"recommend=\"{c['recommendation']}\""
        )
    if len(candidates) > limit:
        print(f"  fix_candidate:+{len(candidates) - limit} more")


def print_intent_families(intents):
    for side in ["R", "D"]:
        fam = intent_family_counts(intents, side)
        if fam:
            parts = [f"{k}={v}" for k, v in sorted(fam.items())]
            print(f"  intent_family[{side}]: " + " ".join(parts))


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
    parser.add_argument("--brief", action="store_true",
                        help="Hide raw diag/intent/blocked/timeline sections; keep match summary, alerts, arbiter, and fix candidates")
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
        alerts = alert_symptoms(diag, telemetry, intents, blocked, items, action_events)
        candidates = fix_candidates(diag, telemetry, intents, blocked, items, action_events, players, game_s)

        if args.brief:
            print("  brief: raw diag/intent/blocked/timeline hidden; rerun without --brief for full trace")
        else:
            for key in sorted(diag):
                sides = " ".join(f"{s}#{n}" for s, n in sorted(diag[key].items()))
                print("  diag:", key, sides)
            for name in sorted(intents):
                chunks = []
                for side, entry in sorted(intents[name].items()):
                    last = f" last({entry['last']})" if entry["last"] else ""
                    chunks.append(f"{side}#{entry['count']}{last}")
                print("  intent:", name, " ".join(chunks))
        print_intent_families(intents)
        if not args.brief:
            for name in sorted(blocked):
                chunks = []
                for side, reasons in sorted(blocked[name].items()):
                    reason_bits = []
                    for reason, entry in sorted(reasons.items()):
                        last = f" last({entry['last']})" if entry["last"] else ""
                        reason_bits.append(f"{reason}#{entry['count']}{last}")
                    chunks.append(f"{side}[" + ", ".join(reason_bits) + "]")
                print("  blocked:", name, " ".join(chunks))
        for alert in alerts:
            print("  alert:", alert)
        print_state_metrics(diag, intents)
        print_tower_opportunities(diag, intents, blocked)
        print_arbiter_metrics(intents, blocked, action_events)
        if not args.brief:
            print_debug_tree(diag, intents, blocked, alerts)
        for verdict in verdicts(diag, telemetry):
            print("  verdict:", verdict)
        print_fix_candidates(candidates)
        def _pk(idx, key):
            return int(players[idx].get(key) or 0) if idx < len(players) else 0
        score = (_pk(0, "kills"), _pk(0, "deaths"), _pk(1, "kills"), _pk(1, "deaths"))
        flow = format_flow(extract_deaths(telemetry), dur,
                           max((int(p.get('kills') or 0) for p in players), default=0) >= 2, score)
        if flow:
            print("  flow:", flow)
        if not args.brief:
            for side in ["R", "D"]:
                if timeline.get(side):
                    print(f"  timeline[{side}]: " + " | ".join(timeline[side]))
            for side in ["R", "D"]:
                ft = farm_trace(telemetry.get(side, []))
                if ft:
                    print(f"  farmtrace[{side}]: {ft}")
        for side in ["R", "D"]:
            bs = bottle_summary(telemetry.get(side, []))
            if bs:
                print(f"  bottle[{side}]: {bs}")
        for side in ["R", "D"]:
            spans = stationary_spans(telemetry.get(side, []))
            if spans:
                shown = []
                for start, end in spans[:5]:
                    dur_span = end["t"] - start["t"]
                    shown.append(f"{start['t']:.0f}-{end['t']:.0f}s({dur_span:.0f}s)@{end['loc'][0]:.0f},{end['loc'][1]:.0f}")
                more = f" +{len(spans)-5} more" if len(spans) > 5 else ""
                print(f"  stationary[{side}]: " + "; ".join(shown) + more)
        if pg_locs and not args.brief:
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
