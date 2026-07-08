#!/usr/bin/env python3
"""Print the exact repo/live/config state before starting a Dota test match."""

from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DOTA_BOTS_DIR = Path(r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots")


def git(*args):
    result = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        return "ERR: " + result.stderr.strip()
    return result.stdout.strip()


def live_build():
    path = DOTA_BOTS_DIR / "FunLib" / "aibattle_build.lua"
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r'sha\s*=\s*"([^"]+)"', text)
    return match.group(1) if match else "unknown"


def playstyle(side):
    path = ROOT / "bots" / "Customize" / f"playstyle_{side}.lua"
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r"Customize/(canonical_[A-Za-z0-9_]+)", text)
    return match.group(1) if match else "custom/unknown"


def main():
    head = git("rev-parse", "--short", "HEAD")
    branch = git("branch", "--show-current")
    upstream = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    dirty = git("status", "--short")
    live = live_build()

    print("===== pre-match state =====")
    print(f"branch: {branch}")
    print(f"head:   {head}")
    print(f"upstream: {upstream}")
    print(f"live:   {live}")
    print(f"live_matches_head: {str(live == head).lower()}")
    print(f"radiant: {playstyle('radiant')}")
    print(f"dire:    {playstyle('dire')}")
    print("dirty:")
    if dirty:
        for line in dirty.splitlines():
            print(f"  {line}")
    else:
        print("  clean")
    print("before match:")
    if live != head:
        print("  - deploy code or explicitly record that this match uses a custom live marker")
    if dirty:
        print("  - commit configs or explicitly record them as a local experiment")
    if live == head and not dirty:
        print("  - ok")


if __name__ == "__main__":
    main()
