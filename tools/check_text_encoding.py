#!/usr/bin/env python3
"""Check repo text for mojibake, risky non-ASCII in active code, and stray Cyrillic.

Three rules, narrowest first:

1. mojibake markers        -- everywhere
2. ASCII-only              -- the files we deploy, where a Windows console reads the output
3. no Cyrillic             -- everywhere except an explicit allowlist

Rule 3 exists because this repository is reviewed by people who do not read Russian. The
allowlist has exactly two members: vendored user-facing localisation, which is upstream's and
must not be touched, and the Russian working notes under docs/, which are deliberately kept in
Russian for the original authors. Anything else in Cyrillic is a leak, not a decision.

The queue left that second group on 2026-08-30. A reviewer sent to English documents while the
list of what is pending -- and the signature each pending edit is judged by -- exists only in
Russian is not being given optional background; they are being given a shop window.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TEXT_SUFFIXES = {".lua", ".md", ".py", ".txt", ".bat", ".sh"}
SKIP_DIRS = {".git", "__pycache__", "node_modules", ".pytest_cache"}
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
    Path("NOTICE.md"),
)

# Cyrillic is allowed here and nowhere else.
#
#   - bots/FretBots/, localization.lua, aba_chat_table.lua: vendored OHA localisation
#     (ru/zh/ja strings shown to players). Upstream's; do not edit.
#   - docs/SPECS.md, docs/history/: Russian working notes, kept on purpose. BACKLOG.md left
#     this list on 2026-08-30: the reviewer is English and the queue is what tells them what
#     is pending and how it will be judged, so it cannot be optional background.
#     README.md "Language" says so; CODE_MAP.md section 7 marks them RU in the reading table.
#   - archive/dota/local_automation/: gitignored one-off desktop automation, never shipped.
CYRILLIC_ALLOWED_PREFIXES = (
    Path("bots/FretBots/"),
    Path("bots/FunLib/localization.lua"),
    Path("bots/FunLib/aba_chat_table.lua"),
    Path("docs/SPECS.md"),
    Path("docs/history/"),
    Path("archive/dota/local_automation/"),
)


def iter_text_files():
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
            yield path, rel


def matches_prefix(rel, prefixes):
    rel_text = rel.as_posix()
    for prefix in prefixes:
        prefix_text = prefix.as_posix()
        if rel_text == prefix_text or rel_text.startswith(prefix_text):
            return True
    return False


def has_cyrillic(line):
    return any("\u0400" <= ch <= "\u04ff" for ch in line)


def main():
    issues = []
    for path, rel in iter_text_files():
        text = path.read_text(encoding="utf-8", errors="replace")
        ascii_only = matches_prefix(rel, ASCII_ONLY_PREFIXES)
        cyrillic_ok = matches_prefix(rel, CYRILLIC_ALLOWED_PREFIXES)
        for line_no, line in enumerate(text.splitlines(), 1):
            if any(marker in line for marker in MOJIBAKE_MARKERS):
                issues.append((rel, line_no, "mojibake-marker", line))
            if ascii_only and any(ord(ch) > 127 for ch in line):
                issues.append((rel, line_no, "non-ascii-active-code", line))
            if not cyrillic_ok and has_cyrillic(line):
                issues.append((rel, line_no, "cyrillic-outside-allowlist", line))

    for rel, line_no, kind, line in issues[:200]:
        preview = line.encode("unicode_escape").decode("ascii")[:180]
        print(f"{rel}:{line_no}: {kind}: {preview}")
    if len(issues) > 200:
        print(f"... {len(issues) - 200} more issues")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
