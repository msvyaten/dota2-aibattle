# CODE MAP - what lives where, how big it is, who owns it

> Navigation map for anyone reading this repository for the first time.
> Rewritten in English 2026-08-27. **The numbers below are a snapshot, not the source of
> truth.** Current sizes, direct action sites, shared-state writers and dead local helpers
> come from `python tools/project_inventory.py`.
> Companions: `ARCHITECTURE.md` (product and ownership), `HANDOFF.md` (operations),
> `SPECS.md` (design mandates, Russian), `BACKLOG.md` (current queue, Russian).

---

## 0. TL;DR - the 30-second version

The product: **plain-English strategy -> LLM -> config -> measurable Dota 2 bot behaviour,
1v1 mid.** The base is a fork of the OpenHyperAI (OHA) bot-script engine; see
[`NOTICE.md`](../NOTICE.md) for attribution and licence status.

**Live matchup:** both sides play a `npc_dota_hero_nevermore` (Shadow Fiend) mirror, Radiant
on `canonical_gemini`, Dire on `canonical_grok`. A Juggernaut melee mirror was run earlier and
is frozen, not deleted - some constants and all positioning logic were written for a ranged
hero with 500 attack range, and mean something different at melee 150. **Never read the
current matchup out of this file:**

```powershell
python tools\pre_match_state.py
```

**Scale, and what is actually ours:**

| | lines | % of `bots/` | do we touch it? |
|---|---:|---:|---|
| **Our layer `aibattle_*`** (behaviour) | **8,195** | 3.9% | YES - all the logic is here |
| Configs `Customize/` | 678 | 0.3% | YES - archetype presets |
| **Our patches inside vendored files** | **~469** | 0.2% | CAREFULLY - 21 files, see section 3 |
| Vendored OHA (everything else in `bots/`) | ~190,000 | ~96% | NO - upstream base, synced from above |
| Tools (Python) | 5658 | - | YES |
| Backend (Python + prompt) | 720 | - | YES |

**Total Lua in `bots/`: ~199,000 lines. Ours: ~8,300 (4.2%)**, counting the vendor patches.

**Conclusion for a new engineer:** do not be scared by 199k lines of Lua. **You need to learn
about 8.5k** - the `aibattle_*` layer plus the configs. The rest is the OHA engine: read it
when you need to, never refactor it.

---

## 1. The AIBattle layer - our code (`bots/FunLib/aibattle_*.lua`, 8,195 lines, 22 files)

All behaviour lives here. One file, one responsibility.

### Core (decision engine and config)

| File | lines | Role |
|---|---:|---|
| `aibattle_style.lua` | 1296 | **The hub**: config loading (rules/dials), item/skill build, ability-harass config, and the telemetry primitives `Style.Intent/Diag/TickOwner/Blocked`. Everything calls it. |
| `aibattle_engine.lua` | 274 | Stage and intent runner: `Stage/Intent/Resolve`, `KillWindow`, `RecoveryPolicy`, `PowerRuneState`, `RuneUsePolicy`. |
| `aibattle_laning_policy.lua` | 345 | **Desire scoring**: `Safety/PowerRune/Fight/Recover/Siege` -> score; HP bands, thresholds, no-action caps. |
| `aibattle_laning_arbiter.lua` | 132 | **Top-desire arbiter**: `Run/Candidate` - winner hysteresis, tick owner. The heart of the choice. |
| `aibattle_constants.lua` | 59 | Engineering thresholds (distances, cooldowns, HP bands). Not model-facing. |
| `aibattle_motor.lua` | 45 | Movement ownership `Claim/Active/Release` (v1). Slated for retirement in P1-C. |
| `aibattle_intents.lua` / `aibattle_laning_context.lua` | 73 / 37 | Intent helpers and the per-tick context builder. |
| `aibattle_build.lua` | 4 | Build SHA stamp, overwritten by deploy. |

### Laning behaviour modules

