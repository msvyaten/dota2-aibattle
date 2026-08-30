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

## Empty `fight` Wins - Found 28.08 (from 5 logs, no match needed)

**Predicate gap.** `fightCanAct` is THREE conditions against **38 refusal points** in the action
itself. `c2ed8ac` added a fourth (`uphill`), Codex a fifth (`abilityReady`); about 33 remain.

**`empty_action` is NOT a burnt tick** ([aibattle_laning_arbiter.lua:92-128]): the arbiter falls
through and a lower candidate takes the tick. The cost is that THE SCORE LIES - the election is
won at 124 and the work is done at 40. Real empty ownership is `return true` with no action.
**Consequence: splitting `fight` fixes telemetry, not behaviour.**

The `--never-fired` method gives a verdict about SPECIFIC matches. Always re-check it.

## Acceptance For The Edits Of 30.08 (signatures of the next match)

The 29.08 batch was accepted on the pair `8974058954`/`8974086880` - see `git show 9b95ba7`.
Remaining debt from it: six `*-no-edge` keys read 0, which means MEASURED BY NOTHING. That is a
different claim from "they do not work".

- **`c802251` rune trip:** `route_unsafe`/`enemy_near`/`spot_race_lost` carrying `stage=1|hold`.
  Already fired in `8974387496` (D, enemy at 567 with hp 44) - hold it, do not widen it.
- **`51b9896` tower cover:** `siege-thin-shield` counts the refusals when cover is one creep.
- **`9c94a06` creep before tower:** `siege-creep-first` LEAVES ZERO and `siege-terminal-tower`
  falls. If terminal did not move, the wave really was hitting the tower - that is a pass,
  not a failure.
- **`153ee96` consumables owner:** acceptance here is SUBTRACTION, read both directions - total
  consumables drunk must NOT fall, and `heal-skip-trip-committed` catches the clarity drunk on
  the way to the fountain. The vendor-refusal counter was rewritten before the match (`9c7b732`).
  It used to be `vendor-heal-suppressed`: ONE key for seven items on a 30-second window, so it
  measured windows rather than refusals and could not exceed about seventeen in a whole match -
  it would have read as "the switch barely fired" whatever the truth was. It is now
  `vendor-heal-suppressed-<item>`, edge-triggered (`DiagEdge`, 1.0s), which puts the number on
  the SAME scale as what got drunk: `-flask` against flasks, `-clarity` against clarities.
- **`03a70bf` penalty for being behind:** `hp_behind` in the `state-desire-fight` detail; fight
  stops winning the tick at a deficit of 0.15 or worse. The risk is the inverse of the bug: if
  `mutual low` and kill pressure both go to zero, the cap is too wide before it is wrong - move
  the threshold, do not throw the edit away.

## Measured Debts 29.08 (not blockers, fix one at a time between matches)

- **About 140 hardcoded hp thresholds duplicate named constants** (`0.45`=`activeRecovery` in 27
  places, `0.35`=`danger` 22, `0.55`=`softRecovery` 16, `0.30`=`critical` 14). The VALUE was
  compared, not the meaning - read every site. The precedent was paid for in `7e2b066`.
- **Tower branch shadowing - partly closed by `9c94a06`** (the branch that hits the CREEP was
  raised). The four branches that hit the TOWER are still shadowed by `terminal` (+180 against
  +60). **`ERA_START`** in `binding.py` spans both hero populations - split it into eras.
- **`binding.py` is unanswerable on the current series BY CONSTRUCTION**: the configs were
  written by three models from ONE text, the dials sit within 0.05-0.10 of each other, and
  `MIN_ROWS=6` means three matches on one build. The user's call: either a second, opposing
  prompt text, or rewrite the tool to answer "how far apart are the readings". Permanently red
  is the worst option.

## Open After `8974387496` (confirmed twice, reproduces)

- **Walking to the fountain.** `fountain-floor` refuses on `heal_in_hand`/`heal_in_flight`, and
  the TP home belongs to THAT owner, so `anti-idle:2` drives the bot instead. In `8974387496`
  Dire left past its own T2 in the sixth minute walking TOWARD THE COURIER with a flask on it,
  not toward the fountain.
- **Runes: `nearest=inf`** while runes are alive (`rune-ground-truth status=2`), 11 R / 37 D.
  The scan requires `RUNE_STATUS_AVAILABLE`, that is, visibility of the spot. NOT diagnosed.
- **Spells are not ours.** Shadowraze is cast by the vendored `BotLib/hero_nevermore.lua`, which
  reads NO dial (`ability_aggro` was withdrawn in `dfac88a`). The cast point is a fixed distance
  along the facing direction, and the hit is a linear extrapolation with the radius cut when
  `GetMovementDirectionStability` is low - so it misses exactly when a trade starts.
- **`safety` wins the election and cannot act:** `safety-candidate no_action_capped` 47 times in
  a match, and the tick falls through to `wave-watch:10`. Both Radiant deaths went through this.
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
