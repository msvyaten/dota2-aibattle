# AIBattle Architecture

Last updated: 2026-08-29.

> This is the **conventions / philosophy** doc (how to add behavior, telemetry rules,
> decision order). For the **file inventory** (what lives where + line counts + a
> "where do I change X" guide), see [`CODE_MAP.md`](CODE_MAP.md). For open work with
> design, see [`SPECS.md`](SPECS.md).

Measured sizes and ownership leaks are generated, not maintained by hand:

```powershell
python tools\project_inventory.py
```

## Product Shape

AIBattle is an LLM-controlled 1v1 Dota bot product:

- the LLM chooses strategy through configs and model-facing rules;
- the bot engine executes those choices through stable runtime modules;
- match logs must explain what the bot wanted, what it did, and what blocked it.

The long-term goal is not to pile on fallbacks. The goal is a small decision engine with clear owners, clear telemetry, and small behavior modules.

## Ownership

Runtime code / architecture / deploy tooling / diagnostics is **formally Codex's** zone.
In practice, when Codex is unavailable Claude fixes runtime directly with the user's
approval (precedents: UseGlyph crash, arbiter hysteresis, the recovery buy-escape).

Configs (`bots/Customize/canonical_*.lua`) are **Claude's zone** — committable, but only
**with an explicit command** (they are strategy, not code).

**Never stage/commit without an explicit command** (live matchup state, not source of truth):

- `bots/Customize/playstyle_radiant.lua` — live binding: which canonical runs on Radiant.
- `bots/Customize/playstyle_dire.lua` — live binding: which canonical runs on Dire.

Full config/archetype list and roles: see [`CODE_MAP.md`](CODE_MAP.md) §4.

### Adding a behaviour: re-target before you add an owner

A new behaviour is usually a better TARGET for an action the bot was already allowed to take,
not a new candidate in the election. Prefer the re-target.

Every gate in the attack path — hp floor, tower danger, uphill, concede-lane, dive licence —
was written because the bot did something stupid without it. A new high-priority candidate
starts life above all of them and inherits none, so it re-opens each of those bugs one at a
time. The healing-ward work (03.08) is the worked example: "kill the ward before trading" was
added by pointing the already-permitted swing at a different unit in three call sites behind
one shared helper, and every existing gate kept deciding the tick.

Add a real owner when the behaviour needs to WIN a tick that something else would otherwise
take. Re-target when it only needs to change what the winner does with it.

### A guard that defers to another owner must know what that owner does back

Two guards can each yield to the other, produce no action, and log no error. Live examples:
the buy guard waiting on a fountain floor that never ran (`b7209fd`), and the drink waiting on
a trip while the trip waited on the drink (open, `BACKLOG.md`). When writing "skip this,
because X will handle it", go read what X does when it sees this guard.

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

- `aibattle_engine.lua`: stage runner, candidate arbitration, and the shared kill/recovery/rune
  policies, including `PowerRuneState`, `RuneUsePolicy`, and `IsActionPowerRune`.
- `aibattle_style.lua`: config loading, clamping, diag helpers, model-facing rules/dials.
- `aibattle_constants.lua`: internal numeric guards and distances.
- `aibattle_laning_context.lua`: per-tick lane snapshot.
- `aibattle_laning_creeps.lua`: last-hit, push, deny, ranged spacing hooks.
- `aibattle_laning_combat.lua`: hero contact, chase, ability pressure, power-rune pressure.
- `aibattle_laning_recovery.lua`: low-HP gates, critical recovery, recovery-yield logic.
- `aibattle_laning_safety.lua`: visual hold/AFK, creep damage reaction, damage unstuck, CS watchdog.
- `aibattle_laning_tempo.lua`: pregame, pre-creep standoff, tower dive policy, death window.
- `aibattle_laning_arbiter.lua`: the tick election. Scores every candidate without letting
  it act, sorts by score, then walks down the sorted list calling `action()` until one
  returns true. It is a priority cascade, not a single-winner election: a candidate that
  scored fifth owns the tick if the four above it decline. A desire that wins and cannot
  act logs `blocked=top-arbiter reason=empty_action` and loses its hysteresis; a tail
  candidate falls through silently, which is what the old sequential tail did.
### Two words the project kept using as one

**Elected** is the candidate that won the score election. **Acted** is the one that produced the
action. Because the arbiter is a cascade they are routinely different, and almost every
measurement mistake made against this codebase comes from reading one as the other:

- `intent=top-arbiter winner=X` is logged only when X's action returned true. X **acted**.
- `blocked=top-arbiter reason=empty_action winner=X` means X was **elected and did not act**.
  Something further down almost certainly did, on the same tick.

So `empty_action` does not count lost ticks. It counts elections that did not become actions,
and the cost is a score that lies about who is doing the work - the election is won at 124 and
the tick is spent by a candidate scoring 40 - rather than a tick nobody spent. Reading it as
lost ticks turns a scoring problem into an imaginary behaviour problem, and pointed at a
refactor of the fight candidate that would have fixed telemetry and changed nothing on screen.

Two more traps in the same reports. `empty_action` is emitted for the desire band only, so tail
candidates that decline are invisible by design; and the "who acted" panel is a ~1.5s sample,
because `Style.Intent` rate-limits on the shared name `top-arbiter`, so its shares are usable
and its absolute counts are not.

