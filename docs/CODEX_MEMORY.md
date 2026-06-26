# Codex Memory

Last updated: 2026-06-26.

Current live code build before latest architecture deploy: `59c016a`.
Current repo HEAD before latest architecture commit: `59c016a`.

## Ownership

Codex owns engine/code cleanup and behavior fixes.

Claude currently owns config/playstyle changes. Do not stage or commit these files unless the user explicitly asks:
- `bots/Customize/canonical_ganker.lua`
- `bots/Customize/canonical_pusher.lua`
- `bots/Customize/playstyle_radiant.lua`
- `bots/Customize/playstyle_dire.lua`

## Latest Codex Commits

Latest architecture package in progress:
- `aibattle_constants.lua` centralizes internal thresholds/distances.
- `aibattle_laning_context.lua` builds a per-tick laning snapshot.
- `aibattle_laning_creeps.lua` owns last-hit, push, and deny work.
- `aibattle_runes.lua` owns bottle rune transaction/staging/pickup memory.
- `aibattle_laning_combat.lua` owns hero contact, chase, ability pressure, and power-rune pressure.
- `aibattle_laning_recovery.lua` owns low-HP gates, critical recovery, and recovery-yield-to-kill.
- `aibattle_laning_safety.lua` owns visual hold/AFK, creep damage reaction, damage unstuck, and CS watchdog.
- `aibattle_laning_intents.lua` keeps ordered step execution explicit.
- `mode_laning_generic.lua` is now the orchestrator (~1200 lines after this split, down from ~2000).
- Legacy inactive bot files moved to `archive/dota/legacy_code/`.
- Keep `deploy.bat` and `check_all.py` in sync with every new runtime module.

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
