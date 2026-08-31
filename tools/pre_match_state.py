#!/usr/bin/env python3
"""Print the exact repo/live/config state before starting a Dota test match."""

from pathlib import Path
import re
import subprocess

from aibattle_log import DOTA_BOTS_DIR, live_build_sha

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_DIRTY = {
    "bots/Customize/general.lua",
    "bots/Customize/playstyle_radiant.lua",
    "bots/Customize/playstyle_dire.lua",
}


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


def dirty_paths(status_text):
    paths = []
    for line in status_text.splitlines():
        if not line:
            continue
        path = line[2:].strip() if len(line) > 2 else ""
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        paths.append(path.replace("\\", "/"))
    return paths


def main():
    head = git("rev-parse", "--short", "HEAD")
    branch = git("branch", "--show-current")
    upstream = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    dirty = git("status", "--short")
    dirty_list = dirty_paths(dirty)
    unexpected_dirty = [p for p in dirty_list if p not in EXPECTED_DIRTY]
    canonical_dirty = [p for p in dirty_list if "/Customize/canonical_" in p]
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
    print(f"dirty_expected_only: {str(bool(dirty_list) and not unexpected_dirty).lower()}")
    if canonical_dirty:
        print("canonical_dirty: " + ", ".join(canonical_dirty))
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
    if canonical_dirty:
        print("  - canonical configs changed; commit them only if this is the intended strategy under test")
    if unexpected_dirty:
        print("  - inspect unexpected dirty files before the match: " + ", ".join(unexpected_dirty))
    elif dirty:
        print("  - ok with local experiment bindings; do not clean/commit them accidentally")
    if dirty and not dirty_list:
        print("  - commit configs or explicitly record them as a local experiment")
    if live == head and not dirty and not playstyle_drift:
        print("  - ok")


if __name__ == "__main__":
    main()
