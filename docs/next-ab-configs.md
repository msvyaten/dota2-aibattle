# Ready-to-apply mirror A/B configs — remaining Sniper dials

> Mirror method: both bots IDENTICAL except the ONE dial under test → clean attribution
> in a single match (Radiant slot 0 vs Dire slot 128). Baseline `forwardness = 0.70` so the
> bots actually close and engage (at 0.50 they stand off and the test comes back empty).
> `item_build` is symmetric across both bots so loot never confounds the metric.
> Swap sides between consecutive runs (side-bias control). After all three, restore CANON
> from git (`playstyle_radiant` = aggressor, `playstyle_dire` = passive).
>
> Apply = paste the block into the matching `bots/Customize/playstyle_<team>.lua` (and the
> live copy under the Dota vscripts path), then play one match to completion (need the stat dump).

Shared baseline dials (everything not under test): `harass_desire 0.50, farm_focus 0.50,
forwardness 0.70, ability_aggro 0.50, rune_control 0.50, retreat_caution 0.50,
execute_threshold 0.00`; `rules.respawn_behavior = tp_to_tower`; symmetric item_build.

---

## Test 2 — `ability_aggro` gradient (Sniper-ONLY; cannot be tested on melee)
Expect: Shrapnel magical hero-damage on the 0.90 bot noticeably > the 0.30 bot (a gradient,
not 0↔max). This is the priority — Shrapnel is hard-coded to Sniper.

**playstyle_radiant.lua** (ability_aggro = 0.90)
```lua
return {
    dials = {
        harass_desire     = 0.50,
        farm_focus        = 0.50,
        forwardness       = 0.70,
        ability_aggro     = 0.90,
        rune_control      = 0.50,
        retreat_caution   = 0.50,
        execute_threshold = 0.00,
    },
    rules = { respawn_behavior = "tp_to_tower" },
    item_build = { "item_power_treads", "item_dragon_lance", "item_maelstrom", "item_satanic" },
}
```
**playstyle_dire.lua** (ability_aggro = 0.30) — identical except `ability_aggro = 0.30`.

---

## Test 5 — `retreat_caution`
Expect: low-caution (0.2) bot fights to lower HP / dies more; high-caution (0.8) backs off
earlier. Compare lowest-HP-before-retreat and deaths between slot 0 and slot 128.
NOTE: the passive creep-fix kite branch is gated on `retreat_caution > 0.4`, so the 0.8 bot
will also kite out of creep fire — that is expected and part of what this dial expresses.

**playstyle_radiant.lua** (retreat_caution = 0.80) — baseline with `retreat_caution = 0.80`.
**playstyle_dire.lua** (retreat_caution = 0.20) — baseline with `retreat_caution = 0.20`.

---

## Test 6 — `forwardness` (currently BINARY at 0.5 — confirm the binary effect)
Expect: 0.9 bot pushes to the lane front; 0.1 bot holds near its tower. Subjective/positional
(watch replay or lane-front distance). True 0–1 gradation is a deferred follow-up.

**playstyle_radiant.lua** (forwardness = 0.90) — baseline with `forwardness = 0.90`.
**playstyle_dire.lua** (forwardness = 0.10) — baseline with `forwardness = 0.10`.

---

## After the three runs
Fill Tests 2/5/6 in `validation-v2-results.md` + the scorecard in `report-schema-v2.md`,
then restore canon from git and move to Step 3 (melee hero: `harass_desire` + `farm_focus`
+ item_build override). Merge gate: rows 2–7 ✅ with evidence.
