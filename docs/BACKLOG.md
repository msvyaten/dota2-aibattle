# AIBattle Backlog

Open work only. Forensics and items closed before 2026-08-01 are in git history:
`git show ae2604d:docs/BACKLOG.md`. Never copy HEAD or LIVE out of this file; read them with:

```powershell
python tools\pre_match_state.py
```

## Next Gate

- Before reading a match, take the build debt: `git log <build-from-log>..HEAD`.
- **Read matches only in PAIRS** (both side arrangements). The side effect is larger than the
  config effect, and a single match cannot tell them apart - proved on `8974058954`/`8974086880`.
- Frozen until Juggernaut: the ward approach leg is a question of REACHABILITY, not aiming.

Read `python tools/postmatch.py <id>` top to bottom; the panels are written per edit:

- `runtime_errors`/`aib_err` = 0 and last hits > 0 on both sides - always first;
- **`sustain:`** - `bought`/`drunk` UP, `budget_cap` about 0, `stand-and-regen` DOWN;
- `deny probe`/`deny kill-test` - `deny-act` DOWN while `dn` does not fall;
- `tower pokes` - `backoff` > 0, `parked` instead of empty ownership, commit/terminal HOLD;
- `buy loop` - `stalled` stays 0; `anti-idle` - only an `enter`/`idle` pair.

## Empty `fight` Wins - Found 28.08

**Predicate gap.** `fightCanAct` is THREE conditions against **38 refusal points** in the action
itself. `c2ed8ac` added a fourth (`uphill`), Codex a fifth (`abilityReady`); about 33 remain.
What `empty_action` does and does not mean is in `ARCHITECTURE.md`; splitting `fight` fixes
telemetry, not behaviour. `--never-fired` judges SPECIFIC matches - always re-check it.

## Accepted on `8975911100` (build `53e4eeb`, R=grok D=gemini, Dire won)

`9c94a06` creep-before-tower came off zero after four matches; `153ee96` moved consumable
ownership to us (`mana-clarity` off zero); `03a70bf` capped the fight at an hp deficit without
killing kill pressure. `c802251`'s rune leg was measured on the next pair. Still measured by
nothing: `51b9896` (`siege-thin-shield`), now three matches running.

## Read on the pair `8976219545`/`8976241894` (build `4dfcc75`, sides swapped, Radiant won both)

Clean pair: same build, configs swapped, so behaviour claims hold and outcome claims do not.
Radiant won both with opposite configs - the side effect again.

- FIRED **melee-pack refusal claims the motor**: `melee_pack_refuse` 11 and 21. The volume worry
  did not land - nowhere near the 69 a match that would have suppressed lane movement.
- FIRED **`c802251` rune trip**: `spot_race_lost` 2 in the second match, measured for the first
  time in four builds.
- ZERO across both sides, so still measured by nothing: the clarity gate (`fountain_free_mana`),
  the tower-backoff damage leg (`cause=tower_damage`), the empty-bottle fountain floor
  (`empty_bottle_no_rune_floor`), and `siege-thin-shield` for the third match running. Their
  trigger conditions did not arise. Do not "fix" any of them on the strength of a zero.
- **`tower_any` refuted the reading it was built for.** Tower damage arrived ALONE in three of
  four side-matches (172/172, 64/64, 373/373); only Dire in the second carried 126 in company.
  So `tower=0` in `8975911100` was not damage hiding in `mixed`, and the tower hits the user
  watched at 6:14 are still unexplained - the `other=1021` bucket there is where to look next.

## Next signature: did the salve actually land

`heal-item` counted ORDERS. Below 0.30 the flask branch drinks on purpose while a hero is
hitting us, and damage cancels the channel. The healing modifier is now asked directly:
`heal-item-took` against `heal-item-cancelled` (`under_fire=` in the blocked line), plus
`heal-item-under-fire` for how often the risky path is taken. If cancelled dominates under fire,
the sub-0.30 bypass pays nothing and the threshold is what to move.

## Measured Debts 29.08 (not blockers, fix one at a time between matches)

- **About 140 hardcoded hp thresholds duplicate named constants** (`0.45`, `0.35`, `0.55`,
  `0.30`). The VALUE was compared, not the meaning - read every site. Precedent: `7e2b066`.
- **Tower branch shadowing - the creep branch is now measured off zero (`8975911100`).** The
  four branches that hit the TOWER are still shadowed by `terminal` (+180 against +60).
  **`ERA_START`** in `binding.py` spans both hero populations - split it into eras.
- **`binding.py` is unanswerable on this series BY CONSTRUCTION**: three configs from ONE text,
  dials within 0.05-0.10, and `MIN_ROWS=6` = three matches per build. User's call: a second
  opposing prompt, or rewrite it to measure how far apart the readings are.

