#!/usr/bin/env python3
"""Run the fast AIBattle sanity checks before starting a test match."""

from pathlib import Path
import argparse
import filecmp
import re
import subprocess
import sys

from aibattle_log import DOTA_BOTS_DIR, live_build_sha as shared_live_build_sha

ROOT = Path(__file__).resolve().parents[1]

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
    "FunLib/aibattle_intents.lua",
    "FunLib/aibattle_item_policy.lua",
    "FunLib/aibattle_constants.lua",
    "FunLib/aibattle_laning_context.lua",
    "FunLib/aibattle_style.lua",
    "FunLib/aibattle_runes.lua",
    "FunLib/aibattle_survive.lua",
    "FunLib/aibattle_laning_creeps.lua",
    "FunLib/aibattle_laning_safety.lua",
    "FunLib/aibattle_laning_recovery.lua",
    "FunLib/aibattle_laning_combat.lua",
    "FunLib/aibattle_laning_tempo.lua",
    "FunLib/aibattle_laning_arbiter.lua",
    "FunLib/aibattle_motor.lua",
    "FunLib/aibattle_laning_policy.lua",
    "FunLib/aibattle_laning_duel.lua",
    "FunLib/aibattle_laning_siege.lua",
    "FunLib/aibattle_laning_survival.lua",
    "FunLib/aibattle_laning_trade.lua",
    "FunLib/aibattle_utils.lua",
    "FunLib/aba_global_overrides.lua",
    "FunLib/jmz_func.lua",
    "ability_item_usage_generic.lua",
    "item_purchase_generic.lua",
    "mode_laning_generic.lua",
    "mode_roam_generic.lua",
    "mode_retreat_generic.lua",
    "mode_rune_generic.lua",
    "FretBots/SettingsDefault.lua",
    "FretBots/Utilities.lua",
]

LIVE_PLAYSTYLE_FILES = [
    "Customize/canonical_brawler.lua",
    "Customize/canonical_farmer.lua",
    "Customize/canonical_pusher.lua",
    "Customize/canonical_ganker.lua",
    "Customize/canonical_grok.lua",
    "Customize/canonical_gemini.lua",
    "Customize/canonical_deepseek.lua",
    "Customize/playstyle_radiant.lua",
    "Customize/playstyle_dire.lua",
]

GENERATED_CODE_FILES = {
    "FunLib/aibattle_build.lua",
}

STALE_LIVE_FILES = [
    "FunLib/aibattle_laning_intents.lua",
    # phase-22 era relics (can reappear after old-build comparison deploys)
    "FunLib/aibattle_heal.lua",
    "mode_laning_generic.aibattle.lua",
    "mode_retreat_generic_wip.lua",
    "--mode_item_generic.lua",
    # retired experiment configs (June bettability era)
    "Customize/playstyle_A_duelist.lua",
    "Customize/playstyle_B_farmer.lua",
    "Customize/playstyle_C_trader.lua",
]

ACTIVE_DOC_LIMITS = {
    "ARCHITECTURE.md": 250,
    # 150 of queue + 2 for the English language banner the handoff requires
    # on a Russian working doc (see README "Language").
    "BACKLOG.md": 152,
    "CODE_MAP.md": 350,
    "HANDOFF.md": 180,
    "SPECS.md": 800,
    "STATE.md": 150,
    # Compatibility pointers for old config/code comments. The real content is archived.
    "llm_system_prompt.md": 10,
    "match_log.md": 10,
}

# Files we hand-edit and deploy: a syntax slip here crashes the live match. Mirrors deploy.bat.
SYNTAX_FILES = LIVE_CODE_FILES + LIVE_PLAYSTYLE_FILES


def _norm_rel(path):
    return path.replace("\\", "/")


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


def check_active_docs():
    print("[check] active documentation surface", flush=True)
    docs_dir = ROOT / "docs"
    actual = {path.name for path in docs_dir.glob("*.md")}
    expected = set(ACTIVE_DOC_LIMITS)
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    oversized = []
    for name, limit in ACTIVE_DOC_LIMITS.items():
        path = docs_dir / name
        if path.exists():
            lines = len(path.read_text(encoding="utf-8", errors="ignore").splitlines())
            if lines > limit:
                oversized.append(f"{name}={lines}>{limit}")
    if missing:
        print("[fail] missing active docs:", ", ".join(missing), flush=True)
    if unexpected:
        print("[fail] unexpected root docs; use docs/history or update the contract:", ", ".join(unexpected), flush=True)
    if oversized:
        print("[fail] active docs exceeded review budget:", ", ".join(oversized), flush=True)
    return not missing and not unexpected and not oversized


