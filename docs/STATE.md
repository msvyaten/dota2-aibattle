# AIBattle Current State

This file contains only the current plan and operating constraints. Historical match
forensics live in `BACKLOG.md`, design mandates in `SPECS.md`, and commands in `HANDOFF.md`.

## Start Here

Never trust a SHA, live binding, or dirty-tree statement copied into documentation. Get the
current snapshot from the repository and live Dota installation:

```powershell
python tools\pre_match_state.py
```

Then run the fast local gate:

```powershell
python tools\check_all.py --skip-live
```

The live bindings and generated strategies are experiment state. Do not commit these without
an explicit user command:

- `bots/Customize/general.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`
- generated/canonical configs when Claude is currently tuning them

Use named files with `git add`; never stage the whole tree in this repository.

## Product

A prompt is interpreted by an LLM into 12 numeric dials and model-facing rules. The runtime
must turn that config into distinct, competent, explainable 1v1-mid behavior. The model picks
strategy; the engine owns mechanics and safety. Engine constants such as distances, rune
staging windows, AFK timing, and tower leashes must not leak into model-facing rules.

Bettability requires repeated runs with frozen code and a side swap. A single win, or an 8/8
deterministic stomp, is not enough evidence that two generated agents make a good product.

## Current Architecture Status

Completed:

- Gate 0 technical runtime gate.
- Gate 1 comparison against the phase-22 monolith.
- Stage 0.5 watchability package.
- P3-A recovery owner skeleton and P3-B.1 episode telemetry.
- P1-A phase A (`a2bc9a9`): top desires and the old tail participate in one election.
- Real 1v1 rune schedule, pregame anchor, bounded uphill reposition, tower-range licence,
  fountain-trip ownership, and recovery `canAct` alignment through current HEAD.

Open structural work, in order:

1. Validate the current code stack in a match before stacking more gameplay changes.
2. P1-B: migrate urgent head-of-tick decisions into the same arbiter.
3. P3-B.2: make recovery destination-aware and remove remaining parallel low-HP movers.
4. P3-C: windup protection, safe CS in soft recovery, and the remaining rune/recovery semantics.
5. P1-C: remove duplicated suppression/commit machinery and reduce anti-idle to a watchdog.

Do not perform a mechanical file split before these ownership cuts. Moving 500 lines without
changing who owns a tick makes review harder but does not cure oscillation.

## Current Watchlist

- Intentional bottle-rune completion and `rune_control` binding remain weak. Diagnose from
  complete transaction telemetry, not bottle-empty percentage alone.
- Recovery can still win while having no useful action; verify `empty_action by winner` and
  low-HP episode traces after every recovery change.
- Anti-idle still contains gameplay actions; its long-term job is detection only. Measured
  (`8926148548`): largest tick owner on both sides, 109/106 against 65/68 for fight, and empty
  in 66-67% of activations. It wins because nothing above it is a candidate at all — `fight`
  was absent from the loser list in 103 of 117 of its wins.
- Two owners can deadlock by deferring to each other, and neither logs an error. Open case:
  `blocked=heal-item reason=fountain_trip_committed` with `blocked=fountain-floor
  reason=heal_in_hand` on one tick — drink waits for trip, trip waits for drink, bot leaves
  lane holding an unused salve. Adding a guard that defers? Read what that owner does back.
- Cross-module `bot.aib_*` state is ownership debt; move writes behind owner APIs when touching
  those systems (`tools/project_inventory.py` lists the writers).
- `mode_laning_generic.lua`, `aibattle_style.lua`, and `aibattle_survive.lua` remain large.
  Shrink them by ownership extraction, not by arbitrary line-count targets.

## Telemetry Volume: Deliberate, Not Debt

Diag/Intent/Blocked all post to ALL CHAT (`ActionImmediate_Chat(msg, true)`); the console log
is a record of chat, and `print()` does not reach it, so chat is a bot script's only channel.
About 4400 lines a match, five a second. **User's call, 03.08: keep it while debugging** -- it
is the only source that says who owned a tick and why, and it is what located the window where
the last match was decided. Do not "clean it up".

It becomes a product problem once a match has a spectator, since telemetry and watchability
share one channel. Then: a switch in `Customize/general.lua` (a silent show match teaches us
nothing), or thin the `intent=` traffic, ~3000 of those 4400 lines. Counter dumps are already
once per 60s at 30 lines a match -- the dense data is disciplined, the per-event data is not.

## Evidence Rules

Use evidence in this order:

1. positions, HP, targets, and actions over time;
2. transaction/episode telemetry and tick owner;
3. cumulative diag counters;
4. rate-limited intent strings, which are lower bounds only;
5. visual observation, tied to a match timestamp.

Never divide two counters without checking both rate limits in the source. `Style.Diag` is
plain and `Style.DiagRL(bot, key, sec)` fires once per `sec`; putting them side by side invites
a ratio that does not exist. In the anti-idle block the only honest pair is `anti-idle-enter`
against `idle`, both `DiagRL(3s)`.

Grep locates code; it never justifies a claim about it. Before writing that a function is dead,
unreachable, or never fires, read the whole body — the actual conditions, not the `return`
lines a grep happens to surface — and enumerate every definition that reads like it:

```powershell
python tools\check_all.py --twins <FunctionName>
```

Two similarly named functions in different files are two functions. On 02.08 the mechanism of
`MissingBuildCheckpoint` (`aibattle_item_policy.lua`, genuinely dead — it reads an empty
`Style.GetItemBuild`) was assumed to hold for `missingCheckpointItem` (`aibattle_survive.lua`,
hardcoded list, very much alive). It held a second consumable cap and made a shipped fix half
work. `--twins` prints both.

Compare rates per minute, not raw counters. Attribute every match to the build SHA written in
its log. Validation debt is `git log <match-build>..HEAD`; do not carry a hand-written count.

One behavior batch should have a clear expected signature and a match before another risky
batch. Tooling, tests, documentation, and behavior-preserving deduplication may be grouped.

## Toolchain

- `tools/postmatch.py <matchid>`: main post-match report.
- `tools/pathology.py <matchid>`: movement/watchability shapes.
- `tools/betting.py <matchid>`: betting/product metrics.
- `tools/binding.py`: prove that config knobs reach behavior.
- `tools/project_inventory.py`: current sizes, direct action surface, shared state writers,
  and dead local helpers.
- `tools/run_tests.py`: dependency-free Python test runner.
- `tools/check_schema_contract.py`: Python/Lua/prompt/config schema agreement.
- `tools/check_all.py --skip-live`: local pre-deploy gate.
- `tools/check_all.py --twins NAME`: every Lua definition whose name reads like NAME, with
  file and line. Run before claiming any function is dead or unreachable.
- `tools/deploy.bat [code|playstyle|all|general|check]`: explicit deployment profiles.

## Collaboration

Claude may edit the project in parallel. Before every edit, commit, or deploy, re-read
`git status` and the touched diff. Work with concurrent changes; never revert them implicitly.
Runtime/tooling is normally Codex-owned. Live strategy/config tuning is normally Claude-owned,
but the user's newest instruction always wins.
