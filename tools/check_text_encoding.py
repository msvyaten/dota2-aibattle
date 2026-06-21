#!/usr/bin/env python3
"""Check repo text for common mojibake and risky non-ASCII in active code files."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {".lua", ".md", ".py", ".txt", ".bat", ".sh"}
SKIP_DIRS = {".git", "__pycache__", "node_modules"}
MOJIBAKE_MARKERS = [
    "\ufffd",  # replacement char
    "\u00d0",  # D0, common Cyrillic mojibake lead
    "\u00d1",  # D1, common Cyrillic mojibake lead
    "\u00c3",  # Latin-1 mojibake lead
    "\u00e2",  # punctuation mojibake lead
]

# These are the files we actively edit/deploy for AIBattle. Keep them ASCII-only
# so Windows console output and quick reviews do not turn comments into noise.
ASCII_ONLY_PREFIXES = (
    Path("bots/FunLib/aibattle_"),
    Path("bots/mode_laning_generic.lua"),
    Path("tools/match_stats.py"),
    Path("tools/check_text_encoding.py"),
    Path("README.md"),
)


def iter_text_files():
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
            yield path, rel


def is_ascii_only(rel):
    rel_text = rel.as_posix()
    for prefix in ASCII_ONLY_PREFIXES:
        prefix_text = prefix.as_posix()
        if rel_text == prefix_text or rel_text.startswith(prefix_text):
            return True
    return False


def main():
    issues = []
    for path, rel in iter_text_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        for line_no, line in enumerate(text.splitlines(), 1):
            if any(marker in line for marker in MOJIBAKE_MARKERS):
                issues.append((rel, line_no, "mojibake-marker", line))
            if is_ascii_only(rel) and any(ord(ch) > 127 for ch in line):
                issues.append((rel, line_no, "non-ascii-active-code", line))

    for rel, line_no, kind, line in issues[:200]:
        preview = line.encode("unicode_escape").decode("ascii")[:180]
        print(f"{rel}:{line_no}: {kind}: {preview}")
    if len(issues) > 200:
        print(f"... {len(issues) - 200} more issues")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
