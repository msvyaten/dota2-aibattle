local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local Version      = require(GetScriptDirectory()..'/FunLib/version')
local Localization = require(GetScriptDirectory()..'/FunLib/localization')


local bot = GetBot()
local botName = bot:GetUnitName()
-- IsInvulnerable is not part of the load guard: pregame fountain invulnerability
-- used to prevent this module from defining GetDesire/Think at all.
-- Runtime invulnerability checks live inside GetDesire().
if bot == nil or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

local local_mode_laning_generic = nil
local nAllyCreeps = nil
local nEnemyCreeps = nil
local nFurthestEnemyAttackRange = 0
local nInRangeEnemy = nil
local botAssignedLane = nil
local botAttackRange = bot:GetAttackRange()
local attackDamage = bot:GetAttackDamage()
local nH, enemyBots = J.Utils.NumHumanBotPlayersInTeam(GetOpposingTeam())
local teamHumans, teamBots = J.Utils.NumHumanBotPlayersInTeam(GetTeam())

-- Announcer state
local hasPickedOneAnnouncer      = false
local lastAnnouncePrintedTime    = 0
local numberAnnouncePrinted      = 1
local announcementGapSeconds     = 6
local isChangePosMessageDone     = false

if Utils.BuggyHeroesDueToValveTooLazy[botName] then
    local ok, result = pcall(dofile, GetScriptDirectory().."/FunLib/override_generic/mode_laning_generic")
    if ok and result then local_mode_laning_generic = result end
end

-- AIBattle Schema v2: shared loader (dials + rules), with safe defaults/clamping.
local Style   = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBConst = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local AIBLaningContext = require(GetScriptDirectory()..'/FunLib/aibattle_laning_context')
local _buildOk, AIBBuild = pcall(require, GetScriptDirectory()..'/FunLib/aibattle_build')
if not _buildOk then AIBBuild = { sha = "unknown" } end
local _healOk, _healResult = pcall(require, GetScriptDirectory()..'/FunLib/aibattle_survive')
local AIBSurvive = _healOk and _healResult or { Think = function() return false end }
local AIBLaneSurvival = require(GetScriptDirectory()..'/FunLib/aibattle_laning_survival')
local AIBLaneTrade = require(GetScriptDirectory()..'/FunLib/aibattle_laning_trade')
local AIBLaneSiege = require(GetScriptDirectory()..'/FunLib/aibattle_laning_siege')
local AIBLaneDuel = require(GetScriptDirectory()..'/FunLib/aibattle_laning_duel')
local AIBLaneCreeps = require(GetScriptDirectory()..'/FunLib/aibattle_laning_creeps')
local AIBLaneSafety = require(GetScriptDirectory()..'/FunLib/aibattle_laning_safety')
local AIBLaneRecovery = require(GetScriptDirectory()..'/FunLib/aibattle_laning_recovery')
local AIBLaneCombat = require(GetScriptDirectory()..'/FunLib/aibattle_laning_combat')
local AIBLaneTempo = require(GetScriptDirectory()..'/FunLib/aibattle_laning_tempo')
local AIBTopArbiter = require(GetScriptDirectory()..'/FunLib/aibattle_laning_arbiter')
local AIBLanePolicy = require(GetScriptDirectory()..'/FunLib/aibattle_laning_policy')

local function AIB_ClearRecoveryState()
	if AIBSurvive.Reset ~= nil then
		AIBSurvive.Reset(bot)
	else
		bot.aib_fountainTrip = false
		bot.aib_fountainTping = false
		bot.aib_fountainTpCast = nil
		bot.aib_fountainWaitLast = nil
		bot.aib_bottleRuneTarget = nil
		bot.aib_bottleRuneStarted = nil
	end
end
if not _healOk then
    -- Emit once to all-chat so it shows in console.log during test matches
    local _b = GetBot(); if _b then _b:ActionImmediate_Chat("AIB HEAL LOAD ERR: " .. tostring(_healResult), true) end
end
local function GetRules() return Style.Get().rules end

-- AIBattle diag: count each branch firing silently, then emit ONE combined summary line at most
-- once per minute (only when something fired) so a TEST GAME yields measurable numbers without
-- spamming chat. Format 'AIB[R] anti-afk=15 heal-item=7'; the LAST such line in console.<id>.log
-- carries the cumulative totals. (print() is invisible in console.log, so chat is the only
-- logging channel - keep it sparse.)
local AIB_SIDE = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
local AIB_VISUAL_AFK_SECONDS = AIBConst.Visual.afkSeconds
local AIB_VISUAL_AFK_DISTANCE = AIBConst.Visual.afkDistance
local AIB_VISUAL_HOLD_SECONDS = AIBConst.Visual.holdSeconds
local AIB_VISUAL_HOLD_DISTANCE = AIBConst.Visual.holdDistance
local AIB_RUNE_COMMIT_SECONDS = AIBConst.Rune.commitSeconds
-- Delegates to the shared counter (FunLib/aibattle_style M.Diag); kept as a thin local
-- wrapper so existing call sites stay unchanged. Counters live on the bot handle, so
-- laning + team-mode diags merge into the same summary line.
local function AIB_Diag(key)
	Style.Diag(bot, key)
end

local function AIB_State(name, detail, sec)
	Style.Intent(bot, "state-" .. tostring(name), detail or "", sec or 2.0)
end

local function AIB_TowerOpportunity(result, detail, sec)
	Style.Intent(bot, "tower-opportunity", "result=" .. tostring(result) .. " " .. (detail or ""), sec or 2.0)
end

local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

-- Utility wrappers: logic lives in aibattle_utils.lua, these close over module-level `bot`.
local function AIB_EnemyTowerDanger()          return AIBUtils.EnemyTowerDanger(bot) end
local function AIB_ForwardSurvivingTowerLoc()  return AIBUtils.ForwardSurvivingTowerLoc(bot) end
local function AIB_EnemyCreepCentroid(creeps)  return AIBUtils.EnemyCreepCentroid(creeps) end
local function AIB_UphillMiss(target)          return AIBUtils.UphillMiss(bot, target) end

local function AIB_HealingChannelActive()
	return bot:HasModifier("modifier_tango_heal")
		or bot:HasModifier("modifier_flask_healing")
		or bot:HasModifier("modifier_bottle_regeneration")
		or bot:HasModifier("modifier_clarity_potion")
end

local function AIB_IsMeleeCreep(unit)
	if not J.IsValid(unit) then return false end
	local ok, range = pcall(function() return unit:GetAttackRange() end)
	return ok and type(range) == "number" and range <= 220
end

local function AIB_MeleeCreepCentroid(creeps, maxDist)
	local sx, sy, sz, n = 0, 0, 0, 0
	for _, creep in pairs(creeps or {}) do
		if AIB_IsMeleeCreep(creep) and GetUnitToUnitDistance(bot, creep) <= (maxDist or 320) then
			local loc = creep:GetLocation()
			sx = sx + loc.x; sy = sy + loc.y; sz = sz + loc.z; n = n + 1
		end
	end
	if n == 0 then return nil, 0 end
	return Vector(sx / n, sy / n, sz / n), n
end

