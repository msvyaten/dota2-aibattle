# AIBattle Handoff

Short operational reference. The current plan lives in [`STATE.md`](STATE.md) and
[`BACKLOG.md`](BACKLOG.md); the architecture in [`ARCHITECTURE.md`](ARCHITECTURE.md); the file
inventory in [`CODE_MAP.md`](CODE_MAP.md); the large design mandates in [`SPECS.md`](SPECS.md).
The older, longer version of this document is in git history: `git show ae2604d:docs/HANDOFF.md`.

## Cold start

```powershell
python tools\pre_match_state.py
python tools\check_all.py --skip-live
```

If `python` is not in PATH on this Windows workstation, use the bundled runtime:

```powershell
& 'C:\Users\Shadow\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' tools\pre_match_state.py
& 'C:\Users\Shadow\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' tools\check_all.py --skip-live
```

**Do not copy HEAD or LIVE out of any document.** `pre_match_state.py` prints the branch,
upstream, live marker, bindings and dirty files as they are on this machine right now.

The working branch is `1v1-mid-validation`, not `main`. It was called
`phase-2-team-dials` until 2026-08-30; that name came from the 5v5 team-mode dials of
Phase 2 and had stopped describing the work. A stale clone needs `git fetch --prune`.

For a teammate joining the project, start with [`TEAM_REVIEW_START.md`](TEAM_REVIEW_START.md).
It is the checklist for commands, evidence set, and deliverable format.

## Paths

- Repo: `C:\Users\Shadow\dota2-aibattle`
- Dota root: `...\dota 2 beta\game\dota`
- LIVE bots: `...\dota\scripts\vscripts\bots`
- Match log: `console.<matchid>.log`
- Replay: `<matchid>.dem`

To move the installation without editing sources, set:

- `DOTA_LOG_DIR`
- `DOTA_BOTS_DIR`
- `DOTA_REPLAY_DIR`
- `DOTA_ITEMBUILDS_DIR`

## Ownership

- Runtime, tooling, telemetry, deploy: Codex.
- Canonical and generated strategies, and the live matchup: usually Claude.
- `playstyle_radiant.lua`, `playstyle_dire.lua` and `general.lua` are **experiment state, not
  ordinary source**. Do not commit them without a direct instruction.
- Two agents work in this repository under the same git identity. Before editing or
  committing, re-read `git status` and the diff of what you touched. Never revert a change you
  do not recognise.

## Checks

The local gate:

```powershell
python tools\check_all.py --skip-live
```

It covers text encoding, Lua and Python syntax, the deploy manifest, runtime module coverage,
the schema contract, the Python tests and the project inventory. The full check, after a deploy:

```powershell
python tools\check_all.py
```

That additionally requires `HEAD == LIVE`, no drift, and no stale runtime files in the Dota
installation.

Before claiming that any function is dead, unreachable, or never fires:

```powershell
python tools\check_all.py --twins <FunctionName>
```

It prints every definition whose name reads like that one, with file and line. **Grep locates
code; it never proves anything about it.** Read the whole body, and read it for every
same-named twin - two similarly named functions in different files are two functions.

## Deploy

```powershell
tools\deploy.bat check
tools\deploy.bat code
tools\deploy.bat playstyle
tools\deploy.bat all
tools\deploy.bat general
```

- `code` - runtime only. The safe default, and what runs with no argument.
- `playstyle` - canonical presets and live bindings.
- `all` - `code` plus `playstyle`, without `general.lua`.
- `general` - explicit lobby/general sync only.
- `check` - dry run.

After a `code` deploy, restart the lobby and confirm a full `check_all.py`.

## Reading a match

Main analysis:

```powershell
python tools\postmatch.py <matchid>
python tools\pathology.py <matchid>
python tools\betting.py <matchid>
```

Supporting tools:

- `match_stats.py` - full telemetry, counters, timeline, items, farm trace;
- `scorecard.py` - watchability criteria as a bare PASS/FAIL;
- `binding.py` - proof that a config knob reaches behaviour;
- `series.py` - a series on a frozen build and config;
- `project_inventory.py` - current size and ownership debt.

## Reading the evidence

Strongest to weakest:

1. position, HP, target and action over time;
2. tick owner, and transaction/episode telemetry;
3. cumulative diag counters;
4. rate-limited `intent=` and `blocked=` lines, which are lower bounds only;
5. visual observation, tied to an exact timestamp.

Never compare raw counters between matches of different length - use rate per minute. Take the
build of a match from its own log. Validation debt is `git log <match-build>..HEAD`, computed,
never carried by hand.

## Config pipeline

The live model-facing schema is `backend/style_schema.py`. It is checked automatically against
`bots/FunLib/aibattle_style.lua`, `backend/system_prompt.txt` and the canonical configs by
`tools/check_schema_contract.py`.

The main path, no API key required:

```powershell
python backend\generate_playstyle.py --radiant-json <file-or-json> --dire-json <file-or-json> --output-dir bots\Customize
```

The optional API path uses `OPENAI_API_KEY` and `AIBATTLE_OPENAI_MODEL`.

## Git

Stage named files only. Never `git add -A` here - the bindings are deliberately dirty.
Force-push and destructive resets are forbidden. After a push, confirm the sync:

```powershell
git rev-list --left-right --count origin/1v1-mid-validation...HEAD
```

The expected result is `0 0`.
