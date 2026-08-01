#!/usr/bin/env python3
"""
tools/parse_demo.py  —  Dota 2 Source 2 demo parser (v1)

What it extracts:
  - Match duration and tick info
  - Hero names (from DEM_FileInfo)
  - Abilities/items/modifiers used (from CombatLogNames snapshots)
  - Active modifiers at FullPacket snapshots (buffs/debuffs timeline)
  - AIB bot diagnostic messages (if present in replay)

NOT YET implemented (requires Source 2 bitstream string table decoder):
  - Kill / death events with exact timestamps
  - Hero positions over time
  - Damage per ability
  These are in svc_UpdateStringTable bitstream format (not plain protobuf).

Usage:
  python tools/parse_demo.py <matchid>
  python tools/parse_demo.py <matchid> --debug
  python tools/parse_demo.py C:/path/to/file.dem

Requirements: pip install python-snappy
"""

import sys, struct, re
from pathlib import Path
from collections import defaultdict

from aibattle_log import DOTA_REPLAY_DIR

# ── snappy ────────────────────────────────────────────────────────────────
def decompress(data):
    try:
        import snappy
        return snappy.decompress(data)
    except ImportError:
        raise RuntimeError("Install python-snappy:  pip install python-snappy")

# ── protobuf primitives ────────────────────────────────────────────────────
def varint(buf, pos):
    r, s = 0, 0
    while pos < len(buf):
        b = buf[pos]; pos += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80): return r, pos
        s += 7
    raise EOFError

def pb_iter(buf):
    """Yield (field_no, wire_type, value, end_pos) for every field in a protobuf blob."""
    pos = 0
    while pos < len(buf):
        try:
            tag, pos = varint(buf, pos)
            wire = tag & 7; fn = tag >> 3
            if wire == 0:
                v, pos = varint(buf, pos);            yield fn, 0, v, pos
            elif wire == 1:
                v = buf[pos:pos+8]; pos += 8;         yield fn, 1, v, pos
            elif wire == 2:
                n, pos = varint(buf, pos)
                v = bytes(buf[pos:pos+n]); pos += n;  yield fn, 2, v, pos
            elif wire == 5:
                v = buf[pos:pos+4]; pos += 4;         yield fn, 5, v, pos
            else:
                break
        except (EOFError, IndexError, OverflowError, struct.error):
            break

def pb_get(buf, fn_target):
    """Return first occurrence of field fn_target, or None."""
    for fn, wt, v, _ in pb_iter(buf):
        if fn == fn_target:
            return v
    return None

def pb_getall(buf, fn_target):
    return [v for fn, wt, v, _ in pb_iter(buf) if fn == fn_target]

# ── Source 2 demo constants ────────────────────────────────────────────────
DEM_COMPRESSED   = 0x40
DEM_FileHeader   = 1
DEM_FileInfo     = 2
DEM_SyncTick     = 3
DEM_SendTables   = 4
DEM_ClassInfo    = 5
DEM_StringTables = 6
DEM_Packet       = 7
DEM_SignonPacket = 8
DEM_FullPacket   = 13

# ── Demo frame reader ──────────────────────────────────────────────────────
def iter_frames(raw):
    if raw[:8] != b"PBDEMS2\x00":
        raise ValueError("Not a Source 2 demo (wrong magic bytes)")
    pos = 16
    while pos < len(raw) - 6:
        try:
            kind_raw, pos = varint(raw, pos)
            tick_u,   pos = varint(raw, pos)
            size,     pos = varint(raw, pos)
        except EOFError:
            break
        compressed = bool(kind_raw & DEM_COMPRESSED)
        kind = kind_raw & ~DEM_COMPRESSED
        data = bytes(raw[pos:pos+size]); pos += size
        tick = tick_u if tick_u < 0x80000000 else -1
        if compressed:
            try: data = decompress(data)
            except: continue
        yield kind, tick, data

# ── Inner message iterator ─────────────────────────────────────────────────
def iter_inner(packet_pb):
    """Extract (mtype, mdata) pairs from CDemoPacket field-3 data."""
    inner = pb_get(packet_pb, 3)
    if not inner: return
    pos = 0
    while pos < len(inner) - 2:
        try:
            mtype, pos = varint(inner, pos)
            msize, pos = varint(inner, pos)
            mdata = inner[pos:pos+msize]; pos += msize
            yield mtype, mdata
        except:
            break

