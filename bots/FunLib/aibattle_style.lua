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
-- default / for_ganks = OHA smoke logic unchanged (aliases; for_ganks kept for backward compat).
local SMOKE_VALUES = { default = true, for_ganks = true, never = true }
local DEFAULT_SMOKE = "default"

-- buyback_policy: never = suppress entirely; default = stock OHA logic (unchanged).
-- 'always' was removed — it never fired in testing (always-side tended to win and not need buyback).
local BUYBACK_VALUES = { never = true, default = true }
local DEFAULT_BUYBACK = "default"

-- aegis_policy: who picks up Aegis of the Immortal after Roshan.
-- carry_only = pos1 only; if dead nobody picks it up.
-- core      = pos1 preferred, pos3/pos2 fallback if pos1 is dead (default).
-- any       = no restriction — whoever is closest takes it (OHA original).
local AEGIS_VALUES = { carry_only = true, core = true, any = true }
local DEFAULT_AEGIS = "core"

-- low_hp_behavior: what the bot does when health is critically low.
-- tp_fountain = current OHA: use TP scroll to go to base (fast but cancellable by damage — a Golem
--               or chasing hero can cancel the channel and the bot dies standing still).
-- run_to_tower = suppress TP escape, just run toward nearest friendly tower. Safer when
--               there are nearby units that would cancel the channel anyway.
-- fight_back   = don't activate retreat mode at all — keep fighting to the end.
--               Pair with dive_policy=always for max-aggression builds.
-- regen_lane   = don't TP or run — step back ~400 units from danger and wait for natural regen.
--               Only fires when safe (no hero damage in last 2.5s + enemy not chasing).
--               Stays near lane. Diag: 'regen-lane' (fired) / 'retreat-blocked' (wanted but unsafe).
-- walk_fountain = no TP escape — walk to own fountain on foot when critically low and no items.
--               Slower than tp_fountain but immune to damage-cancel. Costs XP/gold (long walk).
--               Falls back to TP if a scroll is available. Diag: 'recovery-walk'.
local LOW_HP_VALUES = { tp_fountain = true, run_to_tower = true, fight_back = true, regen_lane = true, walk_fountain = true }
local DEFAULT_LOW_HP = "tp_fountain"

-- pregame_behavior: what the bot does before creeps spawn (DotaTime < 0).
-- nil / unset  = OHA default (routes to bounty runes — useless in 1v1 where no runes spawn at 0:00).
-- safe_tower   = stand ~350 units in front of own mid T1 tower (safe zone, good default for 1v1).
-- aggressive_mid = hold the river crossing (~45% of the way from own T1 to enemy T1).
--                 Puts pressure and denies vision of mid approach.
-- jungle_pressure = walk deep into enemy half (~70% toward enemy T1), near their jungle entrance.
--                 Safe in 1v1 (neutrals almost never attack). Can zone or observe.
-- Diag: 'pregame-<value>' rate-limited 5s.
local PREGAME_VALUES = { safe_tower = true, aggressive_mid = true, jungle_pressure = true }
local DEFAULT_PREGAME = nil  -- nil = OHA default (no override)

-- healing_style: controls whether our defensive heal system is active.
-- active  = use heal items / pullback / regen when low HP (was: improvements.defensive_heal=true).
-- default / passive = OHA default healing only (passive kept for backward compat).
-- never   = suppress all healing: blocks our system AND OHA item usage (tango/flask/bottle/etc).
local HEALING_STYLE_VALUES = { active = true, default = true, passive = true, never = true }
local DEFAULT_HEALING_STYLE = "default"

-- ability_usage: controls whether our AbilityHarass system fires.
-- aggressive = use abilities for harass, gated by ability_aggro dial (was: improvements.ability_on_dials=true).
-- default / basic = OHA default ability casting only (basic kept for backward compat).
local ABILITY_USAGE_VALUES = { aggressive = true, default = true, basic = true }
local DEFAULT_ABILITY_USAGE = "default"

-- creep_wave_priority: how the bot handles the enemy creep wave.
-- push         = attack all in-range creeps freely (wave advances toward enemy tower).
-- last_hit_only = only attack within the kill window (default; wave holds equilibrium).
-- freeze        = never attack enemy creeps (wave drifts back; enemy must walk far to farm).
local CREEP_WAVE_PRIORITY_VALUES = { push = true, last_hit_only = true, freeze = true }
local DEFAULT_CREEP_WAVE_PRIORITY = "last_hit_only"

