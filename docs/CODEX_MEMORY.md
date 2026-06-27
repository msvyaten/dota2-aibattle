# Codex Memory

Last updated: 2026-06-26.

Current live code build before latest arbiter-audit pass: `0b7e813`.
Current repo HEAD before latest arbiter-audit commit: `0b7e813`.

## Ownership

Codex owns engine/code cleanup and behavior fixes.

Claude currently owns config/playstyle changes. Do not stage or commit these files unless the user explicitly asks:
- `bots/Customize/canonical_ganker.lua`
- `bots/Customize/canonical_pusher.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`

## Latest Codex Commits

Post-regression fixes from `8868630321`:
- Root cause #1: old OHA hero-damage/offlane gate in `GetDesire()` could return `BOT_MODE_DESIRE_NONE` before the 1v1 laning override. With `heal=active`, Dire stopped thinking after early damage, producing no `top-arbiter`, no CS, and `LH=0`. In 1v1 this gate is now bypassed so AIBattle recovery/farm/fight owners keep running.
- Root cause #2: `PreCreepStandoff()` ignored `pregame_behavior` and always built an `aggressive_mid` anchor after horn. `pgb=safe_tower` could still be dragged into mid contact, take early damage, and fall into recovery. Post-horn precreep anchor now respects the configured pregame behavior.
- Match evidence: `8868630321` Dire stood at `-427,-296` from 31s to 97s with enemy at ~780u and LH=0, while no top-arbiter/farm/fight intents were emitted. That pattern means mode ownership was disabled, not merely a bad last-hit choice.

Post-regression fixes from `8868671903`:
- Match still had 0 hero damage and almost no CS on `bff62b6`; both bots stayed on pregame anchors for minutes while `tick-owner stage=laning-core` misleadingly implied work happened.
- Fixed `ThinkLaningCore()` return semantics so `laning-core` only reports handled when a real owner/fallback returns true; this should make future `tick-owner` telemetry honest.
- Fixed `HarassAndChase()` so a failed `moveToAttackEdge()` no longer returns handled=true.
- Added a 1v1 lane-line last resort that moves along the own-T1 -> enemy-T1 line by `forwardness` when all normal owners yield, preventing silent parking on pregame anchors.
- Follow-up without logs: `PreCreepStandoff()` no longer consumes the tick with `precreep-hold` when already at anchor and no action is issued; it yields to core fallback instead.
- Follow-up from interrupted `8868751540`: if lane-line fallback's first target is too close to the current anchor, it advances the target by +0.12 forwardness instead of silently yielding. Dire had sat at `170,299` with the enemy ~1105u away and no actions.
- Live `8868768840` showed Dire got only `state-post-horn-reset` after `t=0` and then no `tick-owner`, while staying at `170,299` with 0 LH. Root cause candidate: old OHA `local_mode_laning_generic.GetDesire()` sat before the 1v1 desire override and could yield laning ownership after horn. The 1v1 override now returns before OHA local-mode fallback, so Think keeps running and internal recovery/retreat owns decisions.
- Live `8868788347` was on `f16c7b5` and still showed no post-horn `laning-core` ownership. Root cause: `Think()` still had an early `if local_mode_laning_generic then local_mode_laning_generic.Think(); return end`, so 1v1 `GetDesire()` was ours but the frame execution was still handed to OHA. In 1v1, `Think()` now skips that local-mode handoff and always runs the AIBattle laning stages.
- Same follow-up also hardened the frame loop: lane-front amount comparisons now tolerate nil values, and `AIBEngine.Run()` is wrapped in a throttled error report so a Lua exception becomes an `AIB[R/D] ERR` chat line instead of silently killing all post-horn ownership.

Pre-match rune bug fixes:
- `stage_unchecked` no longer closes the bottle rune staging window unless the bot actually observed the staged rune spot.
- Added `AIBEngine.IsActionPowerRune()` so `double_damage/haste/arcane/regen/invis/illusion` are handled through one runtime helper instead of four hard-coded combat-rune lists.
- Fight desire now opens an ability-pressure window up to 900u at safe HP, matching `AbilityPressure()` scan range so raze opportunities are not skipped at 700-900u.
- Kept 45-55% HP recovery-without-damage disabled on purpose; that band previously made bots over-recover and look passive.