local function AIB_MeleeCreepCentroidAround(loc, maxDist)
	if loc == nil then return nil, 0 end
	local sx, sy, sz, n = 0, 0, 0, 0
	for _, creep in pairs(nEnemyCreeps or {}) do
		if AIB_IsMeleeCreep(creep) and GetUnitToLocationDistance(creep, loc) <= (maxDist or 360) then
			local cLoc = creep:GetLocation()
			sx = sx + cLoc.x; sy = sy + cLoc.y; sz = sz + cLoc.z; n = n + 1
		end
	end
	if n == 0 then return nil, 0 end
	return Vector(sx / n, sy / n, sz / n), n
end

-- AIBattle: tower aggro drop cooldown (per bot instance)
local aib_lastAggroDrop = 0

-- AIBattle: tower aggro drop - attack an allied creep to redirect enemy tower fire onto it.
-- Only fires when bot is in actual tower attack range (not just detection range).
-- Throttled to 2.5s so it doesn't spam and interrupt last-hits every tick.
-- Returns true if action was issued.
local function AIB_TowerAggroDrop(twr)
	if twr == nil then return false end
	if DotaTime() - aib_lastAggroDrop < 2.5 then return false end
	if GetUnitToUnitDistance(bot, twr) > twr:GetAttackRange() + 100 then return false end
	local alliedCreeps = bot:GetNearbyCreeps(800, false)
	if not alliedCreeps or #alliedCreeps == 0 then return false end
	for _, creep in ipairs(alliedCreeps) do
		if creep:IsAlive() and not creep:IsHero() then
			bot:Action_AttackUnit(creep, false)
			aib_lastAggroDrop = DotaTime()
			AIB_Diag("tower-aggro-drop")
			return true
		end
	end
	return false
end

local function AIB_GetMainItem(name)
	local slot = bot:FindItemSlot(name)
	if slot == nil or slot < 0 then return nil end
	if bot:GetItemSlotType(slot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
	return bot:GetItemInSlot(slot)
end

-- AIBattle: on death->alive transition, act per rules.respawn_behavior. Returns true if it issued an action.
local function AIB_HandleRespawn()
	if not bot:IsAlive() then
		bot.aib_wasDead = true
		bot.aib_tping = false
		AIB_ClearRecoveryState()
		return false
	end
	if not bot.aib_wasDead then return false end
	AIB_ClearRecoveryState()

	-- Pregame: no TP waste -- let pregame block handle positioning instead.
	if DotaTime() < 0 then bot.aib_wasDead = false; return false end

	-- We already issued our TP: PROTECT THE CHANNEL so normal Think can't move the bot mid-cast
	-- (this was the tp_to_tower bug: clearing the flag on the cast tick let Think walk the bot
	-- toward creeps and cancel the 3s channel to a rear tower). Hold until the channel resolves.
	if bot.aib_tping then
		if bot:HasModifier("modifier_teleporting") then return true end          -- channelling: hold
		if (DotaTime() - (bot.aib_tpCastTime or 0)) < 1.0 then return true end    -- grace: modifier not applied yet
		-- Channel ended or interrupted. If scroll still in inventory the cast failed silently; retry.
		-- If scroll is gone it was consumed; clear wasDead and let bot walk.
		bot.aib_tping = false
		local tpStill = AIB_GetMainItem("item_tpscroll")
		if tpStill ~= nil then return false end   -- scroll intact: retry TP on next tick
		bot.aib_wasDead = false; return false     -- scroll consumed: channel done, walk normally
	end

	-- already left base without TPing (no scroll / gave up) -> stop trying
	if bot:DistanceFromFountain() > 1500 then bot.aib_wasDead = false; return false end

	local behavior = GetRules().respawn_behavior
	if behavior == "walk_back" then bot.aib_wasDead = false; return false end

	local tp = AIB_GetMainItem("item_tpscroll")
	if tp == nil then
		Style.DiagRL(bot, "respawn-no-tp", 5)
		-- No TP: walk out of fountain explicitly so normal laning picks up at dist>1500.
		-- Without this, fwd can fail silently (GetLaneFrontLocation nil or competing actions)
		-- leaving the bot AFK at fountain indefinitely.
		local walkDest = AIB_ForwardSurvivingTowerLoc()
			or GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
		if walkDest ~= nil then bot:Action_MoveToLocation(walkDest); return true end
		return false
	end
	if not tp:IsFullyCastable() then
		Style.DiagRL(bot, "respawn-tp-cd", 5)
		local walkDest = AIB_ForwardSurvivingTowerLoc()
			or GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
		if walkDest ~= nil then bot:Action_MoveToLocation(walkDest); return true end
		return false
	end

	local loc
	if behavior == "tp_to_tower" then
		loc = AIB_ForwardSurvivingTowerLoc()
	elseif behavior == "tp_to_lane" then
		-- Target own T1 directly (not creep front): creep-front TPs get cancelled when the
		-- enemy kills those creeps mid-channel, leaving the bot stuck walking instead of TPing.
		-- fwd drives bot from T1 into lane after landing.
		local t1 = GetTower(GetTeam(), TOWER_MID_1)
		if t1 ~= nil and t1:IsAlive() then
			loc = t1:GetLocation()
		else
			loc = AIB_ForwardSurvivingTowerLoc()
		end
	end
	if loc == nil then bot.aib_wasDead = false; return false end

	bot:Action_UseAbilityOnLocation(tp, loc)
	-- keep aib_wasDead = true: GetDesire holds laning ABSOLUTE and Think keeps calling this guard
	-- until the channel completes, so the bot can't be moved mid-cast.
	bot.aib_tping = true
	bot.aib_tpCastTime = DotaTime()
	return true
end

function GetDesire()
	PickOneAnnouncer()
	AnnounceMessages()

	-- AIBattle: mark death here so respawn handling fires (Think() doesn't run while dead).
	if bot:IsHero() and not bot:IsIllusion() and not bot:IsAlive() then bot.aib_wasDead = true end
	-- IsInvulnerable is intentionally ignored here: fountain invulnerability would produce
	-- DESIRE_NONE, prevent Think(), and strand the bot at fountain during pregame.
	-- Combat invulnerability such as BKB does not block laning logic.
	if not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
	if bot:IsAlive() and bot.aib_wasDead then return BOT_MODE_DESIRE_ABSOLUTE end
	local botLV = bot:GetLevel()
	local currentTime = DotaTime()

	botAttackRange = bot:GetAttackRange()
	local _ok, _res
	_ok, _res = pcall(function() return bot:GetNearbyLaneCreeps(1200, false) end)
	nAllyCreeps  = (_ok and type(_res) == "table") and _res or {}
	_ok, _res = pcall(function() return bot:GetNearbyLaneCreeps(1200, true) end)
	nEnemyCreeps = (_ok and type(_res) == "table") and _res or {}
	_ok, _res = pcall(function() return bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) end)
	nInRangeEnemy = (_ok and type(_res) == "table") and _res or {}
	nFurthestEnemyAttackRange = GetFurthestEnemyAttackRange(nInRangeEnemy)
	if local_mode_laning_generic then
		botAssignedLane = local_mode_laning_generic.GetBotTargetLane()
	else
		botAssignedLane = bot:GetAssignedLane()
	end
	attackDamage = bot:GetAttackDamage()
	if bot:GetItemSlotType(bot:FindItemSlot("item_quelling_blade")) == ITEM_SLOT_TYPE_MAIN then
		if bot:GetAttackRange() > 310 or bot:GetUnitName() == "npc_dota_hero_templar_assassin" then
			attackDamage = attackDamage + 4
		else
			attackDamage = attackDamage + 8
		end
	end

	if GetGameMode() == 23 then currentTime = currentTime * 1.65 end

	-- AIBattle 1v1: laning is the ONLY useful mode here. Keep desire high before any
	-- OHA local-mode fallback can yield control; recovery/retreat is handled in Think().
	if GetGameMode() == GAMEMODE_1V1MID then return 0.7 end

	if J.GetEnemiesAroundAncient(bot, 3200) > 0 then
		return BOT_MODE_DESIRE_NONE
	end

	if bot:WasRecentlyDamagedByAnyHero(5)
	and #J.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
		local nLaneFrontLocation = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
		local nDistFromLane = GetUnitToLocationDistance(bot, nLaneFrontLocation)
		if GetGameMode() ~= GAMEMODE_1V1MID
		and (not J.WeAreStronger(bot, 1200) or (nDistFromLane > 700 and J.GetHP(bot) < 0.7)) then
			-- AIBattle: regen_lane handles its own retreat logic in Think(); keep laning active
			-- so our regen-lane / retreat-blocked code can run even during fights.
			if Style.Get().rules.low_hp_behavior ~= "regen_lane" then
				return BOT_MODE_DESIRE_NONE
			end
		end
	end

	if J.Utils.IsTeamPushingSecondTierOrHighGround(bot) then
		return BOT_MODE_DESIRE_NONE
	end

	if local_mode_laning_generic or (J.GetPosition(bot) == 1 and J.IsPosxHuman(5)) then
		if J.IsInLaningPhase() then
			local hitCreep, _ = GetBestLastHitCreep(nEnemyCreeps)
			if J.IsValid(hitCreep) then
				if J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700)
				then
					return 0.9
				end
			end
		end
	end
	if local_mode_laning_generic and local_mode_laning_generic.GetDesire ~= nil then return local_mode_laning_generic.GetDesire() end

	if currentTime <= 10 then return 0.268 end
	if currentTime <= 9 * 60 and botLV <= 7 then return 0.446 end
	if currentTime <= 12 * 60 and botLV <= 11 then return 0.369 end
	if botLV <= 14 and J.GetCoresAverageNetworth() < 7000 then return 0.2 end

	J.Utils.GameStates.passiveLaningTime = true
	return 0.01
