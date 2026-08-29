#!/usr/bin/env python3
"""Print the exact repo/live/config state before starting a Dota test match."""

from pathlib import Path
import re
import subprocess

from aibattle_log import DOTA_BOTS_DIR, live_build_sha

ROOT = Path(__file__).resolve().parents[1]


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
    return live_build_sha() or "missing"


def playstyle(side):
    return read_playstyle(ROOT / "bots" / "Customize" / f"playstyle_{side}.lua")


def read_playstyle(path):
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r"Customize/(canonical_[A-Za-z0-9_]+)", text)
    return match.group(1) if match else "custom/unknown"


def live_playstyle(side):
    return read_playstyle(DOTA_BOTS_DIR / "Customize" / f"playstyle_{side}.lua")


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
    repo_radiant = playstyle("radiant")
    repo_dire = playstyle("dire")
    live_radiant = live_playstyle("radiant")
    live_dire = live_playstyle("dire")
    playstyle_drift = repo_radiant != live_radiant or repo_dire != live_dire

    print(f"radiant: {repo_radiant} (live {live_radiant})")
    print(f"dire:    {repo_dire} (live {live_dire})")
    print(f"live_playstyles_match_repo: {str(not playstyle_drift).lower()}")
    print("dirty:")
    if dirty:
        for line in dirty.splitlines():
            print(f"  {line}")
    else:
        print("  clean")
    print("before match:")
    if live != head:
        print("  - deploy code or explicitly record that this match uses a custom live marker")
    if playstyle_drift:
        print("  - sync live playstyle bindings back to repo, or deploy the repo bindings")
    if dirty:
        print("  - commit configs or explicitly record them as a local experiment")
    if live == head and not dirty and not playstyle_drift:
        print("  - ok")


if __name__ == "__main__":
    main()
