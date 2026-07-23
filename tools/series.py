"""Series 1 round-robin: set the sides for match N and say what to expect.

Usage:
  python tools/series.py            # show the whole schedule and where we are
  python tools/series.py <N>        # write playstyle_* and nicknames for match N (1..6)

Three models, three pairs, each pair played once on each side assignment = 6 matches.
Every model gets 4 matches, 2 per side, and every pair meets on both arrangements, so a
side effect cannot masquerade as a model effect.

This exists because doing it by hand is where a series silently breaks: one match with
the wrong side, or a nickname that no longer matches the config, and the whole run is
worthless with nothing in the numbers to show it. After writing, run:

    cmd //c "tools\\deploy.bat playstyle" && cmd //c "tools\\deploy.bat general"

Do NOT deploy `code` between matches of a series -- the build must stay frozen.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CUSTOM = ROOT / "bots" / "Customize"
MODELS = ("grok", "gemini", "deepseek")

# (radiant, dire) -- each unordered pair appears twice, once per arrangement.
SCHEDULE = [
    ("grok", "gemini"),
    ("gemini", "grok"),
    ("grok", "deepseek"),
    ("deepseek", "grok"),
    ("gemini", "deepseek"),
    ("deepseek", "gemini"),
]

PLAYSTYLE = ('return require(GetScriptDirectory().."/Customize/canonical_%s")\n')


def set_match(n):
    if not 1 <= n <= len(SCHEDULE):
        print("match number must be 1..%d" % len(SCHEDULE))
        return 1
    rad, dire = SCHEDULE[n - 1]
    (CUSTOM / "playstyle_radiant.lua").write_text(PLAYSTYLE % rad, encoding="utf-8")
    (CUSTOM / "playstyle_dire.lua").write_text(PLAYSTYLE % dire, encoding="utf-8")

    # The nickname must follow the config, not the side: an in-game name that says
    # "Grok" while the file says gemini is a mislabelled result nobody can catch later.
    gen = CUSTOM / "general.lua"
    text = gen.read_text(encoding="utf-8")
    text = re.sub(r"(Radiant_Names = \{\s*\n\s*'[^']*',\s*\n\s*)'[^']*'",
                  lambda m: m.group(1) + "'%s'" % rad.capitalize(), text)
    text = re.sub(r"(Dire_Names = \{\s*\n\s*'[^']*',\s*\n\s*)'[^']*'",
                  lambda m: m.group(1) + "'%s'" % dire.capitalize(), text)
    gen.write_text(text, encoding="utf-8")

    print("match %d/%d set:  Radiant = %s   Dire = %s" % (n, len(SCHEDULE), rad, dire))
    print("\nnow deploy (code stays frozen -- do NOT deploy 'code' mid-series):")
    print('  cmd //c "tools\\deploy.bat playstyle"')
    print('  cmd //c "tools\\deploy.bat general"')
    return 0


def build_sha():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT,
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def show():
    print("Series 1 -- one prompt, three models. Frozen build required: %s" % build_sha())
    print("\n  #   Radiant      Dire")
    for i, (rad, dire) in enumerate(SCHEDULE, 1):
        print("  %d   %-12s %s" % (i, rad, dire))
    print("\nEach model plays 4 matches, 2 per side; each pair meets on both arrangements.")
    print("\nPre-registered prediction (write it down BEFORE the matches, not after):")
    print("  Only Gemini lacks a pre-creep engage licence -- it has neither")
    print("  pregame_behavior=aggressive_mid nor hero_priority=always (bfa60b8), so it")
    print("  should be the one standing still at the horn while the other two step up.")
    print("  Grok gets the licence via hero_priority, DeepSeek via aggressive_mid --")
    print("  same visible behaviour reached through different knobs.")
    print("\nAfter each match:  python tools/postmatch.py <id> && python tools/betting.py <id>")
    print("Findings go to docs/BACKLOG.md. Do not fix code until the series ends.")


if __name__ == "__main__":
    sys.exit(set_match(int(sys.argv[1])) if len(sys.argv) > 1 else (show() or 0))
