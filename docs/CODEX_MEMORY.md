# Codex Memory

Last updated: 2026-06-26.

Current live code build before latest infrastructure pass: `0a92d26`.
Current repo HEAD before latest infrastructure commit: `0a92d26`.

## Ownership

Codex owns engine/code cleanup and behavior fixes.

Claude currently owns config/playstyle changes. Do not stage or commit these files unless the user explicitly asks:
- `bots/Customize/canonical_ganker.lua`
- `bots/Customize/canonical_pusher.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`

## Latest Codex Commits

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
- `aibattle_laning_intents.lua` keeps ordered step execution explicit.
- `aibattle_intents.lua` adds stable public intent families without changing the old intent names.
- `aibattle_item_policy.lua` owns AIBattle bottle/mango/TP/purchase guards.
- `mode_laning_generic.lua` is now the orchestrator (~950 lines after this split, down from ~2000).
- `match_stats.py` prints `intent_family[R/D]` from `family=` fields in intent telemetry.
- `match_stats.py` prints conservative `fix_candidate` advisory lines with priority, confidence, evidence, and recommendation. Treat them as hints, not ground truth.
- Legacy inactive bot files moved to `archive/dota/legacy_code/`.
- `docs/ARCHITECTURE.md` defines module ownership, rules/dials/constants boundaries, and telemetry conventions.
- `tools/check_all.py` now checks that `deploy.bat` and the check manifest stay in sync.
- `tools/check_all.py` also fails if a `bots/FunLib/aibattle_*.lua` runtime module is not listed for deploy/check.

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
