# AIBattle - Dota 2 1v1 mid bot

An experiment in making a Dota 2 bot whose strategy is written by a language model and whose
behaviour is measurable. A person writes a strategy in plain English; an LLM turns it into a
small numeric config; the bot engine executes that config; the match log has to explain what
the bot wanted, what it did, and what stopped it.

```
plain-English strategy  ->  LLM  ->  config (12 dials + 11 rules + item build)
                                        |
                                        v
                     Lua bot engine in Dota 2, 1v1 solo mid
                                        |
                                        v
                     console.<matchid>.log  ->  Python analysis tools
```

The product question is not "does the bot win". It is **"are two generated agents worth
watching"** - a match with a contested middle, not a deterministic stomp.

## Start here (in this order)

| # | Read | Why |
|---|---|---|
| 1 | [`NOTICE.md`](NOTICE.md) | What is vendored, what is ours, and the unresolved licence status. |
| 2 | [`docs/CODE_MAP.md`](docs/CODE_MAP.md) | File inventory, the vendor boundary, and a "where do I change X" table. |
| 3 | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Decision order, module ownership, telemetry rules, how to add behaviour. |
| 4 | [`docs/STATE.md`](docs/STATE.md) | Current plan, open structural work, and the evidence rules. |
| 5 | [`docs/HANDOFF.md`](docs/HANDOFF.md) | Operational reference: paths, gate, deploy, match analysis. |

`docs/SPECS.md`, `docs/BACKLOG.md` and `docs/history/` are **written in Russian** and are
working notes, not handoff material. See "Language" below.

## Do not be scared by the size

`bots/` is about 199,000 lines of Lua. **7,829 of them are ours.** The rest is the vendored
OpenHyperAI engine: read it when you need to, do not refactor it.

| | lines | ours? |
|---|---:|---|
| `bots/FunLib/aibattle_*.lua` - the behaviour layer | 7,829 | yes, this is the project |
| `bots/Customize/` - strategy presets and live bindings | 683 | yes |
| In-place patches inside vendored files (21 files, marked `AIB`) | ~217 | yes, see `CODE_MAP.md` section 3 |
| Everything else under `bots/` | ~190,000 | no - vendored, synced from upstream |
| `tools/` - match analysis and repo gates | 5,233 | yes |
| `backend/` - LLM config generator | 359 | yes |

## Run the checks

Everything below is offline. You do not need Dota 2 installed, an API key, or a match log.

```bash
python tools/check_all.py --skip-live
```

That is the pre-commit gate. It runs text-encoding checks, Lua syntax, Lua
local-use-before-declaration, duplicate global names, `require` cycle detection, Python
syntax, a forbidden-fallback lint, deploy-manifest sync, runtime-module coverage, the
Python/Lua/prompt schema contract, 58 tests, and a project inventory. It should print
`[ok] all checks passed`.

Two more that are useful on a cold read:

```bash
python tools/project_inventory.py
```

Current file sizes, the count of direct engine-action call sites, cross-module shared-state
writers, and dead local helpers. **Prefer this over any number written in a document** -
documented numbers are snapshots and go stale.

```bash
python backend/generate_playstyle.py --radiant-json <file-or-json> --dire-json <file-or-json> --output-dir bots/Customize
```

The config generator, offline path. The API path is optional and uses `OPENAI_API_KEY`.

## Run the bot

Copy `bots/` into the Dota 2 vscripts directory. `BotLib/`, `FunLib/` and `Customize/` all
live inside `bots/`, so one copy handles everything.

macOS:
```bash
cp -r bots "$HOME/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/dota/scripts/vscripts/"
```

Windows - copy `bots/` to:
`C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\`

On Windows there is a deploy script with explicit profiles, which also stamps the build SHA
into `aibattle_build.lua` so a match log can be attributed to a commit:

```bash
tools/deploy.bat code
```

Then: launch Dota 2 -> private lobby -> Game Mode "1v1 Solo Mid" -> fill empty slots with
bots -> start -> open console with `~` -> confirm no `[Lua Error]` lines. With `-condebug`
the match writes `game/dota/console.<matchid>.log`, which is the input to every analysis tool.

## Reading a match

```bash
python tools/postmatch.py <matchid>    # main report
python tools/pathology.py <matchid>    # movement shapes (stalling, walking in circles)
python tools/betting.py <matchid>      # is this match watchable / priceable
```

`docs/HANDOFF.md` lists the rest.

## Language

The code, the code comments, the commit messages, `README.md`, `NOTICE.md`,
`docs/ARCHITECTURE.md`, `docs/STATE.md`, `docs/CODE_MAP.md` and `docs/HANDOFF.md` are
English. This is enforced - `tools/check_text_encoding.py` fails the gate on Cyrillic
outside an explicit allowlist.

Two categories are deliberately not English:

- **Vendored localisation.** `bots/FretBots/HeroNames.lua`, `bots/FunLib/localization.lua`
  and `bots/FunLib/aba_chat_table.lua` carry Russian, Chinese and Japanese strings. They are
  upstream user-facing translations. Do not touch them.
- **`docs/SPECS.md`, `docs/BACKLOG.md`, `docs/history/`** are Russian working notes kept for
  the original authors. They are not required to work on this repository, and nothing in the
  five documents listed under "Start here" depends on them.

## Glossary

The code comments cite real matches and real arguments. Some shorthand recurs:

| Term | Meaning |
|---|---|
| **Claude**, **Codex** | AI coding agents that wrote parts of this repository, not people. "Codex's audit" means a review pass, not a colleague. |
| Dates like `03.08` | Day.Month, 2026. `03.08` is 3 August 2026. |
| **dial** | A model-facing float, 0.0-1.0 (e.g. `harass_desire`). Twelve of them. |
| **rule** | A model-facing discrete choice (e.g. `low_hp_behavior`). Eleven of them. |
| **constant** | An engine threshold in `aibattle_constants.lua`. Never model-facing. |
| **tick** | One `Think()` call. Exactly one owner acts per tick. |
| **owner / candidate / election** | Behaviours compete for a tick by score; the arbiter runs only the winner and logs the losers. |
| **intent / diag / blocked** | The three telemetry lines: what it wanted, an implementation-level counter, and why it refused. |
| **mutual low** | Seconds where *both* heroes are simultaneously in danger. It reads `0` in every match measured so far, which is the headline product problem. |
| **LIVE** | The deployed copy inside the Dota 2 install, as opposed to this repository. |
| An 8-10 digit number like `8968270421` | A Dota match ID; the evidence behind the comment next to it. |

## A note on `git status`

Three files under `bots/Customize/` are normally dirty in the working tree:
`general.lua`, `playstyle_radiant.lua`, `playstyle_dire.lua`. That is **deliberate** - they
hold live experiment state (which hero, which config runs on which side), not source of
truth. Do not commit them, and do not "clean them up".