def _deploy_copyfiles(section_name):
    text = (ROOT / "tools" / "deploy.bat").read_text(encoding="utf-8", errors="ignore")
    in_section = False
    files = []
    marker = f'if "%{section_name}%"=="1" ('
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == marker:
            in_section = True
            continue
        if in_section and stripped == ")":
            break
        if not in_section:
            continue
        m = re.search(r'call\s+:copyfile\s+"([^"]+)"', stripped, re.IGNORECASE)
        if m:
            files.append(_norm_rel(m.group(1)))
    return files


def check_deploy_manifest_sync():
    print("[check] deploy manifest sync", flush=True)
    deployed_code = set(_deploy_copyfiles("DO_CODE")) - GENERATED_CODE_FILES
    deployed_playstyle = set(_deploy_copyfiles("DO_PLAYSTYLE"))
    expected_code = set(LIVE_CODE_FILES)
    expected_playstyle = set(LIVE_PLAYSTYLE_FILES)

    ok = True
    missing_code = sorted(expected_code - deployed_code)
    extra_code = sorted(deployed_code - expected_code)
    missing_playstyle = sorted(expected_playstyle - deployed_playstyle)
    extra_playstyle = sorted(deployed_playstyle - expected_playstyle)

    if missing_code:
        print("[fail] code files missing from deploy.bat:", ", ".join(missing_code), flush=True)
        ok = False
    if extra_code:
        print("[fail] deploy.bat code files missing from check_all.py:", ", ".join(extra_code), flush=True)
        ok = False
    if missing_playstyle:
        print("[fail] playstyle files missing from deploy.bat:", ", ".join(missing_playstyle), flush=True)
        ok = False
    if extra_playstyle:
        print("[fail] deploy.bat playstyle files missing from check_all.py:", ", ".join(extra_playstyle), flush=True)
        ok = False
    return ok


def check_aibattle_runtime_modules():
    print("[check] aibattle runtime modules", flush=True)
    expected = set(LIVE_CODE_FILES) | GENERATED_CODE_FILES
    actual = {
        _norm_rel(str(path.relative_to(ROOT / "bots")))
        for path in (ROOT / "bots" / "FunLib").glob("aibattle_*.lua")
    }
    missing = sorted(actual - expected)
    if missing:
        print("[fail] aibattle modules not listed for deploy/check:", ", ".join(missing), flush=True)
        return False

    require_re = re.compile(r"FunLib/(aibattle_[A-Za-z0-9_]+)")
    required = set()
    for rel in LIVE_CODE_FILES:
        path = ROOT / "bots" / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore").replace("\\", "/")
        for name in require_re.findall(text):
            required.add(f"FunLib/{name}.lua")

    unresolved = sorted(required - expected)
    if unresolved:
        print("[fail] required aibattle modules not listed for deploy/check:", ", ".join(unresolved), flush=True)
        return False
    return True


def check_top_desire_policy_boundary():
    print("[check] top desire policy boundary", flush=True)
    text = (ROOT / "bots" / "mode_laning_generic.lua").read_text(encoding="utf-8", errors="ignore")
    marker = "local function AIB_BuildDesireCandidates"
    start = text.find(marker)
    end = text.find("-- Main laning policy.", start)
    if start == -1 or end == -1:
        print("[fail] cannot locate AIB_BuildDesireCandidates boundary", flush=True)
        return False
    body = text[start:end]
    forbidden = ["local score", "score =", "score +", "score -"]
    found = [frag for frag in forbidden if frag in body]
    if found:
        print("[fail] top desire scoring must live in FunLib/aibattle_laning_policy.lua:", ", ".join(found), flush=True)
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