| File | lines | Role |
|---|---:|---|
| `aibattle_survive.lua` | 1282 | **Healing and low-HP regen**: `fountainRecovery`, `defensiveHeal`, `regenLane`, `recovery` (bottle / flask / tango / rune fallback chain, buy-escape). |
| `aibattle_runes.lua` | 784 | **Runes**: `SeekBottleRune`, `FindWaterRecoveryRune`, staging and pickup memory, the bottle-fill transaction. |
| `aibattle_laning_safety.lua` | 747 | `CreepHitReact`, `DamageUnstuck`, `RangedMeleePackSpacing`, `LastHitWatchdog`, visual-hold / AFK anti-idle. |
| `aibattle_laning_combat.lua` | 563 | `HarassAndChase`, `ContactHero`, `AbilityPressure`, `RunePowerPressure`, `UphillReposition`, `EmergencyKillPriority`, `AbilityHarass`. |
| `aibattle_laning_tempo.lua` | 441 | `Pregame`, `DivePolicy`, `DeathWindow`, `PreCreepStandoff` - the hard stage guards. |
| `aibattle_laning_recovery.lua` | 426 | **Low-HP owners** (the P3 target): `ThinkIfAllowed`, `CriticalLock`, `ActiveLowHp`, `EmergencyRetreat`, `ForwardLowHpPullback`, `LowHpHoldState`. |
| `aibattle_laning_siege.lua` | 435 | Tower siege, siege-commit, and the latch owner API. |
| `aibattle_laning_creeps.lua` | 290 | `GetBestLastHitCreep`, `GetBestDenyCreep`, `HandleCreepWork`. |
| `aibattle_laning_duel.lua` | 212 | `Prewave` and `Pregame` duel movement. |
| `aibattle_utils.lua` | 236 | `SafeRetreatTowerLoc`, `ForwardSurvivingTowerLoc`, `EnemyTowerDanger`, `UphillMiss`, `IsTowerActuallyThreatening`. |
| `aibattle_laning_trade.lua` | 234 | `KillLock`, `HealInterrupt`, `PassingHeroTrade` - the urgent trades. |
| `aibattle_item_policy.lua` | 169 | `ShouldUseMango`, `ShouldDelaySpareTpPurchase`. |
| `aibattle_laning_survival.lua` | 117 | `CreepAggroRelief`. |

---

## 2. How a decision flows (one tick)

The orchestrator is `bots/mode_laning_generic.lua`. `GetDesire()` bids for the laning mode;
`Think()` -> `ThinkLaningCore()` runs the pipeline. After P1-A the old tail participates in a
single election, but an urgent head still runs before it.

```
HEAD - short-circuits, invisible to arbiter telemetry:
  1. true-emergency survive / emergency-low recovery                     [survive, recovery]
  2. urgent kill lock / channel interrupt                                [trade]
  3. early-low recovery / Recovery.Owner                                 [recovery]
  4. prewave duel / pre-creep standoff                                   [duel, tempo]

ELECTION - one call to Arbiter.Run:
  5. score every candidate WITHOUT acting: desires 66-126 (capped 40-44),
     last-hit 140, tail lanework/position/idle 56..2                     [policy -> arbiter]
  6. sort by score, walk down calling action() until one returns true
     - a desire that wins but cannot act logs empty_action and loses hysteresis
     - a tail candidate that yields falls through silently
```

The walk in step 6 is why this is a **priority cascade, not a single-winner election**: the
fifth-ranked candidate owns the tick if the four above it decline. `ARCHITECTURE.md` carries
the two calibration traps in this ladder - the no-action caps sitting just under `safe-cs` 56,
and `last-hit` at 140 being the only candidate that never yields.

Every decision is logged as `intent=<key>`, `blocked=<key> reason=<why>`, `tick-owner`, and
`top-arbiter winner/losers`, then read back by the tools in section 5.