Desire policy architecture pass:
- Added `aibattle_laning_policy.lua` as the owner for named HP bands, top-level desire gates, score weights, forward thresholds, and siege candidate thresholds.
- `mode_laning_generic.lua` no longer builds top-level `safety / power-rune / fight / recover / siege` scores from anonymous literals.
- `state-desire-*` details now include score components such as `base=... range=... execute=... hp_adv=... rune=...`, so the next match can explain why a desire won.
- Forwardness thresholds and suppression-after-empty-desire are named in policy instead of living as raw `900/10/1600/3` values in the orchestrator.

Post-match fixes from `8868017746`:
- Top-level desire candidates are now stricter: `fight` only enters the arbiter when the enemy is actionable by range/kill/advantage/rune pressure, not merely visible around 1000u.
- `recover` no longer becomes top desire at 45-55% HP unless recent damage or a lower HP gate makes it urgent.
- `safety` only enters top desire when recent damage has an actionable creep/low-HP/hero-damage reason.
- Siege candidate fallback requires a closer tower window and at least two allied creeps near enemy T1, reducing "stand under enemy tower" behavior.
- After a `top-arbiter empty_action`, forwardness is suppressed briefly and logs `fwd-suppressed-empty`; forwardness also needs a larger distance and longer cooldown.
- Next match watch: `top-arbiter empty_action` should drop sharply from `8868017746` levels (`R=278`, `D=212`), `fwd-position` should be rarer, and visible back/forth at low HP should reduce.

Post-match fixes from `8867764859`:
- Rune staging no longer marks a spawn point as known-empty unless the bot actually observed it closely enough or the rune status is already gone; otherwise it emits `stage_unchecked`.
- Double-damage tower pressure can target mid T1 with allied creeps even when the tower is not the current `enemyTowerDanger`, so DD should not fall through to creep-only pressure near a siege.
- Repeated creep damage lets ranged bots answer from normal attack range, and Haste lowers the forced creep-response HP floor so a hasted bot near its tower is less likely to stand/tank creeps.

Top-level arbiter pass:
- Added `aibattle_laning_arbiter.lua`.
- `ThinkLaningCore` now scores and arbitrates `safety / power-rune / fight / recover / siege` after emergency/critical/precreep gates.
- The arbiter emits `top-arbiter` plus `state-desire-<name>` and `TickOwner desire/<name>` with score/reason detail.
- Recovery is no longer a fixed sequential owner before fight/safety/siege; it competes by score and can fall through if its action yields.
- `match_stats.py` prints `arbiter[R/D]` summaries: winners, active desire states, empty actions, and simple desire loops.
- Arbiter auto-audit flags: recover dominance during lane contact, power-rune wins that only hit creeps, safety wins while damage continues, siege wins without tower hits, and top-arbiter `empty_action`.
- Use `python tools/match_stats.py --brief <matchid>` for the first pass: it hides raw `diag/intent/blocked/timeline` noise but keeps configs, duration, intent families, alerts, state/tower/arbiter summaries, fix candidates, flow, bottle, stationary spans, and score/items.
- Next match watch: `arbiter[R/D] winner ...`, `fix_candidate area=arbiter`, and whether `tick-owner stage=laning-core` drops in favor of detailed `desire/*`.

Post-match fixes from `8867661051`:
- High-HP single creep chip no longer sends the bot into a large safe retreat; it is logged/blocked as `creep-aggro reason=chip_ignored`.
- Rune staging now closes a checked empty spawn window before `water_emergency` can reopen the same route.
- `visual-hold reason=empty` escalates faster when healthy, so the bot should look for a creep/action sooner instead of standing.