## Open After `8974387496` (confirmed twice, reproduces)

- **Walking to the fountain.** `fountain-floor` refuses on `heal_in_hand`/`heal_in_flight` and
  the TP home belongs to THAT owner, so `anti-idle:2` drives instead. Seen again in `8975911100`
  at 6:34-6:59. The `empty_bottle_no_rune_floor` above is the first edit aimed at it.
- **Runes: `nearest=inf` is HONEST. Diagnosed 31.08; this entry used to state it wrong.** Status
  2 is not "rune alive" - `RUNE_STATUS_AVAILABLE` is 1, proved by which side logged
  `rune-clock-dead` in `8975911100` (Dire, whose first status-1 came after the check; Radiant's
  came before and never logged it). All 64 refusals fired at status 0 or 2, none at 1. The bottle
  stays empty because the bot is not at the spot when a rune appears: travel timing, not blindness.
- **Spells are not ours.** Shadowraze is cast by the vendored `BotLib/hero_nevermore.lua`, which
  reads NO dial. The cast point is a fixed distance along the facing direction, so it misses
  exactly when a trade starts - `git show dfac88a` for the whole mechanism.
- **`safety` wins the election and cannot act:** 47 times a match. The cause is now logged -
  `cause=symptom_no_action`, 16 R / 18 D in `8975911100` - so this can finally be worked on.
- **LLM dials barely reach tick ELECTIONS:** only `execute_threshold` and `farm_focus` enter them
  (36.4-39.6, that is 3.2 points against gaps of tens). `harass_desire`, `forwardness` and
  `retreat_caution` work INSIDE the owner that already won. The categorical rules matter most -
  they switch whole branches on and off.

## Open After `8926148548`

- **Healing and the fountain trip yield to each other.** In one tick,
  `heal-item/fountain_trip_committed` and `fountain-floor/heal_in_hand`: drinking waits for the
  trip, the trip waits for the drink, nobody acts. Which one stops being polite is a user call.
- **The `item_build` path is ready and the LIVE configs are empty** - all three `canonical_*`
  carry ZERO `item_build` (generated before the change). Regenerating changes the very thing
  under measurement, so it is a user call.
- **Which `anti-idle` leg walks the bot FORWARD at low HP.** The legs are instrumented
  (`lane`/`lowhp-back`/`push`/`combat`) - the data exists, the answer does not.

## Behaviour

- **`ability_aggro` was withdrawn 28.08 and should come BACK reworked.** Why it was pulled and
  what it cost (293 `invalid order (101)` in one match, 188 of them matched) - `git show dfac88a`.
  Its acceptance is closed: `invalid order (101)` = 0. **Open:** give the model an intensity knob
  without creating a second cast path.
- **`rune_control`.** The dial should drive planned rune collection, not only power-rune
  pressure; count completed transactions, not empty-bottle percentage.
- **Tower-aggro CS.** Controlled aggro-pull under T1 - after P3 and only on a new symptom.
- **Uphill / low-ground travel.** Not another step-back, but one combat path/position owner.

## Bettability

The headline number of the project is **`mutual low`**, from `state markets` in
`tools/betting.py` (`2d86ed6`). After `03a70bf` watch it especially: if it went to zero together
with kill pressure, the cap is too wide.

Still to do:

- tower HP/progress, and pressure measured with a live wave;
- a net-worth proxy instead of unspent gold (which is high because the bot saves for a component
  it cannot reach);
- advantages actually used (rune power windows, not merely holding one);
- series aggregation with a frozen build/config and a mandatory side swap.

New fields go into the shared parser `tools/aibattle_log.py` and under tests, or `match_stats`,
`postmatch` and `betting` will read the same line three different ways.

## Infrastructure

- Shrink `mode_laning_generic.lua`, `aibattle_style.lua` and `aibattle_survive.lua` by moving
  ownership, never by mechanically splitting files.
- `tools/project_inventory.py`: watch direct action sites, dead helpers and shared writers.
- `tools/check_schema_contract.py`: keep the Python/Lua/prompt/config schema in sync.
- Old forensics go to `docs/history`, never back into the active BACKLOG/HANDOFF.

## Invariants

- The model picks strategy; engine constants do not become LLM-facing rules.
- One tick, one owner of the ACTION (not of the election); the arbiter does not hold a candidate
  that cannot act.
- One risky behaviour batch, one expected signature, one match.
- Compare values per minute, and always tie a match to the build SHA from its log.
- Configs and live bindings are committed only on the user's explicit instruction.
- The structural queue lives in `STATE.md` ("Open structural work"), the mandates in
  `docs/SPECS.md`. Keep no copy here: on 29.08 such a copy drifted from its source a third time.
