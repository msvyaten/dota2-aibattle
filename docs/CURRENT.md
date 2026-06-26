# AIBattle Current State

Last updated by Codex on 2026-06-26 after the constants/context/creeps/runes architecture split.
Current live bot build before deploy: `82b4929`.
Current repo HEAD before deploy: `e2bb36e`.
Codex-specific compact memory: `docs/CODEX_MEMORY.md`.

## Goal

Make the 1v1 mid bot watchable and debuggable:
- no visual AFK when enemies or creeps are in range;
- no jitter from competing fallback layers;
- logs must explain what the bot wanted, what it did, and what was blocked.

## Current Laning Order

The active laning loop is intentionally small:

1. Respawn / pregame / tower-dive guards.
2. Urgent intent arbitration before survival (`arbiter family=urgent`):
   - `kill-lock`
   - `channel-interrupt`
3. Recovery gates use `AIBEngine.RecoveryPolicy` / `KillWindow` before consuming the tick:
   - emergency survival below true death HP;
   - `recovery-yield-kill` when execute / attack kill / mutual-low window is commit-safe;
   - `recovery-policy action=recover` when survival owns the tick.
4. `critical-recovery` lock, but active DD/Haste/Arcane or a valid kill window can clear it.
5. Prewave duel and pre-creep standoff:
   - `prewave-duel-*`;
   - `precreep-contact`;
   - `precreep-close`;
   - `precreep-space`.
6. Ability and power-rune pressure:
   - `ability-pressure`;
   - `rune-pressure`.
7. Visual-hold / visual-AFK / contact / creep-hit / damage-unstuck guards.
8. Low-HP safe last-hit can fire before normal recovery if the creep is already in range.
9. Normal fight intent arbitration (`arbiter family=fight`):
   - `creep-aggro`
   - `channel-interrupt`
   - `hero-pass`
10. Last-hit, survival, emergency retreat, kill-priority, harass, CS-walk, push/deny/siege.
11. Last-hit watchdog, ranged melee-pack spacing, and final positioning via `fwd-position`.
12. Last-resort `AntiIdleGlobal`.

## Removed From Active Laning

These old active fallback layers should not return to `mode_laning_generic.lua`:
- `dt-walk`
- `idle-creep-atk`
- `fwd-ahead`
- `fwd-fallback`
- `fwd-push`
- `fb-skip`
- `packSafeDest`

`tools/check_all.py` fails if those keys appear in the active laning file.

## Normal Diag Keys

Combat / hero:
- `arbiter family=urgent`
- `arbiter family=fight`
- `ability-harass`
- `ability-harass-move`
- `execute`
- `execute-approach`
- `hero-contact-atk`
- `hero-contact-chase`
- `hero-contact-kite`
- `hero-pass-atk`
- `hero-pass-chase`
- `kill-lock-atk`
- `kill-lock-chase`
- `mutual-low-finish-atk`
- `mutual-low-finish-chase`
- `channel-interrupt-atk`
- `channel-interrupt-chase`
- `damage-unstuck`
- `creep-hit-react-atk`
- `creep-hit-react-force-atk`
- `creep-hit-react-back`
- `harass-atk`
- `kill-priority`
- `pg-duel-approach`
- `pg-duel-trade`
- `pg-duel-space`
- `pg-duel-disengage`
- `prewave-duel-approach`
- `prewave-duel-trade`
- `prewave-duel-space`
- `prewave-duel-disengage`
- `precreep-close`
- `precreep-contact`
- `precreep-space`

Creeps / lane:
- `cs-inrange`
- `cs-watchdog-atk`
- `cs-watchdog-step`
- `cs-walk`
- `deny-act`
- `creep-dmg`
- `creep-aggro-hit`
- `creep-aggro-back`
- `cw-push`
- `siege-creep`
- `siege-tower`
- `siege-step`
- `siege-commit-tower`
- `siege-commit-step`

Positioning:
- `melee-pack-space`
- `visual-hold-creep`
- `visual-hold-hero`
- `visual-hold-dmg`
- `visual-hold-lane`
- `fwd-position`
- `fwd-at-position`
- `fwd-suppressed-hero`
- `fwd-suppressed-creep`
- `fwd-suppressed-lowhp`
- `fwd-suppressed-tower`
- `low-hp-fight`
- `low-hp-creep`
- `low-hp-back`