-- ability_timing: when to use abilities (only meaningful when ability_usage = "aggressive").
-- on_cooldown     = use for both harass and execute as soon as available (default).
-- save_for_execute = skip harass; hold mana for the execute cast when enemy is low.
-- harass_only     = use for harass only; never cast as an execute finisher.
local ABILITY_TIMING_VALUES = { on_cooldown = true, save_for_execute = true, harass_only = true }
local DEFAULT_ABILITY_TIMING = "on_cooldown"

-- hero_priority: whether the bot auto-attacks the enemy hero.
-- always  = always attack hero when in range (ignores farm_focus / hp-disadvantage gates).
-- default = OHA behaviour (farm_focus roll + hp-disadvantage check).
-- never   = never auto-attack hero (pure creep focus).
local HERO_PRIORITY_VALUES = { always = true, default = true, never = true }
local DEFAULT_HERO_PRIORITY = "default"

-- deny_policy: how aggressively the bot denies allied creeps.
-- always  = deny any allied creep below 60% HP (wider window than kill-guarantee).
-- default = OHA behaviour (deny only when health <= attackDamage).
-- never   = never deny allied creeps.
local DENY_POLICY_VALUES = { always = true, default = true, never = true }
local DEFAULT_DENY_POLICY = "default"

local RULE_NUMBERS = {
    low_hp_hold = { default = 0.45, min = 0.25, max = 0.70 },
    creep_aggro_relief_hp = { default = 0.68, min = 0.45, max = 0.90 },
    bottle_rune_max_dist = { default = 1900.0, min = 900.0, max = 2600.0 },
    bottle_rune_lane_budget = { default = 1500.0, min = 700.0, max = 2400.0 },
    visual_afk_seconds = { default = 6.0, min = 3.0, max = 12.0 },
    visual_afk_distance = { default = 90.0, min = 50.0, max = 180.0 },
}

local function clamp01(x)
    if type(x) ~= "number" then return nil end
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function clampNumber(x, default, minValue, maxValue)
    local v = tonumber(x)
    if v == nil then return default end
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

local function ruleNumber(rawRules, name)
    local spec = RULE_NUMBERS[name]
    return clampNumber(rawRules[name], spec.default, spec.min, spec.max)
end

local function parseDials(rawDials)
    local dials = {}
    for k, default in pairs(DEFAULT_DIALS) do
        local v = clamp01(rawDials[k])
        if v ~= nil then dials[k] = v else dials[k] = default end
    end
    return dials
end

local BUILD_STYLES = { brawler = true, spellcaster = true, farmer = true }

