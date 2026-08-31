"""Shared paths and parsers for AIBattle console telemetry."""

from __future__ import annotations

import os
import re
from pathlib import Path
from collections import Counter


DEFAULT_DOTA_DIR = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota"
)
DOTA_LOG_DIR = Path(os.environ.get("DOTA_LOG_DIR", DEFAULT_DOTA_DIR))
DOTA_BOTS_DIR = Path(os.environ.get("DOTA_BOTS_DIR", DOTA_LOG_DIR / "scripts/vscripts/bots"))
DOTA_REPLAY_DIR = Path(os.environ.get("DOTA_REPLAY_DIR", DOTA_LOG_DIR / "replays"))
DOTA_ITEMBUILDS_DIR = Path(os.environ.get("DOTA_ITEMBUILDS_DIR", DOTA_LOG_DIR / "itembuilds"))

TELEMETRY_RE = re.compile(
    r"AIB\[([RD])\]\s+t=([\d.]+)s\s+hp=([\d.]+)%\s+gold=(\d+)\s+"
    r"loc=([-\d.]+),([-\d.]+)(?:\s+enemy-dist=([\d.]+))?"
    r"(?:\s+lh=(-?\d+))?(?:\s+dn=(-?\d+))?(?:\s+dg=([+-]?\d+))?(?:\s+dlh=([+-]?\d+))?"
    r"(?:\s+bottle=(-?\d+))?(?:\s+lvl=(-?\d+))?(?:\s+front=(-?\d+))?(?:\s+ehp=(-?\d+))?"
)


def extract_telemetry(text: str):
    """Return rich, time-sorted periodic reports for both sides."""
    telemetry = {"R": [], "D": []}
    for side, t, hp, gold, x, y, enemy_dist, lh, dn, dg, dlh, bottle, lvl, front, ehp in TELEMETRY_RE.findall(text):
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
            "bottle": int(bottle) if bottle else None,
            "lvl": int(lvl) if lvl else None,
            "front": int(front) if front else None,
            "ehp": int(ehp) if ehp else None,
        })
    for samples in telemetry.values():
        samples.sort(key=lambda sample: sample["t"])
        earned = 0
        for sample in samples:
            earned += max(sample.get("dg") or 0, 0)
            sample["earned"] = earned
    return telemetry


def latest_match_id():
    candidates = []
    for path in DOTA_LOG_DIR.glob("console.*.log"):
        match = re.fullmatch(r"console\.(\d+)\.log", path.name)
        if match:
            candidates.append((path.stat().st_mtime, int(match.group(1))))
    return str(max(candidates)[1]) if candidates else None


def live_build_sha():
    path = DOTA_BOTS_DIR / "FunLib" / "aibattle_build.lua"
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    match = re.search(r'sha\s*=\s*"([^"]+)"', text)
    return match.group(1) if match else None


def find_log(value):
    """Resolve a path, console filename, or bare match id."""
    direct = Path(value)
    if direct.is_file():
        return direct
    name = str(value) if str(value).startswith("console.") else f"console.{value}.log"
    for root in (Path.cwd(), Path.cwd() / "logs", DOTA_LOG_DIR):
        path = root / name
        if path.is_file():
            return path
    return None


def aib_lines(text: str, side: str | None = None):
    """Yield parsed AIB chat payloads from a console log."""
    pattern = re.compile(r"'AIB\[([RD])\]\s+([^']*)'")
    for match in pattern.finditer(text):
        row_side, payload = match.groups()
        if side is not None and row_side != side:
            continue
        yield row_side, payload


def field_counts(text: str, name: str, side: str, field: str) -> Counter:
    """Count `field=value` on AIB intent lines with a given intent name."""
    out: Counter = Counter()
    needle = f"intent={name}"
    field_re = re.compile(r"\b%s=([A-Za-z0-9_.-]+)" % re.escape(field))
    for _side, payload in aib_lines(text, side):
        if needle not in payload:
            continue
        m = field_re.search(payload)
        if m:
            out[m.group(1)] += 1
    return out


def blocked_reason_counts(text: str, name: str, side: str) -> Counter:
    """Count `blocked=<name> reason=<reason>` telemetry."""
    out: Counter = Counter()
    prefix = f"blocked={name}"
    reason_re = re.compile(r"\breason=([A-Za-z0-9_.-]+)")
    for _side, payload in aib_lines(text, side):
        if prefix not in payload:
            continue
        m = reason_re.search(payload)
        if m:
            out[m.group(1)] += 1
    return out


def rune_bottle_summary(text: str, side: str) -> dict[str, object]:
    """Summarize the bottle-rune transaction without interpreting gameplay."""
    tx_phase = field_counts(text, "rune-transaction", side, "phase")
    tx_source = field_counts(text, "rune-transaction", side, "source")
    results = field_counts(text, "rune-result", side, "result")
    result_source = field_counts(text, "rune-result", side, "source")
    blocks = Counter()
    for name in ("bottle-rune", "recovery-rune-bottle"):
        for reason, count in blocked_reason_counts(text, name, side).items():
            blocks[f"{name}:{reason}"] += count
    return {
        "phase": tx_phase,
        "source": tx_source,
        "result": results,
        "result_source": result_source,
        "blocked": blocks,
    }