**Open structural debt (see `SPECS.md`):** P1-A merged the middle and the tail, but the urgent
head still short-circuits the election (P1-B), and the suppress/commit/anti-idle machinery is
still duplicated (P1-C). P3 folds the remaining low-HP movers into one owner.
`mode_laning_generic.lua` is about 1.6k lines and should shrink as those ownership cuts land -
by extraction, not by moving lines around.

---

## 3. Entry points and patches inside vendored files

**This is the most important table in the map.** Each row is a place where our code lives
inside somebody else's. When the OHA base is updated, merge conflicts will happen here and
nowhere else.

Counted as lines mentioning `AIB` in a vendored file, which is reproducible:

```bash
grep -rlE "(^|[^A-Za-z])AIB" --include="*.lua" bots/ | grep -v "FunLib/aibattle_"
```

A patch that mentions no `AIB` identifier is invisible to this audit, so the marker is a
measurement tool, not a style preference.

| File | total lines | ours | share |
|---|---:|---:|---:|
| `bots/mode_laning_generic.lua` | 1661 | 286 | 17% |
| `bots/mode_roam_generic.lua` | 2209 | 42 | 1% |
| `bots/item_purchase_generic.lua` | 1418 | 31 | 2% |
| `bots/ability_item_usage_generic.lua` | 8482 | 23 | 0% |
| `bots/mode_retreat_generic.lua` | 856 | 15 | 1% |
| `bots/mode_push_tower_bot_generic.lua` | 38 | 9 | 23% |
| `bots/mode_push_tower_mid_generic.lua` | 34 | 8 | 23% |
| `bots/mode_push_tower_top_generic.lua` | 34 | 8 | 23% |
| `bots/FretBots/SettingsDefault.lua` | 442 | 6 | 1% |
| `bots/mode_roshan_generic.lua` | 189 | 6 | 3% |
| `bots/mode_rune_generic.lua` | 863 | 6 | 0% |
| `bots/mode_team_roam_generic.lua` | 1718 | 5 | 0% |
| `bots/FunLib/jmz_func.lua` | 6757 | 4 | 0% |
| `bots/mode_ward_generic.lua` | 211 | 4 | 1% |
| `bots/BotLib/hero_sniper.lua` | 707 | 3 | 0% |
| `bots/mode_defend_tower_bot_generic.lua` | 17 | 3 | 17% |
| `bots/mode_defend_tower_mid_generic.lua` | 15 | 3 | 20% |
| `bots/mode_defend_tower_top_generic.lua` | 17 | 3 | 17% |
| `bots/hero_selection.lua` | 1127 | 2 | 0% |
| `bots/FunLib/aba_defend.lua` | 1409 | 1 | 0% |
| `bots/FunLib/aba_role.lua` | 436 | 1 | 0% |

**21 vendored files carry about 469 of our lines.**

Rule: patch vendored files only where you must, and only narrowly. Every line here is a future
merge conflict.

---

## 4. Configs (`bots/Customize/`, 683 lines)

| File | lines | Role |
|---|---:|---|
| `canonical_farmer.lua` | 88 | "Farmer" archetype - economy, high `farm_focus`, `hero_priority=default`. |
| `canonical_brawler.lua` | 72 | "Brawler" archetype - fight on sight, high harass. |
| `canonical_pusher.lua` | 56 | "Pusher" archetype. |
| `canonical_ganker.lua` | 56 | "Ganker" archetype. |
| `canonical_deepseek.lua` | 39 | LLM-generated preset. |
| `canonical_gemini.lua` | 38 | LLM-generated preset, currently bound to Radiant. |
| `canonical_grok.lua` | 37 | LLM-generated preset, currently bound to Dire. |
| `canonical_oha_default.lua` | 12 | Bare OHA default - the baseline to compare against. |
| `hero/viper.lua` | 57 | Per-hero override. |
| `playstyle_radiant.lua` / `playstyle_dire.lua` | 1 / 1 | **The binding**: which canonical runs on which side. Live experiment state. Do not commit without an explicit instruction. |
| `general.lua` | 220 | Lobby and hero-pick settings. Live experiment state. Sync LIVE -> repo only. |