def check_lua_local_use_before_decl():
    """Catch a local called before it is declared -- Lua resolves that to a global, i.e. to nil.

    Not a style rule: it is a runtime crash the structure check cannot see. Written after
    shipping exactly this -- uphillBlocks was declared below M.KillLock and called inside it,
    which compiles fine, passes the balanced-delimiter check, and dies the first time the branch
    runs. Lua scopes a local from its declaration point onward, so a call above it never binds.

    The forward-declaration pattern (`local f` now, `f = function() ...` later) is legitimate and
    is honoured: what matters is where the NAME becomes local, not where the body lands.
    """
    print("[check] lua local-use-before-declaration", flush=True)
    decl_fn = re.compile(r"^[ \t]*local\s+function\s+([A-Za-z_]\w*)", re.M)
    decl_var = re.compile(r"^[ \t]*local\s+([A-Za-z_]\w*)\s*(?:=|$)", re.M)
    bad = []
    for rel in SYNTAX_FILES:
        path = ROOT / "bots" / rel
        if not path.exists():
            continue
        src = _strip_lua(path.read_text(encoding="utf-8", errors="ignore"))
        first_decl = {}
        for m in list(decl_fn.finditer(src)) + list(decl_var.finditer(src)):
            name = m.group(1)
            if name not in first_decl or m.start() < first_decl[name]:
                first_decl[name] = m.start()
        for name, at in first_decl.items():
            # A call, not a mention: `name(` and not preceded by a field/method separator, so
            # ctx.name(...) and obj:name(...) are somebody else's binding, not this local.
            hit = re.search(r"(?<![\w.:])" + re.escape(name) + r"\s*\(", src[:at])
            if hit:
                line = src.count(chr(10), 0, hit.start()) + 1
                bad.append("%s: %s() called at line ~%d, declared local further down" % (rel, name, line))
    if bad:
        print("[fail] local used before declaration (binds to a nil global at runtime):", flush=True)
        for b in bad:
            print("   ", b, flush=True)
        return False
    return True


def _lua_definitions():
    """Every function definition in the live Lua set: (name, rel, line, is_global)."""
    # The name may be qualified (M.Foo, J.Bar, CDOTA_Bot_Script:Baz). Only a bare `function Foo`
    # writes a global -- anything with a dot or colon is a field on a table that already exists.
    pat = re.compile(r"^[ \t]*(local\s+function|function)\s+([A-Za-z_][\w.:]*)", re.M)
    out = []
    for rel in SYNTAX_FILES:
        path = ROOT / "bots" / rel
        if not path.exists():
            continue
        src = _strip_lua(path.read_text(encoding="utf-8", errors="ignore"))
        for m in pat.finditer(src):
            raw = m.group(2)
            qualified = "." in raw or ":" in raw
            name = re.split(r"[.:]", raw)[-1]
            is_global = m.group(1) == "function" and not qualified
            out.append((name, rel, src.count(chr(10), 0, m.start()) + 1, is_global))
    return out


def _name_tokens(name):
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower()
    return {t for t in re.split(r"[^a-z0-9]+", spaced) if len(t) > 3}


# Vendor mode entry points: every mode_*.lua is expected to define these, the engine calls the
# one belonging to the active mode. Not a collision, and not ours to rename. OnStart/OnEnd
# joined the list when mode_rune_generic entered the deploy contract.
KNOWN_GLOBAL_TWINS = {"Think", "GetDesire", "GetDesireHelper", "OnStart", "OnEnd"}


def check_lua_global_twins():
    """A plain `function Name()` in two live files is one binding, and the last load wins.

    Not hypothetical: mode_laning_generic and override_generic/mode_laning_generic both define
    GetBestDenyCreep. Nothing warns, nothing crashes, and which body runs depends on load order.
    """
    print("[check] lua global twin names", flush=True)
    by_name = {}
    for name, rel, line, is_global in _lua_definitions():
        if is_global and name not in KNOWN_GLOBAL_TWINS:
            by_name.setdefault(name, []).append("%s:%d" % (rel, line))
    dupes = {n: v for n, v in by_name.items() if len(v) > 1}
    if dupes:
        print("[fail] same global function name in more than one live file (last load wins):", flush=True)
        for n, where in sorted(dupes.items()):
            print("    %s -- %s" % (n, ", ".join(where)), flush=True)
        return False
    return True


def report_twins(query):
    """`--twins NAME`: every definition whose name reads like NAME, with file and line.

    This exists because of a specific mistake, not as a style report. On 02.08 I read
    MissingBuildCheckpoint in aibattle_item_policy.lua (which asks Style.GetItemBuild, empty in
    both live configs, so genuinely dead), then met missingCheckpointItem in aibattle_survive.lua
    -- similar name, different file -- grepped out its `return` lines, and filled in the
    conditions from the function I had already read. That one hardcodes its checkpoint list and
    was very much alive: it held a second salve cap that made a shipped fix half work.

    So: before writing "this function is dead / unreachable / never fires", run this and read
    every body it prints. A name that reads the same is not the same function.
    """
    want = _name_tokens(query)
    if not want:
        print("[twins] give a name with at least one word longer than 3 characters", flush=True)
        return True
    rows = []
    for name, rel, line, is_global in _lua_definitions():
        toks = _name_tokens(name)
        if not toks:
            continue
        shared = toks & want
        exact = name.lower() == query.lower()
        if exact or (len(shared) >= 2 and len(shared) / min(len(toks), len(want)) >= 0.6):
            rows.append((0 if exact else 1, name, rel, line, is_global))
    if not rows:
        print("[twins] no definition reads like %r in the live Lua set" % query, flush=True)
        return True
    print("[twins] %d definition(s) read like %r -- READ EVERY BODY before claiming anything "
          "about any of them:" % (len(rows), query), flush=True)
    for _, name, rel, line, is_global in sorted(rows):
        print("    %-34s %s:%d%s" % (name, rel, line, "  (global)" if is_global else ""), flush=True)
    return True


