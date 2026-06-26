#!/usr/bin/env python3
"""Run the fast AIBattle sanity checks before starting a test match."""

from pathlib import Path
import argparse
import filecmp
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DOTA_BOTS_DIR = Path(r"C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots")

FORBIDDEN_LANING_KEYS = [
    "fwd-fallback",
    "fwd-push",
    "fwd-ahead",
    "fb-skip",
    "idle-creep-atk",
    "dt-walk",
    "packSafeDest",
]

LIVE_CODE_FILES = [
    "FunLib/aibattle_engine.lua",
    "FunLib/aibattle_constants.lua",
    "FunLib/aibattle_laning_context.lua",
    "FunLib/aibattle_style.lua",
    "FunLib/aibattle_runes.lua",
    "FunLib/aibattle_survive.lua",
    "FunLib/aibattle_laning_creeps.lua",
    "FunLib/aibattle_laning_duel.lua",
    "FunLib/aibattle_laning_siege.lua",
    "FunLib/aibattle_laning_survival.lua",
    "FunLib/aibattle_laning_trade.lua",
    "FunLib/aibattle_utils.lua",
    "FunLib/jmz_func.lua",
    "mode_laning_generic.lua",
    "mode_roam_generic.lua",
    "mode_retreat_generic.lua",
    "FretBots/SettingsDefault.lua",
]

LIVE_PLAYSTYLE_FILES = [
    "Customize/canonical_pusher.lua",
    "Customize/canonical_ganker.lua",
    "Customize/playstyle_radiant.lua",
    "Customize/playstyle_dire.lua",
]

# Files we hand-edit and deploy: a syntax slip here crashes the live match. Mirrors deploy.bat.
SYNTAX_FILES = LIVE_CODE_FILES + LIVE_PLAYSTYLE_FILES + [
    "item_purchase_generic.lua",
]


def run_step(name, cmd):
    print(f"[check] {name}", flush=True)
    result = subprocess.run(cmd, cwd=ROOT, text=True)
    if result.returncode != 0:
        print(f"[fail] {name} exited {result.returncode}", flush=True)
        return False
    return True


def check_forbidden_laning_keys():
    print("[check] forbidden laning fallbacks", flush=True)
    text = (ROOT / "bots" / "mode_laning_generic.lua").read_text(encoding="utf-8", errors="ignore")
    found = []
    for key in FORBIDDEN_LANING_KEYS:
        if key in text:
            found.append(key)
    if found:
        print("[fail] forbidden keys in mode_laning_generic.lua:", ", ".join(found), flush=True)
        return False
    return True