Follow-up behavior package after `8867661051`:
- `recovery-policy source=lane-low` yields to nearby lane work at HP >=45% when no recent hero/creep damage happened.
- `tick-owner` telemetry records the stage/intent that consumed the tick (`stage=laning-core`, `stage=forwardness`, `stage=visual-hold`, etc.).
- Early laning runner now tries hero contact / creep reaction / damage unstuck before `visual-hold`, so safety should be a rarer fallback.
- Forwardness has a wider move threshold, a 6s cooldown, and is suppressed after visual-hold / CS watchdog; `fwd-position` should drop sharply.
- Rune staging marks the checked spawn point as known-empty through the next rune tick when a stage window resolves as empty.

Latest architecture package in progress:
- `aibattle_constants.lua` centralizes internal thresholds/distances.
- `aibattle_laning_context.lua` builds a per-tick laning snapshot.
- `aibattle_laning_creeps.lua` owns last-hit, push, and deny work.
- `aibattle_runes.lua` owns bottle rune transaction/staging/pickup memory.
- `aibattle_laning_combat.lua` owns hero contact, chase, ability pressure, and power-rune pressure.
- `aibattle_laning_recovery.lua` owns low-HP gates, critical recovery, and recovery-yield-to-kill.
- `aibattle_laning_safety.lua` owns visual hold/AFK, creep damage reaction, damage unstuck, and CS watchdog.
- `aibattle_laning_tempo.lua` owns pregame, pre-creep standoff, tower dive policy, and death window.
- `aibattle_laning_arbiter.lua` owns top-level laning desire selection.
- `aibattle_intents.lua` adds stable public intent families without changing the old intent names.
- `aibattle_item_policy.lua` owns AIBattle bottle/mango/TP/purchase guards.
- `mode_laning_generic.lua` is now the orchestrator (~950 lines after this split, down from ~2000).
- `match_stats.py` prints `intent_family[R/D]` from `family=` fields in intent telemetry.
- `match_stats.py` prints conservative `fix_candidate` advisory lines with priority, confidence, evidence, and recommendation. Treat them as hints, not ground truth.
- Legacy inactive bot files moved to `archive/dota/legacy_code/`.
- `docs/ARCHITECTURE.md` defines module ownership, rules/dials/constants boundaries, and telemetry conventions.
- `tools/check_all.py` now checks that `deploy.bat` and the check manifest stay in sync.
- `tools/check_all.py` also fails if a `bots/FunLib/aibattle_*.lua` runtime module is not listed for deploy/check.
- `deploy.bat code` removes stale live `FunLib/aibattle_laning_intents.lua`; `check_all.py` fails if that retired module is still present in the live Dota folder.

`82b4929 codex: tighten rune and chase gates`
- Water rune `stage_cooldown` can be overridden by `rune-stage-override reason=water_emergency`.
- Empty bottle duration is tracked by `aib_emptyBottleSince`.
- Low-farm Brawler kill-window now requires enemy HP <=60%, not <=78%.
- `channel-interrupt-chase` for healing targets requires at least 32% self HP.

`2b005e7 codex: add fight recovery arbiter`
- Shared `AIBEngine.KillWindow`.
- `AIBEngine.RecoveryPolicy` decides when recovery yields to kill windows.
- `AIBEngine.Resolve` logs `arbiter family=urgent|fight|generic`.
- Bottle rune logic emits `rune-transaction`.
- Pre-creep standoff uses `precreep-close` instead of holding when an enemy is nearby but not attackable.

`12d0d5b codex: prioritize finishing fights`
- Mango mana check uses 75 mana.
- Haste chase policy is wider.
- Mutual-low finish and recovery-yield-to-kill were added before the shared engine refactor.

## Next Match Watchlist

- `rune-stage-override` should replace repeated water `stage_cooldown` when bottle is empty and water rune is reachable.
- `recovery-policy yield_kill` should not fire against healthy enemies above roughly 60% HP.
- `channel-interrupt-chase` should not cause low-HP deaths.
- `precreep-close` should reduce pre-creep visual AFK.
- `arbiter family=urgent|fight` should explain which fight intent won.

## Debug Rule

Do not add a new fallback first. Check build SHA, debug tree, timeline, blocked reasons, and the last action before the visual symptom.