A preset is a table of `{ dials, rules, item_build, skill_build }`. The model-facing schema
lives in `backend/style_schema.py`; runtime validation lives in `aibattle_style.lua`; the two
are checked against each other by `tools/check_schema_contract.py`.

- **dials** - model-facing floats 0..1 (`harass_desire`, `farm_focus`, `forwardness`, `push_desire`, ...). Eleven of them.
- **rules** - model-facing discrete choices (`hero_priority`, `low_hp_behavior`, `tower_aggression`, ...). Eleven of them.
- **constants** - engineering values in `aibattle_constants.lua`. Never in a config.

---

## 5. Tools (`tools/`, Python, 4,628 lines)

| File | lines | Role |
|---|---:|---|
| `match_stats.py` | 1164 | Deep analysis - KDA/LH, intent families, arbiter behaviour, stationary spans, fix candidates. |
| `betting.py` | 711 | **Market layer**: the Radiant-minus-Dire advantage curve over time, market lines, in-play base. See below. |
| `product_scorecard.py` | 106 | Product gate: dead-tail, bottle economy, first event, lead changes, and mutual-low tension. |
| `hero_readiness.py` | 71 | Hero expansion matrix: what is covered for SF/Juggernaut and what is still risky. |
| `check_all.py` | 760 | The repo gate: encoding, Lua/Python syntax, deploy manifest, live drift, schema contract, tests, inventory. |
| `postmatch.py` | 623 | **Main match report**: scorecard, fix signatures, jitter breakdown. |
| `binding.py` | 279 | Proves a config knob actually reaches behaviour. |
| `test_match_stats.py` / `test_betting.py` / `test_project_inventory.py` | 324 / 108 / 12 | Tests. |
| `scorecard.py` | 139 | Bare PASS/FAIL verdict on watchability criteria. |
| `project_inventory.py` | 302 | Current sizes, direct action surface, shared-state writers, dead helpers. |
| `deploy.bat` | 129 | Deploy profiles. |
| `pathology.py` | 98 | Movement shapes: STALL and YOYO detection from positions alone. |
| `check_text_encoding.py` | 104 | Mojibake, ASCII-only runtime files, and the no-Cyrillic rule. |
| `aibattle_log.py` | 83 | The single telemetry parser everything else builds on. |
| `test_arbiter_ladder.py` | 399 | Ladder arithmetic and owner contracts, read as text; see its docstring for what green does not mean. |
| `check_schema_contract.py` | 110 | Python/Lua/prompt/config schema agreement, including the worked example the model copies. |
| `run_tests.py` | 104 | Runs the test files above without pytest. |
| `series.py` | 91 | Sets the sides for match N of a round robin, so a side effect cannot masquerade as a model effect. |
| `pre_match_state.py` | 86 | Branch, HEAD, live build, repo vs live playstyles, dirty files. Run before every match. |

### Why `betting.py` is separate from `match_stats.py`

They answer **different questions** and deliberately do not overlap:

| | `match_stats.py` | `betting.py` |
|---|---|---|
| Question | Did the bot work? (engineering QA) | Is there a market here, and how would you price it? |
| Looks at | each side on its own | the **Radiant-minus-Dire difference over time** |
| Reader | engine developer | product / bookmaker |

The one thing `match_stats.py` does not produce is the **advantage curve**. Every
`betting.py` metric derives from it. Both run offline against a finished
`console.<matchid>.log` - no Lua, no engine, no deploy involved.

**Per match** - the shape of the match over time:

- `first_event` - when the match came alive (first blood, or a trade costing >20% HP)
- `decided_at` / `dead_tail%` - when the outcome stopped being contested, and how much of the
  match was already decided. The direct measure of "does the tension hold"
