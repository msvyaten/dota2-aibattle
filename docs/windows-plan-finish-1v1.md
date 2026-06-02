# Windows plan — finish 1v1, then melee hero + item builds

> For the Claude running on the Windows/Shadow PC. Branch: `schema-v2-item-builds`.
> Rule: a claim is confirmed ONLY with a number from the stat dump or a `console.<id>.log` line.
> FREEZE new features (no new dials, execute_threshold/item_rules stay dormant) until the
> validation matrix is closed. Record everything in `docs/validation-v2-results.md`.

## Step 0 — sync
```
git pull
robocopy bots "C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots" /E
```
First check `git status` / `git log origin/schema-v2-item-builds..HEAD` for any UNPUSHED local edits and push them.

## Step 1 — verify the tp_to_tower fix (already pushed)
`mode_laning_generic.lua` → `AIB_HandleRespawn` now PROTECTS the TP channel: after casting it
keeps `aib_wasDead = true` and holds (returns true, issues no other action) while
`modifier_teleporting` is present (plus a 1s grace for the cast point), clearing only once the
channel resolves. This fixes the prior bug where the bot walked toward creeps and cancelled the
3s channel to a rear tower.

**Test:** put `respawn_behavior = "tp_to_tower"` on the **passive (dying)** bot, run a 1v1,
let it die. Expect: after respawn it stands still and teleports to its forward surviving tower
(not walk). Evidence: `teleports_used > 0` in stat dump, or observe the channel + arrival.
Record in `validation-v2-results.md` Test 7.

## Step 2 — close the remaining duel dials (Sniper)
One dial per A/B run, everything else equal, evidence into the matrix:
- **`ability_aggro`** clean A/B: 0.3 vs 0.9 → Shrapnel magical dmg scales (Test 2).
- **`retreat_caution`** 0.2 vs 0.8 → fights to low HP vs backs off early; deaths/lowest-HP differ (Test 5).
- **`forwardness`** 0.1 vs 0.9 → holds near tower vs pushes to lane front (Test 6; currently a binary at 0.5 — confirm the binary effect only).

## Step 3 — melee hero (revives harass_desire + tests item builds)
`harass_desire` is structurally dead on Sniper (ranged farmers never close to autoattack range).
A melee hero MUST close to last-hit, so the enemy hero is regularly in autoattack range and the
harass branch can fire.

1. In `bots/Customize/general.lua`, set both teams' mid hero to a simple aggressive melee
   (e.g. `npc_dota_hero_sven` or `npc_dota_hero_juggernaut`). Keep the mirror (same hero both sides).
2. Run A/B on **`harass_desire`** 0.3 vs 0.9 → expect PHYSICAL hero damage / hero attacks to
   scale (the metric that was 0 on Sniper). This is the key test.
3. Also observe **`farm_focus`** (last-hits vs trading) — now meaningful since the melee is in range.
4. **Item builds:** give the melee an `item_build` in its playstyle config and confirm the
   purchaser overrides the hero default (the override was only ever checked on Sniper). Watch the
   bot actually buy the listed items in order.

> NOTE: `ability_aggro` is hard-coded to Sniper's Shrapnel (`bot:GetAbilityByName("sniper_shrapnel")`).
> On a melee it will NOT fire — that is expected. Mark `ability_aggro` as "validated on Sniper only";
> do NOT generalize ability casting now (out of scope for this pass).

## Step 4 — record + merge gate
Fill `docs/validation-v2-results.md` and the scorecard in `docs/report-schema-v2.md`.
Merge `schema-v2-item-builds` → `main` only when the duel dials + tp_to_tower + the melee
harass_desire test are ✅ with evidence. Honestly mark `rune_control` (doesn't express in a 1v1
standoff) and `ability_aggro`-on-melee as deferred / hero-specific rather than forcing them.

## After merge → next phase (not now)
Pivot to 5v5, where the team/rune/positional dials come alive naturally and matches become
non-deterministic (bettable). `execute_threshold` + `item_rules` get their own validation there.

## If something breaks
Don't rewrite blind. Report which step fails with the log evidence, push your diagnosis, and
we fix precisely from the Mac side.
