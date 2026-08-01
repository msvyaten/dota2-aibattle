#!/usr/bin/env python3
"""Print a reproducible size and ownership inventory for the AIBattle layer."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
ACTION_RE = re.compile(r"\bAction_(?:MoveToLocation|MoveToUnit|AttackUnit)\s*\(")
STATE_WRITE_RE = re.compile(r"\bbot\.(aib_[A-Za-z0-9_]+)\s*=(?!=)")
LOCAL_FUNCTION_RE = re.compile(r"\blocal\s+function\s+([A-Za-z_][A-Za-z0-9_]*)")


def line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="ignore").splitlines())


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def source_stats(paths: list[Path]) -> dict[str, object]:
    rows = [{"path": rel(path), "lines": line_count(path)} for path in paths]
    rows.sort(key=lambda row: (-int(row["lines"]), str(row["path"])))
    return {"files": len(rows), "lines": sum(int(row["lines"]) for row in rows), "largest": rows[:10]}


def runtime_paths() -> list[Path]:
    paths = list((ROOT / "bots" / "FunLib").glob("aibattle_*.lua"))
    paths.extend(
        ROOT / "bots" / name
        for name in (
            "mode_laning_generic.lua",
            "mode_roam_generic.lua",
            "mode_retreat_generic.lua",
            "ability_item_usage_generic.lua",
            "item_purchase_generic.lua",
        )
    )
    return sorted(path for path in paths if path.exists())


def build_inventory() -> dict[str, object]:
    aibattle = sorted((ROOT / "bots" / "FunLib").glob("aibattle_*.lua"))
    tools = sorted((ROOT / "tools").glob("*.py"))
    backend = sorted((ROOT / "backend").glob("*.py"))
    active_docs = sorted(
        path for path in (ROOT / "docs").rglob("*.md")
        if "history" not in path.relative_to(ROOT / "docs").parts
    )
    archived_docs = sorted((ROOT / "docs" / "history").rglob("*.md"))
    runtime = runtime_paths()

    action_sites = []
    dead_local_helpers = []
    state_owners: dict[str, set[str]] = defaultdict(set)
    state_writes: dict[str, int] = defaultdict(int)
    for path in runtime:
        source = path.read_text(encoding="utf-8", errors="ignore")
        for name in LOCAL_FUNCTION_RE.findall(source):
            if len(re.findall(rf"\b{re.escape(name)}\b", source)) == 1:
                dead_local_helpers.append({"path": rel(path), "name": name})
        for lineno, line in enumerate(source.splitlines(), 1):
            if ACTION_RE.search(line):
                action_sites.append({"path": rel(path), "line": lineno})
            for key in STATE_WRITE_RE.findall(line):
                state_owners[key].add(rel(path))
                state_writes[key] += 1

    shared_state = [
        {"key": key, "writes": state_writes[key], "files": sorted(files)}
        for key, files in state_owners.items()
        if len(files) > 1
    ]
    shared_state.sort(key=lambda row: (-len(row["files"]), -int(row["writes"]), str(row["key"])))

    return {
        "aibattle_lua": source_stats(aibattle),
        "runtime_surface": source_stats(runtime),
        "tools_python": source_stats(tools),
        "backend_python": source_stats(backend),
        "active_docs": source_stats(active_docs),
        "archived_docs": source_stats(archived_docs),
        "direct_action_sites": len(action_sites),
        "dead_local_helpers": dead_local_helpers,
        "cross_file_state_writers": shared_state,
    }


def print_human(data: dict[str, object]) -> None:
    for key in (
        "aibattle_lua", "runtime_surface", "tools_python", "backend_python",
        "active_docs", "archived_docs",
    ):
        section = data[key]
        print(f"{key}: {section['files']} files, {section['lines']} lines")
        for row in section["largest"][:5]:
            print(f"  {row['lines']:>5}  {row['path']}")
    print(f"direct_action_sites: {data['direct_action_sites']}")
    dead = data["dead_local_helpers"]
    print(f"dead_local_helpers: {len(dead)}")
    for row in dead:
        print(f"  {row['path']}: {row['name']}")
    shared = data["cross_file_state_writers"]
    print(f"cross_file_state_writers: {len(shared)}")
    for row in shared[:15]:
        print(f"  {row['key']}: {row['writes']} writes in {', '.join(row['files'])}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--check", action="store_true", help="scan quietly for use in check_all")
    args = parser.parse_args()
    data = build_inventory()
    if args.check:
        print(
            "[ok] project inventory: "
            f"{data['aibattle_lua']['files']} AIBattle Lua files, "
            f"{data['direct_action_sites']} direct action sites, "
            f"{len(data['dead_local_helpers'])} dead local helpers"
        )
    elif args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_human(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