local function parseItems(rawItems, build_style)
    local items = {}
    for heroName, heroList in pairs(rawItems) do
        if type(heroName) == "string" and type(heroList) == "table" then
            if build_style and type(heroList[build_style]) == "table" then
                heroList = heroList[build_style]
            end
            local filtered = {}
            for _, name in ipairs(heroList) do
                if type(name) == "string" and string.match(name, "^item_") then
                    filtered[#filtered + 1] = name
                end
            end
            if #filtered > 0 then items[heroName] = filtered end
        end
    end
    return items
end

local function parseSkills(rawSkills)
    local skills = {}
    for heroName, heroList in pairs(rawSkills) do
        if type(heroName) == "string" and type(heroList) == "table" then
            local filtered = {}
            for _, idx in ipairs(heroList) do
                if type(idx) == "number" and idx >= 1 and math.floor(idx) == idx then
                    filtered[#filtered + 1] = math.floor(idx)
                end
            end
            if #filtered > 0 then skills[heroName] = filtered end
        end
    end
    return skills
end

local function parseItemRules(rawItemRules)
    local item_rules = {}
    for _, r in ipairs(rawItemRules) do
        if type(r) == "table" and type(r.when) == "string"
            and type(r.item) == "string" and string.match(r.item, "^item_") then
            item_rules[#item_rules + 1] = { when = r.when, item = r.item, first = (r.first ~= false) }
        end
    end
    return item_rules
end

local function buildStyle(raw)
    local rawDials = (type(raw) == "table" and type(raw.dials) == "table") and raw.dials or {}
    local dials = parseDials(rawDials)

    local rawRules = (type(raw) == "table" and type(raw.rules) == "table") and raw.rules or {}
    local rb = rawRules.respawn_behavior
    local respawn = (type(rb) == "string" and RESPAWN_VALUES[rb]) and rb or DEFAULT_RESPAWN
    local dp = rawRules.dive_policy
    local dive = (type(dp) == "string" and DIVE_VALUES[dp]) and dp or DEFAULT_DIVE
    local sm = rawRules.smoke_usage
    if sm == "for_ganks" then sm = "default" end  -- backward compat
    local smoke = (type(sm) == "string" and SMOKE_VALUES[sm]) and sm or DEFAULT_SMOKE
    local bbk = rawRules.buyback_policy
    local buyback = (type(bbk) == "string" and BUYBACK_VALUES[bbk]) and bbk or DEFAULT_BUYBACK
    local aeg = rawRules.aegis_policy
    local aegis = (type(aeg) == "string" and AEGIS_VALUES[aeg]) and aeg or DEFAULT_AEGIS
    local lhb = rawRules.low_hp_behavior
    local low_hp = (type(lhb) == "string" and LOW_HP_VALUES[lhb]) and lhb or DEFAULT_LOW_HP
    local pgb = rawRules.pregame_behavior
    local pregame = (type(pgb) == "string" and PREGAME_VALUES[pgb]) and pgb or DEFAULT_PREGAME

    -- build_style: selects which sub-table to use when item_build provides 3 named builds.
    -- Supported values: "brawler" / "spellcaster" / "farmer". Ignored for flat-array builds.
    local bs = (type(raw) == "table") and raw.build_style or nil
    local build_style = (type(bs) == "string" and BUILD_STYLES[bs]) and bs or nil

    -- Prompt-driven item build: per-hero ordered buy list.
    -- Format A (flat):  { npc_dota_hero_axe = {"item_blink", ...} }
    -- Format B (styled): { npc_dota_hero_axe = { brawler={...}, spellcaster={...}, farmer={...} } }
    -- For Format B, build_style selects the sub-table. Falls back to flat-array if key missing.
    -- Only keeps "item_*" strings; bogus names from LLM are dropped silently.
    -- Consumed by jmz_func.lua SetUserHeroInit (reads items[botName] per hero).
    local rawItems = (type(raw) == "table" and type(raw.item_build) == "table") and raw.item_build or {}
    local items = parseItems(rawItems, build_style)

    -- Prompt-driven skill build: per-hero ability level-up order.
    -- Format: { npc_dota_hero_nevermore = {1,5,1,5,1,6,...} }
    -- Each number = ability slot index (1-based). Lets LLM or test configs override
    -- OHA's default skill priority (e.g. rush ult at level 6 instead of level 9).
    -- Only keeps positive integers; bogus values dropped silently.
    -- Consumed by jmz_func.lua SetUserHeroInit (overrides nAbilityBuildList).
    local rawSkills = (type(raw) == "table" and type(raw.skill_build) == "table") and raw.skill_build or {}
    local skills = parseSkills(rawSkills)

    -- Situational purchase rules (optional): { when=<cond>, item=<name>, first=<bool> }.
    -- Lets a prompt say "if behind, buy survivability". Evaluated in-game by the purchaser.
    local rawItemRules = (type(raw) == "table" and type(raw.item_rules) == "table") and raw.item_rules or {}
    local item_rules = parseItemRules(rawItemRules)

    -- Legacy improvements table: source of truth for backward compat parsing below.
    local rawImp = (type(raw) == "table" and type(raw.improvements) == "table") and raw.improvements or {}

    -- healing_style: rule value takes priority; falls back to improvements.defensive_heal for old configs.
    local hs = rawRules.healing_style
    if hs == "passive" then hs = "default" end  -- backward compat
    local healing_style = (type(hs) == "string" and HEALING_STYLE_VALUES[hs]) and hs
        or (rawImp.defensive_heal == true and "active")
        or DEFAULT_HEALING_STYLE

    -- ability_usage: rule value takes priority; falls back to improvements.ability_on_dials for old configs.
    local au = rawRules.ability_usage
    if au == "basic" then au = "default" end  -- backward compat
    local ability_usage = (type(au) == "string" and ABILITY_USAGE_VALUES[au]) and au
        or (rawImp.ability_on_dials == true and "aggressive")
        or DEFAULT_ABILITY_USAGE

    local cwp = rawRules.creep_wave_priority
    local creep_wave_priority = (type(cwp) == "string" and CREEP_WAVE_PRIORITY_VALUES[cwp]) and cwp or DEFAULT_CREEP_WAVE_PRIORITY

    local at = rawRules.ability_timing
    local ability_timing = (type(at) == "string" and ABILITY_TIMING_VALUES[at]) and at or DEFAULT_ABILITY_TIMING

    local hp = rawRules.hero_priority
    local hero_priority = (type(hp) == "string" and HERO_PRIORITY_VALUES[hp]) and hp or DEFAULT_HERO_PRIORITY

    local denp = rawRules.deny_policy
    local deny_policy = (type(denp) == "string" and DENY_POLICY_VALUES[denp]) and denp or DEFAULT_DENY_POLICY

    local low_hp_hold = ruleNumber(rawRules, "low_hp_hold")
    local creep_aggro_relief_hp = ruleNumber(rawRules, "creep_aggro_relief_hp")
    local bottle_rune_max_dist = ruleNumber(rawRules, "bottle_rune_max_dist")
    local bottle_rune_lane_budget = ruleNumber(rawRules, "bottle_rune_lane_budget")

    -- Debug-only switches for isolating AFK/jitter. These are deliberately not LLM-visible
    -- style rules; set them by hand in playstyle_*.lua for one diagnostic match.
    local debug_disable_forwardness_fallbacks = rawRules.debug_disable_forwardness_fallbacks == true
    local debug_skeleton_laning = rawRules.debug_skeleton_laning == true
    local visual_afk_seconds = ruleNumber(rawRules, "visual_afk_seconds")
    local visual_afk_distance = ruleNumber(rawRules, "visual_afk_distance")

    return { dials = dials, rules = {
        respawn_behavior = respawn, dive_policy = dive, smoke_usage = smoke,
        buyback_policy = buyback, aegis_policy = aegis, low_hp_behavior = low_hp,
        pregame_behavior = pregame,
        healing_style = healing_style, ability_usage = ability_usage,
        creep_wave_priority = creep_wave_priority, ability_timing = ability_timing,
        hero_priority = hero_priority, deny_policy = deny_policy,
        low_hp_hold = low_hp_hold,
        creep_aggro_relief_hp = creep_aggro_relief_hp,
        bottle_rune_max_dist = bottle_rune_max_dist,
        bottle_rune_lane_budget = bottle_rune_lane_budget,
        debug_disable_forwardness_fallbacks = debug_disable_forwardness_fallbacks,
        debug_skeleton_laning = debug_skeleton_laning,
        visual_afk_seconds = visual_afk_seconds,
        visual_afk_distance = visual_afk_distance,
    }, item_build = items, skill_build = skills, item_rules = item_rules }
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

function M.RuleNumberSchema()
    return RULE_NUMBERS
end

-- Backward-compat shim for old callers; new code should read rules directly.
function M.Imp(name)
    local r = M.Get().rules
    if name == "defensive_heal"   then return r.healing_style  == "active"     end
    if name == "ability_on_dials" then return r.ability_usage  == "aggressive"  end
    return false
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

-- Rate-limited intent telemetry. Unlike Diag(), this describes what the bot wanted
-- to do and why; match_stats.py prints it separately from branch counters.
function M.Intent(bot, name, detail, sec)
    if bot == nil or name == nil then return end
    bot.aib_intentLast = bot.aib_intentLast or {}
    local now = DotaTime()
    local gap = sec or 5.0
    if bot.aib_intentLast[name] ~= nil and now - bot.aib_intentLast[name] < gap then
        return
    end
    bot.aib_intentLast[name] = now
    local side = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
    local suffix = (detail ~= nil and detail ~= "") and (" " .. detail) or ""
    bot:ActionImmediate_Chat("AIB[" .. side .. "] intent=" .. tostring(name) .. suffix, true)
end

function M.Blocked(bot, name, reason, detail, sec)
    if bot == nil or name == nil then return end
    bot.aib_blockedLast = bot.aib_blockedLast or {}
    local key = tostring(name) .. ":" .. tostring(reason or "unknown")
    local now = DotaTime()
    local gap = sec or 5.0
    if bot.aib_blockedLast[key] ~= nil and now - bot.aib_blockedLast[key] < gap then
        return
    end
    bot.aib_blockedLast[key] = now
    local side = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
    local suffix = " reason=" .. tostring(reason or "unknown")
    if detail ~= nil and detail ~= "" then suffix = suffix .. " " .. detail end
    bot:ActionImmediate_Chat("AIB[" .. side .. "] blocked=" .. tostring(name) .. suffix, true)
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
-- triggers the push window immediately rather than waiting for 2 kills.
-- Net-worth gate: must NOT be losing by >15% NW — prevents a losing team from pushing after
-- a lucky kill while already down 30k gold (they should defend, not rush enemy base).
-- DIAL-INDEPENDENT base competence: push_desire shapes mid-game sieging; this handles closeout.
-- Edge-triggered diag 'finish-push' so logs show how often the override engaged.
local FINISH_DEAD = 1       -- engage once this many of the 5 enemy heroes are dead
local FINISH_MIN_TIME = 600 -- seconds: ~10 min Turbo = meaningful mid/late game
local FINISH_NW_RATIO = 0.85 -- must have >= 85% of enemy net worth to push
function M.IsFinishState(bot)
    if DotaTime() < FINISH_MIN_TIME then return false end
    local myTeam = bot:GetTeam()
    local enemyTeam = (myTeam == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    -- Net-worth gate
    local myNW, enNW = 0, 0
    for _, id in ipairs(GetTeamPlayers(myTeam)) do
        myNW = myNW + (PlayerResource:GetNetWorth(id) or 0)
    end
    for _, id in ipairs(GetTeamPlayers(enemyTeam)) do
        enNW = enNW + (PlayerResource:GetNetWorth(id) or 0)
    end
    if enNW > 0 and myNW < enNW * FINISH_NW_RATIO then return false end
    -- Kill gate
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

-- Aegis pickup eligibility, driven by aegis_policy rule.
-- carry_only: pos1 only; if dead nobody takes it.
-- core (default): pos1 preferred; pos2/pos3 fallback only if pos1 is dead; pos4/5 never.
-- any: no restriction — whoever is closest (OHA original behaviour).
-- Call from ItemOpsDesire/ItemOpsThink in mode_team_roam_generic.lua.
function M.ShouldPickupAegis(bot)
    local policy = M.Get().rules.aegis_policy or DEFAULT_AEGIS
    local pos = J.GetPosition(bot)

    if policy == "any" then return true end

    if policy == "carry_only" then
        return pos == 1
    end

    -- policy == "core" (default): pos1 always; pos2/3 only if no pos1 alive
    if pos >= 4 then return false end
    if pos == 1 then return true end
    for i = 1, 5 do
        local ally = GetTeamMember(i)
        if ally ~= nil and ally ~= bot and ally:IsAlive() and J.GetPosition(ally) == 1 then
            return false  -- carry alive → let them take it
        end
    end
    return true  -- carry dead → pos2/3 eligible
end

local function antiIdleCombat(bot, lowHp)
    if lowHp then return false end
    local enemies = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
    if not (enemies and #enemies > 0 and enemies[1]:IsAlive()) then return false end

    if GetUnitToUnitDistance(bot, enemies[1]) <= bot:GetAttackRange() then
        bot:Action_AttackUnit(enemies[1], true)
    else
        bot:Action_MoveToUnit(enemies[1])
    end
    M.Diag(bot, "anti-idle-combat")
    return true
end

local function antiIdleAssist(bot)
    local allies = bot:GetNearbyHeroes(1500, false, BOT_MODE_NONE)
    if allies == nil then return false end
    for _, a in ipairs(allies) do
        if a:IsAlive() and a ~= bot then
            local ae = a:GetNearbyHeroes(600, true, BOT_MODE_NONE)
            if ae and #ae > 0 then
                -- AIBattle #6: RandomVector avoids creep-collision stalling.
                bot:Action_MoveToLocation(a:GetLocation() + RandomVector(100))
                M.Diag(bot, "anti-idle-assist")
                return true
            end
        end
    end
    return false
end

local function antiIdleCreep(bot)
    local creeps = bot:GetNearbyCreeps(1200, true)
    if not (creeps and #creeps > 0) then return false end
    for _, c in ipairs(creeps) do
        if c:IsAlive() then
            if GetUnitToUnitDistance(bot, c) <= bot:GetAttackRange() then
                bot:Action_AttackUnit(c, true)
                M.Diag(bot, "anti-idle-creep")
            else
                bot:Action_MoveToUnit(c)
                M.DiagRL(bot, "anti-idle-creep-walk", 5)
            end
            return true
        end
    end
    return false
end

local function antiIdleLane(bot, lane)
    local dest = GetLaneFrontLocation(bot:GetTeam(), lane, 0)
    if dest ~= nil and GetUnitToLocationDistance(bot, dest) > 150 then
        bot:Action_MoveToLocation(dest)
        M.DiagRL(bot, "anti-idle-lane", 5)
        return true
    end
    return false
end

local function antiIdlePush(bot, lane, lowHp)
    if lowHp then return false end
    local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
    if enmT1 == nil or not enmT1:IsAlive() then return false end

    local atkRange = bot:GetAttackRange()
    if GetUnitToUnitDistance(bot, enmT1) <= atkRange then
        bot:Action_AttackUnit(enmT1, true)
        M.DiagRL(bot, "anti-idle-push", 5)
        return true
    end
    local pushDest = GetLaneFrontLocation(bot:GetTeam(), lane, -400) or enmT1:GetLocation()
    if GetUnitToLocationDistance(bot, pushDest) > atkRange then
        bot:Action_MoveToLocation(pushDest)
        M.DiagRL(bot, "anti-idle-push", 5)
        return true
    end
    return false
end

-- Anti-idle global fallback: call at the END of any mode's Think() as a last resort.
-- No meaningful-action gate: caller must place this after all normal mode logic.
function M.AntiIdleGlobal(bot)
    M.DiagRL(bot, "anti-idle-enter", 3)
    local lowHp = J.GetHP(bot) < 0.25
    local lane = bot:GetAssignedLane()

    if antiIdleCombat(bot, lowHp) then return true end
    if antiIdleAssist(bot) then return true end
    if antiIdleCreep(bot) then return true end
    if antiIdleLane(bot, lane) then return true end
    if antiIdlePush(bot, lane, lowHp) then return true end

    M.DiagRL(bot, "idle", 3)
    return false
end

-- ─── Hero ability config ──────────────────────────────────────────────────────
-- Declares which abilities each hero uses for harass (ability_aggro dial) and
-- execute (execute_threshold dial). Four targeting types:
--   "unit"        → Action_UseAbilityOnEntity(ab, enemy)
--   "point"       → Action_UseAbilityOnLocation(ab, enemy:GetLocation())
--   "no_target"   → Action_UseAbility(ab)          (AoE around self / instant global)
--   "directional" → Action_UseAbility(ab) after positioning at range±aoe from enemy.
--                   Bot must be facing the enemy — use for fixed-direction abilities like
--                   SF Shadowraze (fires in front at a fixed distance, not at a unit/point).
-- harass entries are ordered highest→lowest range (try safest first).
-- execute.max_range: don't cast if enemy is farther than this.
M.HeroAbilityConfig = {
    ["npc_dota_hero_nevermore"] = {
        -- Shadowraze is point-targeted (aim anywhere within range), not directional.
        -- Using "point" casts Action_UseAbilityOnLocation(enemy:GetLocation()) — accurate aim.
        -- Old "directional" used Action_UseAbility() which fired wherever the bot was facing.
        -- raze1 excluded — range 200 is melee distance, not worth rushing in for.
        harass = {
            { name = "nevermore_shadowraze3", type = "point", range = 700 },
            { name = "nevermore_shadowraze2", type = "point", range = 450 },
        },
        -- Requiem of Souls: no-target AoE; souls travel 1300 but damage drops off.
        -- Only execute when close so the burst reliably kills.
        execute = { name = "nevermore_requiem",           type = "no_target", max_range = 700 },
    },
    ["npc_dota_hero_sniper"] = {
        harass  = { { name = "sniper_shrapnel",    type = "point",  range = 900 } },
        execute = { name = "sniper_assassinate",   type = "unit",   max_range = 2500 },
    },
    ["npc_dota_hero_juggernaut"] = {
        -- Blade Fury: no-target AoE spin at 280 radius; cast when enemy is adjacent.
        harass  = { { name = "juggernaut_blade_fury", type = "no_target", max_range = 280 } },
    },
    ["npc_dota_hero_zeus"] = {
        harass = {
            { name = "zeus_arc_lightning",  type = "unit", range = 700 },
            { name = "zeus_lightning_bolt", type = "unit", range = 600 },
        },
        -- Thundergod's Wrath: global no-target — cast whenever enemy HP below threshold.
        execute = { name = "zeus_thundergods_wrath", type = "no_target", max_range = nil },
    },
    ["npc_dota_hero_lina"] = {
        harass = {
            { name = "lina_dragon_slave",      type = "point", range = 925 },
            { name = "lina_light_strike_array", type = "point", range = 625 },
        },
        execute = { name = "lina_laguna_blade", type = "unit", max_range = 600 },
    },
    ["npc_dota_hero_lion"] = {
        harass = {
            { name = "lion_impale",  type = "point", range = 500 },
            { name = "lion_voodoo", type = "unit",  range = 500 },
        },
        execute = { name = "lion_finger_of_death", type = "unit", max_range = 750 },
    },
    ["npc_dota_hero_skywrath_mage"] = {
        harass = {
            { name = "skywrath_mage_arcane_bolt",     type = "unit",      range = 700 },
            { name = "skywrath_mage_concussive_shot", type = "no_target", max_range = 1000 },
        },
        execute = { name = "skywrath_mage_mystic_flare", type = "point", max_range = 1000 },
    },
    -- Phantom Assassin: Stifling Dagger (unit, 825). No execute — Coup de Grace is passive.
    ["npc_dota_hero_phantom_assassin"] = {
        harass = {
            { name = "phantom_assassin_stifling_dagger", type = "unit", range = 825 },
        },
    },
    -- Sven: Storm Bolt (unit stun, 600). No execute — God's Strength is a self-buff.
    ["npc_dota_hero_sven"] = {
        harass = {
            { name = "sven_storm_bolt", type = "unit", range = 600 },
        },
    },
    -- Drow Ranger: Wave of Silence (point, 900). No execute — Marksmanship is passive.
    ["npc_dota_hero_drow_ranger"] = {
        harass = {
            { name = "drow_ranger_wave_of_silence", type = "point", range = 900 },
        },
    },
    -- Lich: Frost Nova (unit, 600) + Sinister Gaze (unit, 525). Chain Frost (unit execute, 750).
    ["npc_dota_hero_lich"] = {
        harass = {
            { name = "lich_frost_nova",    type = "unit", range = 600 },
            { name = "lich_sinister_gaze", type = "unit", range = 525 },
        },
        execute = { name = "lich_chain_frost", type = "unit", max_range = 750 },
    },
    -- Axe: Battle Hunger (unit DoT, 750). Culling Blade (unit execute, 250 — must be melee range).
    ["npc_dota_hero_axe"] = {
        harass = {
            { name = "axe_battle_hunger", type = "unit", range = 750 },
        },
        execute = { name = "axe_culling_blade", type = "unit", max_range = 250 },
    },
    -- Tidehunter: Gush (unit slow+armor, 750). Ravage (no_target AoE, 1025 radius — panic execute).
    ["npc_dota_hero_tidehunter"] = {
        harass = {
            { name = "tidehunter_gush", type = "unit", range = 750 },
        },
        execute = { name = "tidehunter_ravage", type = "no_target", max_range = 1025 },
    },
    -- Warlock: Shadow Word (unit harass/DoT, 700). No targeted execute — Chaotic Offering summons a golem.
    ["npc_dota_hero_warlock"] = {
        harass = {
            { name = "warlock_shadow_word", type = "unit", range = 700 },
        },
    },
    -- Templar Assassin: Psi Blades is passive; Refraction and Meld are self/positional.
    -- Auto-attack harass (harass_desire) handles TA naturally. No entry needed.

    -- Clockwerk: Rocket Flare (point, 1800) + Battery Assault (no_target AoE, 250 radius).
    -- Hookshot (unit, 2500) as execute — closes gap and stuns low-HP targets.
    ["npc_dota_hero_rattletrap"] = {
        harass = {
            { name = "rattletrap_rocket_flare",    type = "point",     range = 1800 },
            { name = "rattletrap_battery_assault", type = "no_target", max_range = 250 },
        },
        execute = { name = "rattletrap_hookshot", type = "unit", max_range = 2500 },
    },
}

-- AbilityHarass: use a hero-specific ability on the enemy, gated by ability_aggro dial.
-- Walks through HeroAbilityConfig[hero].harass (highest→lowest range) and casts the
-- first ability that can reach the enemy:
--   unit/point   → cast immediately if in range
--   directional  → cast if enemy is in the hit zone (range±aoe); move to sweet spot if too far
--   no_target    → cast if enemy is within max_range (or always if max_range is nil)
-- Returns true if an action was issued (cast or positioning move), false otherwise.
function M.AbilityHarass(bot, enemy)
    if M.Get().rules.ability_usage ~= "aggressive" then return false end
    if M.Get().rules.ability_timing == "save_for_execute" then return false end
    local dial = M.Get().dials.ability_aggro
    if dial == nil or math.random() >= dial then return false end
    local cfg = M.HeroAbilityConfig[bot:GetUnitName()]
    if not cfg or not cfg.harass then return false end
    local dist = GetUnitToUnitDistance(bot, enemy)
    for i, abCfg in ipairs(cfg.harass) do
        local ab = bot:GetAbilityByName(abCfg.name)
        if ab and ab:IsFullyCastable() then
            if abCfg.type == "unit" then
                if dist <= abCfg.range then
                    bot:Action_UseAbilityOnEntity(ab, enemy)
                    M.Diag(bot, "ability-harass"); return true
                end
            elseif abCfg.type == "point" then
                if dist <= abCfg.range then
                    bot:Action_UseAbilityOnLocation(ab, enemy:GetLocation())
                    M.Diag(bot, "ability-harass"); return true
                end
            elseif abCfg.type == "directional" then
                local hitMin = abCfg.range - abCfg.aoe
                local hitMax = abCfg.range + abCfg.aoe
                if dist >= hitMin and dist <= hitMax then
                    -- In hit zone: bot should already be facing enemy (last move/attack aimed at them)
                    bot:Action_UseAbility(ab)
                    M.Diag(bot, "ability-harass"); return true
                elseif dist > hitMax and i == 1 then
                    -- Too far even for the longest-range raze: move to sweet spot
                    local dir = (enemy:GetLocation() - bot:GetLocation()):Normalized()
                    bot:Action_MoveToLocation(enemy:GetLocation() - dir * abCfg.range)
                    M.Diag(bot, "ability-harass-move"); return true
                end
                -- dist < hitMin → too close for this raze, fall through to shorter-range one
            elseif abCfg.type == "no_target" then
                if not abCfg.max_range or dist <= abCfg.max_range then
                    bot:Action_UseAbility(ab)
                    M.Diag(bot, "ability-harass"); return true
                end
            end
        end
    end
    return false
end

-- AbilityExecute: cast the hero's execute ability when enemy HP < execute_threshold dial.
-- Handles unit/point/no_target types. For no_target executes (SF Requiem, Zeus ult):
-- if enemy is beyond max_range, moves closer WITHOUT returning true, so other laning
-- logic can still fire on the same tick.
-- Returns true only when an ability was actually cast.
function M.AbilityExecute(bot, enemy)
    if M.Get().rules.ability_timing == "harass_only" then return false end
    local threshold = M.Get().dials.execute_threshold
    if threshold == nil or threshold <= 0 then return false end
    local cfg = M.HeroAbilityConfig[bot:GetUnitName()]
    if not cfg or not cfg.execute then return false end
    local exCfg = cfg.execute
    local ab = bot:GetAbilityByName(exCfg.name)
    if not ab or not ab:IsFullyCastable() then return false end
    local maxHp = enemy:GetMaxHealth()
    if maxHp <= 0 then return false end
    if (enemy:GetHealth() / maxHp) > threshold then return false end
    local dist = GetUnitToUnitDistance(bot, enemy)
    if exCfg.type == "unit" then
        if not exCfg.max_range or dist <= exCfg.max_range then
            bot:Action_UseAbilityOnEntity(ab, enemy)
            M.Diag(bot, "execute"); return true
        end
    elseif exCfg.type == "point" then
        if not exCfg.max_range or dist <= exCfg.max_range then
            bot:Action_UseAbilityOnLocation(ab, enemy:GetLocation())
            M.Diag(bot, "execute"); return true
        end
    elseif exCfg.type == "no_target" then
        if not exCfg.max_range or dist <= exCfg.max_range then
            bot:Action_UseAbility(ab)
            M.Diag(bot, "execute"); return true
        else
            -- Not close enough: approach but don't block other actions this tick
            bot:Action_MoveToLocation(enemy:GetLocation())
            M.Diag(bot, "execute-approach")
        end
    end
    return false
end

-- Returns the lane with the most push progress (fewest enemy towers remaining).
-- Used in late-game so bots rally to the most advanced lane instead of
-- dispersing back to original assigned lanes after ganks / AFK recovery.
function M.GetGroupPushLane()
    local enemy = GetOpposingTeam()
    local bestLane = LANE_MID
    local fewestTowers = 99
    local laneData = {
        { LANE_TOP, { TOWER_TOP_1, TOWER_TOP_2, TOWER_TOP_3 } },
        { LANE_MID, { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3 } },
        { LANE_BOT, { TOWER_BOT_1, TOWER_BOT_2, TOWER_BOT_3 } },
    }
    for _, entry in ipairs(laneData) do
        local lane = entry[1]
        local towers = entry[2]
        local count = 0
        for _, tSlot in ipairs(towers) do
            local t = GetTower(enemy, tSlot)
            if t ~= nil and t:IsAlive() then count = count + 1 end
        end
        if count < fewestTowers then
            fewestTowers = count
            bestLane = lane
        end
    end
    return bestLane
end

return M