# ── String table state ─────────────────────────────────────────────────────
class StringTables:
    def __init__(self):
        self._tables = {}

    def ingest_full(self, frame_data):
        """Parse CDemoStringTables (from DEM_StringTables frame or FullPacket field-1)."""
        for fn, wt, v, _ in pb_iter(frame_data):
            if fn != 1 or wt != 2: continue
            name_raw = pb_get(v, 1)
            if not name_raw: continue
            name = name_raw.decode('utf-8', errors='replace')
            items = pb_getall(v, 2)
            strings = []
            for item in items:
                s = pb_get(item, 1)
                strings.append(s.decode('utf-8', errors='replace') if s else "")
            self._tables[name] = strings

    def get(self, name):
        return self._tables.get(name, [])

# ── Hero info from DEM_FileInfo ────────────────────────────────────────────
def parse_fileinfo(data):
    """Extract readable strings from CDemoFileInfo."""
    results = []
    cur = ''
    for b in data:
        c = chr(b)
        if c.isprintable() and b >= 32:
            cur += c
        else:
            if len(cur) >= 4: results.append(cur)
            cur = ''
    if cur: results.append(cur)
    return results

# ── Main analysis ──────────────────────────────────────────────────────────
REPLAY_DIR = DOTA_REPLAY_DIR
TICK_RATE = 30

def find_demo(match_id):
    p = REPLAY_DIR / f"{match_id}.dem"
    if p.exists(): return p
    userdata = Path("C:/Program Files (x86)/Steam/userdata")
    if userdata.exists():
        for p2 in userdata.rglob(f"{match_id}.dem"):
            return p2
    return None

def tick_to_str(t):
    if t < 0: return f"pre-{abs(t):.0f}s"
    m, s = divmod(int(t), 60)
    return f"{m}:{s:02d}" if m else f"+{s}s"