- `lead_changes` - how often the lead changed hands
- `amplitude` - the swing of the gap. Catches what lead changes miss: the gap can move 1400
  gold without crossing zero - the sign never flips, but odds should still move
- `deficit_overcome` - the largest deficit the winner came back from. **Zero across a whole
  series means the live market dies after the first break** and there is nothing to bet on
  past minute three

**Per series** (`--series`) - ready-made market lines: totals (match-length distribution),
handicap (final-gap distribution), method-of-victory split (kills vs tower+LH), a replay-check
across four axes, and an empirical in-play base for P(win | gap at minute N). Six matches do
not price it; roughly 25-30 do. It accumulates from day one so the series does not have to be
replayed later.

**Deploy:** `tools/deploy.bat` from `cmd`, or copy the files into LIVE manually and stamp the
SHA into `LIVE/FunLib/aibattle_build.lua`. LIVE is
`...\dota 2 beta\game\dota\scripts\vscripts\bots\`. The match log is
`game\dota\console.<matchid>.log` (Solo Mid lobby, cheats on, `-condebug`).

---

## 6. Backend - the LLM config generator

| File | lines | Role |
|---|---:|---|
| `generate_playstyle.py` | 186 | API or offline JSON -> a validated Lua config. |
| `test_generate.py` | 140 | Offline tests for sanitising, JSON handling and Lua output. No API key needed. |
| `style_schema.py` | 39 | The single model-facing schema: 11 dials + 11 rules. |
| `system_prompt.txt` | - | The live generator prompt. |

---

## 7. Docs - what to read when

| File | Language | Open it when |
|---|---|---|
| `../README.md` | EN | First contact: what the product is, how to run the gate, glossary. |
| `../NOTICE.md` | EN | Before touching or redistributing anything: vendor attribution and licence status. |
| **`CODE_MAP.md`** (this file) | EN | You need to know where something lives. |
| `ARCHITECTURE.md` | EN | Conventions: decision order, ownership, telemetry, how to add behaviour. |
| `STATE.md` | EN | Current plan, open structural work, evidence rules. |
| `HANDOFF.md` | EN | Operations: paths, gate, deploy, match analysis. |
| `SPECS.md` | **RU** | Design mandates and open work with rationale. Working notes. |
| `BACKLOG.md` | **RU** | Current work queue. Working notes. |
| `history/` | **RU** | Old handoffs, prompt drift, manual match journal. Archive. |

---

## 8. "Where do I change X?" - quick reference

| I want to... | Go to... |
|---|---|
| Change how the bot plays | `bots/Customize/canonical_*.lua` (dials / rules) |
| Change the matchup (who plays whom) | `bots/Customize/playstyle_radiant.lua`, `playstyle_dire.lua` |
| Change how desires are scored (safety/fight/...) | `aibattle_laning_policy.lua` |
| Change tick order or arbitration | `aibattle_laning_arbiter.lua` + `mode_laning_generic.lua` |
| Change low-HP behaviour or regen | `aibattle_laning_recovery.lua` + `aibattle_survive.lua` |
| Change last-hit / deny / creep-wave handling | `aibattle_laning_creeps.lua` |
| Change harass / chase / ability use | `aibattle_laning_combat.lua` |
| Change rune and bottle behaviour | `aibattle_runes.lua` |
| Change tower siege | `aibattle_laning_siege.lua` |
| Change a threshold (distance, cooldown) | `aibattle_constants.lua` |
| Check SF/Juggernaut expansion readiness | `python tools/hero_readiness.py` |
| Add telemetry or a diag signature | `aibattle_style.lua` (`Intent/Diag/Blocked/TickOwner`) |
| Find out whether the bot worked in a match | `python tools/postmatch.py <id>` |
| Find out whether a match was worth watching | `python tools/betting.py <id>` + `python tools/product_scorecard.py <id>` |
| Find out what to do next | `docs/SPECS.md` (Russian), `docs/STATE.md` (English) |
