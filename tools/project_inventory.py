#!/usr/bin/env python3
"""Print a reproducible size and ownership inventory for the AIBattle layer."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ACTION_RE = re.compile(r"\bAction_(?:MoveToLocation|MoveToUnit|AttackUnit)\s*\(")
STATE_WRITE_RE = re.compile(r"\bbot\.(aib_[A-Za-z0-9_]+)\s*=(?!=)")
LOCAL_FUNCTION_RE = re.compile(r"\blocal\s+function\s+([A-Za-z_][A-Za-z0-9_]*)")


def line_count(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="ignore").splitlines())


# CODE_MAP.md is the reading map a reviewer starts from: every table row carries a file and the
# size it claims. Nothing was checking those numbers, and 24 of the 44 had drifted -- by +83 on
# aibattle_laning_safety.lua and -56 on binding.py -- so the first thing an outside reader
# measured was wrong. A size that lies is worse than no size: it is what decides whether someone
# opens the file at all. The doc-size limits in check_all guard how long the docs are; this
# guards what they claim about the code.
CODE_MAP = ROOT / "docs" / "CODE_MAP.md"
CODE_MAP_ROW_RE = re.compile(r"\|\s*`([A-Za-z0-9_.]+\.(?:lua|py))`\s*\|\s*(\d+)\s*\|")


def resolve_mapped_file(name: str) -> Path | None:
    for candidate in (ROOT / "tools" / name, ROOT / "bots" / "FunLib" / name,
                      ROOT / "bots" / name, ROOT / name):
        if candidate.is_file():
            return candidate
    hits = [h for h in ROOT.rglob(name) if "archive" not in h.parts and ".git" not in h.parts]
    return hits[0] if hits else None


def code_map_drift() -> list[tuple[str, int, int]]:
    """Rows in CODE_MAP whose claimed line count no longer matches the file."""
    if not CODE_MAP.is_file():
        return []
    drift = []
    for name, claimed in CODE_MAP_ROW_RE.findall(CODE_MAP.read_text(encoding="utf-8", errors="ignore")):
        path = resolve_mapped_file(name)
        if path is None:
            continue
        real = line_count(path)
        if real != int(claimed):
            drift.append((name, int(claimed), real))
    return drift


# Checking the numbers on the rows that exist says nothing about the rows that do not. The first
# version of this check passed while CODE_MAP was missing five tools outright -- series.py, which
# is what keeps a side effect from masquerading as a model effect, and pre_match_state.py, which
# every session is told to run first among them. The scope of a check is part of its answer.
# The dead-helper scan below only ever looked at `local function`. An exported `M.Name` that
# nothing calls is just as dead and more misleading, because it reads as public API. Two were
# sitting there: M.PublicFamilies copied a local list, M.ItemCost forwarded to a local one line
# above it, and neither was mentioned anywhere else in the tree.
#
# Detection is by MENTION, not by call site. The obvious `[.:]Name\s*\(` pattern reported two
# live functions as dead -- GetItemRules and EvalItemCondition are handed to pcall by reference
# in item_purchase_generic.lua and never appear next to an opening paren. A check that produces
# false positives on live code would be turned off within a week.
def dead_exported_functions() -> list[tuple[str, str]]:
    """Exported `M.Name` in the AIBattle layer that nothing anywhere mentions."""
    corpus = []
    for folder, pattern in ((ROOT / "bots", "**/*.lua"), (ROOT / "tools", "*.py"),
                            (ROOT / "backend", "*.py"), (ROOT / "docs", "*.md")):
        if not folder.is_dir():
            continue
        for path in folder.glob(pattern):
            if "archive" in path.parts:
                continue
            corpus.append(path.read_text(encoding="utf-8", errors="ignore"))
    joined = "\n".join(corpus)
    dead = []
    for path in sorted((ROOT / "bots" / "FunLib").glob("aibattle_*.lua")):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for name in re.findall(r"^function M\.([A-Za-z_][A-Za-z0-9_]*)", text, re.M):
            if len(re.findall(r"\b%s\b" % re.escape(name), joined)) <= 1:
                dead.append((path.name, name))
    return dead


# The scale table at the top of CODE_MAP is the first thing a reader meets, and every number in
# it was wrong: the AIBattle layer read 7,829 against 8,072, tools 5,115 against 5,484, and the
# backend 359 against 720 -- off by a factor of two. Docs carry ~10x the correction rate of the
# bot code in this repo's history (5 of 37 BACKLOG edits against 2 of 166 for the orchestrator),
# and until today every doc gate checked form -- line budgets, encoding -- and none checked
# whether a claim was true. This one does, for the claims that are mechanically checkable.
#
# Rows are found by their label, so renaming one fails loudly instead of silently unhooking the
# check. Numbers written with a leading ~ are approximations by intent and are left alone.
# Every row sums TRACKED files, for the same reason code_map_missing_tools does: an untracked
# scratch file must not fail this gate for work that never touched it. Fixing only the other
# check left the same false positive standing behind a different door -- a scratch script in
# tools/ still reddened the build through this table.
CODE_MAP_SCALE_ROWS = {
    "Our layer": lambda: tracked_line_count("bots/FunLib/aibattle_*.lua"),
    "Configs": lambda: tracked_line_count("bots/Customize/*.lua"),
    "Tools (Python)": lambda: tracked_line_count("tools/*.py"),
    "Backend": lambda: tracked_line_count("backend/*.py") + tracked_line_count("backend/*.txt"),
}


def code_map_scale_drift() -> list[str]:
    """Claims in CODE_MAP's scale table that no longer match the tree."""
    if not CODE_MAP.is_file():
        return []
    text = CODE_MAP.read_text(encoding="utf-8", errors="ignore")
    problems = []
    for label, compute in CODE_MAP_SCALE_ROWS.items():
        row = re.search(r"^\|[^|\n]*%s[^|\n]*\|\s*\*{0,2}([\d,~]+)\*{0,2}\s*\|" % re.escape(label),
                        text, re.M)
        if row is None:
            problems.append(f"the '{label}' row is gone from the scale table")
            continue
        claimed_text = row.group(1)
        if claimed_text.startswith("~"):
            continue
        claimed = int(claimed_text.replace(",", ""))
        real = compute()
        if claimed != real:
            problems.append(f"'{label}' says {claimed:,}, the tree has {real:,}")
    return problems