The genuinely lost tick has a different shape and no counter at all: an owner that returns
`true` having done nothing ends the cascade, so everything below it - including the anti-AFK
backstops at 8 and 2 - never runs. That is what wave-watch did until `1c458c5` gave it a real
action and `d377da7` bounded it.

Telemetry itself is narrower than it looks from the call sites. There are **five** primitives,
all in `aibattle_style.lua`: `Diag` (plain counter), `DiagRL` (the same, at most once per `sec`),
`DiagEdge` (once per occasion - it counts how many times a thing came up, where DiagRL counts how
long it lasted), `Intent` and `Blocked`. Everything else that looks like a separate channel is a named wrapper that adds a
prefix or a default - `ctx.diag`/`ctx.blocked` bind the bot, `ctx.state` prefixes `state-`,
`ctx.towerOpportunity` and `runeTxn` are fixed-name Intents, `TickOwner` is an Intent with a
throttle. `Engine.Intent`/`Engine.Blocked` emit nothing at all; they build candidate records.

The one real trap in it is that the three counters live on different scales, so a ratio between
a pair drawn from two of them is wrong. `STATE.md` under "Evidence Rules" carries that rule and
the honest pair to use in anti-idle.

- `aibattle_laning_policy.lua`: named HP bands, top-level desire gates, score weights, and forward/siege thresholds.
- `aibattle_laning_duel.lua`: pregame/prewave duel movement.
- `aibattle_laning_siege.lua`: tower pressure and allied-tank rules.
- `aibattle_laning_survival.lua`: creep aggro relief and combat safety candidates.
- `aibattle_laning_trade.lua`: hero trade candidates and chase scoring.
- `aibattle_runes.lua`: bottle rune transaction, staging, pickup memory.
- `aibattle_item_policy.lua`: AIBattle bottle/mango/TP/purchase guards.
- `aibattle_survive.lua`: healing and regeneration - fountain recovery, defensive heal,
  lane regen, and the consumable/bottle/rune fallback chain.
- `aibattle_utils.lua`: shared geometry helpers - retreat/forward tower locations, uphill
  miss chance, real tower threat.
- `aibattle_motor.lua`: movement ownership (`Claim`/`Active`/`Release`).
- `aibattle_intents.lua`: public intent family taxonomy for summaries.

When adding a new behavior:

1. Put it in the narrow owner module.
2. Add it to the ordered runner only where it should compete.
3. Emit one public intent family and one specific diag key.
4. Add blocked reasons instead of silent returns.
5. Keep `tools/deploy.bat` and `tools/check_all.py` green.

Top-level desire scores must be explainable in telemetry. Prefer details like `base=78 range=18 execute=20` over anonymous final scores.

## Decision Order

A tick has two parts: a head of guards that short-circuit, then one election.

**Head** - each of these returns and ends the tick if it acts. None of them appears in the
arbiter's telemetry, which is why a tick the head took cannot be explained from the winner
line. Collapsing the head into the election is the open P1-B work.

1. true-emergency survive, then emergency-low recovery;
2. urgent fight intents: kill lock and channel interrupt;
3. early-low recovery, then the recovery owner;
4. prewave duel and pre-creep standoff.

**Election** - everything else competes in one call to `Arbiter.Run` (P1-A). Scores encode
priority across two bands that were merged, not unified:

| Band | Score range | Where the number lives |
|---|---|---|
| desires - `safety`, `power-rune`, `fight`, `recover`, `siege` | 66-126 live, 40-44 when capped | `aibattle_laning_policy.lua`, `M.Score` |
| `last-hit` | 140 | inline in `mode_laning_generic.lua` |
| lanework / position / idle tail | 56 down to 2 | inline at each `tail(...)` call |

Two things about that table are load-bearing and easy to break:

- **The no-action caps are calibrated against a number in another file.** When a desire has
  symptoms but no feasible action, its score is capped (`safetyNoAction` 44, `fightNoAction`
  40, `recoverNoAction` 44, `siegeNoAction`). Those values are chosen to sit *below*
  `tail("safe-cs", 56)` so a symptom-only desire yields the tick to farming. Changing either
  side without the other reintroduces "the bot idles under the tower instead of last-hitting".
- **`last-hit` is the one candidate that can never yield.** It scores 140, above every desire
  including `safetyDanger` (126), and its action always returns true. It is safe only because
  its gate is strict - hp floor, no tower danger, creep within reach, no active siege. Widen
  that gate and you have given last-hitting absolute priority over safety.

If two layers fight for the same tick, add ownership or priority to the existing layer
instead of adding a new fallback at the end.

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
When a runtime module is retired, add it to the deploy cleanup and stale-live check. Live Dota must not keep old modules that are no longer part of the engine.

The Python side follows the same contract: telemetry parsing belongs in `tools/aibattle_log.py`,
and the generator schema belongs in `backend/style_schema.py`. Reports may derive different
metrics, but they must parse the same source telemetry identically.

Keep technical gates and product gates separate. `scorecard.py` answers whether a match was
runtime-clean enough to trust. `product_scorecard.py` answers whether it had enough tension,
bottle economy, early action, and mutual danger to be worth showing or pricing. A product gate
failure is a watchlist signal, not a reason to reject an unrelated syntax/runtime fix.

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