end

function GetFurthestEnemyAttackRange(enemyList)
	local attackRange = 0
	for _, enemy in pairs(enemyList) do
		if J.IsValidHero(enemy) and not J.IsSuspiciousIllusion(enemy) then
			local enemyAttackRange = enemy:GetAttackRange()
			if enemyAttackRange > attackRange then
				attackRange = enemyAttackRange
			end
		end
	end

	return attackRange
end

function GetBestLastHitCreep(hCreepList)
	return AIBLaneCreeps.GetBestLastHitCreep(bot, hCreepList, attackDamage)
end

function GetBestDenyCreep(hCreepList)
	return AIBLaneCreeps.GetBestDenyCreep(hCreepList, attackDamage)
end

-- THINK SECTION FUNCTIONS
-- Each function handles one phase of the Think() loop. They close over module-level
-- variables (bot, nEnemyCreeps, etc.) and take dials/ctx as explicit parameters.
-- Returning true signals "action taken; exit Think() for this tick."

-- Dumps config to all-chat once per game. Called before pregame check so it fires even
-- when the game hasn't started. Splits into two messages (Dota silently drops >~160 chars).
local function ThinkAnnounce(dials)
	if bot.aib_announced then return end
	bot.aib_announced = true
	bot:ActionImmediate_Chat("AIB[" .. AIB_SIDE .. "] build=" .. tostring(AIBBuild.sha or "unknown"), true)
	bot:ActionImmediate_Chat("> " .. bot:GetUnitName() .. " [" .. AIB_SIDE .. "]", false)
	bot:ActionImmediate_Chat(string.format(
		"AIB[%s] harass=%.2f farm=%.2f fwd=%.2f abil=%.2f rune=%.2f retreat=%.2f exec=%.2f gank=%.2f push=%.2f",
		AIB_SIDE,
		dials.harass_desire, dials.farm_focus, dials.forwardness, dials.ability_aggro,
		dials.rune_control, dials.retreat_caution, dials.execute_threshold,
		dials.gank_desire, dials.push_desire), true)
	local r = Style.Get().rules
	bot:ActionImmediate_Chat(string.format(
		"AIB[%s] defend=%.2f ward=%.2f roshan=%.2f dive=%s heal=%s abil=%s cw=%s at=%s pgb=%s",
		AIB_SIDE,
		dials.defend_desire, dials.ward_desire, dials.roshan_desire,
		tostring(r.dive_policy or "finish_only"),
		tostring(r.healing_style or "default"),
		tostring(r.ability_usage or "default"),
		tostring(r.creep_wave_priority or "last_hit_only"),
		tostring(r.ability_timing or "on_cooldown"),
		tostring(r.pregame_behavior or "default")), true)
end

local function AIB_TowerActuallyThreatening(twr)
	return AIBUtils.IsTowerActuallyThreatening(bot, twr)
end

local function AIB_SafeCounter(methodName)
	if bot == nil or bot[methodName] == nil then return nil end
	local ok, val = pcall(function() return bot[methodName](bot) end)
	if ok and type(val) == "number" then return val end
	return nil
end

-- Periodic location report every 5s (in-game only, DotaTime > 0).
local function ThinkLocationReport()
	local now = DotaTime()
	if now <= 0 then return end
	if bot.aib_igLocLast ~= nil and now - bot.aib_igLocLast < 5.0 then return end
	bot.aib_igLocLast = now
	local sp   = bot:GetLocation()
	local side = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
	local nearby = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
	local gold = bot:GetGold()
	local lh = AIB_SafeCounter("GetLastHits")
	local dn = AIB_SafeCounter("GetDenies")
	local dg = (bot.aib_lastReportGold ~= nil) and (gold - bot.aib_lastReportGold) or 0
	local dlh = (lh ~= nil and bot.aib_lastReportLH ~= nil) and (lh - bot.aib_lastReportLH) or 0
	bot.aib_lastReportGold = gold
	if lh ~= nil then bot.aib_lastReportLH = lh end
	-- Bottle charges: the one sustain signal we couldn't see before. -1 = no bottle owned.
	local bottleCharges = -1
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot ~= nil and bSlot >= 0 then
		local bottle = bot:GetItemInSlot(bSlot)
		if bottle ~= nil then bottleCharges = bottle:GetCurrentCharges() end
	end
	local statSuffix = string.format(" lh=%d dn=%d dg=%+d dlh=%+d bottle=%d", lh or -1, dn or -1, dg, dlh, bottleCharges)
	if nearby and #nearby > 0 and nearby[1]:IsAlive() then
		bot:ActionImmediate_Chat(string.format(
			"AIB[%s] t=%.0fs hp=%.0f%% gold=%d loc=%.0f,%.0f enemy-dist=%.0f%s",
			side, now, J.GetHP(bot)*100, gold, sp.x, sp.y,
			GetUnitToUnitDistance(bot, nearby[1]), statSuffix), true)
	else
		bot:ActionImmediate_Chat(string.format(
			"AIB[%s] t=%.0fs hp=%.0f%% gold=%d loc=%.0f,%.0f%s",
			side, now, J.GetHP(bot)*100, gold, sp.x, sp.y, statSuffix), true)
	end