def tracked_files(pathspec: str) -> list[Path]:
    """Files git tracks under `pathspec`. Falls back to a glob outside a work tree."""
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files", pathspec],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return sorted(ROOT.glob(pathspec))
    return [ROOT / line for line in out.split() if line]


def tracked_line_count(pathspec: str) -> int:
    return sum(line_count(p) for p in tracked_files(pathspec) if p.is_file())


def tracked_tools() -> list[Path]:
    """Tools git knows about.

    Deliberately not a filesystem glob. Globbing meant an untracked scratch file left in tools/
    failed this gate for everyone, on every commit, including work that never touched it -- and a
    gate that blocks unrelated work is a gate somebody switches off. Only committed tools are the
    project's to document.
    """
    return tracked_files("tools/*.py")


def code_map_missing_tools() -> list[str]:
    """Tools under tools/ that CODE_MAP does not mention at all."""
    if not CODE_MAP.is_file():
        return []
    text = CODE_MAP.read_text(encoding="utf-8", errors="ignore")
    return [p.name for p in sorted(tracked_tools()) if f"`{p.name}`" not in text]


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
        orphans = dead_exported_functions()
        if orphans:
            print("[fail] exported functions nothing mentions:")
            for file_name, func in orphans:
                print(f"    {file_name}: M.{func}")
            print("    call it, or delete it -- a public name with no caller reads as API")
            return 1
        drift = code_map_drift()
        missing = code_map_missing_tools()
        scale = code_map_scale_drift()
        if drift or missing or scale:
            print("[fail] CODE_MAP.md no longer matches the tree:")
            for name, claimed, real in drift:
                print(f"    {name}: says {claimed}, file has {real}")
            for name in missing:
                print(f"    {name}: exists in tools/ but CODE_MAP does not mention it")
            for problem in scale:
                print(f"    scale table: {problem}")
            print("    fix docs/CODE_MAP.md -- a reviewer picks what to open by that table")
            return 1
        print(
            "[ok] project inventory: "
            f"{data['aibattle_lua']['files']} AIBattle Lua files, "
            f"{data['direct_action_sites']} direct action sites, "
            f"{len(data['dead_local_helpers'])} dead local helpers, "
            "CODE_MAP sizes match"
        )
    elif args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_human(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
