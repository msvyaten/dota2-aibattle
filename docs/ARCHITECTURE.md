# AIBattle Architecture

Last updated: 2026-06-26.

## Product Shape

AIBattle is an LLM-controlled 1v1 Dota bot product:

- the LLM chooses strategy through configs and model-facing rules;
- the bot engine executes those choices through stable runtime modules;
- match logs must explain what the bot wanted, what it did, and what blocked it.

The long-term goal is not to pile on fallbacks. The goal is a small decision engine with clear owners, clear telemetry, and small behavior modules.

## Ownership

Codex owns runtime code, architecture, deploy tooling, diagnostics, and behavior fixes.

Claude currently owns strategy/config changes. Do not stage or commit these files unless the user explicitly asks:

- `bots/Customize/canonical_ganker.lua`
- `bots/Customize/canonical_pusher.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`

## Rules, Dials, Constants

Use the right layer:

- `rules`: model-facing strategic choices, for example `hero_priority`, `creep_wave_priority`, `low_hp_behavior`, `rune_use_policy`.
- `dials`: model-facing numeric preferences in the 0..1 space, for example aggression/farm/rune pressure.
- `aibattle_constants.lua`: engine thresholds, distances, cooldowns, and hard safety limits.
- policy modules: logic that turns rules/dials/constants into decisions.

Do not put implementation details such as rune staging distance, AFK heartbeat seconds, or tower leash radii into LLM-facing `rules`. Those are engine constants or policy internals.

## Runtime Modules

`mode_laning_generic.lua` is the orchestrator. It should describe order and ownership, not hold every behavior inline.

Current owners:

- `aibattle_engine.lua`: stage runner, candidate arbitration, shared kill/recovery/rune policies.
- `aibattle_style.lua`: config loading, clamping, diag helpers, model-facing rules/dials.
- `aibattle_constants.lua`: internal numeric guards and distances.
- `aibattle_laning_context.lua`: per-tick lane snapshot.
- `aibattle_laning_creeps.lua`: last-hit, push, deny, ranged spacing hooks.
- `aibattle_laning_combat.lua`: hero contact, chase, ability pressure, power-rune pressure.
- `aibattle_laning_recovery.lua`: low-HP gates, critical recovery, recovery-yield logic.
- `aibattle_laning_safety.lua`: visual hold/AFK, creep damage reaction, damage unstuck, CS watchdog.
- `aibattle_laning_tempo.lua`: pregame, pre-creep standoff, tower dive policy, death window.
- `aibattle_laning_arbiter.lua`: top-level laning desire arbitration; evaluates `safety / power-rune / fight / recover / siege` candidates by score and runs only the winner.
- `aibattle_laning_duel.lua`: pregame/prewave duel movement.
- `aibattle_laning_siege.lua`: tower pressure and allied-tank rules.
- `aibattle_laning_survival.lua`: creep aggro relief and combat safety candidates.
- `aibattle_laning_trade.lua`: hero trade candidates and chase scoring.
- `aibattle_runes.lua`: bottle rune transaction, staging, pickup memory.
- `aibattle_item_policy.lua`: AIBattle bottle/mango/TP/purchase guards.
- `aibattle_intents.lua`: public intent family taxonomy for summaries.

When adding a new behavior:

1. Put it in the narrow owner module.
2. Add it to the ordered runner only where it should compete.
3. Emit one public intent family and one specific diag key.
4. Add blocked reasons instead of silent returns.
5. Keep `tools/deploy.bat` and `tools/check_all.py` green.

## Decision Order

The active laning loop should stay readable in this order:

1. hard tempo guards: respawn, pregame, tower-dive policy, death window;
2. urgent fight arbitration: kill lock and channel interrupt;
3. recovery policy: true emergency first, then yield to valid kill windows;
4. critical recovery lock, with explicit power-rune/kill-window yields;
5. prewave duel and pre-creep contact;
6. top-level desire arbiter:
   - `safety`
   - `power-rune`
   - `fight`
   - `recover`
   - `siege`
7. last-hit and safe lane work;
8. lower-priority harass, creep work, watchdogs, spacing, final positioning;
9. last-resort anti-idle.

If two layers fight for the same tick, add ownership/priority to the existing layer instead of adding a new fallback at the end.

## Telemetry

Logs have two levels:

- Public family: stable, small names used by match summaries and LLM-facing analysis, for example `fight`, `farm`, `rune`, `recover`, `safety`, `siege`.
- Specific diag key: implementation-level name used to fix exact behavior, for example `rune-stage-override`, `creep-aggro`, `visual-hold`.

Keep the public family list small. Add new specific diag keys freely when they explain behavior.

When a behavior refuses to act, prefer:

```text
blocked=<intent> reason=<short_reason> key=value
```

over a silent return.

## Deploy Contract

Every active runtime module must be covered by:

- `tools/deploy.bat`
- `tools/check_all.py`

`tools/check_all.py` intentionally fails when a `bots/FunLib/aibattle_*.lua` runtime module is not listed for deploy/check, or when the deploy manifest and check manifest drift.

Use deploy profiles carefully:

- `code`: runtime code only;
- `playstyle`: canonical configs and live bindings only;
- `all`: code plus playstyle;
- `general`: explicit lobby/general sync only.

## Size Guardrails

Keep files boring and small enough to review:

- `mode_laning_generic.lua` should remain an orchestrator; move new behavior into modules.
- One module should own one reason to move/attack/recover.
- A function that needs many unrelated config fields probably belongs in a policy helper.
- A fallback that returns true every tick should be treated as a decision owner and logged as such.