end

-- Pre-game positioning (DotaTime < 0, GAMEMODE_1V1MID). Returns true when Think() should exit.
-- Positions based on pregame_behavior rule; attacks enemy hero on sight.
local function AIB_Dist2D(a, b)
	if a == nil or b == nil then return math.huge end
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx*dx + dy*dy)
end

local function AIB_ResetVisualAFK(now, loc)
	bot.aib_afkAnchorLoc = loc
	bot.aib_afkAnchorTime = now
end

local function AIB_MoveAwayFrom(loc, awayFrom, distance)
	local dx, dy = loc.x - awayFrom.x, loc.y - awayFrom.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then return loc + RandomVector(distance) end
	return Vector(loc.x + (dx/d)*distance, loc.y + (dy/d)*distance, loc.z)
end

local function AIB_TowardFountainFrom(loc, distance)
	local fountain = J.GetTeamFountain()
	if fountain == nil then return nil end
	local dx, dy = fountain.x - loc.x, fountain.y - loc.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then return loc + RandomVector(distance) end
	return Vector(loc.x + (dx/d)*distance, loc.y + (dy/d)*distance, loc.z)
end

local function AIB_BottleIfUseful(hpLimit, manaLimit, diagKey)
	local bottle = AIB_GetMainItem("item_bottle")
	if bottle == nil or not bottle:IsFullyCastable() or bottle:GetCurrentCharges() <= 0 then return false end
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	if J.GetHP(bot) > hpLimit and mana > manaLimit then return false end
	bot:Action_UseAbility(bottle)
	AIB_Diag(diagKey or "bottle-heal")
	return true
end

local function AIB_NearestEnemyHero(maxDist)
	local best = nil
	local bestDist = maxDist or math.huge
	local function scan(list)
		if list == nil then return end
		for _, enemy in ipairs(list) do
			if J.IsValidHero(enemy) and enemy:IsAlive() and not J.IsSuspiciousIllusion(enemy) then
				local dist = GetUnitToUnitDistance(bot, enemy)
				if dist <= bestDist then
					best = enemy
					bestDist = dist
				end
			end
		end
	end
	scan(nInRangeEnemy)
	if best == nil then
		local ok, enemies = pcall(function()
			return bot:GetNearbyHeroes(maxDist or 1600, true, BOT_MODE_NONE)
		end)
		if ok then scan(enemies) end
	end
	return best, bestDist
end

local function AIB_HasAttackableEnemyCreep(range)
	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= range then
			return true
		end
	end
	return false
end

local AIB_MoveToAttackEdgeOf

local function AIB_AttackEdgeLocation(target, extraBack)
	if target == nil then return nil end
	local range = botAttackRange or bot:GetAttackRange()
	if target.GetLocation == nil or bot.GetLocation == nil then return nil end
	local okTarget, tl = pcall(function() return target:GetLocation() end)
	local okBot, bl = pcall(function() return bot:GetLocation() end)
	if not okTarget or not okBot or tl == nil or bl == nil then return nil end
	if range <= 300 then return tl end
	local packCen, packCount = AIB_MeleeCreepCentroidAround(tl, 380)
	if packCen ~= nil and packCount >= 2 then
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		local home = ownT1 ~= nil and ownT1:GetLocation() or bl
		local hx, hy = home.x - packCen.x, home.y - packCen.y
		local hd = math.sqrt(hx*hx + hy*hy)
		if hd > 1 then
			local safe = math.max(420, range - 60 + (extraBack or 0))
			return Vector(packCen.x + (hx/hd)*safe, packCen.y + (hy/hd)*safe, packCen.z)
		end
	end
	local dx, dy = bl.x - tl.x, bl.y - tl.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then return bl + RandomVector(160) end
	local safe = math.max(320, range - 70 + (extraBack or 0))
	return Vector(tl.x + (dx/d)*safe, tl.y + (dy/d)*safe, tl.z)
end

AIB_MoveToAttackEdgeOf = function(target, diagKey, extraBack)
	local loc = AIB_AttackEdgeLocation(target, extraBack)
	if loc == nil then return false end
	if (botAttackRange or bot:GetAttackRange()) <= 300 then
		bot:Action_MoveToUnit(target)
	else
		bot:Action_MoveToLocation(loc)
	end
	if diagKey then AIB_Diag(diagKey) end
	return true
end

local function AIB_NearestAttackableEnemyCreep(range)
	return AIBLaneCreeps.NearestAttackableEnemyCreep(bot, nEnemyCreeps, range)
end

local function AIB_WeakestAttackableEnemyCreep(maxDist)
	return AIBLaneCreeps.WeakestAttackableEnemyCreep(bot, nEnemyCreeps, maxDist)
end

local function AIB_AlliedCreepsAtTower(tower, distLimit)
	return AIBLaneCreeps.AlliedCreepsAtTower(nAllyCreeps, tower, distLimit)
end

local function AIB_WantBlocked(name, reason, detail, sec)
	Style.Blocked(bot, name, reason, detail, sec or 3.0)
end

local function AIB_EnemyDeadRecently()
	return bot.aib_eDeadSince ~= nil and DotaTime() - bot.aib_eDeadSince < 45.0
end

local function AIB_LaningModuleCtx(dials, rules)
	return {
		bot = bot,
		dials = dials or {},
		rules = rules or GetRules(),
		allyCreeps = nAllyCreeps,
		enemyCreeps = nEnemyCreeps,
		assignedLane = botAssignedLane or bot:GetAssignedLane() or LANE_MID,
		attackRange = botAttackRange or bot:GetAttackRange(),
		enemyTowerDanger = AIB_EnemyTowerDanger,
		towerThreatening = AIB_TowerActuallyThreatening,
		alliedCreepsAtTower = AIB_AlliedCreepsAtTower,
		enemyDeadRecently = AIB_EnemyDeadRecently,
		healingChannelActive = AIB_HealingChannelActive,
		nearestAttackableEnemyCreep = AIB_NearestAttackableEnemyCreep,
		nearestEnemyHero = AIB_NearestEnemyHero,
		moveToAttackEdge = AIB_MoveToAttackEdgeOf,
		towardFountain = AIB_TowardFountainFrom,
		uphillMiss = AIB_UphillMiss,
		diag = AIB_Diag,
		blocked = AIB_WantBlocked,
		state = AIB_State,
		towerOpportunity = AIB_TowerOpportunity,
	}
end

local function AIB_RuntimeCtx(dials, rules, extra)
	local ctx = AIB_LaningModuleCtx(dials, rules)
	ctx.safeCounter = AIB_SafeCounter
	ctx.moveAwayFrom = AIB_MoveAwayFrom
	ctx.towardFountain = AIB_TowardFountainFrom
	ctx.forwardSurvivingTowerLoc = AIB_ForwardSurvivingTowerLoc
	ctx.enemyCreepCentroid = AIB_EnemyCreepCentroid
	ctx.meleeCreepCentroid = AIB_MeleeCreepCentroid
	ctx.hasAttackableEnemyCreep = AIB_HasAttackableEnemyCreep
	ctx.weakestAttackableEnemyCreep = AIB_WeakestAttackableEnemyCreep
	ctx.bottleIfUseful = AIB_BottleIfUseful
	ctx.surviveThink = function(b, ds, creeps) return AIBSurvive.Think(b, ds, creeps) end
	ctx.clearRecovery = AIB_ClearRecoveryState
	ctx.towerAggroDrop = AIB_TowerAggroDrop
	ctx.pregameDuel = function() return AIBLaneDuel.Pregame(AIB_LaningModuleCtx(nil, GetRules())) end
	if extra ~= nil then
		for k, v in pairs(extra) do ctx[k] = v end
	end
	return ctx
