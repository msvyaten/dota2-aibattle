-- AIBattle: shared playstyle loader (Schema v2).
-- Reads Customize/playstyle_<team>.lua  ->  { dials = {...}, rules = {...} }
-- Merges with safe defaults, clamps dials to 0-1, validates rules against a whitelist.
-- Consumed by mode_laning_generic, mode_rune_generic, mode_retreat_generic.

local M = {}

-- per-team cache (both heroes on a team share the same config)
local _cache = {}

local DEFAULT_DIALS = {
    harass_desire     = 0.5,
    farm_focus        = 0.5,
    forwardness       = 0.5,
    ability_aggro     = 0.5,
    rune_control      = 0.5,
    retreat_caution   = 0.5,
    -- Finish/ultimate aggression: cast Assassinate on a fleeing enemy below this HP
    -- fraction. 0 = never (conservative OHA default), 0.45 = finish enemies under 45%.
    execute_threshold = 0.0,
    -- Phase 2 (team dials): each scales the matching OHA team-mode desire via ScaleDesire,
    -- same proven pattern as rune_control/retreat_caution. 0.5 = baseline (x1), so a config
    -- that leaves them at 0.5 behaves exactly like pre-Phase-2.
    gank_desire       = 0.5,  -- mode_roam + mode_team_roam (roaming/ganking pressure)
    push_desire       = 0.5,  -- mode_push_tower_{mid,top,bot} (siege/tower pressure)
    defend_desire     = 0.5,  -- mode_defend_tower_{mid,top,bot} (defending own towers)
    ward_desire       = 0.5,  -- mode_ward (vision investment)
}

local RESPAWN_VALUES = { tp_to_tower = true, tp_to_lane = true, walk_back = true }
local DEFAULT_RESPAWN = "walk_back"