def report_never_fired(n_logs):
    """`--never-fired N`: diag keys the code can emit that N recent matches never show.

    The dominant defect in this codebase is not wrong logic, it is code that never runs --
    a knob nothing writes, an escape behind the gate that closes when you need it, a branch
    made unreachable by something upstream. Every one of those found so far was found by
    accident. This makes the question askable on purpose.

    A zero is not automatically a bug: 1v1 has no ally, so anti-idle-assist cannot fire, and
    a build with no bottle makes every bottle branch dead by construction. Read it as "these
    branches have never executed -- for each, do I know why".

    Known limits, so a reader does not chase ghosts. Keys assembled at runtime
    (`"deny-cand-"..rejected`) are listed by their literal prefix and will always look dead.
    Counters added after the scanned matches were played will too -- check the commit date
    before treating one as a finding.
    """
    import aibattle_log as _log
    keys = {}
    # Scan everything we deploy, not a hand-picked subset. The first version looked only at
    # FunLib/aibattle_* plus mode_laning, so mode_rune_generic -- which owns rune pickup and
    # carries the rune-grab counter written specifically to A/B the rune_control dial -- was
    # outside the scan entirely. A "has this ever run" tool that cannot see a file cannot
    # answer for it, and I read its silence as an answer.
    src_files = [ROOT / "bots" / rel for rel in LIVE_CODE_FILES]
    # Counters and intents are emitted by different calls and land in the log in different
    # shapes -- `key=N` inside a dump line versus `intent=name`. Scanning only the first said
    # the whole rune subsystem was silent when rune-ground-truth is in the log 102 times; it
    # just reports as an intent. A tool that answers "has this ever run" has to know both.
    emit_counter = re.compile(r'(?:Style\.Diag|Style\.DiagRL|ctx\.diag|M\.Diag|M\.DiagRL|AIB_Diag)'
                              r'\s*\(\s*(?:bot\s*,\s*)?"([a-z0-9][a-z0-9-]*)"')
    emit_intent = re.compile(r'(?:Style\.Intent|ctx\.state|M\.Intent)'
                             r'\s*\(\s*(?:bot\s*,\s*)?"([a-z0-9][a-z0-9-]*)"')
    for path in src_files:
        if not path.exists():
            continue
        text_src = path.read_text(encoding="utf-8", errors="ignore")
        for m in emit_counter.finditer(text_src):
            keys.setdefault(m.group(1), (path.name, "counter"))
        for m in emit_intent.finditer(text_src):
            keys.setdefault(m.group(1), (path.name, "intent"))
    logs = sorted(_log.DOTA_LOG_DIR.glob("console.*.log"),
                  key=lambda p: p.stat().st_mtime, reverse=True)[:n_logs]
    if not logs:
        print("[never-fired] no console logs found", flush=True)
        return True
    text = "".join(p.read_text(encoding="utf-8", errors="ignore") for p in logs)
    never = []
    for k, (fname, kind) in sorted(keys.items()):
        pat = (r"(?<![\w-])%s=\d" % re.escape(k)) if kind == "counter"             else (r"intent=%s(?![\w-])" % re.escape(k))
        if not re.search(pat, text):
            never.append((k, fname, kind))
    print("[never-fired] %d of %d emit points never appeared across %d match(es): %s"
          % (len(never), len(keys), len(logs), ", ".join(p.stem.split(".")[-1] for p in logs)),
          flush=True)
    for k, fname, kind in never:
        print("    %-34s %-8s %s" % (k, kind, fname), flush=True)
    return True


