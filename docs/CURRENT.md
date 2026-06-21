# AIBattle Current State

Last updated by Codex after match `8861167287`.

## Goal

Make the 1v1 mid bot watchable and debuggable:
- no visual AFK when enemies or creeps are in range;
- no jitter from competing fallback layers;
- logs must explain what the bot wanted, what it did, and what was blocked.

## Current Laning Order

The active laning loop is intentionally small:

1. Respawn / pregame / tower-dive guards.
2. Low-HP survival if health is dangerous.
3. `hero-contact`: point-blank enemy hero response before visual-AFK and normal intents.
4. Intent arbitration:
   - `creep-aggro`
   - `heal-interrupt`
   - `hero-pass`
5. Last-hit, survival, emergency retreat, kill-priority, harass, CS-walk, push/deny.
6. Ability execute/harass.
7. Final positioning via one forwardness action: `fwd-position`, rate-limited by `fwd-hold`.
8. Visual-AFK watchdog only after normal combat/creep/positioning had a chance to act.
9. Last-resort `AntiIdleGlobal`.

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
- `hero-contact-atk`
- `hero-contact-chase`
- `hero-contact-kite`
- `hero-pass-atk`
- `hero-pass-chase`
- `heal-interrupt-atk`
- `heal-interrupt-chase`
- `harass-atk`
- `kill-priority`

Creeps / lane:
- `cs-inrange`
- `cs-walk`
- `deny-act`
- `creep-dmg`
- `creep-aggro-hit`
- `creep-aggro-back`
- `cw-push`

Positioning:
- `fwd-position`
- `fwd-at-position`
- `fwd-suppressed-hero`
- `fwd-suppressed-creep`
- `fwd-suppressed-lowhp`
- `fwd-suppressed-tower`

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

## Regression Signals

Bad signs in a fresh match:
- `legacy-forwardness-noise` verdict.
- `close-enemy-without-hero-action` verdict.
- `stationary-while-damaged` alert.
- Many old keys in match logs from a new build: `fwd-fallback`, `fwd-push`, `fwd-ahead`, `fb-skip`, `dt-walk`, `idle-creep-atk`.
- `build_mismatch_vs_live` on a match that was supposed to use current code.
- `fwd-position` firing while an enemy hero or attackable creep is nearby.

Expected on old matches:
- Old matches can still show removed keys because their logs were produced by older builds.

## Commands

Before a match:

```powershell
python tools\check_all.py --latest
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

Deploy current bot code to live Dota folder:

```powershell
cmd /c tools\deploy.bat
```

## Live Build Rule

`tools/deploy.bat` writes:

```lua
return {
    sha = "<git-head>",
}
```

`tools/check_all.py` requires live sha to match repo `HEAD` and checks that key live Lua files match the repo.

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
