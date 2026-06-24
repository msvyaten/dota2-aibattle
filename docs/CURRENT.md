# AIBattle Current State

Last updated by Codex on 2026-06-24 after matches `8864125273` and `8864152947`.
Current live/repo build after the latest deploy: `f3b5403`.

## Goal

Make the 1v1 mid bot watchable and debuggable:
- no visual AFK when enemies or creeps are in range;
- no jitter from competing fallback layers;
- logs must explain what the bot wanted, what it did, and what was blocked.

## Current Laning Order

The active laning loop is intentionally small:

1. Respawn / pregame / tower-dive guards.
2. Urgent intent arbitration before survival:
   - `kill-lock`
   - `channel-interrupt`
3. Low-HP survival if health is dangerous.
4. `hero-contact`: point-blank enemy hero response before visual-AFK and normal intents.
5. Normal intent arbitration:
   - `creep-aggro`
   - `channel-interrupt`
   - `hero-pass`
6. Early ability pressure (`AbilityExecute` / `AbilityHarass`) before normal hero contact.
7. Last-hit, survival, emergency retreat, kill-priority, harass, CS-walk, push/deny/siege.
8. Last-hit watchdog, ranged melee-pack spacing, and visual-hold heartbeat.
9. Ability execute/harass still also exists later as a secondary chance.
10. Final positioning via one forwardness action: `fwd-position`, rate-limited by `fwd-hold`.
11. Visual-AFK watchdog only after normal combat/creep/positioning had a chance to act.
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
- `channel-interrupt-atk`
- `channel-interrupt-chase`
- `damage-unstuck`
- `creep-hit-react-atk`
- `creep-hit-react-kite`
- `harass-atk`
- `kill-priority`

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
- `recovery-regen`
- `recovery-walk`
- `recovery-wait`
- `fountain-wait`
- `fountain-tp-lane`

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
- `enemy-healed-without-interrupt` alerts.

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
- `f3b5403 codex: soften lane chase guard`
- `0bd1edd codex: make lane pressure less passive`
- `1a2bd66 codex: add lane watchdog guardrails`
- `ac9a368 codex: widen rune staging and soften timeout`

What `0bd1edd` fixed:
- SF ability pressure started working: match `8864152947` had `ability-harass D#36 R#47`, `execute D#2`.
- The dials/rules announcement no longer falls into `invalid index`.

What `f3b5403` fixed after Claude's review:
- `hero-prio-chase` is no longer blocked by `lane_work` when the enemy is within 700u, bot has at least
  +8% HP advantage, bot HP is >=45%, no enemy tower is threatening, and there is no uphill miss.
- `visual-hold empty` now attempts a lane-front/enemy-T1 step via `visual-hold-lane`.
- It was deployed with `deploy all`, so current live canonical configs are actually `pregame_behavior="aggressive_mid"`.

Open code candidates:
- Improve bottle/rune recovery: `no_close_rune` and empty bottle are still high in long games.
- Strengthen heal interrupt: `enemy-healed-without-interrupt` still appeared in `8864152947`.
- Consider adding config drift checks for `Customize/canonical_*.lua` and `Customize/playstyle_*.lua`.

## Current Debug Philosophy

Do not add another fallback first.

When a bot looks AFK or jittery:
1. Check build mismatch.
2. Check `timeline[R/D]`.
3. Check `verdict:`.
4. Look for the last action or blocked reason before the visual symptom.
5. Only then change behavior.

The bot should have one owner per concern:
- hero close contact: `hero-contact`;
- blocked/competing desires: intent telemetry;
- lane depth: `fwd-position`;
- true last resort: `AntiIdleGlobal`.