def check_require_cycles():
    """A require cycle among our own modules is a load-time crash Lua reports as nil.

    Nearly shipped one: safety already required creeps, and adding the reverse edge to let
    creep-work ask a safety question closed the loop. Syntax passes, the module list passes,
    the tests pass -- and the match dies on load. Nothing in this repo could see it, so this
    check exists to make the next attempt fail here instead of in a lobby.
    """
    print("[check] aibattle require cycles", flush=True)
    edges, req = {}, re.compile(r"require\(\s*GetScriptDirectory\(\)\s*\.\.\s*'/FunLib/(aibattle_[A-Za-z0-9_]+)'")
    for path in sorted((ROOT / "bots" / "FunLib").glob("aibattle_*.lua")):
        edges[path.stem] = set(req.findall(path.read_text(encoding="utf-8", errors="ignore")))
    bad = []
    for start in edges:
        seen, stack = set(), [(start, [start])]
        while stack:
            node, trail = stack.pop()
            for nxt in edges.get(node, ()):
                if nxt == start:
                    bad.append(" -> ".join(trail + [start]))
                elif nxt not in seen:
                    seen.add(nxt)
                    stack.append((nxt, trail + [nxt]))
    if bad:
        print("[fail] require cycle among aibattle modules (Lua returns nil at load):", flush=True)
        for b in sorted(set(bad))[:6]:
            print("   ", b, flush=True)
        return False
    return True


def check_python_syntax():
    """Compile source in memory so syntax checks never create __pycache__ files."""
    print("[check] python syntax", flush=True)
    bad = []
    paths = sorted((ROOT / "tools").glob("*.py")) + sorted((ROOT / "backend").glob("*.py"))
    for path in paths:
        try:
            compile(path.read_text(encoding="utf-8"), str(path), "exec")
        except (OSError, SyntaxError, UnicodeError) as exc:
            bad.append(f"{path.relative_to(ROOT)}: {exc}")
    if bad:
        print("[fail] python syntax:", flush=True)
        for problem in bad:
            print("   ", problem, flush=True)
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
    return shared_live_build_sha()


def check_live_build():
    print("[check] live build sha", flush=True)
    head = git_head()
    live = live_build_sha()
    print(f"  repo={head or 'unknown'} live={live or 'unknown'}", flush=True)
    if live in {"dev", "unknown"}:
        print("[fail] live build sha is not a deployed git commit", flush=True)
        return False
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


def check_live_stale_files():
    print("[check] stale live files", flush=True)
    found = [rel for rel in STALE_LIVE_FILES if (DOTA_BOTS_DIR / rel).exists()]
    if found:
        print("[fail] stale live files present:", ", ".join(found), flush=True)
        print("       run: tools\\deploy.bat code", flush=True)
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Run AIBattle sanity checks.")
    parser.add_argument("--match", help="Optional match id for match_stats smoke")
    parser.add_argument("--latest", action="store_true", help="Run match_stats against newest console log")
    parser.add_argument("--skip-live", action="store_true", help="Skip live Dota folder checks")
    parser.add_argument("--never-fired", nargs="?", type=int, const=3, metavar="N",
                        help="List diag keys the code can emit that the N most recent match "
                             "logs never show, then exit. Default N=3.")
    parser.add_argument("--twins", metavar="NAME",
                        help="List every Lua definition whose name reads like NAME, and exit. "
                             "Run this before claiming a function is dead or unreachable.")
    args = parser.parse_args()

    if args.twins:
        return 0 if report_twins(args.twins) else 1

    if args.never_fired is not None:
        return 0 if report_never_fired(args.never_fired or 3) else 1

    ok = True
    ok = run_step("text encoding", [sys.executable, "tools/check_text_encoding.py"]) and ok
    ok = check_active_docs() and ok
    ok = check_lua_syntax() and ok
    ok = check_lua_local_use_before_decl() and ok
    ok = check_lua_global_twins() and ok
    ok = check_require_cycles() and ok
    ok = check_python_syntax() and ok
    ok = check_forbidden_laning_keys() and ok
    ok = check_deploy_manifest_sync() and ok
    ok = check_aibattle_runtime_modules() and ok
    ok = check_top_desire_policy_boundary() and ok
    ok = run_step("style schema contract", [sys.executable, "tools/check_schema_contract.py"]) and ok
    ok = run_step("python tests", [sys.executable, "tools/run_tests.py"]) and ok
    ok = run_step("project inventory", [sys.executable, "tools/project_inventory.py", "--check"]) and ok

    if not args.skip_live:
        ok = check_live_build() and ok
        ok = check_live_drift() and ok
        ok = check_live_stale_files() and ok

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
