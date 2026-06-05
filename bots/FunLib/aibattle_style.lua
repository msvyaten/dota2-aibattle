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
    roshan_desire     = 0.5,  -- mode_roshan (Roshan priority; ABSOLUTE finish-pass-through untouched)
}

local RESPAWN_VALUES = { tp_to_tower = true, tp_to_lane = true, walk_back = true }
local DEFAULT_RESPAWN = "walk_back"

-- dive_policy: under what conditions a bot may sit in enemy tower range (chase/farm under tower).
-- Gradient of risk: never -> finish_only -> when_grouped -> when_ahead -> always. Default
-- finish_only = don't burn under tower, but still secure a near-dead enemy. Aggressive prompts
-- set 'always'. Used by M.MayDive in the laning guard (NOT during push/siege).
local DIVE_VALUES = { never = true, finish_only = true, when_grouped = true, when_ahead = true, always = true }
local DEFAULT_DIVE = "finish_only"

-- smoke_usage: whether the team uses Smoke of Deceit (OHA already has the behaviour; this gates it).
local SMOKE_VALUES = { for_ganks = true, never = true }
local DEFAULT_SMOKE = "for_ganks"

-- buyback_policy: never = suppress entirely; default = stock OHA logic (unchanged).
-- 'always' was removed — it never fired in testing (always-side tended to win and not need buyback).
local BUYBACK_VALUES = { never = true, default = true }
local DEFAULT_BUYBACK = "default"

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
    local dp = rawRules.dive_policy
    local dive = (type(dp) == "string" and DIVE_VALUES[dp]) and dp or DEFAULT_DIVE
    local sm = rawRules.smoke_usage
    local smoke = (type(sm) == "string" and SMOKE_VALUES[sm]) and sm or DEFAULT_SMOKE
    local bbk = rawRules.buyback_policy
    local buyback = (type(bbk) == "string" and BUYBACK_VALUES[bbk]) and bbk or DEFAULT_BUYBACK

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

    return { dials = dials, rules = { respawn_behavior = respawn, dive_policy = dive, smoke_usage = smoke, buyback_policy = buyback }, item_build = items, item_rules = item_rules, improvements = improvements }
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

-- Rate-limited counter: increments key at most once per `sec` seconds (per bot, per key).
-- For per-frame events (desire functions, mode ticks) so the count reflects episodes, not frames.
function M.DiagRL(bot, key, sec)
    if bot == nil then return end
    bot.aib_rlLast = bot.aib_rlLast or {}
    local now = DotaTime()
    if bot.aib_rlLast[key] == nil or now - bot.aib_rlLast[key] >= sec then
        bot.aib_rlLast[key] = now
        M.Diag(bot, key)
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

-- Lead-aware "finish" detector. Returns true once an enemy hero is dead AND game is past
-- the early phase (>10 min Turbo-time). FINISH_DEAD=1 so a single kill in mid/late game
-- triggers the push window immediately rather than waiting for 2 kills (which was causing
-- 60+ min Turbo games). Time gate prevents early-game overreaction (one kill at min 5 → push).
-- DIAL-INDEPENDENT base competence: push_desire shapes mid-game sieging; this handles closeout.
-- Edge-triggered diag 'finish-push' so logs show how often the override engaged.
local FINISH_DEAD = 1       -- engage once this many of the 5 enemy heroes are dead
local FINISH_MIN_TIME = 600 -- seconds: ~10 min Turbo = meaningful mid/late game
function M.IsFinishState(bot)
    if DotaTime() < FINISH_MIN_TIME then return false end
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

-- dive_policy gate: may this bot currently be inside enemy tower range (chase/farm under tower)?
-- Gradient: never < finish_only < when_grouped < when_ahead < always (each level adds permission).
-- Finishing a near-dead enemy is allowed at every level except 'never'. Used by the LANING guard
-- only — push/siege runs in a different mode, so sieging towers is never blocked by this.
local DIVE_FINISH_HP = 0.35
local function countNonSelfAllies(bot, radius)
    local list = bot:GetNearbyHeroes(radius, false, BOT_MODE_NONE)
    local n = 0
    if list then for _, h in ipairs(list) do if h ~= bot and h:IsAlive() then n = n + 1 end end end
    return n
end
function M.MayDive(bot)
    local policy = M.Get().rules.dive_policy or DEFAULT_DIVE
    if policy == "always" then return true end
    if policy == "never" then return false end
    -- finishing a low-HP enemy in range: allowed for finish_only and above
    local he = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
    if he then
        for _, e in ipairs(he) do
            if e:IsAlive() and (e:GetHealth() / e:GetMaxHealth()) < DIVE_FINISH_HP then return true end
        end
    end
    if policy == "finish_only" then return false end
    if policy == "when_grouped" then
        return countNonSelfAllies(bot, 1200) >= 1
    end
    if policy == "when_ahead" then
        if countNonSelfAllies(bot, 1200) >= 1 then return true end  -- grouped subsumed
        local myTeam = bot:GetTeam()
        local enemyTeam = (myTeam == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
        local function alive(t) local n = 0 for _, id in ipairs(GetTeamPlayers(t)) do if IsHeroAlive(id) then n = n + 1 end end return n end
        return alive(myTeam) > alive(enemyTeam)
    end
    return false
end

return M