local function clamp01(x)
    if type(x) ~= "number" then return nil end
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function buildStyle(raw)
    local dials = {}
    local rawDials = (type(raw) == "table" and type(raw.dials) == "table") and raw.dials or {}
    for k, default in pairs(DEFAULT_DIALS) do
        local v = clamp01(rawDials[k])
        if v ~= nil then dials[k] = v else dials[k] = default end
    end

    local rawRules = (type(raw) == "table" and type(raw.rules) == "table") and raw.rules or {}
    local rb = rawRules.respawn_behavior
    local respawn = (type(rb) == "string" and RESPAWN_VALUES[rb]) and rb or DEFAULT_RESPAWN

    -- Prompt-driven item build (ordered). Keep only "item_*" strings here; the
    -- purchaser validates each against GetItemCost so a bogus name can't break the buy loop.
    local items = {}
    local rawItems = (type(raw) == "table" and type(raw.item_build) == "table") and raw.item_build or {}
    for _, name in ipairs(rawItems) do
        if type(name) == "string" and string.match(name, "^item_") then
            items[#items + 1] = name
        end
    end

    -- Situational purchase rules (optional): { when=<cond>, item=<name>, first=<bool> }.
    -- Lets a prompt say "if behind, buy survivability". Evaluated in-game by the purchaser.
    local item_rules = {}
    local rawItemRules = (type(raw) == "table" and type(raw.item_rules) == "table") and raw.item_rules or {}
    for _, r in ipairs(rawItemRules) do
        if type(r) == "table" and type(r.when) == "string"
            and type(r.item) == "string" and string.match(r.item, "^item_") then
            item_rules[#item_rules + 1] = { when = r.when, item = r.item, first = (r.first ~= false) }
        end
    end

    -- Optional behaviour improvements (booleans, default OFF). Composable self-preservation /
    -- ability layers, dormant unless a playstyle explicitly enables them, so they never disturb
    -- the validated dials.
    local IMPROVEMENT_KEYS = { tower_avoid = true, ability_on_dials = true, defensive_heal = true, anti_afk = true }
    local improvements = {}
    local rawImp = (type(raw) == "table" and type(raw.improvements) == "table") and raw.improvements or {}
    for k in pairs(IMPROVEMENT_KEYS) do
        improvements[k] = (rawImp[k] == true)
    end

    return { dials = dials, rules = { respawn_behavior = respawn }, item_build = items, item_rules = item_rules, improvements = improvements }
end

-- Returns the {dials, rules} config for the calling bot's team (cached, with safe defaults).
function M.Get()
    local team = GetBot():GetTeam()
    if _cache[team] ~= nil then return _cache[team] end
    local rel = (team == TEAM_RADIANT)
        and "Customize/playstyle_radiant"
        or  "Customize/playstyle_dire"
    -- Use the GetScriptDirectory()-prefixed path (the form OHA actually resolves).
    local ok, raw = pcall(require, GetScriptDirectory().."/"..rel)
    local style = buildStyle(ok and raw or nil)
    _cache[team] = style
    return style
end

-- Returns the prompt-driven ordered item build for the calling bot's team (may be empty).
function M.GetItemBuild()
    return M.Get().item_build
end

-- Returns the situational purchase rules for the calling bot's team (may be empty).
function M.GetItemRules()
    return M.Get().item_rules
end

-- Behaviour improvement flags (booleans). M.Imp(name) -> true only if explicitly enabled.
function M.GetImprovements() return M.Get().improvements end
function M.Imp(name)
    local i = M.Get().improvements
    return i ~= nil and i[name] == true
end

-- Evaluate a named situational condition for the CALLING bot. Returns boolean.
-- Cheap, fog-of-war-tolerant signals used so a prompt-authored item_rule can react
-- to the match state. Nil-safe; unknown conditions return false.
function M.EvalItemCondition(cond)
    local bot = GetBot()
    if bot == nil or cond == nil then return false end

    local enemyLevel, enemyInt, enemyPhys = nil, false, false
    local enemies = GetUnitList(UNIT_LIST_ENEMY_HEROES)
    if enemies ~= nil then
        for _, e in pairs(enemies) do
            if e ~= nil then
                local lv = e:GetLevel()
                if enemyLevel == nil or (lv ~= nil and lv > enemyLevel) then enemyLevel = lv end
                if e:GetPrimaryAttribute() == ATTRIBUTE_INTELLECT then enemyInt = true else enemyPhys = true end
            end
        end
    end

    if cond == "behind" then
        return enemyLevel ~= nil and bot:GetLevel() <= (enemyLevel - 2)
    elseif cond == "ahead" then
        return enemyLevel ~= nil and bot:GetLevel() >= (enemyLevel + 2)
    elseif cond == "dying" then
        return (bot.aib_deathCount or 0) >= 2
    elseif cond == "low_hp" then
        local mx = bot:GetMaxHealth()
        return bot:IsAlive() and mx > 0 and (bot:GetHealth() / mx) < 0.4
    elseif cond == "enemy_magical" then
        return enemyInt
    elseif cond == "enemy_physical" then
        return enemyPhys and not enemyInt
    end
    return false
end

-- Shared diagnostic counter (promoted from mode_laning so any mode file can report).
-- Counts each branch firing silently on the bot handle, then emits ONE combined summary
-- chat line at most once per 60s (only when something fired) so a TEST GAME yields
-- measurable numbers without spamming. Format 'AIB[R] ward-place=4 rune-grab=2'; the LAST
-- such line in console.<id>.log carries the cumulative totals (match_stats.py parses it).
-- print() is invisible in console.log, so chat is the only logging channel — keep it sparse.
function M.Diag(bot, key)
    if bot == nil then return end
    bot.aib_diagCnt = bot.aib_diagCnt or {}
    bot.aib_diagCnt[key] = (bot.aib_diagCnt[key] or 0) + 1
    local now = DotaTime()
    if bot.aib_diagLast == nil or now - bot.aib_diagLast >= 60.0 then
        bot.aib_diagLast = now
        local side = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
        local parts = {}
        for k, v in pairs(bot.aib_diagCnt) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        bot:ActionImmediate_Chat("AIB[" .. side .. "] " .. table.concat(parts, " "), true)
    end
end

-- Scale a "soft" mode desire by a 0-1 dial: 0.5 = baseline (x1), 0 = off, 1 = x2.
-- Leaves NONE (<=0) and hard overrides (>= ABSOLUTE) untouched, so we never break
-- the engine's forced behaviours.
function M.ScaleDesire(desire, dial)
    if desire == nil or desire <= 0 then return desire end
    if desire >= BOT_MODE_DESIRE_ABSOLUTE then return desire end
    local d = clamp01(dial)
    if d == nil then return desire end
    local scaled = desire * (2 * d)
    if scaled > 0.99 then scaled = 0.99 end  -- keep strictly below ABSOLUTE
    return scaled
end

-- Lead-aware "finish" detector. Returns true once enough enemy heroes are dead that the team
-- should stop farming/roaming and group-push to actually CLOSE the game. Intentionally
-- DIAL-INDEPENDENT base competence: push_desire shapes mid-game sieging (enemies alive), this
-- handles closeout. Fixes the '40k lead, game never ends' problem where push mode loses
-- arbitration to fight/farm even at push_desire=0.90 (towerDmg ~549 in 39 min, 8838026385).
-- Edge-triggered diag 'finish-push' so logs show how often the override engaged.
local FINISH_DEAD = 2  -- engage once this many of the 5 enemy heroes are dead
function M.IsFinishState(bot)
    local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local dead = 0
    for _, id in ipairs(GetTeamPlayers(enemyTeam)) do
        if not IsHeroAlive(id) then dead = dead + 1 end
    end
    local active = dead >= FINISH_DEAD
    if active and not bot.aib_finishActive then M.Diag(bot, "finish-push") end
    bot.aib_finishActive = active
    return active
end

-- Apply the finish override to a (already dial-scaled) push desire. In finish state, force the
-- desire near ABSOLUTE so push mode wins arbitration; rank by rawLaneDesire (0.90..0.99) so the
-- lane most ready to push wins and all bots converge on the SAME lane (group push) without any
-- cross-lane queries. Outside finish state, returns the scaled desire untouched.
function M.FinishPush(bot, scaledDesire, rawLaneDesire)
    if not M.IsFinishState(bot) then return scaledDesire end
    local forced = 0.90 + 0.09 * (clamp01(rawLaneDesire) or 0)
    return (forced > scaledDesire) and forced or scaledDesire
end

return M
