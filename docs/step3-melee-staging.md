# Step 3 — melee hero staging (revive harass_desire + item_build override)

> Goal: `harass_desire` is structurally dead on Sniper (ranged farmer never closes to autoattack
> range → physical hero damage = 0 even at 0.90). A melee MUST close to last-hit, so the enemy
> hero is regularly in autoattack range and the harass branch (step 2 in mode_laning Think) fires.
> This is THE test that proves `harass_desire` is a real gradient.
>
> Hero choice: **Sven** (`npc_dota_hero_sven`) — dedicated OHA script exists (`BotLib/hero_sven.lua`),
> not on the weak/buggy lists, simple autoattack-aggressive (cleaner physical-damage signal than
> Jugg's Blade Fury). Alternative: `npc_dota_hero_juggernaut` (also has an OHA script).
>
> NOTE: `ability_aggro` is hard-coded to Sniper's Shrapnel → it will NOT fire on a melee. Set it
> to 0.00 and mark `ability_aggro` as "validated on Sniper only". Don't generalize ability casting.
>
> ⚠️ Apply via the LIVE files directly. Do NOT copy `general.lua` from the repo — the repo copy is
> OLDER than LIVE. Edit the LIVE `general.lua` in place.

## 1. LIVE `Customize/general.lua` edit (mirror melee, pos1 both sides)
```lua
Customize.Radiant_Heros = { "npc_dota_hero_sven", "npc_dota_hero_wisp", "npc_dota_hero_wisp", "npc_dota_hero_wisp", "npc_dota_hero_wisp" }
Customize.Dire_Heros    = { "npc_dota_hero_sven", "npc_dota_hero_wisp", "npc_dota_hero_wisp", "npc_dota_hero_wisp", "npc_dota_hero_wisp" }
```
(Keep the `wisp` fillers — they get kicked in the 1v1 lobby anyway. Names ChatGPT/Gemini stay.)

## 2. Test 3 — `harass_desire` gradient (mirror, melee)
Both bots identical except `harass_desire`. Baseline `forwardness 0.70` so they engage;
`ability_aggro 0.00` (Sniper-only, off); symmetric melee item_build.

**playstyle_radiant.lua** (harass_desire = 0.90)
```lua
return {
    dials = {
        harass_desire     = 0.90,
        farm_focus        = 0.50,
        forwardness       = 0.70,
        ability_aggro     = 0.00,
        rune_control      = 0.50,
        retreat_caution   = 0.50,
        execute_threshold = 0.00,
    },
    rules = { respawn_behavior = "tp_to_tower" },
    item_build = { "item_power_treads", "item_mask_of_madness", "item_sange", "item_satanic" },
}
```
**playstyle_dire.lua** (harass_desire = 0.30) — identical except `harass_desire = 0.30`.

**Expect:** PHYSICAL hero damage (and hero attacks) on the 0.90 bot noticeably > the 0.30 bot —
the metric that was flat 0 on Sniper. That confirms `harass_desire` is a live gradient.

## 3. Also observe (free, same match)
- **`farm_focus`** — now meaningful: 0.90-harass bot trades more, 0.30 bot last-hits more (compare last_hits).
- **item_build override on a non-Sniper** — confirm the purchaser overrides Sven's default build
  (watch the bot actually buy treads/MoM/sange/satanic, not its hero default). This was only ever
  verified on Sniper.

## After Step 3
Fill `validation-v2-results.md` (Test 3 row) + scorecard. Then matrix is: swap✅, tp_to_tower✅,
tp_to_lane✅, execute✅, ability_aggro (Sniper-only), harass_desire (melee), farm_focus,
retreat_caution, forwardness → merge-gate review for `main`. Restore Sniper canon from git when done.