def analyze(path, debug=False):
    print(f"\n{'='*60}")
    print(f"Demo: {path.name}")
    raw = path.read_bytes()
    print(f"Size: {len(raw)//1024} KB\n")

    # State
    st_initial = StringTables()   # from DEM_StringTables (initial signon)
    fp_snapshots = []              # (tick, StringTables) from DEM_FullPacket
    fileinfo_strings = []
    aib_messages = []
    max_tick = 0
    mtype_counts = defaultdict(int)

    for kind, tick, data in iter_frames(raw):
        if tick > 0: max_tick = max(max_tick, tick)

        if kind == DEM_FileInfo:
            fileinfo_strings = parse_fileinfo(data)

        elif kind == DEM_StringTables:
            st_initial.ingest_full(data)

        elif kind == DEM_FullPacket:
            st_fp = StringTables()
            for fn, wt, v, _ in pb_iter(data):
                if fn == 1 and isinstance(v, bytes):
                    st_fp.ingest_full(v)
            fp_snapshots.append((tick, st_fp))
            # Also scan inner messages of field-2 (CDemoPacket)
            for fn, wt, v, _ in pb_iter(data):
                if fn == 2 and isinstance(v, bytes):
                    for mtype, mdata in iter_inner(v):
                        mtype_counts[mtype] += 1
                        if b"AIB[" in mdata:
                            chunk = mdata[mdata.find(b"AIB["):mdata.find(b"AIB[")+160]
                            text = ''.join(c for c in chunk.decode('utf-8', errors='replace') if c >= ' ')[:120]
                            aib_messages.append((tick, tick/TICK_RATE, text))

        elif kind in (DEM_Packet, DEM_SignonPacket):
            for mtype, mdata in iter_inner(data):
                mtype_counts[mtype] += 1
                if b"AIB[" in mdata:
                    chunk = mdata[mdata.find(b"AIB["):mdata.find(b"AIB[")+160]
                    text = ''.join(c for c in chunk.decode('utf-8', errors='replace') if c >= ' ')[:120]
                    aib_messages.append((tick, tick/TICK_RATE, text))

    # Use last FullPacket snapshot for richest data
    last_st = fp_snapshots[-1][1] if fp_snapshots else st_initial
    last_tick = fp_snapshots[-1][0] if fp_snapshots else max_tick

    # ── Duration ──────────────────────────────────────────────────────────
    total_s = max_tick / TICK_RATE
    # 1v1 pregame is ~90s before DotaTime=0
    PREGAME_EST = 90
    match_s = max(0, total_s - PREGAME_EST)
    print(f"Total demo time : {total_s:.1f}s  ({total_s/60:.1f} min)")
    print(f"Match time (est): {match_s:.1f}s  ({match_s/60:.1f} min)  [total - {PREGAME_EST}s pregame]")
    print(f"Ticks           : {max_tick}  @  {TICK_RATE} ticks/s")
    print(f"FullPacket snaps: {len(fp_snapshots)}  at ticks {[t for t,_ in fp_snapshots]}")

    # ── Heroes ────────────────────────────────────────────────────────────
    hero_names = [s for s in fileinfo_strings if 'npc_dota_hero' in s]
    print(f"\n── HEROES (from DEM_FileInfo) ─────────────────────────────")
    if hero_names:
        for h in set(hero_names):
            print(f"  {h}")
    else:
        print("  (not found)")

    # ── CombatLogNames ────────────────────────────────────────────────────
    cl_names = last_st.get("CombatLogNames")
    if cl_names:
        print(f"\n── COMBAT LOG NAMES ({len(cl_names)} entries @ tick {last_tick}) ──")
        categories = defaultdict(list)
        for i, n in enumerate(cl_names):
            if not n: continue
            if n.startswith("npc_dota_hero"):         categories["heroes"].append((i, n))
            elif n.startswith("item_"):                categories["items"].append((i, n))
            elif n.startswith("modifier_"):            categories["modifiers"].append((i, n))
            elif any(n.startswith(h.split('_hero_')[1]) for h in hero_names if '_hero_' in h):
                categories["abilities"].append((i, n))
            elif n.startswith("npc_"):                 categories["units"].append((i, n))
            else:                                      categories["other"].append((i, n))
        for cat, items in categories.items():
            print(f"  {cat}: {', '.join(n for _,n in items)}")

    # ── Active modifiers at each snapshot ────────────────────────────────
    print(f"\n── ACTIVE MODIFIERS AT SNAPSHOTS ──────────────────────────")
    modifier_names = last_st.get("ModifierNames")  # full list, rarely useful
    for fp_tick, fp_st in fp_snapshots:
        active = fp_st.get("ActiveModifiers")
        relevant = [m for m in active if m and ('nevermore' in m or 'hero' in m or 'flask' in m or 'tango' in m)]
        t_s = fp_tick / TICK_RATE - PREGAME_EST
        print(f"  tick={fp_tick} ({tick_to_str(t_s)}): {len(active)} active modifiers")
        for m in relevant[:8]:
            print(f"    {m}")

    # ── AIB diagnostics ───────────────────────────────────────────────────
    if aib_messages:
        print(f"\n── AIB DIAGNOSTICS ({len(aib_messages)}) ──────────────────────────────")
        for tick, t, msg in sorted(set(aib_messages)):
            t_adj = t - PREGAME_EST
            print(f"  [{tick_to_str(t_adj):>8s}]  {msg}")
    else:
        print(f"\n── AIB DIAGNOSTICS: 0 found ─────────────────────────────")
        print("  Bot diagnostic chat (AIB[...]) is not stored in local replays.")
        print("  Use match_stats.py <id> for console-log based analysis.")

    # ── Note on combat log ────────────────────────────────────────────────
    print(f"\n── NOTE ─────────────────────────────────────────────────────")
    print("  Kill/death events are in svc_UpdateStringTable bitstream format")
    print("  (Source 2 custom bitstream, not plain protobuf).")
    print("  Implementing the bitstream decoder is TODO for parse_demo.py v2.")

    # ── Debug ─────────────────────────────────────────────────────────────
    if debug:
        print(f"\n── DEBUG: ALL STRING TABLES (last FullPacket) ───────────")
        for name, entries in last_st._tables.items():
            ne = [e for e in entries if e]
            print(f"  {name:40s}  {len(entries):4d} total  {len(ne):4d} non-empty")
        print(f"\n── DEBUG: INNER MESSAGE TYPE COUNTS (top 30) ─────────────")
        for mt, cnt in sorted(mtype_counts.items(), key=lambda x: -x[1])[:30]:
            print(f"  type={mt:8d}  count={cnt}")

    print()


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(0)

    debug = "--debug" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__); sys.exit(0)

    arg = args[0]
    if re.fullmatch(r'\d+', arg):
        path = find_demo(arg)
        if not path:
            print(f"Demo not found for match {arg}")
            print(f"Expected: {REPLAY_DIR}/{arg}.dem")
            sys.exit(1)
    else:
        path = Path(arg)
        if not path.exists():
            print(f"File not found: {path}"); sys.exit(1)

    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    analyze(path, debug=debug)


if __name__ == "__main__":
    main()