Last resort:
- `pre-aig`
- `anti-idle-enter`
- `anti-idle-combat`
- `anti-idle-creep`
- `anti-idle-creep-walk`
- `anti-idle-lane`
- `anti-idle-push`

Recovery / runes:
- `bottle-rune`
- `recovery-rune-bottle`
- `recovery-policy`
- `recovery-yield-kill`
- `critical-recovery`
- `critical-recover-lock`
- `power-rune-yield`
- `recovery-regen`
- `recovery-walk`
- `recovery-wait`
- `fountain-wait`
- `fountain-tp-lane`
- `rune-transaction`
- `rune-result`
- `rune-stage-override`
- `rune-pressure`

## Regression Signals

Bad signs in a fresh match:
- `legacy-forwardness-noise` verdict.
- `close-enemy-without-hero-action` verdict.
- `stationary-while-damaged` alert.
- Many old keys in match logs from a new build: `fwd-fallback`, `fwd-push`, `fwd-ahead`, `fb-skip`, `dt-walk`, `idle-creep-atk`.
- `build_mismatch_vs_live` on a match that was supposed to use current code.
- `fwd-position` firing while an enemy hero or attackable creep is nearby.
- `creep-dmg` without `creep-hit-react-*`, `creep-aggro-*`, or `damage-unstuck`.
- `ability-harass=0` in SF 1v1 when `ability_usage=aggressive`.
- `hero-prio-chase` blocked mostly by `lane_work` even when the enemy is close and bot has HP advantage.
- `visual-hold empty` accumulating without `visual-hold-lane`.
- Bottle empty above ~70% of telemetry samples with repeated `no_close_rune`.
- Bottle empty above ~70% with repeated `stage_cooldown`; after `82b4929`, water rune emergency should emit `rune-stage-override`.
- `enemy-healed-without-interrupt` alerts.
- Deaths shortly after `channel-interrupt-chase`; after `82b4929`, chase interrupt requires at least 32% HP for healing targets.
- `recovery-policy yield_kill` against enemies above ~60% HP; after `82b4929`, low-farm Brawler recovery bypass should no longer treat 78% HP as a kill window.

Expected on old matches:
- Old matches can still show removed keys because their logs were produced by older builds.

## Commands

Before a match:

```powershell
python tools\check_all.py --latest
```

Deploy current bot code only:

```powershell
cmd /c tools\deploy.bat code
```

Deploy config/playstyle changes only:

```powershell
cmd /c tools\deploy.bat playstyle
```

Deploy both code and canonical/playstyle config:

```powershell
cmd /c tools\deploy.bat all
```

Analyze a specific match:

```powershell
python tools\match_stats.py --live 8860297514
```

Analyze the newest console log:

```powershell
python tools\match_stats.py --live --latest
```

Encoding check only:

```powershell
python tools\check_text_encoding.py
```

## Live Build Rule

`tools/deploy.bat` writes:

```lua
return {
    sha = "<git-head>",
}
```

`tools/check_all.py` requires live sha to match repo `HEAD` and checks that key live Lua files match the repo.

Important deploy trap: `deploy.bat code` updates engine/code and live SHA, but it does not copy
`Customize/canonical_*.lua` or `Customize/playstyle_*.lua`. When Claude or Codex changes configs,
use `deploy.bat playstyle` or `deploy.bat all`. Match `8864152947` showed this trap: build was
`0bd1edd`, but live canonical configs were still old `pregame_behavior="safe_tower"` until `deploy all`.

## Latest State

Recent local commits:
- Current architecture package in progress:
  - `FunLib/aibattle_constants.lua` centralizes internal thresholds/distances;
  - `FunLib/aibattle_laning_context.lua` builds a per-tick laning snapshot;
  - `FunLib/aibattle_laning_creeps.lua` owns last-hit, push, and deny work;
  - `FunLib/aibattle_runes.lua` owns bottle rune transaction/staging/pickup memory;
  - `aibattle_survive.lua` no longer owns the rune transaction engine;
  - legacy unused files moved from `bots/` to `archive/dota/legacy_code/`;
  - `tools/deploy.bat` and `tools/check_all.py` must include any new runtime module.
