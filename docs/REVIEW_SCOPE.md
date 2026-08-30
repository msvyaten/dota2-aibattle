# Review scope

What we are asking for, what to read to answer it, and what to ignore. Written so a teammate
can move from the global picture to local code without rediscovering the project map.

## The one number this product hangs on

Two LLM-configured bots play 1v1 mid against each other. The product question is not whether
a bot wins - it is whether the match is **worth watching**, and we measure that as **mutual
low**: seconds in which both heroes are simultaneously in danger.

For most measured matches, mutual low was `0s in 0 windows`. Both bots had danger windows,
but the windows did not overlap: one bot backed off, healed, came back; then the other did.
That is what "boring" looks like as a number.

The first non-zero signal appeared in match `8968270421` on build `81547c2`: `10s in 2
windows`. Treat this as a signal, not proof. It was about 2% of a short, one-sided match with
zero lead changes. Later accepted matches can still fall back to `0s`, so the review question
is now sharper: why is simultaneous danger rare and unstable?

Everything below exists to help answer why.

## What we want from the review

Four tracks, in priority order. Answers we can act on beat a list of style findings.

### 0. Are the current documents, code boundaries and tools enough to work efficiently?

Before gameplay advice, tell us what still wastes review time: stale docs, duplicated
ownership, missing tests, unclear metrics, or places where the vendor boundary leaks.

### 1. Is "one owner per tick" still the right model, or has it become a cascade we should cut?

`aibattle_laning_arbiter.lua` scores every candidate without letting it act, sorts by score,
then walks down the sorted list calling `action()` until one returns true. A candidate that
ranked fifth owns the tick when the four above it decline.

Two numbers in that ladder are load-bearing and live in different files: the no-action caps
(`safetyNoAction` 44, `fightNoAction` 40, `recoverNoAction` 44 in `aibattle_laning_policy.lua`)
are calibrated to sit below `tail("safe-cs", 56)`, which is written inline in
`mode_laning_generic.lua`. And `last-hit` scores 140 - above `safetyDanger` at 126 - with an
action that always returns true, making it the only candidate that cannot yield.

One thing to know before reading any match log for this question: **the cascade is only half
visible in telemetry.** `empty_action` is logged when a candidate in the *desire* band wins and
declines; tail candidates in the lanework, position and idle bands fall through silently, on
purpose, because they replaced an older sequential tail that logged nothing. So `empty/min` on
the scorecard is not "ticks wasted" - the tick is handed straight down and something lower
usually acts. What it actually measures is how often the top of the ladder wins an election it
cannot honour, and the cost is that the score is a lie, not that the tick is lost: the election
is won at 124 and the work is done at 40.

The reverse case is the one that does cost a tick, and it is invisible: an owner that returns
`true` having done nothing ends the loop, and everything below it - including the anti-AFK
backstops at scores 8 and 2 - never runs. `wave-watch` was doing exactly that until `1c458c5`
gave it an action and `d377da7` bounded it.

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

### 3. Is near-zero mutual low a mechanics defect or a scoring defect?

Put differently: does the engine make simultaneous danger impossible, or does the scoring
ladder always find a reason for somebody to disengage first? The evidence lives in
`aibattle_laning_trade.lua` (kill lock, heal interrupt, passing trades),
`aibattle_laning_combat.lua` (hero contact, chase, ability pressure) and the recover/safety
scores in `aibattle_laning_policy.lua`.

There is now a third possibility, and it should be tested before the other two: **the metric may
be measuring the wrong thing.** `8972520526` held its outcome to the final second - decided at
95% of the match, 4.8% dead tail, the loser ahead on last hits - and scored `mutual low = 0s`.
That match had whatever "worth watching" means, and the number did not move, while `decided_at`,
`dead_tail` and `deficit_overcome` all tracked it correctly. Simultaneous near-death is one
specific way a match gets tense, not the only one.

So the question splits. If simultaneous danger is the real goal, the disengage question above
stands. If we picked it as a proxy for tension because it was cheap to compute, the fix is in
`betting.py`, not in the ladder - and chasing it through combat code would be optimising a
metric instead of the product. One match is not an answer, but it makes the proxy look weak.

### 4. What should change before expanding to more heroes and 5v5?

The current live baseline is Shadow Fiend 1v1 mid. Juggernaut melee has been tested, but many
assumptions still smell ranged/SF-specific: attack range, windup, melee-pack spacing, spell
targeting, sustain, rune timing, item builds, and kill thresholds. For 5v5, do not assume the
1v1 owners scale directly: enemy selection, lane ownership, teamfight roles, wards, roam, rune
control, telemetry volume and OHA/vendor ownership all need a staged plan.

We want a roadmap with smallest playable milestones, not a rewrite proposal.

## What to read

About 1,000 lines of documentation and 2,400 lines of code. Not 199,000.

**Documents, in order:**

| File | lines |
|---|---:|
| `README.md` | 151 |
| `NOTICE.md` | 47 |
| `docs/TEAM_REVIEW_START.md` | short |
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
| `bots/BotLib/hero_nevermore.lua` | vendor | SF baseline ability behaviour |
| `bots/BotLib/hero_juggernaut.lua` | vendor | melee contrast |
| `bots/mode_roam_generic.lua` / `mode_team_roam_generic.lua` | vendor patched | 5v5 expansion |
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

Expect `[ok] all checks passed` and the current Python test count. This gate also checks architecture, not just
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
- **The working branch is `1v1-mid-validation`, not `main`.**
- Three files under `bots/Customize/` are deliberately dirty in `git status`
  (`general.lua`, `playstyle_radiant.lua`, `playstyle_dire.lua`). They hold live experiment
  state, not source of truth. Do not commit them.
- Compare rates per minute, never raw counters between matches of different length.

## Evidence set

Use these matches before proposing gameplay changes. The first three are the newest and carry
most of the evidence for questions 1 and 3; the last three are the older baseline.

- `8972520526` - **the one that reframes question 3.** Best tension profile in the series
  (decided at 95% of the match, 4.8% dead tail, loser ahead on last hits) and `mutual low = 0`.
- `8972598364` - the kill lock broke off a finish at `ehp=10` under `chase_into_tower` (fixed
  since); the fountain return walked because `fountain-floor reason=heal_in_hand` kept the trip
  owner out of the tick; the rune scan read `nearest=inf` all match for Dire while Radiant
  committed and arrived late twice - same code, different result, not yet diagnosed.
- `8969965270` - decided at 78s with an 87% dead tail: the one-sided end of the range.
- `8964702771` - accepted technical gate, two lead changes, mutual low still zero. The only
  match here that passed the gate; `8968270421` and `8926148548` are older and superseded.

```bash
python tools/postmatch.py 8972520526   # then 8972598364, 8969965270
python tools/betting.py 8972520526 8972598364 8969965270 8964702771
```