end

local function AIB_SiegeIntent(dials, rules)
	return AIBLaneSiege.Think(AIB_LaningModuleCtx(dials, rules))
end

local function AIB_PreWaveDuelStep(rules)
	return AIBLaneDuel.Prewave(AIB_LaningModuleCtx(nil, rules))
end

local function AIB_RunFightArbiter(intentCtx)
	local intents = {}
	intentCtx.arbiter = "fight"
	local killIntent = AIBLaneTrade.KillLock(intentCtx)
	if killIntent ~= nil then intents[#intents + 1] = killIntent end
	local creepIntent = AIBLaneSurvival.CreepAggroRelief(intentCtx)
	if creepIntent ~= nil then intents[#intents + 1] = creepIntent end
	local healInterruptIntent = AIBLaneTrade.HealInterrupt(intentCtx)
	if healInterruptIntent ~= nil then intents[#intents + 1] = healInterruptIntent end
	local passingHeroIntent = AIBLaneTrade.PassingHeroTrade(intentCtx)
	if passingHeroIntent ~= nil then intents[#intents + 1] = passingHeroIntent end
	return AIBEngine.Resolve(intents, intentCtx)
end

local function AIB_HasSiegeCandidate()
	local range = botAttackRange or bot:GetAttackRange()
	local twr = AIB_EnemyTowerDanger()
	if twr ~= nil then return true end
	local midT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
	if midT1 == nil then return false end
	local siege = AIBLanePolicy.SiegeConfig
	return GetUnitToUnitDistance(bot, midT1) <= range + siege.candidateExtra
		and AIB_AlliedCreepsAtTower(midT1, midT1:GetAttackRange() + siege.towerCreepRangeExtra) >= siege.alliedCreepsRequired
end

local function AIB_LaneLineFallback(dials)
	if GetGameMode() ~= GAMEMODE_1V1MID then return false end
	local now = DotaTime()
	if J.GetHP(bot) < AIBLanePolicy.Forward.laneFallbackMinHp then
		Style.DiagRL(bot, "lane-line-suppressed-lowhp", 5)
		return false
	end
	if AIB_HealingChannelActive() then
		Style.DiagRL(bot, "lane-line-suppressed-heal", 5)
		return false
	end
	if bot.aib_recMoveLast ~= nil and now - bot.aib_recMoveLast < AIBLanePolicy.Forward.laneFallbackRecoveryCooldown then
		Style.DiagRL(bot, "lane-line-suppressed-recovery", 5)
		return false
	end
	if bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < AIBLanePolicy.Forward.laneFallbackCreepReliefCooldown then
		Style.DiagRL(bot, "lane-line-suppressed-damage", 5)
		return false
	end
	if bot.aib_topArbiterEmptyLast ~= nil and now - bot.aib_topArbiterEmptyLast < AIBLanePolicy.Forward.suppressAfterEmptyDesire then
		Style.DiagRL(bot, "lane-line-suppressed-empty", 5)
		return false
	end
	if bot:WasRecentlyDamagedByCreep(2.0) then
		Style.DiagRL(bot, "lane-line-suppressed-creep-dmg", 5)
		return false
	end
	if AIB_HasAttackableEnemyCreep((botAttackRange or bot:GetAttackRange()) + 60) then
		Style.DiagRL(bot, "lane-line-suppressed-creep", 5)
		return false
	end
	if AIB_EnemyDeadRecently() and AIB_HasSiegeCandidate() then
		Style.DiagRL(bot, "lane-line-suppressed-siege", 5)
		return false
	end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
	if ownT1 == nil or enmT1 == nil then return false end
	local a, b = ownT1:GetLocation(), enmT1:GetLocation()
	local dx, dy = b.x - a.x, b.y - a.y
	local laneLen = math.sqrt(dx * dx + dy * dy)
	if laneLen <= 1 then return false end
	local dirX, dirY = dx / laneLen, dy / laneLen
	local function projRatio(loc)
		if loc == nil then return nil end
		local px, py = loc.x - a.x, loc.y - a.y
		return math.max(0.0, math.min(1.0, (px * dirX + py * dirY) / laneLen))
	end
	local fwd = math.max(0.35, math.min(0.72, (dials or {}).forwardness or 0.5))
	local frontFwd = nil
	for _, creep in pairs(nAllyCreeps or {}) do
		if J.IsValid(creep) then
			local cr = projRatio(creep:GetLocation())
			if cr ~= nil and (frontFwd == nil or cr > frontFwd) then frontFwd = cr end
		end
	end
	local clampReason = nil
	if frontFwd ~= nil then
		local range = botAttackRange or bot:GetAttackRange()
		local maxLead = math.max(180, range - AIBLanePolicy.Forward.laneFallbackFrontBackoff)
		local maxFwd = math.min(0.72, frontFwd + maxLead / laneLen)
		if fwd > maxFwd then
			fwd = maxFwd
			clampReason = "front"
		end
	else
		local maxFwd = AIBLanePolicy.Forward.laneFallbackNoCreepMaxFwd
		if fwd > maxFwd then
			fwd = maxFwd
			clampReason = "no_creep"
		end
	end
	local dest = Vector(a.x + (b.x - a.x) * fwd, a.y + (b.y - a.y) * fwd, a.z)
	if GetUnitToLocationDistance(bot, dest) <= 220 then
		fwd = math.min(0.84, fwd + 0.12)
		if frontFwd ~= nil then
			local range = botAttackRange or bot:GetAttackRange()
			local maxLead = math.max(180, range - AIBLanePolicy.Forward.laneFallbackFrontBackoff)
			fwd = math.min(fwd, math.min(0.72, frontFwd + maxLead / laneLen))
		else
			fwd = math.min(fwd, AIBLanePolicy.Forward.laneFallbackNoCreepMaxFwd)
		end
		dest = Vector(a.x + (b.x - a.x) * fwd, a.y + (b.y - a.y) * fwd, a.z)
		if GetUnitToLocationDistance(bot, dest) <= 220 then return false end
	end
	bot:Action_MoveToLocation(dest + RandomVector(45))
	AIB_Diag("lane-line-fallback")
	Style.TickOwner(bot, "lane-line-fallback",
		string.format("dist=%.0f fwd=%.2f clamp=%s", GetUnitToLocationDistance(bot, dest), fwd, tostring(clampReason or "none")), 2.0)
	return true
end

local function AIB_RunTopDesireArbiter(dials, rules, runtimeCtx, intentCtx)
	local hp = J.GetHP(bot)
	local range = botAttackRange or bot:GetAttackRange()
	local enemy, enemyDist = AIB_NearestEnemyHero(AIBLanePolicy.EnemyScanRange(range))
	local enemyHp = enemy ~= nil and J.GetHP(enemy) or 1.0
	local powerRune = AIBEngine.PowerRuneState(bot)
	local actionPowerRune = AIBEngine.IsActionPowerRune(powerRune)
	local recentCreepDamage = bot:WasRecentlyDamagedByCreep(AIBLanePolicy.RecentDamage.creepSeconds)
	local recentHeroDamage = bot:WasRecentlyDamagedByAnyHero(AIBLanePolicy.RecentDamage.heroSeconds)
	local attackableCreep = AIB_NearestAttackableEnemyCreep(range + AIBLanePolicy.Scan.safetyCreepExtra) ~= nil
	local policyArgs = {
		bot = bot,
		dials = dials,
		rules = rules,
		hp = hp,
		range = range,
		enemy = enemy,
		enemyDist = enemyDist or 99999,
		enemyHp = enemyHp,
		powerRune = powerRune,
		actionPowerRune = actionPowerRune,
		recentCreepDamage = recentCreepDamage,
		recentHeroDamage = recentHeroDamage,
		attackableCreep = attackableCreep,
		executeThreshold = dials.execute_threshold or 0,
	}
	local candidates = {}

	local safetyPolicy = AIBLanePolicy.Safety(policyArgs)
	if safetyPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("safety", safetyPolicy.score, safetyPolicy.reason,
			safetyPolicy.detail,
			function()
				if AIBLaneSafety.CreepHitReact(runtimeCtx) then return true end
				if AIBLaneSafety.DamageUnstuck(runtimeCtx) then return true end
				if (recentHeroDamage or hp < AIBLanePolicy.Hp.activeRecovery)
					and AIBLaneRecovery.ActiveLowHp(runtimeCtx, AIBLanePolicy.Hp.softRecovery, true) then return true end
				return false
			end)
	end

	local powerPolicy = AIBLanePolicy.PowerRune(policyArgs)
	if powerPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("power-rune", powerPolicy.score, powerPolicy.reason,
			powerPolicy.detail,
			function() return AIBLaneCombat.RunePowerPressure(runtimeCtx) end)
	end

	local fightPolicy = AIBLanePolicy.Fight(policyArgs)
	if fightPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("fight", fightPolicy.score, fightPolicy.reason,
			fightPolicy.detail,
			function()
				if AIBLaneCombat.AbilityPressure(runtimeCtx) then return true end
				if AIBLaneCombat.ContactHero(runtimeCtx) then return true end
				return AIB_RunFightArbiter(intentCtx)
			end)
	end

	local recoverPolicy = AIBLanePolicy.Recover(policyArgs)
	if recoverPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("recover", recoverPolicy.score, recoverPolicy.reason,
			recoverPolicy.detail,
			function() return AIBLaneRecovery.ThinkIfAllowed(runtimeCtx, AIBLanePolicy.Hp.softRecovery, "lane-low") end)
	end

	policyArgs.hasSiegeCandidate = AIB_HasSiegeCandidate()
	policyArgs.enemyDeadRecently = AIB_EnemyDeadRecently()
	local siegePolicy = AIBLanePolicy.Siege(policyArgs)
	if siegePolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("siege", siegePolicy.score, siegePolicy.reason,
			siegePolicy.detail,
			function() return AIB_SiegeIntent(dials, rules) end)
	end

	return AIBTopArbiter.Run(candidates, runtimeCtx)
end

-- Main laning policy. Think() below only schedules high-level stages.
local function ThinkLaningCore(dials, rules)
	local debugSkeleton = rules.debug_skeleton_laning == true
	local debugNoForward = debugSkeleton or rules.debug_disable_forwardness_fallbacks == true
	if debugSkeleton then
		Style.DiagRL(bot, "dbg-skeleton", 10)
	elseif debugNoForward then
		Style.DiagRL(bot, "dbg-no-fwd", 10)
	end
	local intentCtx = AIBLaningContext.Build(bot, dials, rules, nEnemyCreeps, nAllyCreeps, botAssignedLane, botAttackRange)
	local runtimeCtx = AIB_RuntimeCtx(dials, rules, { debugSkeleton = debugSkeleton })
	if DotaTime() >= 0 and DotaTime() <= 25 and not bot.aib_postHornRecoveryReset then
		bot.aib_postHornRecoveryReset = true
		AIB_ClearRecoveryState()
		AIB_State("post-horn-reset", "reason=laning-start", 2.0)
	end
	if J.GetHP(bot) < AIBConst.Recovery.trueEmergencyHp and AIBSurvive.Think(bot, dials, nEnemyCreeps) then return true end
	if AIBLaneRecovery.ThinkIfAllowed(runtimeCtx, AIBConst.Recovery.emergencyHp, "emergency-low") then return true end
	local urgentIntents = {}
	intentCtx.arbiter = "urgent"
	local urgentKill = AIBLaneTrade.KillLock(intentCtx)
	if urgentKill ~= nil then urgentIntents[#urgentIntents + 1] = urgentKill end
	local urgentInterrupt = AIBLaneTrade.HealInterrupt(intentCtx)
	if urgentInterrupt ~= nil then urgentIntents[#urgentIntents + 1] = urgentInterrupt end
	if AIBEngine.Resolve(urgentIntents, intentCtx) then return true end

	if AIBLaneRecovery.ThinkIfAllowed(runtimeCtx, AIBLanePolicy.Hp.danger, "early-low") then return true end
	if AIBLaneRecovery.CriticalLock(runtimeCtx) then return true end
	if AIB_PreWaveDuelStep(rules) then return true end
	if AIBLaneTempo.PreCreepStandoff(runtimeCtx) then return true end
	if AIB_RunTopDesireArbiter(dials, rules, runtimeCtx, intentCtx) then return true end
	if J.GetHP(bot) >= AIBLanePolicy.Hp.safeLastHitMin and J.GetHP(bot) < AIBLanePolicy.Hp.softRecovery then
		local safeCs, safeCsSoon = GetBestLastHitCreep(nEnemyCreeps)
		if J.IsValid(safeCs) and safeCsSoon ~= true
			and GetUnitToUnitDistance(bot, safeCs) <= (botAttackRange or bot:GetAttackRange()) + AIBLanePolicy.Scan.safeCsRangeBuffer
			and not (bot:WasRecentlyDamagedByAnyHero(AIBLanePolicy.RecentDamage.heroSeconds) and J.GetHP(bot) < AIBLanePolicy.Hp.damageLockout)
			and not AIB_TowerActuallyThreatening(AIB_EnemyTowerDanger()) then
			bot:SetTarget(safeCs)
			bot:Action_AttackUnit(safeCs, true)
			AIB_Diag("low-hp-cs")
			return true
		end
	end

	local hitCreep, csSoon = GetBestLastHitCreep(nEnemyCreeps)

	-- Last-hit / harass interleave: secure an IN-RANGE last-hit before heal check.
	-- attack is instant and safe even at low HP; heal can fire next tick if still needed.
	-- needMove simplified: only move when TRULY out of attack range (0.8x caused bot to
	-- walk toward a creep already in range, wasting the last-hit window).
	local csLaneCheck = J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700)
	-- freeze: never use the push block, but still last-hit (wave stays frozen without proactive attacks)
	local csAllowed = J.IsValid(hitCreep) and csLaneCheck
	local csDistNow = csAllowed and GetUnitToUnitDistance(bot, hitCreep) or nil
	local needMove = csAllowed and (csDistNow > botAttackRange or csSoon == true)

	if AIBLaneCombat.HeroOverCreep(runtimeCtx) then return true end

	-- 1) grab a securable last-hit that's already in range
	if csAllowed and not needMove and csSoon ~= true then
		bot:SetTarget(hitCreep)
		bot:Action_AttackUnit(hitCreep, true)
		AIB_Diag("cs-inrange")
		return true
	end

	if AIBSurvive.Think(bot, dials, nEnemyCreeps) then return true end

	-- Global emergency retreat: critically low HP (<25%) and far from tower means go back now.
	-- Only fires at true emergency level; regen_lane handles the normal 25-45% range.
	if AIBLaneRecovery.EmergencyRetreat(runtimeCtx) then return true end

	-- Forward low-HP pullback: being low on the ENEMY's half is the gap that emergency-retreat
	-- (HP<25%) and low-hp-hold (near OWN tower) both miss. Match 8862516153: the bot pushed onto
	-- the enemy side at 25-30% HP and was killed by the respawned enemy. Skip during the enemy-dead
	-- window -- that's a safe siege (fix #5), not an overextension.
	if AIBLaneRecovery.ForwardLowHpPullback(runtimeCtx) then return true end

	-- Survival gate: if already died once, don't risk a second death at low HP.
	-- Second death = game over in 1v1 mid. Retreat instead of fighting.
	local aib_deathSurvive = GetHeroDeaths(bot:GetPlayerID()) >= 1 and J.GetHP(bot) < AIBLanePolicy.Hp.secondDeathSurvive
	runtimeCtx.deathSurvive = aib_deathSurvive

	-- AIBattle: kill-priority. Enemy HP below execute_threshold means always attack.
	-- Runs before harass so a killable enemy is not ignored for a creep action.
	-- Opt-in: active only when execute_threshold > 0.
	if AIBLaneCombat.EmergencyKillPriority(runtimeCtx) then return true end

	-- Survival baseline: low HP near own tower limits risky actions, but it must not
	-- consume the tick by itself. Only take an active low-HP step when danger is present.
	local aib_lowHpHold, aib_lowHpDanger = AIBLaneRecovery.LowHpHoldState(runtimeCtx)
	runtimeCtx.lowHpHold = aib_lowHpHold
	if aib_lowHpHold and aib_lowHpDanger and AIBLaneRecovery.ActiveLowHp(runtimeCtx) then return true end

	-- Uphill repositioning: fires BEFORE harass; no trading from low ground.
	-- Target = own T1 location (guaranteed high ground). 350u-ahead offset overshoots the ramp.
	if AIBLaneCombat.UphillReposition(runtimeCtx) then return true end

	-- 2) Harass hero (uphill already handled above; bot is on own ramp or has no terrain disadvantage).
	--    hero_priority=never skips entirely (pure creep focus).
	--    hero_priority=always bypasses farm_focus roll and hp-disadvantage gate.
	--    hero_priority=default attacks immediately when in range; farm_focus+harass_desire
	--                            gate only applies when enemy is out of range (seeking behaviour).
	runtimeCtx.csAllowed = csAllowed
	runtimeCtx.needMove = needMove
	if AIBLaneCombat.HarassAndChase(runtimeCtx) then return true end

	if AIBLaneCreeps.HandleCreepWork({
		bot = bot,
		rules = rules,
		enemyCreeps = nEnemyCreeps,
		allyCreeps = nAllyCreeps,
		attackRange = botAttackRange,
		hitCreep = hitCreep,
		csSoon = csSoon,
		csAllowed = csAllowed,
		csDistNow = csDistNow,
		needMove = needMove,
		diag = AIB_Diag,
		moveToAttackEdge = AIB_MoveToAttackEdgeOf,
		rangedSpacing = function() return AIBLaneSafety.RangedMeleePackSpacing(runtimeCtx) end,
		lastHitWatchdog = function() return AIBLaneSafety.LastHitWatchdog(runtimeCtx) end,
		enemyTowerDanger = AIB_EnemyTowerDanger,
		siegeIntent = function() return AIB_SiegeIntent(dials, rules) end,
		bestDeny = GetBestDenyCreep,
	}) then return true end

	local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
	local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
	-- HP-aware safe offset: at full HP push closer to creep front (200u); at low HP stay further back (600u).
	-- Stops bots from camping defensively near T1 when healthy with enemy not immediately threatening.
	local hpScale    = math.max(0.0, math.min(1.0, (J.GetHP(bot) - 0.5) / 0.5))  -- 0 at HP<=50%, 1 at HP=100%
	local safeOffset = math.floor(nLongestAttackRange * (1.0 - 0.65 * hpScale))   -- 600u at 50% HP, ~210u at 100%
	local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -safeOffset)
	if (fLaneFrontAmount_enemy or 0) < (fLaneFrontAmount or 1) then
		target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -safeOffset)
	end

	-- AIBattle: hero-specific ability harass + execute, driven by ability_aggro / execute_threshold dials.
	-- Covers all targeting types (unit, point, directional, no_target) via HeroAbilityConfig in
	-- aibattle_style.lua. Heroes not in the config return false and fall through silently.
	-- Execute is checked first (higher priority: kill a fleeing enemy over general harassment).
	-- AbilityHarass shares the same HP-disadvantage gate as auto-attack harass above.
	if AIBLaneCombat.AbilityHarass(runtimeCtx) then return true end

	-- Forwardness is only a final lane-positioning preference. Keep it rare and
	-- quiet: it must yield to combat, creep damage, recovery/rune commits, CS,
	-- low-HP limits, siege commits, and tower safety.
	local pressureEnemy = AIB_NearestEnemyHero(math.max(botAttackRange + 180, 700))
	local attackableCreep = AIB_HasAttackableEnemyCreep(botAttackRange + 30)
	local nowFwd = DotaTime()
	local pendingLastHit = csAllowed and (csDistNow or math.huge) <= botAttackRange * 1.8
	local recentRecovery = bot.aib_recMoveLast ~= nil and nowFwd - bot.aib_recMoveLast < 2.5
	local recentCreepRelief = bot.aib_creepReliefLast ~= nil and nowFwd - bot.aib_creepReliefLast < 1.8
	local recentVisualHold = bot.aib_holdLast ~= nil and nowFwd - bot.aib_holdLast < 2.5
	local recentWatchdog = bot.aib_csWatchLast ~= nil and nowFwd - bot.aib_csWatchLast < 3.0
	local recentTopEmpty = bot.aib_topArbiterEmptyLast ~= nil and nowFwd - bot.aib_topArbiterEmptyLast < AIBLanePolicy.Forward.suppressAfterEmptyDesire
	local runeCommit = bot.aib_bottleRuneStarted ~= nil and nowFwd - bot.aib_bottleRuneStarted < AIB_RUNE_COMMIT_SECONDS
	local siegeCommit = bot.aib_siegeCommitUntil ~= nil and nowFwd <= bot.aib_siegeCommitUntil
	local suppressForward = pressureEnemy ~= nil
		or attackableCreep
		or pendingLastHit
		or aib_lowHpHold
		or recentRecovery
		or recentCreepRelief
		or recentVisualHold
		or recentWatchdog
		or recentTopEmpty
		or AIB_HealingChannelActive()
		or runeCommit
		or siegeCommit
		or bot:WasRecentlyDamagedByCreep(2.0)
		or (J.GetHP(bot) < AIBLanePolicy.Hp.softRecovery and bot:WasRecentlyDamagedByAnyHero(2.0))
		or (AIB_EnemyTowerDanger() ~= nil and AIB_TowerActuallyThreatening(AIB_EnemyTowerDanger()) and not Style.MayDive(bot))
	if not debugNoForward and not suppressForward then
		local fwd = dials.forwardness or 0.5
		local dest = target_loc
		if dest == nil then
			dest = GetLaneFrontLocation(GetTeam(), botAssignedLane, math.floor(200 + 400 * fwd))
		end
		if dest == nil then
			local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
			local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
			if ownT1 ~= nil and enmT1 ~= nil then
				local a, b = ownT1:GetLocation(), enmT1:GetLocation()
				dest = Vector(a.x + (b.x - a.x) * fwd, a.y + (b.y - a.y) * fwd, a.z)
			end
		end
		if dest ~= nil and GetUnitToLocationDistance(bot, dest) > AIBLanePolicy.Forward.minUsefulMoveDist then
			if bot.aib_fwdLast == nil or nowFwd - bot.aib_fwdLast >= AIBLanePolicy.Forward.cooldown
				or GetUnitToLocationDistance(bot, dest) > AIBLanePolicy.Forward.longMoveOverrideDist then
				bot.aib_fwdLast = nowFwd
				bot:Action_MoveToLocation(dest)
				AIB_Diag("fwd-position")
				Style.TickOwner(bot, "forwardness", string.format("dist=%.0f", GetUnitToLocationDistance(bot, dest)), 2.0)
				return true
			else
				Style.DiagRL(bot, "fwd-hold", 5)
			end
		end
		Style.DiagRL(bot, "fwd-at-position", 5)
	else
		if debugNoForward then
			Style.DiagRL(bot, "dbg-skip-fwd", 5)
		elseif aib_lowHpHold then
			Style.DiagRL(bot, "fwd-suppressed-lowhp", 5)
		elseif pressureEnemy ~= nil then
			Style.DiagRL(bot, "fwd-suppressed-hero", 5)
		elseif attackableCreep then
			Style.DiagRL(bot, "fwd-suppressed-creep", 5)
		elseif pendingLastHit then
			Style.DiagRL(bot, "fwd-suppressed-cs", 5)
		elseif recentRecovery then
			Style.DiagRL(bot, "fwd-suppressed-recovery", 5)
		elseif runeCommit then
			Style.DiagRL(bot, "fwd-suppressed-rune", 5)
		elseif recentCreepRelief then
			Style.DiagRL(bot, "fwd-suppressed-damage", 5)
		elseif recentVisualHold then
			Style.DiagRL(bot, "fwd-suppressed-visual", 5)
		elseif recentWatchdog then
			Style.DiagRL(bot, "fwd-suppressed-watchdog", 5)
		elseif recentTopEmpty then
			Style.DiagRL(bot, "fwd-suppressed-empty", 5)
		else
			Style.DiagRL(bot, "fwd-suppressed-tower", 5)
		end
	end

	-- AIBattle: anti-idle fallback - reached when forwardness had no dest OR bot is already at target.
	-- Attack a visible enemy or move to assist an ally in combat.
	if AIBLaneSafety.VisualHoldHeartbeat(runtimeCtx) then return true end
	if AIBLaneSafety.VisualAFK(runtimeCtx) then return true end
	if AIB_LaneLineFallback(dials) then return true end
	Style.DiagRL(bot, "pre-aig", 3)
	return Style.AntiIdleGlobal(bot)
end

local LANING_STAGES = {
	AIBEngine.Stage("pregame", function(ctx) return AIBLaneTempo.Pregame(AIB_RuntimeCtx(ctx.dials, ctx.rules)) end),
	AIBEngine.Stage("dive", function(ctx) return AIBLaneTempo.DivePolicy(AIB_RuntimeCtx(ctx.dials, ctx.rules)) end),
	AIBEngine.Stage("death-window", function(ctx) return AIBLaneTempo.DeathWindow(AIB_RuntimeCtx(ctx.dials, ctx.rules)) end),
	AIBEngine.Stage("laning-core", function(ctx)
		return ThinkLaningCore(ctx.dials, ctx.rules)
	end),
}

-- AIBattle: Think() defined unconditionally so the engine always has a callable function.
-- Vanilla only defined it inside a condition that's false for normal heroes in all-bot games,
-- causing EXC_GUARD when the engine tried to call nil.
function Think()
	if GetGameMode() ~= GAMEMODE_1V1MID and local_mode_laning_generic then local_mode_laning_generic.Think(); return end
	if AIB_HandleRespawn() then return end

	local style = Style.Get()
	local ctx = {
		dials = style.dials,
		rules = style.rules,
		bot = bot,
	}

	ThinkAnnounce(ctx.dials)
	ThinkLocationReport()
	local ok, err = pcall(function() AIBEngine.Run(LANING_STAGES, ctx) end)
	if not ok then
		local side = bot:GetTeam() == TEAM_RADIANT and "R" or "D"
		local msg = tostring(err or "nil"):sub(1, 100)
		if bot.aib_crashLogLast == nil or DotaTime() - bot.aib_crashLogLast >= 4.0 then
			bot.aib_crashLogLast = DotaTime()
			bot:ActionImmediate_Chat("AIB[" .. side .. "] ERR: " .. msg, true)
		end
	end
end


function PickOneAnnouncer()
	if not hasPickedOneAnnouncer then
		for i, _ in pairs(GetTeamPlayers(GetTeam())) do
			local member = GetTeamMember(i)
			if member ~= nil and member.isAnnouncer then return end
		end
		bot.isAnnouncer = true
		hasPickedOneAnnouncer = true
	end
end

function AnnounceMessages()
	if DotaTime() > 60 then return end

	local welcomeMessages = Localization.Get('welcome_msgs')
	local inTurbo         = J.IsModeTurbo()

	if ((inTurbo and DotaTime() > -50 + GetTeam() * 2) or (not inTurbo and DotaTime() > -75 + GetTeam() * 2))
	   and numberAnnouncePrinted < #welcomeMessages + 1
	   and bot.isAnnouncer
	   and DotaTime() < 0
	then
		if GameTime() - lastAnnouncePrintedTime >= announcementGapSeconds then
			local message      = welcomeMessages[numberAnnouncePrinted]
			local isFirstLine  = (numberAnnouncePrinted == 1)
			if message then
				bot:ActionImmediate_Chat(isFirstLine and (message .. Version.number) or message, enemyBots == 0 or isFirstLine)
			end
			numberAnnouncePrinted   = numberAnnouncePrinted + 1
			lastAnnouncePrintedTime = GameTime()
		end
	end

	if GetGameMode() ~= GAMEMODE_1V1MID
	   and GetGameMode() ~= 0
	   and GetGameState() == GAME_STATE_PRE_GAME
	   and (bot.announcedRole == nil or bot.announcedRole ~= J.GetPosition(bot))
	then
		bot.announcedRole = J.GetPosition(bot)
		bot:ActionImmediate_Chat(Localization.Get('say_play_pos') .. J.GetPosition(bot), false)
	end

	if GetGameMode() ~= GAMEMODE_1V1MID and not isChangePosMessageDone then
		if DotaTime() >= 0 and teamHumans > 0 and teamBots > 0 then
			bot:ActionImmediate_Chat(Localization.Get('pos_select_closed'), true)
			isChangePosMessageDone = true
		end
	end
end

