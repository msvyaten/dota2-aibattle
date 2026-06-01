# Schema v2 — Lua edits to apply on the Windows live code

Apply these to the LIVE files under
`...\dota 2 beta\game\dota\scripts\vscripts\bots\`.
The backend + new files (`FunLib/aibattle_style.lua`, `Customize/playstyle_*.lua`,
`system_prompt.txt`, `generate_playstyle.py`, `test_generate.py`) are already done and
just need copying over. These three mode files are edited in place because they were
changed during Phase 2 on Windows.

Run `luac -p <file>` after each edit if available; otherwise verify in-game (load lobby,
confirm no Lua error in console and the bot behaves).

---

## 1) `mode_laning_generic.lua`

### 1a. Replace the hardcoded `GetPlayStyle()` with the shared loader
Find the AIBattle `GetPlayStyle()` function (the one returning the playstyle table — in the
Phase-2 build it does `require("Customize/playstyle_<team>")`). Replace it with:

```lua
-- AIBattle Schema v2: shared loader (dials + rules), with safe defaults/clamping.
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local function GetDials() return Style.Get().dials end
local function GetRules() return Style.Get().rules end
```

### 1b. Respawn rule handler — add near the top-level functions of the file
```lua
-- AIBattle: returns the location of the most-forward SURVIVING friendly tower (closest to fight)
local function AIB_ForwardSurvivingTowerLoc()
    local team = GetBot():GetTeam()
    local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
    for _, id in ipairs(ids) do
        local t = GetTower(team, id)
        if t ~= nil and t:IsAlive() then return t:GetLocation() end
    end
    return nil
end

-- AIBattle: on death->alive transition, act per rules.respawn_behavior. Returns true if it issued an action.
local function AIB_HandleRespawn()
    if not bot:IsAlive() then bot.aib_wasDead = true; return false end
    if not bot.aib_wasDead then return false end
    -- already left base without TPing (no scroll / gave up) -> stop trying
    if bot:DistanceFromFountain() > 1500 then bot.aib_wasDead = false; return false end

    local behavior = GetRules().respawn_behavior
    if behavior == "walk_back" then bot.aib_wasDead = false; return false end

    local tp = bot:GetItemInSlot(bot:FindItemSlot("item_tpscroll"))
    if tp == nil or not tp:IsFullyCastable() then return false end  -- wait for scroll

    local loc
    if behavior == "tp_to_tower" then
        loc = AIB_ForwardSurvivingTowerLoc()
    elseif behavior == "tp_to_lane" then
        loc = GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
    end
    if loc == nil then bot.aib_wasDead = false; return false end

    bot:Action_UseAbilityOnLocation(tp, loc)
    bot.aib_wasDead = false
    return true
end
```

### 1c. In `GetDesire()` — make laning win for one tick right after respawn so Think runs the TP
Add right after the early-out guards at the top of `GetDesire()`:
```lua
    if bot:IsAlive() and bot.aib_wasDead then return BOT_MODE_DESIRE_ABSOLUTE end
```

### 1d. In `Think()` — run the respawn handler first, then drive behaviour from 0-1 dials
At the very top of `Think()` (after the `local_mode_laning_generic` delegation block, if present):
```lua
    if AIB_HandleRespawn() then return end
    local dials = GetDials()
```

Replace the old style-driven harass/ability/tower block (the part that read
`style.ability_aggro` / `style.harass_desire` / `style.farm_priority` / `style.tower_safe`)
with this dial-driven version:
```lua
    -- ability_aggro as probability (0..1)
    if math.random() < (dials.ability_aggro or 0.5) then
        local shrapnel = bot:GetAbilityByName("sniper_shrapnel")
        if shrapnel and shrapnel:IsFullyCastable() then
            local atk = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
            if atk and #atk > 0 and atk[1]:IsAlive() then
                bot:Action_UseAbilityOnLocation(shrapnel, atk[1]:GetLocation())
                return
            end
        end
    end

    -- farm_focus low -> trade CS for harass; harass_desire = swing probability
    if math.random() > (dials.farm_focus or 0.5) then
        local atk = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
        if atk and #atk > 0 and atk[1]:IsAlive() and math.random() < (dials.harass_desire or 0.5) then
            bot:Action_AttackUnit(atk[1], true)
            return
        end
    end

    -- forwardness: interpolate standing position from own mid tower (0) to lane front (1)
    local fwd = dials.forwardness or 0.5
    local ownTower = GetTower(GetTeam(), TOWER_MID_1)
    if ownTower ~= nil and ownTower:IsAlive() then
        local stand = ownTower:GetLocation() + (target_loc - ownTower:GetLocation()) * fwd
        bot:Action_MoveToLocation(stand + RandomVector(50))
    else
        bot:Action_MoveToLocation(target_loc + RandomVector(50))
    end
```

> Note: keep the existing last-hit / deny logic above this block unchanged. `target_loc` is the
> lane-front location already computed earlier in `Think()`.

---

## 2) `mode_rune_generic.lua`

Hook the `rune_control` dial onto the final desire. Rename the existing `GetDesire` body to a
helper and add a thin wrapper that scales it (0.5 = baseline, 0 = off, 1 = x2).

At the top of the file (after the existing `require`s) add:
```lua
local AIBStyle = require(GetScriptDirectory()..'/FunLib/aibattle_style')
```

Rename the existing `function GetDesire()` to `function GetRuneDesireRaw()`, then add:
```lua
function GetDesire()
    return AIBStyle.ScaleDesire(GetRuneDesireRaw(), AIBStyle.Get().dials.rune_control)
end
```

---

## 3) `mode_retreat_generic.lua`

Same pattern with the `retreat_caution` dial. The existing `GetDesire()` is:
```lua
function GetDesire()
    local res = GetDesireHelper()
    return res
end
```
Add the require at the top of the file:
```lua
local AIBStyle = require(GetScriptDirectory()..'/FunLib/aibattle_style')
```
Replace `GetDesire()` with:
```lua
function GetDesire()
    local res = GetDesireHelper()
    return AIBStyle.ScaleDesire(res, AIBStyle.Get().dials.retreat_caution)
end
```

---

## In-game validation (1v1, per spec)
For each control, run a match and confirm the observable effect:
- `rune_control` high vs low -> bot moves to rune spawns vs ignores.
- `retreat_caution` high vs low -> backs off early vs fights to low HP.
- `ability_aggro` 0.3 vs 0.9 -> Shrapnel-on-hero frequency scales (not just on/off).
- `forwardness` 0.1 vs 0.9 -> standing distance from own tower scales.
- `respawn_behavior = tp_to_tower` -> after a death, bot TPs to the forward surviving tower.

Launch: lobby 1v1 Solo Mid, cheats ON, load Local Dev Script bots, kick extras
(`kick 1..4`, `kick 6..9`), `-condebug`, read `console.<matchid>.log`.
