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

Stage named files only; never `git add` the whole tree here.

## Product

A prompt is interpreted by an LLM into 11 numeric dials and 11 model-facing rules. The runtime
must turn that config into distinct, competent, explainable 1v1-mid behavior. The model picks
strategy; the engine owns mechanics and safety. Engine constants such as distances, rune
staging windows, AFK timing, and tower leashes must not leak into model-facing rules.

Bettability needs repeated runs on frozen code with the sides swapped. Five matches ran without
one and had side and config perfectly confounded. The swap was then played on frozen `d9cc1a7`:
`8974058954` (grok Radiant, 2:1) and `8974086880` (gemini Radiant, 2:0). **Radiant won both,
with opposite configs**, so read matches in PAIRS - one match cannot tell a config from a side.
Config-bound across the swap: branch counters (`cw-push`, `hero-prio-*`, `dw-farm`) and the
bottle, which gemini buys 50-70s earlier on either side. Side-bound: Dire's HP, median 64% and
56% in the laning window against 79% and 96%, mechanism not diagnosed. `8974387496` then broke
the streak - Dire won 2:0 on the same arrangement, one build later.

`mutual low` - seconds where both heroes are in danger at once - was picked as the number this
hangs on and is now suspect as a proxy: `8972520526` held its outcome to 95% of the match with a
4.8% dead tail and still scored `0s`. REVIEW_SCOPE question 3 - the fix may belong in
`betting.py`, not in the ladder.

## Current Architecture Status

Completed stages are not listed here - this file is the current plan, and a growing record of
finished work is what pushed it against its budget. `git log` holds it; the last structural one
is P1-A phase A (`a2bc9a9`), where top desires and the old tail began sharing one election.

Open structural work, in order:

1. Validate the current stack in a match. Read logs split into two populations that must not
   be compared in one row: Juggernaut (`8926148548`, `8927375253`, `8940466473`, `8964702771` -
   15.9-17.0 min, decided on towers and last hits) and the Shadow Fiend mirror (`8964741391`,
   `8968270421`, `8969965270`, `8972520526`, `8972598364` - 3.5-10.2 min, all five 0:2 on kills).
2. P1-B: migrate urgent head-of-tick decisions into the same arbiter.
3. P3-B.2: make recovery destination-aware and remove remaining parallel low-HP movers.
4. P3-C: windup protection, safe CS in soft recovery, and the remaining rune/recovery semantics.
5. P1-C: remove duplicated suppression/commit machinery and reduce anti-idle to a watchdog.

No mechanical file split before these ownership cuts: moving 500 lines without changing who
owns a tick makes review harder and cures nothing.

## Current Watchlist

- Recovery can still win while having no useful action; verify `empty_action by winner` and
  low-HP episode traces after every recovery change.
- **`fight` wins the tick and cannot act, on every build measured.** Full finding, including
  why it does NOT explain `mutual low` at zero, in BACKLOG "Empty `fight` Wins".
- **Five edits are deployed and unmeasured** (`c802251`..`03a70bf`), each with its acceptance
  signature in BACKLOG. One match reads all five at once; split the run in two if attribution
  matters more than throughput.
- Anti-idle still holds gameplay actions; its job is detection only. It empties **33-47%** of
  its activations on both sides, and it is what drives the bot when a real owner refuses.
- Two owners can deadlock by deferring to each other, and neither logs an error. Read what an
  owner does back before deferring; the open case is in BACKLOG "Open After `8926148548`".
- Cross-module `bot.aib_*` state is ownership debt; move writes behind owner APIs when
  touching those systems (`project_inventory.py` lists the writers).

## Telemetry Volume: Deliberate, Not Debt

Diag/Intent/Blocked all post to ALL CHAT (`ActionImmediate_Chat(msg, true)`); the console log
is a record of chat, and `print()` does not reach it, so chat is a bot script's only channel.
Measured 29.08: 4301 and 4789 AIB lines over 9-10 minute matches, ~8 a second. **User's call,
03.08: keep it while debugging** - it is the only source that says who owned a tick and why.
Do not "clean it up". It becomes a product problem once a match has a spectator, since
telemetry and watchability share one channel; then thin the per-event `intent=`/`blocked=`
traffic, which is the bulk of it. The dense counter dumps are not: 18 lines and 2% of the file.
`2cc71fc` throttles the pregame share (~6% of a log) and deliberately leaves the match alone.

## Evidence Rules

Use evidence in this order:

1. positions, HP, targets, and actions over time;
2. transaction/episode telemetry and tick owner;
3. cumulative diag counters;
4. rate-limited intent strings, which are lower bounds only;
5. visual observation, tied to a match timestamp.

Never divide two counters without checking both rate limits in the source: `Style.Diag` is
plain, `Style.DiagRL(bot, key, sec)` fires once per `sec`, `Style.DiagEdge(bot, key, gap)` fires
once per occasion, and side by side they invite a ratio that does not exist. In anti-idle the
only honest pair is `anti-idle-enter` against `idle`.

Ask the same question of a counter before the match, not after: does the key exist in `bots/`
at all, and is it on the same scale as the quantity the acceptance sets it against? The worked
case is in BACKLOG under the `153ee96` acceptance: a counter that failed both questions and was
caught on 30.08 before the match rather than after it.

Grep locates code; it never justifies a claim about it. Before writing that a function is dead,
unreachable, or never fires, read the whole body — the actual conditions, not the `return`
lines a grep happens to surface — and enumerate every definition that reads like it:

```powershell
python tools\check_all.py --twins <FunctionName>
```

Two similarly named functions in different files are two functions: on 02.08 the dead
`MissingBuildCheckpoint` was assumed to explain the very-much-alive `missingCheckpointItem`,
which held a second consumable cap and made a shipped fix half work. `--twins` prints both.

Compare rates per minute, not raw counters. Attribute every match to the build SHA written in
its log. Validation debt is `git log <match-build>..HEAD`; do not carry a hand-written count.

One behavior batch should have a clear expected signature and a match before another risky
batch. Tooling, tests, documentation, and behavior-preserving deduplication may be grouped.

## Toolchain

`CODE_MAP.md` sections 6-7 list every tool with its size and a "how do I ..." table, and that
listing is gate-checked. A second copy here had already gone stale - it was missing
`tools/series.py`, which is what sets the sides for a match and keeps a side effect from
masquerading as a model effect.

## Collaboration

Claude may edit the project in parallel. Before every edit, commit, or deploy, re-read
`git status` and the touched diff. Work with concurrent changes; never revert them implicitly.
Runtime/tooling is normally Codex-owned. Live strategy/config tuning is normally Claude-owned,
but the user's newest instruction always wins.
