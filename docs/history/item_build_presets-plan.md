---
name: item-build-presets
description: Plan to implement named item build presets for SF (physical/spell) in hero_nevermore.lua, selectable via build_style in LLM configs
metadata:
  type: project
---

Implement named item build presets for Shadow Fiend that the LLM can choose from by name.

**Why:** Currently the LLM either copies a full flat item list (brittle, error-prone) or item_build is omitted entirely from configs. A preset system lets LLM say `build_style = "physical"` and the engine resolves the correct items — no item names in the prompt.

**Mechanism already exists:** `aibattle_style.lua` supports Format B:
```lua
item_build = {
    npc_dota_hero_nevermore = {
        physical    = { ... },
        spell       = { ... },
    }
}
build_style = "physical"  -- selects sub-table
```
Current supported keys: `brawler / spellcaster / farmer` (aibattle_style.lua:234).
Names need to be changed or extended to match SF-specific presets.

**Presets to define:**

`physical` (pos_2 mid, current standard):
tango, branches, faerie fire, 2x mango, bottle, wand, treads, lifesteal, dragon lance,
lesser crit, BKB, orchid, bloodthorn, greater crit, hurricane pike, aghs shard,
satanic, moon shard, travels 2, aghs scepter 2

`spell` (not yet defined — Codex briefly tried a version, then reverted):
Concept: cyclone, arcane blink, abyssal — high burst/combo with Requiem.
Needs: mana sustain early (clarity start), into spell amp items.
Status: no tested build exists yet.

**How to apply:**
1. Update `BUILD_STYLES` in `aibattle_style.lua` to include `"physical"` and `"spell"`
   (or rename existing brawler/spellcaster/farmer)
2. Add named sub-tables to `hero_nevermore.lua` (or a separate canonical builds file)
3. Update v3 system prompt to document the presets and have LLM output only `build_style`
4. Remove hardcoded flat item_build from canonical_ganker.lua and canonical_pusher.lua

**Current state:** item_build is hardcoded as flat array in both canonical files.
LLM system prompt (v3) intentionally omits item_build — to be added once presets exist.