def _strip_lua(src):
    """Blank out comments and string literals so delimiter counts only see real code."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src[i:i + 2] == "--":
            j = i + 2
            if j < n and src[j] == "[":           # long comment --[[ ... ]] / --[=[ ... ]=]
                k, eqs = j + 1, 0
                while k < n and src[k] == "=":
                    eqs += 1; k += 1
                if k < n and src[k] == "[":
                    close = "]" + "=" * eqs + "]"
                    end = src.find(close, k + 1)
                    i = (end + len(close)) if end != -1 else n
                    continue
            nl = src.find("\n", i)                 # line comment
            i = nl if nl != -1 else n
            continue
        if c == "[":                               # long string [[ ... ]] / [=[ ... ]=]
            k, eqs = i + 1, 0
            while k < n and src[k] == "=":
                eqs += 1; k += 1
            if k < n and src[k] == "[":
                close = "]" + "=" * eqs + "]"
                end = src.find(close, k + 1)
                out.append(" ")
                i = (end + len(close)) if end != -1 else n
                continue
        if c == '"' or c == "'":                   # quoted string with escapes
            q, j = c, i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2; continue
                if src[j] == q:
                    j += 1; break
                j += 1
            out.append(" ")
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def lua_structure_problems(src):
    """Return a list of structural problems for one Lua source string ([] = clean).

    Invariant: in valid Lua, `end` count == (`function` + `if` + `do`), because every for/while
    carries exactly one `do`. Plus balanced ()/[]/{} and repeat==until. Operates on comment-
    and string-stripped code so keywords/brackets inside those don't miscount.
    """
    code = _strip_lua(src)
    problems = []
    for open_c, close_c in (("(", ")"), ("[", "]"), ("{", "}")):
        o, c = code.count(open_c), code.count(close_c)
        if o != c:
            problems.append(f"{open_c}{close_c} {o}/{c}")

    def wc(word):
        return len(re.findall(r"\b" + word + r"\b", code))

    ends, openers = wc("end"), wc("function") + wc("if") + wc("do")
    if ends != openers:
        problems.append(f"end={ends} vs function+if+do={openers}")
    if wc("repeat") != wc("until"):
        problems.append(f"repeat={wc('repeat')} until={wc('until')}")
    return problems


def check_lua_syntax():
    """Structural sanity check (no luac available): balanced delimiters and block keywords.

    Invariant: in valid Lua, `end` count == (`function` + `if` + `do`), because every for/while
    carries exactly one `do`. Validated to flag zero false positives across the whole bots/ tree.
    """
    print("[check] lua syntax", flush=True)
    bad = []
    for rel in SYNTAX_FILES:
        path = ROOT / "bots" / rel
        if not path.exists():
            continue
        problems = lua_structure_problems(path.read_text(encoding="utf-8", errors="ignore"))
        if problems:
            bad.append(f"{rel}: " + "; ".join(problems))
    if bad:
        print("[fail] lua structure imbalance:", flush=True)
        for b in bad:
            print("   ", b, flush=True)
        return False
    return True


def git_head():
    result = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def live_build_sha():
    path = DOTA_BOTS_DIR / "FunLib" / "aibattle_build.lua"
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    m = re.search(r'sha\s*=\s*"([^"]+)"', text)
    return m.group(1) if m else None


def check_live_build():
    print("[check] live build sha", flush=True)
    head = git_head()
    live = live_build_sha()
    print(f"  repo={head or 'unknown'} live={live or 'unknown'}", flush=True)
    if not head or not live or head != live:
        print("[fail] live build sha does not match repo HEAD", flush=True)
        return False
    return True


def check_live_drift():
    print("[check] live file drift", flush=True)
    missing = []
    drift = []
    for rel in LIVE_CODE_FILES + LIVE_PLAYSTYLE_FILES:
        src = ROOT / "bots" / rel
        dst = DOTA_BOTS_DIR / rel
        if not dst.exists():
            missing.append(rel)
        elif not filecmp.cmp(src, dst, shallow=False):
            drift.append(rel)
    if missing:
        print("[fail] missing live files:", ", ".join(missing), flush=True)
    if drift:
        print("[fail] live differs from repo:", ", ".join(drift), flush=True)
    return not missing and not drift


def main():
    parser = argparse.ArgumentParser(description="Run AIBattle sanity checks.")
    parser.add_argument("--match", help="Optional match id for match_stats smoke")
    parser.add_argument("--latest", action="store_true", help="Run match_stats against newest console log")
    parser.add_argument("--skip-live", action="store_true", help="Skip live Dota folder checks")
    args = parser.parse_args()

    ok = True
    ok = run_step("text encoding", [sys.executable, "tools/check_text_encoding.py"]) and ok
    ok = check_lua_syntax() and ok
    ok = check_forbidden_laning_keys() and ok

    if not args.skip_live:
        ok = check_live_build() and ok
        ok = check_live_drift() and ok

    if args.match or args.latest:
        cmd = [sys.executable, "tools/match_stats.py", "--live"]
        if args.latest:
            cmd.append("--latest")
        if args.match:
            cmd.append(args.match)
        ok = run_step("match stats smoke", cmd) and ok

    if ok:
        print("[ok] all checks passed", flush=True)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
