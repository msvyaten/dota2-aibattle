# Team Review Start

This is the shortest path for a teammate joining the project. The goal is to start from the
global product and architecture picture, then zoom into local code hot spots with evidence.

## Review Discipline

Start with a fixed evidence pass before proposing code:

1. Run the local gate.
2. Run the inventory.
3. Read the review documents listed below.
4. Read the named code files only after choosing which review question you are answering.
5. Report findings with file/line references, expected runtime effect, and the smallest safe
   validation step.

Do not begin by refactoring large files. The large files shrink only when ownership moves out
of them.

## Commands

On a normal clone with Python in PATH:

```powershell
python tools\pre_match_state.py
python tools\check_all.py --skip-live
python tools\project_inventory.py
```

If `python` is not in PATH, `docs/HANDOFF.md` has the workstation-specific invocation. It is an
operator detail on one machine, not part of joining the project.

## Read First

1. `README.md` - product shape and glossary.
2. `NOTICE.md` - vendored OpenHyperAI boundary and licence status.
3. `docs/REVIEW_SCOPE.md` - what we are asking you to answer.
4. `docs/CODE_MAP.md` - where things live and what to ignore.
5. `docs/ARCHITECTURE.md` - decision order, ownership, telemetry.
6. `docs/STATE.md` - current queue and evidence rules.
7. `docs/HANDOFF.md` - operations, deploy, match tools.

`docs/BACKLOG.md` is the queue: what is pending and the signature each pending edit will be
judged by. Read it. `docs/SPECS.md` and `docs/history/` are Russian working notes - useful
background, not required reading.

## Current Snapshot Rules

Never trust a SHA or live binding copied into a document. Always run `tools\pre_match_state.py`.

As of the last local audit, branch `1v1-mid-validation` had repo HEAD and LIVE aligned, while
the live experiment files were dirty:

- `bots/Customize/general.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`

Those files are live matchup state. Do not commit or clean them unless explicitly instructed.
`pre_match_state.py` prints `dirty_expected_only` so this state is visible without pretending
the tree is clean.

## High-Value Questions

The work has four tracks. Keep findings grouped by track so we can approve or stop each
thread cleanly.

### Track 1 - Review the current system

Answer these before suggesting broad cleanup:

1. Should the tick arbiter stay a priority cascade, become explicit priority tiers, or become
   a utility model?
2. How should cross-file `bot.aib_*` state get owner APIs without a rewrite?
3. Why does `fight` still win ticks and then fail to act at live scores? Read the correction in
   `ARCHITECTURE.md` first: the tick is not lost, so this is a scoring problem, and a fix that
   only splits the candidate changes telemetry and nothing on screen.
4. Should recovery move next as one destination-aware owner, or should urgent head decisions
   move into the arbiter first?
5. What minimum product metric set proves that two generated strategies are watchable and
   priceable?

Bottle/rune economy is read from `postmatch.py`'s `rune/bottle transaction` panel. Start there
before using the aggregate empty-bottle percentage as a finding.

### Track 2 - Improve what exists

Separate polish from logic. Minor polish is documentation, telemetry naming, tests, and
contract checks. Logic changes need one expected signature and one match.

### Track 3 - Expand beyond Shadow Fiend 1v1

Shadow Fiend is the live baseline; Juggernaut melee work is exploratory. Review which
assumptions are hero-specific: attack range, windup, melee-pack spacing, rune timing, sustain,
ability targeting, item builds, and kill thresholds. Propose a small hero-readiness matrix
before adding more heroes.

### Track 4 - Prepare 5v5

Start from what already exists: five team dials (`gank`, `push`, `defend`, `ward`, `roshan`)
shipped for 5v5 and are dormant here, because the OHA team modes they scale barely run in a solo
mid lane. `push_desire` is the exception - it also feeds the laning siege ladder.
Treat 5v5 as a product mode, not a bigger 1v1. Identify which systems are 1v1-only
(solo-mid rune economy, lane front, tower pressure, enemy selection, shared telemetry volume)
and which OHA/vendor systems should remain owners. Propose a staged 5v5 plan with one
measurable gate per stage.

## Work Triage

Prioritize these first: a written architecture answer, a small patch with one match
signature, or a tooling check that prevents a known class of regression.

Push back on these until scoped: broad file splitting, vendor refactors, style-only Lua
cleanup, new fallbacks at the end of the tick, and claims based only on grep.

Ask for a stop/go checkpoint after any finding that changes tick ownership, recovery, combat
gates, rune economy, or the schema seen by the LLM.

Prefer written decision memos over speculative patches when the scope crosses tracks,
especially for hero expansion and 5v5. A good memo should save implementation time.

## Evidence Set

`REVIEW_SCOPE.md` holds it, with the commands and what each match is there to show. It is not
repeated here: this file carried its own copy, the two drifted apart, and a reviewer following
the stale one would have started from three matches that newer logs supersede.

Two things about that set are worth knowing before you read any of it. The Juggernaut logs and
the Shadow Fiend mirror are separate populations - matches got twice as short and every result
flipped to kills at that boundary, and it is the hero swap, not a change in the code. And in the
Shadow Fiend five, the configs never changed sides, so config and side are perfectly confounded
and none of those matches can tell you which one won. That was fixed afterwards by swapping the
sides and replaying: the pair at the top of the evidence set is what to read, and its answer was
that the side wins. Behaviour does follow the config - branch counters move with it on both
sides - but the result does not.

## Deliverable Format

Use this shape to keep the review actionable:

1. Findings, ordered by user-visible severity.
2. For each finding: file/line, runtime mechanism, why current telemetry proves or fails to
   prove it, and the smallest fix.
3. Risks: what could regress and which existing check catches it.
4. Validation: one command and, for behavior, one match signature.
5. Work estimate split into: no-match tooling/docs, low-risk code, match-required behavior,
   and speculative redesign.

For tracks 3 and 4, also include the smallest playable milestone and the minimum telemetry
needed to prove it worked.
