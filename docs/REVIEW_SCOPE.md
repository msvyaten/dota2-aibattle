# Review scope

What we are asking for, what to read to answer it, and what to ignore. Written so an
external reviewer does not have to spend billable hours working out where the project is.

## The one number this product hangs on

Two LLM-configured bots play 1v1 mid against each other. The product question is not whether
a bot wins - it is whether the match is **worth watching**, and we measure that as **mutual
low**: seconds in which both heroes are simultaneously in danger.

**In every match we have measured, mutual low is `0s in 0 windows`.** Both bots have danger
windows. The windows never overlap. One bot backs off, heals, comes back; then the other
does. Nobody is ever finished. That is what "boring" looks like as a number, and it has not
moved once across roughly 450 commits of gameplay work.

Everything below exists to help answer why.

## What we want from the review

Three questions, in priority order. Answers we can act on beat a list of style findings.

### 1. Is "one owner per tick" still the right model, or has it become a cascade we should cut?

`aibattle_laning_arbiter.lua` scores every candidate without letting it act, sorts by score,
then walks down the sorted list calling `action()` until one returns true. A candidate that
ranked fifth owns the tick when the four above it decline.

Two numbers in that ladder are load-bearing and live in different files: the no-action caps
(`safetyNoAction` 44, `fightNoAction` 40, `recoverNoAction` 44 in `aibattle_laning_policy.lua`)
are calibrated to sit below `tail("safe-cs", 56)`, which is written inline in
`mode_laning_generic.lua`. And `last-hit` scores 140 - above `safetyDanger` at 126 - with an
action that always returns true, making it the only candidate that cannot yield.

We want to know whether this should become explicit priority tiers, a real utility function,
or stay as it is.

### 2. How do we give `bot.aib_*` an owner without rewriting half the engine?

Eleven keys are written from two files each - `aib_healLast` from `aibattle_survive.lua` and
the orchestrator, the four `aib_fountain*` keys likewise, `aib_desireWinner` from the arbiter.
`python tools/project_inventory.py` prints the current list.

This is not theoretical. Two guards already deadlock through it: `blocked=heal-item
reason=fountain_trip_committed` on the same tick as `blocked=fountain-floor
reason=heal_in_hand` - the drink waits for the fountain trip, the trip waits for the drink,
and the bot leaves the lane holding an unused salve. Neither side logs an error.

We want a migration shape that can be done incrementally, not a rewrite.

### 3. Is `mutual low = 0` a mechanics defect or a scoring defect?

Put differently: does the engine make simultaneous danger impossible, or does the scoring
ladder always find a reason for somebody to disengage first? The evidence lives in
`aibattle_laning_trade.lua` (kill lock, heal interrupt, passing trades),
`aibattle_laning_combat.lua` (hero contact, chase, ability pressure) and the recover/safety
scores in `aibattle_laning_policy.lua`.

## What to read

About 850 lines of documentation and 2,400 lines of code. Not 199,000.

**Documents, in order:**

| File | lines |
|---|---:|
| `README.md` | 151 |
| `NOTICE.md` | 47 |
| `docs/CODE_MAP.md` | 293 |
| `docs/ARCHITECTURE.md` | 203 |
| `docs/STATE.md` | 150 |

**Code, for the questions above:**

| File | lines | Relevant to |
|---|---:|---|
| `bots/FunLib/aibattle_laning_arbiter.lua` | 132 | Q1 |
| `bots/FunLib/aibattle_laning_policy.lua` | 345 | Q1, Q3 |
| `bots/mode_laning_generic.lua`, lines 981-1661 | 680 | Q1 - candidate construction and the tick pipeline |
| `bots/FunLib/aibattle_engine.lua` | 274 | Q1 |
| `bots/FunLib/aibattle_laning_trade.lua` | 219 | Q3 |
| `bots/FunLib/aibattle_laning_combat.lua` | 518 | Q3 |
| `bots/FunLib/aibattle_laning_recovery.lua` | 405 | Q2, Q3 |
| `bots/FunLib/aibattle_constants.lua` | 51 | reference |

## What to ignore

- **Everything else under `bots/`** - about 190,000 lines of vendored OpenHyperAI engine.
  `.gitattributes` marks it, so GitHub collapses it in diffs. We do not refactor it; we patch
  it narrowly, and `docs/CODE_MAP.md` section 3 lists every one of those patches.
- **`docs/SPECS.md`, `docs/BACKLOG.md`, `docs/history/`** - Russian working notes. Nothing in
  the reading list depends on them.
- **File sizes as a finding.** `aibattle_survive.lua` and `aibattle_style.lua` are large and we
  know it. `docs/STATE.md` records the decision that they shrink by ownership extraction, not
  by line-count targets - a mechanical split before the ownership cuts makes review harder and
  cures nothing.
- **Telemetry volume.** About 4400 chat lines a match is a deliberate debugging decision, also
  recorded in `STATE.md`. It becomes a product problem only when a match has a spectator.

## Running it

No Dota install, no API key, no third-party packages. Python 3.12 verified on a clean clone;
the tooling is standard library only, and `openai` is needed solely for the optional API path
of the config generator.

```bash
python tools/check_all.py --skip-live
```

Expect `[ok] all checks passed` and 58 tests. This gate also checks architecture, not just
syntax: `require` cycles, deploy-manifest drift, the top-desire policy boundary, a
forbidden-fallback lint, and the schema contract between Python, Lua and the LLM prompt.

```bash
python tools/project_inventory.py
```

Current file sizes, direct engine-action call sites, cross-module state writers, dead local
helpers. Trust this over any number written in a document.

## Ground rules that will save time

- **Grep locates code; it never proves anything about it.** Before writing that a function is
  dead or never fires, read the whole body, and run `python tools/check_all.py --twins <Name>`
  - two similarly named functions in different files are two functions, and assuming otherwise
  has already cost us a half-working fix.
- **The working branch is `phase-2-team-dials`, not `main`.**
- Three files under `bots/Customize/` are deliberately dirty in `git status`
  (`general.lua`, `playstyle_radiant.lua`, `playstyle_dire.lua`). They hold live experiment
  state, not source of truth. Do not commit them.
- Compare rates per minute, never raw counters between matches of different length.
