-- AIBattle: shared playstyle loader (Schema v2).
-- Reads Customize/playstyle_<team>.lua  ->  { dials = {...}, rules = {...} }
-- Merges with safe defaults, clamps dials to 0-1, validates rules against a whitelist.
-- Consumed by mode_laning_generic, mode_rune_generic, mode_retreat_generic.

local M = {}

-- per-team cache (both heroes on a team share the same config)
local _cache = {}

local DEFAULT_DIALS = {
    harass_desire   = 0.5,
    farm_focus      = 0.5,
    forwardness     = 0.5,
    ability_aggro   = 0.5,
    rune_control    = 0.5,
    retreat_caution = 0.5,
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

    return { dials = dials, rules = { respawn_behavior = respawn }, item_build = items }
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

return M