- `82b4929 codex: tighten rune and chase gates` - deployed live and pushed:
  - `stage_cooldown` can yield to `rune-stage-override reason=water_emergency` for water rune recovery when the bottle is empty and the bot is in mid context;
  - empty-bottle duration is tracked via `aib_emptyBottleSince`;
  - low-farm Brawler kill-window was tightened from enemy HP <=78% to <=60%;
  - `channel-interrupt-chase` for healing targets now needs at least 32% self HP.
- `2b005e7 codex: add fight recovery arbiter` - deployed live and pushed:
  - `AIBEngine.KillWindow` is the shared fight/recovery kill-window source;
  - `AIBEngine.RecoveryPolicy` decides when recovery yields to execute / attack kill / mutual-low windows;
  - `AIBLaneTrade.KillLock` now consumes engine kill windows instead of owning separate killability logic;
  - `AIBEngine.Resolve` logs `arbiter family=urgent|fight|generic`;
  - bottle rune logic emits `rune-transaction` for start/commit/pickup/retarget/stage phases;
  - pre-creep standoff now uses `precreep-close` instead of holding when an enemy is nearby but not yet attackable.
- `12d0d5b codex: prioritize finishing fights` - deployed live and pushed:
  - mango mana check uses 75 mana, not 100;
  - haste chase policy is wider;
  - mutual-low finish and recovery-yield-to-kill were added before the shared engine refactor.
- Config/playstyle files are Claude-owned for now. Codex should not stage or commit:
  - `bots/Customize/canonical_ganker.lua`
  - `bots/Customize/canonical_pusher.lua`
  - `bots/Customize/playstyle_radiant.lua`
  - `bots/Customize/playstyle_dire.lua`
- Current architecture package in progress:
  - no intentional behavior changes;
  - prewave/pregame duel logic moved from `mode_laning_generic.lua` into `FunLib/aibattle_laning_duel.lua`;
  - siege-window logic moved from `mode_laning_generic.lua` into `FunLib/aibattle_laning_siege.lua`;
  - `mode_laning_generic.lua` should keep moving toward orchestration + sensors, not owning every behavior mode;
  - deploy/check tooling must list every new runtime module, otherwise live Dota can miss required files.
- Next behavior package in progress:
  - after killing the enemy, siege can step toward tower even without allied tower tanking, but still will not hit tower under no-tank danger;
  - prewave duel low-HP disengage no longer consumes the tick; HP below 35% gets a survival chance before duel.
- Current behavior package in progress:
  - rune pickup attempts are only issued near the rune, not from ~400 units away;
  - seen-empty rune spots are remembered until the next 2-minute spawn tick;
  - visual-hold now issues a fallback action (hero attack, creep attack, or lane step) instead of only logging the hold;
  - low-HP recovery yields to a safe in-range last-hit before leaving lane.
  - bottle rune route distances are internal engine guards, not LLM-facing rules.
  - low-resource water-rune recovery may use a wider mid-only leash so a bot under its own tower can still refill instead of being blocked by normal lane rune distance.
- Current behavior package in progress:
  - close visible enemies get a wider contact/chase window when tower/uphill safety allows it;
  - active DD/Haste/Arcane creates `rune-pressure` so the bot spends the rune on hero pressure or creep damage;
  - long rune trips are blocked by `route_unsafe` when a weak bot would walk through enemy high-ground pressure;
  - siege can explicitly choose an attackable enemy hero under tower instead of only stepping/hitting tower/creeps.
- Current behavior package in progress:
  - no-resource recovery no longer treats passive regen as a terminal action once the bot has reached XP/safe position;
  - post-horn recovery state is cleared once, and pre-creep standoff can keep acting until lane creeps arrive;
  - water-rune recovery uses a wider mid-water corridor while normal power-rune pickup keeps the tighter route budget.
- Current behavior package in progress:
  - visual-hold now escalates to hero step, creep step/back, safe step, or lane step instead of remaining a blocked-only symptom;
  - close rune attempts get a short `pickup_confirm` lock before marking a rune gone;
  - hero-priority chase can override lane work at wider safe distances when HP/kill pressure supports it;
  - no-resource recovery yields between movement refreshes instead of holding the tick.
- Current behavior package in progress:
  - kill-lock chase is blocked earlier at self-critical HP so low-HP recovery is not interrupted by distant kill windows;
  - empty-bottle rune staging is blocked by `critical_no_stage` when HP is critical and the rune/spawn is too far.
- Current behavior package in progress:
  - critical HP now has a short `critical-recovery` lock so recovery does not oscillate between lane/rune/chase every tick;
  - repeated visual-hold reasons escalate into hard actions (`visual-hold-hard-creep`, tower hit/step, safe/lane step);
  - rune staging remembers completed/blocked spawn windows via `stage_cooldown`;
  - empty bottle with healthy HP/MP emits `empty-bottle-ok` instead of repeatedly planning lane recovery;
  - creep-damage relief, creep-hit-react, and damage-unstuck share short cooldowns to reduce action conflicts.
- `lane_override` chase is conservative: max ~950u, enemy HP <=62%, and requires hero-priority always or a strong HP advantage.
- `89d2b65 codex: tighten lane decision states` - deployed live; latest behavior package:
  - engine can continue after an intent action explicitly returns `false`;
  - prewave duel is now approach/trade/space/disengage instead of a single attack gate;
  - creep-damage response uses forced attack or short back-step instead of long kite;
  - close rune commit has a wider pickup range and no random hold offset;
  - siege hold now attacks nearby creeps or keeps stepping toward tower instead of doing no visible action.
- `7284fbf codex: add debug desire tree to match stats` - tooling only, not deployed to Dota.
- `c7a5874 codex: restore pregame duel state metrics` - deployed live; restores pregame duel inside `ThinkPregame`.
- `06a45db codex: make recovery and siege lane-aware` - deployed before `c7a5874`.
- `4aa123f codex: let recovery beat push gates`
- `6870738 codex: protect early lane actions`
- `92e2a34 codex: disable post-horn precreep hold`

What `c7a5874` fixed:
- Pregame duel no longer depends on falling through to lower laning-core. `ThinkPregame` now runs `pg-duel`
  / `pg-duel-step` before passive pregame positioning.
- Added runtime state intents: `state-prewave-duel`, `state-rune-commit`, `state-siege-window`,
  `state-recover-xp`, `state-recover-safe`.
- Recovery now distinguishes XP-range recovery from hard safe retreat via `recover-xp` / `recover-safe`.
- Siege now emits `tower-opportunity result=hit|step|blocked_*`.

What `7284fbf` added:
- `tools/match_stats.py` now prints a compact desire hierarchy:
  `debug_tree[R/D] -> fight / rune / recover / push / lane`.
- Each branch groups `state[...]`, `action[...]`, `blocked[...]`, and `symptom[...]`.
- Existing detailed `diag:`, `intent:`, `blocked:`, timeline, farmtrace, bottle, stationary output remains unchanged.

Open code candidates:
- Build the full laning arbiter for `fight / cs / rune / recover / push` once the current smaller behavior
  package has one match of evidence.
- Make `prewave_duel` a small state machine: approach -> trade -> keep range -> disengage.
- If close rune turns still happen, add a stricter sub-500u rune lock that ignores lane work except critical danger.
- If siege still stalls, promote tower/creep attack under allied tank into the macro arbiter.
- Keep using `check_all.py` live drift checks for `Customize/canonical_*.lua` and `Customize/playstyle_*.lua`
  after any config/playstyle deploy.

## Current Debug Philosophy

Do not add another fallback first.

When a bot looks AFK or jittery:
1. Check build mismatch.
2. Check `debug_tree[R/D]` first.
3. Check `timeline[R/D]`.
4. Check `verdict:` and `alert:`.
5. Look for the last action or blocked reason before the visual symptom.
6. Only then change behavior.

The bot should have one owner per concern:
- hero close contact: `hero-contact`;
- blocked/competing desires: intent telemetry;
- lane depth: `fwd-position`;
- true last resort: `AntiIdleGlobal`.

Debug hierarchy policy:
- LLM-facing config should stay small: roughly 8-12 public dials/rules.
- Internal state/diag keys can be more numerous, but `match_stats.py` should group them into public
  debug branches: `fight`, `rune`, `recover`, `push`, `lane`.
- Do not put runtime symptoms such as visual AFK into `rules`; rules are model-chosen behavior policy,
  not debug observations.
