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
local AIBItemPolicy = require(GetScriptDirectory()..'/FunLib/aibattle_item_policy')
local AIBLaneCombat = require(GetScriptDirectory()..'/FunLib/aibattle_laning_combat')
local AIBLaneTempo = require(GetScriptDirectory()..'/FunLib/aibattle_laning_tempo')
local AIBTopArbiter = require(GetScriptDirectory()..'/FunLib/aibattle_laning_arbiter')
local AIBMotor = require(GetScriptDirectory()..'/FunLib/aibattle_motor')
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
	-- The TP scroll lives in the dedicated TP slot (not MAIN) since 7.x; rejecting
	-- everything non-MAIN made respawn logic report respawn-no-tp while a scroll
	-- was sitting in the TP slot and the bot walked back the whole lane. Castable
	-- means "not in backpack/stash", so gate on those instead.
	local st = bot:GetItemSlotType(slot)
	if st == ITEM_SLOT_TYPE_BACKPACK or st == ITEM_SLOT_TYPE_STASH then return nil end
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
		"AIB[%s] defend=%.2f ward=%.2f roshan=%.2f dive=%s heal=%s abil=%s cw=%s at=%s pgb=%s ta=%s",
		AIB_SIDE,
		dials.defend_desire, dials.ward_desire, dials.roshan_desire,
		tostring(r.dive_policy or "finish_only"),
		tostring(r.healing_style or "default"),
		tostring(r.ability_usage or "default"),
		tostring(r.creep_wave_priority or "last_hit_only"),
		tostring(r.ability_timing or "on_cooldown"),
		tostring(r.pregame_behavior or "default"),
		tostring(r.tower_aggression or "default")), true)
	-- Third line, not a longer second one: the two above already sit near Dota's ~160-char
	-- chat limit, which silently drops anything longer (phase-16). These four were missing
	-- from the announce entirely, so the log could not say which config a match was played
	-- with -- and hero_priority/deny_policy/creep_wave_priority are exactly the three knobs
	-- the two models diverged on in the 21.07 series. A result without its config is not
	-- comparable to anything, which is the whole point of docs/match_log.md.
	bot:ActionImmediate_Chat(string.format(
		"AIB[%s] hero=%s deny=%s lowhp=%s respawn=%s",
		AIB_SIDE,
		tostring(r.hero_priority or "default"),
		tostring(r.deny_policy or "default"),
		tostring(r.low_hp_behavior or "regen_lane"),
		tostring(r.respawn_behavior or "tp_to_lane")), true)
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

local AIB_MoveAwayFrom = AIBUtils.MoveAwayFrom

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
	-- Don't re-sip while the regen is still channelling: this path had no cooldown
	-- and could fire a second bottle a tick after survive.lua's sip, cutting the
	-- 3s regen tail short (observed: bottle pressed twice, HP heal wasted).
	if bot:HasModifier("modifier_bottle_regeneration") then return false end
	-- A committed fountain trip refills the bottle to 3 charges for free on arrival, so a sip
	-- taken en route is a charge burned to arrive full -- the same trade e344e49 blocked for
	-- the salve. It was never applied here because this site lives in the laning tier, which
	-- runs whether or not survive.Think claimed the tick: 8909533277 [D] logged
	-- `blocked=heal-item reason=fountain_trip_committed` (vendor salve correctly refused) and
	-- then healed 12%->45% two seconds later, 4600 units from home, off low-hp-bottle -- which
	-- fired 163 times that match. This is the single chokepoint for all three bottle callers
	-- (critical-recover / low-hp / damage-unstuck), so guarding it here covers them all.
	-- Below 15% hp AIBItemPolicy lets the sip through: surviving the walk beats saving a charge.
	if AIBItemPolicy.SkipConsumableForFountainTrip(bot) then
		Style.Blocked(bot, "bottle-sip", "fountain_trip_committed",
			string.format("hp=%.0f", J.GetHP(bot) * 100), 8.0)
		return false
	end
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	if J.GetHP(bot) > hpLimit and mana > manaLimit then return false end
	bot:Action_UseAbility(bottle)
	bot.aib_healLast = DotaTime()
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

-- True when the bot has any consumable that recover could actually use to restore HP.
-- item_enchanted_mango is deliberately EXCLUDED: it restores mana, not HP, so counting it
-- made recoverCanAct=true while an HP-driven recover had no feasible action -> the desire
-- won and returned empty, twitching under the tower (8903907295 W3 t=5:10-5:12, Codex P2).
-- Deeper bottle-cooldown / tango-needs-tree mirroring stays backlog (AIBSurvive.CanRecoverNow).
local function AIB_HasRecoveryResources()
	for _, name in ipairs({ "item_tango", "item_tango_single", "item_flask",
		"item_faerie_fire" }) do
		local slot = bot:FindItemSlot(name)
		if slot >= 0 and bot:GetItemSlotType(slot) == ITEM_SLOT_TYPE_MAIN then
			local it = bot:GetItemInSlot(slot)
			if it ~= nil and it:IsFullyCastable() then return true end
		end
	end
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot >= 0 and bot:GetItemSlotType(bSlot) == ITEM_SLOT_TYPE_MAIN then
		local bottle = bot:GetItemInSlot(bSlot)
		if bottle ~= nil and bottle:GetCurrentCharges() > 0 then return true end
	end
	return false
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
	-- Yield to whoever currently owns the motor -- recovery movers, or the OTHER
	-- position puller (uphill-reposition). Excluding our own name lets us keep our
	-- committed lane walk without self-suppressing. This is what stops the
	-- forward(lane-line)<->back(uphill) tug-of-war from flipping every tick.
	local _motorOwner = AIBMotor.Active(bot)
	if _motorOwner ~= nil and _motorOwner ~= "lane-line" then
		Style.DiagRL(bot, "lane-line-suppressed-motor", 5)
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
	-- Commit this lane walk for 1.5s so uphill-reposition yields and the bot stops
	-- flip-flopping forward<->back between the two positioners every tick.
	AIBMotor.Claim(bot, "lane-line", 20, 1.5)
	bot:Action_MoveToLocation(dest + RandomVector(45))
	AIB_Diag("lane-line-fallback")
	-- Episode honesty (SPECS 3.10 step 1, metric only): the raw diag above counts every
	-- re-issue of the same legitimate walk (~15-25/min at the 1.5s claim cadence) and
	-- dominates the jitter FAIL with the uphill pair long dead (8905429441 R: counter
	-- 28->74 with uphill at 4 -- steady slope, no oscillation partner). Count DECISIONS:
	-- a new episode only when ownership lapsed >3s or the destination moved >400u.
	-- Transition-only Intent; JITTER_KEYS still reads the raw diag until 2 matches of
	-- episode data exist (do not switch key and threshold in the same commit).
	local nowLL = DotaTime()
	local destShift = math.huge
	if bot.aib_laneLineEpDest ~= nil then
		local ddx, ddy = dest.x - bot.aib_laneLineEpDest.x, dest.y - bot.aib_laneLineEpDest.y
		destShift = math.sqrt(ddx * ddx + ddy * ddy)
	end
	local newEpisode = bot.aib_laneLineEpLast == nil
		or nowLL - bot.aib_laneLineEpLast > 3.0
		or destShift > 400
	if newEpisode then
		bot.aib_laneLineEpDest = dest
		Style.Intent(bot, "lane-line-episode",
			string.format("dist=%.0f fwd=%.2f", GetUnitToLocationDistance(bot, dest), fwd), 2.0)
	end
	bot.aib_laneLineEpLast = nowLL
	-- TickOwner is emitted by the arbiter for the winning candidate (P1-A); no self-emit
	-- here or lane-line would double-count as tick owner.
	return true
end

-- Builds the top-level DESIRE candidates (last-hit-urgent, safety, power-rune, fight,
-- recover, siege). P1-A phase A: instead of running its own election, it returns the list
-- so ThinkLaningCore can merge it with the tail lanework/position/idle candidates and hold
-- ONE election. These candidates carry no band -> the arbiter's nil default treats them as
-- the desire band (winner-hysteresis + empty_action as before). Order-preserving guarantee
-- for the tail lives in the explicit bands/scores assigned there.
-- MEASUREMENT ONLY (21.07, user request) -- no behaviour change.
-- The engine exposes only boolean WasRecentlyDamagedBy* flags, never damage amounts, so
-- "how much did creeps take off versus the tower" was unanswerable and the melee-creep
-- positioning complaints could not be quantified. Sample the HP delta each tick and
-- attribute it by whichever flags are live. Overlapping sources go to a mixed bucket
-- instead of being double counted -- deliberately conservative, so creep/tower/hero are
-- lower bounds and mixed is the ambiguity budget. Regen ticks (delta >= 0) are ignored,
-- which means slow chip damage that regen outpaces is undercounted; that is acceptable
-- for a "who is chewing on me" readout.
-- Emitted cumulatively every 15s: postmatch takes the LAST line, so it needs no counter.
-- Probe v2 (21.07): the first run read other=33-35% on both sides, which made the whole
-- readout unusable -- a third of the damage was unattributed. Two causes, both fixed here.
-- (1) DEATH. The killing blow drops the full remaining bar in one sample, and by the next
-- tick the flag that caused it has usually expired, so every death dumped a whole HP bar
-- into `other`. Deaths get their own bucket now; they are an outcome, not a damage source,
-- and mixing them in was drowning the signal we actually wanted.
-- (2) A FIXED 0.3s FLAG WINDOW. The sampler runs on the laning tick, not on a timer, so
-- whenever two samples fell more than 0.3s apart the flags had already lapsed and the delta
-- landed in `other`. Size the window from the real gap between samples instead.
-- Probe v3 (23.07): v2 still printed other=17-46% in every match, i.e. UNTRUSTED, i.e. no
-- statement about who damaged whom was safe to make. Three causes, all structural, none of
-- them "the flags are unreliable":
-- (1) THE SAMPLER WAS IN STAGE 4. It sat inside AIB_BuildDesireCandidates, reached only via
--     ThinkLaningCore -- the LAST of the four laning stages. Every tick that pregame, dive
--     or death-window claimed took no sample at all, and AIB_HandleRespawn returns from
--     Think even earlier. Damage taken across those gaps arrived at the next sample with its
--     flags long expired. It now runs from Think itself, before the stages.
-- (2) THE WINDOW WAS CLAMPED BELOW THE GAP. `min(1.0, gap + 0.15)` means a 3-second gap was
--     asked about with a 1-second question, so two of those seconds were unattributable by
--     construction. Engine flags do not reach back far anyway, which is the point of (3).
-- (3) `other` CONFLATED TWO DIFFERENT THINGS: "damage with no flag" (a real finding -- self
--     damage, neutrals, something we do not model) and "gap too wide to ask about" (a
--     measurement artefact). They now have separate buckets, so the readout says which it is
--     instead of averaging them into one useless number.
local DMG_FLAG_REACH = 1.2   -- how far back the engine's WasRecentlyDamagedBy* can be trusted
local function AIB_SampleDamageBySource()
	local now = DotaTime()
	local gap = (bot.aib_dmgSampleLast ~= nil) and (now - bot.aib_dmgSampleLast) or 0.3
	bot.aib_dmgSampleLast = now
	local window = math.max(0.3, math.min(DMG_FLAG_REACH, gap + 0.15))
	local alive = bot:IsAlive()
	local hpNow = alive and bot:GetHealth() or 0
	local prev = bot.aib_dmgHpPrev
	bot.aib_dmgHpPrev = hpNow
	if prev ~= nil and hpNow < prev then
		local d = prev - hpNow
		if not alive then
			bot.aib_dmgDeath = (bot.aib_dmgDeath or 0) + d
		elseif gap > DMG_FLAG_REACH then
			-- Honest about our own blind spot: nothing can be attributed across a gap wider
			-- than the flags reach, so do not pretend and do not pollute `other` with it.
			bot.aib_dmgStale = (bot.aib_dmgStale or 0) + d
			bot.aib_dmgStaleN = (bot.aib_dmgStaleN or 0) + 1
		else
			local c = bot:WasRecentlyDamagedByCreep(window)
			local t = bot:WasRecentlyDamagedByTower(window)
			local h = bot:WasRecentlyDamagedByAnyHero(window)
			local n = (c and 1 or 0) + (t and 1 or 0) + (h and 1 or 0)
			if n == 1 then
				if c then bot.aib_dmgCreep = (bot.aib_dmgCreep or 0) + d
				elseif t then bot.aib_dmgTower = (bot.aib_dmgTower or 0) + d
				else bot.aib_dmgHero = (bot.aib_dmgHero or 0) + d end
			elseif n > 1 then
				bot.aib_dmgMixed = (bot.aib_dmgMixed or 0) + d
			else
				bot.aib_dmgOther = (bot.aib_dmgOther or 0) + d
			end
		end
	end
	if bot.aib_dmgLogLast == nil or now - bot.aib_dmgLogLast >= 15.0 then
		bot.aib_dmgLogLast = now
		Style.Intent(bot, "damage-by-source", string.format(
			"creep=%d tower=%d hero=%d mixed=%d death=%d other=%d stale=%d gaps=%d",
			bot.aib_dmgCreep or 0, bot.aib_dmgTower or 0, bot.aib_dmgHero or 0,
			bot.aib_dmgMixed or 0, bot.aib_dmgDeath or 0, bot.aib_dmgOther or 0,
			bot.aib_dmgStale or 0, bot.aib_dmgStaleN or 0), 1.0)
	end
end

local function AIB_BuildDesireCandidates(dials, rules, runtimeCtx, intentCtx)
	local hp = J.GetHP(bot)
	local range = botAttackRange or bot:GetAttackRange()
	local enemy, enemyDist = AIB_NearestEnemyHero(AIBLanePolicy.EnemyScanRange(range))
	local enemyHp = enemy ~= nil and J.GetHP(enemy) or 1.0
	local powerRune = AIBEngine.PowerRuneState(bot)
	local actionPowerRune = AIBEngine.IsActionPowerRune(powerRune)
	local recentCreepDamage = bot:WasRecentlyDamagedByCreep(AIBLanePolicy.RecentDamage.creepSeconds)
	local recentHeroDamage = bot:WasRecentlyDamagedByAnyHero(AIBLanePolicy.RecentDamage.heroSeconds)
	local attackableCreep = AIB_NearestAttackableEnemyCreep(range + AIBLanePolicy.Scan.safetyCreepExtra) ~= nil
	-- Feasibility probe for the safety candidate (canAct contract, P4). Mirrors the
	-- entry throttles of CreepHitReact / ActiveLowHp / DamageUnstuck without side
	-- effects, so a symptom-only safety desire stops outbidding a live fight while
	-- all of its actions would return empty this tick.
	local nowSafety = DotaTime()
	-- Observability, not behaviour (21.07). ead1e05's acceptance signature -- blocked=
	-- creep-hit-react reason=recovery_commit, logged inside CreepHitReact -- has read 0 in
	-- every match, and the audit says it always will: the mirror below removes safety from
	-- the election on exactly the ticks the inner guard would fire, so the handler never runs
	-- to log it. The fix works, it was just unobservable. Log it where the decision actually
	-- happens. The inner guard stays as the enforcement for any path that reaches it.
	local recoveryCommitted = bot.aib_recoveryEpisode ~= nil and hp < 0.55
	if recoveryCommitted and recentCreepDamage and attackableCreep then
		Style.Blocked(bot, "creep-hit-react", "recovery_commit",
			string.format("hp=%.0f band=%s", hp * 100,
				tostring((bot.aib_recoveryEpisode or {}).band)), 3.0)
	end
	local creepReactReady = recentCreepDamage and attackableCreep
		and (bot.aib_creepReactLast == nil or nowSafety - bot.aib_creepReactLast >= 0.75)
		and (bot.aib_creepReliefLast == nil or nowSafety - bot.aib_creepReliefLast >= 1.2)
		-- Mirror of the recovery-commit yield in CreepHitReact (laning_safety.lua): while a
		-- recovery episode is committed below 0.55 the handler refuses to trade, so the probe
		-- must report that too. Without this, safety would still win at 116 and then return
		-- empty -- worse than the bug being fixed, and exactly the failure 140aaa5 closed for
		-- recoverCanAct. Keep these two conditions identical.
		and not recoveryCommitted
	local unstuckArmed = bot.aib_damageAnchorTime ~= nil
		and nowSafety - bot.aib_damageAnchorTime >= 3.5
		and ((bot.aib_damageAnchorHp or 100) - hp * 100) >= 5.0
		and (bot.aib_damageUnstuckLast == nil or nowSafety - bot.aib_damageUnstuckLast >= 3.0)
	-- P3-B.1: low-HP retreat left the safety desire (its ActiveLowHp leg is removed below).
	-- The recover desire and the early-low pre-arbiter gate own low-HP retreat now. Dropping
	-- lowHpRetreatReady keeps safety from winning ticks whose only action no longer lives here
	-- (would spike empty_action). early-low is kept this slice so hp<0.35 still retreats
	-- pre-arbiter; safety only competes at 0.35-0.45 where safetyNoAction caps it.
	local safetyCanAct = creepReactReady or unstuckArmed
	-- Same canAct contract for the fight desire: an enemy merely being SEEN must not
	-- win the tick when every fight action would refuse (out of attack range while
	-- the approach paths are gated by uphill/low-hp). In-range trade, low-hp kite and
	-- downhill chase with hp/execute justification always count as actionable.
	-- Concede-when-losing floor (engine robustness): a fed/behind bot stops INITIATING
	-- fights so safety/farm win the tick. Kill-lock (urgent stage) still finishes a
	-- killable enemy; this only caps the fight DESIRE. See AIBUtils.ShouldConcedeLane.
	-- The fightCanAct path is the main concede route, so log it here (the harass path
	-- barely fires post-death since the enemy is rarely in harass range while we walk
	-- back -- 8886710243 showed only 2 harass concedes and no measurable fight-side).
	local concedeLane, concedeReason = false, nil
	if enemy ~= nil then concedeLane, concedeReason = AIBUtils.ShouldConcedeLane(bot, enemy) end
	if concedeLane then
		Style.Blocked(bot, "fight", "concede_" .. tostring(concedeReason), string.format("hp=%.0f", hp * 100), 3.0)
	end
	-- HP-disadvantage trade gate: don't SEEK a trade the bot is already losing on HP.
	-- Deaths kept landing at 45-49% HP from committing to fights vs a healthier enemy
	-- (8886710243 R died t=128 hp49%). Only blocks the out-of-range SEEK; in-range
	-- trade/defence, desperate kite (hp<0.32), a power rune, and a killable enemy all
	-- still fight. This is the third lever -- neither retreat_caution nor concede covers
	-- an even-but-losing trade.
	local hpBehind = enemy ~= nil and AIBUtils.HpDisadvantaged(bot, enemy, dials.execute_threshold, actionPowerRune)
	if hpBehind and (enemyDist or 99999) > range + 80 then
		Style.DiagRL(bot, "fight-hp-behind", 3)
	end
	-- Reach bound, mirroring what the fight ACTION can actually do. Every leg of the fight
	-- closure is distance-gated -- AbilityPressure scans 900, ContactHero range+50, the
	-- HarassAndChase chase branches top out at 1150 -- but legs 2 and 3 of this probe had no
	-- distance term at all, so a healthy bot with the enemy visible at 1400 read canAct=true,
	-- won the tick at 96-122 and returned empty. 8906755360 [R]: fight@114 x7, fight@96 x6,
	-- fight@122 x1, fight@104 x1 = 15 of 18 empty_action ticks on that side. 1200 keeps slack
	-- above the widest action gate so no reachable engage is cut.
	local fightReach = (enemyDist or 99999) <= 1200
	local fightCanAct = enemy ~= nil and not concedeLane and fightReach and (
		(enemyDist or 99999) <= range + 80
		or hp < 0.32
		or (not AIB_UphillMiss(enemy) and not hpBehind
			and (hp >= 0.45 or enemyHp <= (dials.execute_threshold or 0))))
	-- canAct probe for the recover desire (P4, SPECS 3.6.1). recover has a feasible action
	-- when it has recovery resources to spend, OR it is being actively hit (threat -> a
	-- kite/step-back is real work), OR it is in the danger band and not yet behind its
	-- safe anchor (the retreat still makes progress). Two leaks closed after 8903952032:
	-- (a) "not behind anchor" alone let the bot's own pacing AROUND the anchor flip the
	-- probe every tick (W5: recover hp=36-38 + hyst=18 -> score 120, 16 wins / 10 empty,
	-- free farm skipped after a kill); above danger with no threat/items a cosmetic
	-- step-back is not recovery. (b) "enemy visible within 900" counted a passive enemy
	-- as an action while the bot idled at its anchor (W3). If none hold, policy caps
	-- recover below CS and lane work takes the tick.
	-- (c), third leak: "recently damaged" alone. AIBSurvive.recovery() refuses outright above
	-- its own fallback threshold (survive.lua: 0.20 + 0.20*retreat_caution, +0.08 once dead),
	-- so a bot with no items, taking hero damage at 33% HP with zero deaths -- threshold 0.31 --
	-- had canAct=true and no action anywhere. 8906755360 [D] t=112-117 and t=379-390:
	-- recover@102 empty-won 7 ticks, and the tick then fell to the idle watchdog, which walked
	-- it into the creek (70999f0). Being hit only makes recovery real work if a recovery leg
	-- actually exists, so mirror recovery()'s gate. Must stay in step with survive.lua:
	-- if that threshold moves, this moves.
	local recoverFallbackHp = 0.20 + 0.20 * (dials.retreat_caution or 0.5)
		+ (GetHeroDeaths(bot:GetPlayerID()) >= 1 and 0.08 or 0.0)
	local recoverCanAct = AIB_HasRecoveryResources()
		or ((bot:WasRecentlyDamagedByAnyHero(2.0) or bot:WasRecentlyDamagedByCreep(2.0))
			and hp < recoverFallbackHp)
		or (hp < AIBLanePolicy.Hp.danger
			and not AIBUtils.IsCloserToFountain(bot, AIBUtils.SafeRetreatTowerLoc(bot)))
	-- canAct probe for the siege desire: true only when the siege module would ACT this
	-- tick (mirrors its gate chain without side effects).
	local siegeCanAct = AIBLaneSiege.CanAct(AIB_LaningModuleCtx(dials, rules))
	local policyArgs = {
		safetyCanAct = safetyCanAct,
		fightCanAct = fightCanAct,
		recoverCanAct = recoverCanAct,
		siegeCanAct = siegeCanAct,
		-- Must be set HERE, not in the siege block below: Recover() is called ~37 lines
		-- earlier than that assignment, so the free-farm penalty would have read nil and
		-- never fired. The later siege-side assignment is now redundant but harmless.
		enemyDeadRecently = AIB_EnemyDeadRecently(),
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

	-- Last-hit-urgent: a creep dying to the bot's NEXT hit is now-or-never and must not be
	-- starved by safety/fight desires. Aggressive configs (harass 0.9, aggressive_mid) kept
	-- winning the arbiter every tick, so the bot "hit creeps but never last-hit" (LH ~0 for
	-- 90s). Fire only when a creep dies this hit, is already in range, away from the enemy
	-- tower and above critical HP; secure it then yield. Score beats safety(<=134)/fight;
	-- hero kills live in the urgent arbiter (earlier stage) and still preempt.
	do
		local lhCreep, lhSoon = GetBestLastHitCreep(nEnemyCreeps)
		local siegeCommitted = bot.aib_siegeCommitUntil ~= nil and DotaTime() < bot.aib_siegeCommitUntil
		-- farm_focus reaches last-hitting HERE, and until 23.07 it reached it nowhere at all:
		-- binding.py measured r=-0.01 between the dial and lh/min across a 0.15-0.72 spread,
		-- and reading its consumers explained why -- two `< 0.25` booleans, rune creep
		-- pressure, and a hero-seek gate. Nothing touched CS. The dial that names the farmer
		-- archetype had no farming mechanism behind it.
		-- Two gates now scale with it: how hurt the bot will still stop to secure a last hit,
		-- and how far it will reach for one. Both are CENTRED so farm_focus = 0.5 reproduces
		-- the old constants exactly (0.32 and +40) -- a config that does not ask for this
		-- cannot be blamed for a regression from it.
		-- The candidate's own score stays at 140 on purpose: it exists because aggressive
		-- configs starved CS entirely (LH ~0 for 90s), and scaling it down for a brawler
		-- would walk straight back into that.
		local farm = dials.farm_focus or 0.5
		local lhHpGate = 0.38 - 0.12 * farm
		local lhReach = botAttackRange + 20 + 40 * farm
		if lhCreep ~= nil and not lhSoon
			and not siegeCommitted  -- yield to an active tower siege so pushers keep advancing
			and J.GetHP(bot) >= lhHpGate
			and AIBUtils.EnemyTowerDanger(bot) == nil
			and GetUnitToUnitDistance(bot, lhCreep) <= lhReach then
			candidates[#candidates + 1] = AIBTopArbiter.Candidate("last-hit", 140, "killable_creep",
				string.format("dist=%.0f", GetUnitToUnitDistance(bot, lhCreep)),
				function()
					bot:SetTarget(lhCreep)
					bot:Action_AttackUnit(lhCreep, true)
					Style.Diag(bot, "last-hit-urgent")
					return true
				end)
		end
	end

	-- CAPPED = VETO, not participation. dd74e76 established this for recover (see the
	-- no_action_capped block below): a capped candidate means "no feasible action this tick",
	-- and at cap it still outbids the low-band workers (creep-work 38, wave-watch 10) and
	-- empty-wins first. That fix was never extended to the other three capped candidates, and
	-- 8906632392 shows them as the dominant remaining empty_action source -- the empty-win
	-- scores match the cap constants exactly (fightNoAction 40, safetyNoAction 44,
	-- siegeNoAction 42): [R] fight@40 x34, safety@44 x7, siege@42 x6 = 47 of 105 empty
	-- actions; [D] fight@40 x14, safety@44 x12 = 26 of 65. Same treatment, same signature.
	local safetyPolicy = AIBLanePolicy.Safety(policyArgs)
	if safetyPolicy ~= nil and safetyPolicy.capped then
		Style.Blocked(bot, "safety-candidate", "no_action_capped",
			string.format("hp=%.0f score=%.0f", hp * 100, safetyPolicy.score or 0), 3.0)
	elseif safetyPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("safety", safetyPolicy.score, safetyPolicy.reason,
			safetyPolicy.detail,
			function()
				if AIBLaneSafety.CreepHitReact(runtimeCtx) then return true end
				if AIBLaneSafety.DamageUnstuck(runtimeCtx) then return true end
				-- P3-B.1: low-HP retreat leg removed. The recover desire (and the early-low
				-- pre-arbiter gate) own low-HP retreat now; keeping it here made safety<->fight
				-- alternate on the same ActiveLowHp move (cosmetic arbiter choice = twitch).
				return false
			end, nil, safetyPolicy.capped)
	end

	-- power-rune had NO canAct contract at all: its only entry test was actionPowerRune
	-- ("do I hold an action rune"), while RunePowerPressure gates on seven more conditions.
	-- At score 104-114 it outbids everything, so each infeasible tick was a silent no-op:
	-- 19 empty wins in 8906632392 [R]. Same veto shape as fight/safety/siege/recover.
	local powerPolicy = AIBLanePolicy.PowerRune(policyArgs)
	if powerPolicy ~= nil and not AIBLaneCombat.RunePowerCanAct(AIB_LaningModuleCtx(dials, rules)) then
		Style.Blocked(bot, "power-rune-candidate", "no_action_capped",
			string.format("hp=%.0f score=%.0f", hp * 100, powerPolicy.score or 0), 3.0)
	elseif powerPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("power-rune", powerPolicy.score, powerPolicy.reason,
			powerPolicy.detail,
			function() return AIBLaneCombat.RunePowerPressure(runtimeCtx) end)
	end

	local fightPolicy = AIBLanePolicy.Fight(policyArgs)
	if fightPolicy ~= nil and fightPolicy.capped then
		Style.Blocked(bot, "fight-candidate", "no_action_capped",
			string.format("hp=%.0f score=%.0f", hp * 100, fightPolicy.score or 0), 3.0)
	elseif fightPolicy ~= nil then
		candidates[#candidates + 1] = AIBTopArbiter.Candidate("fight", fightPolicy.score, fightPolicy.reason,
			fightPolicy.detail,
			function()
				if AIBLaneCombat.AbilityPressure(runtimeCtx) then return true end
				if AIBLaneCombat.ContactHero(runtimeCtx) then return true end
				return AIB_RunFightArbiter(intentCtx)
			end, nil, fightPolicy.capped)
	end

	local recoverPolicy = AIBLanePolicy.Recover(policyArgs)
	if recoverPolicy ~= nil then
		-- Resource gate: with no heal items, no bottle charges and the bot already behind
		-- its safe anchor while not being hit, recover has no possible action. Letting it
		-- win the arbiter anyway froze lane work for 10-40s in the 40-55% HP band
		-- (8880453130 t=436-449, 8880823408 t=264-299: LH frozen, 2000u ping-pong).
		local recoverUseless = hp >= 0.30
			and not recentHeroDamage and not recentCreepDamage
			and not AIB_HasRecoveryResources()
			and AIBUtils.IsCloserToFountain(bot, AIBUtils.SafeRetreatTowerLoc(bot))
		if recoverUseless then
			Style.Blocked(bot, "recover-candidate", "no_resources_behind_safe",
				string.format("hp=%.0f score=%.0f", hp * 100, recoverPolicy.score or 0), 3.0)
		elseif recoverPolicy.capped then
			-- A capped recover means "no feasible action" -- don't enter the election at
			-- all. At cap=44 it still outbid creep-work(38) on quiet ticks and empty-won
			-- first, then fell through: 191 no-op first-wins in 8903988046 (the dominant
			-- empty_action source). Veto keeps the hp_gate_no_action signature via this log.
			Style.Blocked(bot, "recover-candidate", "no_action_capped",
				string.format("hp=%.0f score=%.0f", hp * 100, recoverPolicy.score or 0), 3.0)
		else
			candidates[#candidates + 1] = AIBTopArbiter.Candidate("recover", recoverPolicy.score, recoverPolicy.reason,
				recoverPolicy.detail,
				function() return AIBLaneRecovery.ThinkIfAllowed(runtimeCtx, AIBLanePolicy.Hp.softRecovery, "lane-low") end, nil, recoverPolicy.capped)
		end
	end

	-- tower_aggression=never: the siege action is hard-vetoed, so don't let the
	-- desire win the arbiter just to return empty_action. Log the veto here (the
	-- siege module never runs) so 'never' has a positive validation signature.
	if (rules.tower_aggression or "default") == "never" then
		if AIB_HasSiegeCandidate() then
			Style.Blocked(bot, "siege", "tower_aggression_never", "candidate_skipped", 6.0)
		end
	end
	if (rules.tower_aggression or "default") ~= "never" then
		policyArgs.hasSiegeCandidate = AIB_HasSiegeCandidate()
		policyArgs.enemyDeadRecently = AIB_EnemyDeadRecently()
		local siegePolicy = AIBLanePolicy.Siege(policyArgs)
		if siegePolicy ~= nil and siegePolicy.capped then
			Style.Blocked(bot, "siege-candidate", "no_action_capped",
				string.format("hp=%.0f score=%.0f", hp * 100, siegePolicy.score or 0), 3.0)
		elseif siegePolicy ~= nil then
			candidates[#candidates + 1] = AIBTopArbiter.Candidate("siege", siegePolicy.score, siegePolicy.reason,
				siegePolicy.detail,
				function() return AIB_SiegeIntent(dials, rules) end, nil, siegePolicy.capped)
		end
	end

	return candidates
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
	if AIBLaneRecovery.Owner(runtimeCtx) then return true end
	if AIB_PreWaveDuelStep(rules) then return true end
	if AIBLaneTempo.PreCreepStandoff(runtimeCtx) then return true end
	-- === P1-A phase A: one merged tail election (SPECS 3.6.1 / 3.7) ===
	-- The head guards above (survive / emergency-low / urgent kill+interrupt / early-low /
	-- Recovery.Owner / prewave / standoff) still run first and short-circuit. From here the
	-- former desire arbiter AND the whole sequential tail compete in ONE election: the
	-- desire candidates (no band = sticky + empty_action, as before) plus the lanework /
	-- position / idle candidates below, whose scores strictly encode the previous code order
	-- and whose guards stay INSIDE canAct/action so a yielded block falls through silently.
	-- Only intended behavior change: the no-action caps (recover/siege now join safety/fight
	-- in policy.lua), so a symptom-only desire capped to 40-44 loses the tick to CS (50-56).
	local candidates = AIB_BuildDesireCandidates(dials, rules, runtimeCtx, intentCtx)

	-- Tail facts: pure reads computed once BEFORE the election, so ordering never depends on
	-- a score()/canAct() side effect. Diag/action side effects stay lazy inside the closures.
	local hitCreep, csSoon = GetBestLastHitCreep(nEnemyCreeps)
	local csLaneCheck = J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700)
	local csAllowed = J.IsValid(hitCreep) and csLaneCheck
	local csDistNow = csAllowed and GetUnitToUnitDistance(bot, hitCreep) or nil
	local needMove = csAllowed and (csDistNow > botAttackRange or csSoon == true)
	runtimeCtx.csAllowed = csAllowed
	runtimeCtx.needMove = needMove
	local aib_deathSurvive = GetHeroDeaths(bot:GetPlayerID()) >= 1 and J.GetHP(bot) < AIBLanePolicy.Hp.secondDeathSurvive
	runtimeCtx.deathSurvive = aib_deathSurvive
	-- low-hp-hold via the PURE probe (no diag). The low-hp-limit signature stays lazy in the
	-- ActiveLowHp action() below so its per-match count matches baseline (3.6.1 trap).
	local aib_lowHpHold, aib_lowHpDanger = AIBLaneRecovery.LowHpHoldProbe(runtimeCtx)
	runtimeCtx.lowHpHold = aib_lowHpHold
	-- forwardness lane-front target (pure)
	local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
	local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
	local hpScale    = math.max(0.0, math.min(1.0, (J.GetHP(bot) - 0.5) / 0.5))
	local safeOffset = math.floor(nLongestAttackRange * (1.0 - 0.65 * hpScale))
	local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -safeOffset)
	if (fLaneFrontAmount_enemy or 0) < (fLaneFrontAmount or 1) then
		target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -safeOffset)
	end

	local function tail(name, score, band, reason, action)
		candidates[#candidates + 1] = AIBTopArbiter.Candidate(name, score, reason, "", action, band)
	end

	-- safe low-hp CS (56): only entered in the pure hp band, so it is not even a candidate
	-- when healthy (avoids a spurious empty in the election).
	if J.GetHP(bot) >= AIBLanePolicy.Hp.safeLastHitMin and J.GetHP(bot) < AIBLanePolicy.Hp.softRecovery then
		tail("safe-cs", 56, "lanework", "low_hp_secure", function()
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
			return false
		end)
	end

	tail("hero-over-creep", 52, "lanework", "ready", function() return AIBLaneCombat.HeroOverCreep(runtimeCtx) end)

	-- cs-inrange (50): secure an already-in-range last-hit before the heal check.
	if csAllowed and not needMove and csSoon ~= true then
		tail("cs-inrange", 50, "lanework", "in_range", function()
			bot:SetTarget(hitCreep)
			bot:Action_AttackUnit(hitCreep, true)
			AIB_Diag("cs-inrange")
			return true
		end)
	end

	tail("idle-heal", 46, "lanework", "ready", function() return AIBSurvive.Think(bot, dials, nEnemyCreeps) end)
	tail("emergency-retreat", 45, "lanework", "ready", function() return AIBLaneRecovery.EmergencyRetreat(runtimeCtx) end)
	tail("fwd-pullback", 44, "lanework", "ready", function() return AIBLaneRecovery.ForwardLowHpPullback(runtimeCtx) end)
	tail("emergency-kill", 43.5, "lanework", "ready", function() return AIBLaneCombat.EmergencyKillPriority(runtimeCtx) end)

	-- ActiveLowHp / low-hp-hold (43.2): between emergency-kill (43.5) and uphill (43),
	-- reproducing its former code slot. NOTE: this block is absent from the 3.6.1 ladder --
	-- score picked order-preserving; flagged for Codex/Fable review. Entered whenever the
	-- pure hold probe is true; LowHpHoldState() inside emits low-hp-limit lazily (baseline
	-- parity) and ActiveLowHp acts only when danger is present (else yields the tick).
	if aib_lowHpHold then
		tail("low-hp-hold", 43.2, "lanework", "ready", function()
			AIBLaneRecovery.LowHpHoldState(runtimeCtx)
			if aib_lowHpDanger and AIBLaneRecovery.ActiveLowHp(runtimeCtx) then return true end
			return false
		end)
	end

	tail("uphill", 43, "lanework", "ready", function() return AIBLaneCombat.UphillReposition(runtimeCtx) end)
	tail("ranged-spacing", 41, "lanework", "ready", function() return AIBLaneSafety.RangedMeleePackSpacing(runtimeCtx) end)
	tail("harass", 40, "lanework", "ready", function() return AIBLaneCombat.HarassAndChase(runtimeCtx) end)
	-- Third path from farm_focus to farming: how creep work ranks against harass when both
	-- are available. That contest is the dial's plain meaning -- does my attention go to the
	-- wave or to the hero -- and it was decided by two fixed constants. Centred on 0.5 = 38,
	-- the historical value, and deliberately kept inside the 36..40 band so it can never
	-- outbid ranged-spacing (41), which is a safety mechanism, nor fall under ability-harass
	-- (36) and silently reorder a third pair.
	local farmFocusScore = math.max(36.4, math.min(39.6, 38 + 4 * ((dials.farm_focus or 0.5) - 0.5)))
	tail("creep-work", farmFocusScore, "lanework", "ready", function()
		return AIBLaneCreeps.HandleCreepWork({
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
		})
	end)
	tail("ability-harass", 36, "lanework", "ready", function() return AIBLaneCombat.AbilityHarass(runtimeCtx) end)

	-- fwd-position (22): final lane-positioning preference. Its 12-condition suppress guard
	-- lives INSIDE the action (position band -> no hysteresis, silent yield). Fires the
	-- fwd-suppressed-* diags when reached but suppressed, exactly as the old sequential block.
	tail("fwd-position", 22, "position", "ready", function()
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
		-- Yield to whoever owns the motor, exactly as lane-line does. Recovery movers claim at
		-- 90-110, so this also stops forwardness dragging a retreating bot back out.
		local fwdMotor = AIBMotor.Active(bot)
		if fwdMotor ~= nil and fwdMotor ~= "fwd-position" then
			Style.DiagRL(bot, "fwd-suppressed-motor", 5)
			return false
		end
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
				local sinceFwd = bot.aib_fwdLast == nil and math.huge or (nowFwd - bot.aib_fwdLast)
				local farMove = GetUnitToLocationDistance(bot, dest) > AIBLanePolicy.Forward.longMoveOverrideDist
				if sinceFwd >= AIBLanePolicy.Forward.cooldown
					or (farMove and sinceFwd >= AIBLanePolicy.Forward.longMoveCooldown) then
					bot.aib_fwdLast = nowFwd
					-- Own the motor while walking, and it is claimed at the same priority
					-- lane-line uses so the two positioners can no longer both move the hero
					-- in the same second. fwd-position was the one positioner never wired
					-- into Motor, which is exactly the pair Motor was built to kill.
					AIBMotor.Claim(bot, "fwd-position", 20, 1.5)
					bot:Action_MoveToLocation(dest)
					AIB_Diag("fwd-position")
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
		return false
	end)

	tail("visual-hold", 20, "position", "ready", function() return AIBLaneSafety.VisualHoldHeartbeat(runtimeCtx) end)
	tail("lane-line", 18, "position", "ready", function() return AIB_LaneLineFallback(dials) end)
	-- wave-watch (P1-C C.1, idle band 10, below lane-line so it repositions first, above
	-- visual-afk/anti-idle): the enemy wave is close but nothing is last-hittable yet (the
	-- cs candidates above all yielded), so OWN the tick STANDING instead of letting anti-idle
	-- push the wave / pace between creeps. Standing between last-hits is the correct, watchable
	-- behavior; this closes the niche that fell through to the (now disciplined) idle watchdog.
	tail("wave-watch", 10, "idle", "ready", function()
		local r = botAttackRange or bot:GetAttackRange()
		local near = false
		for _, c in pairs(nEnemyCreeps or {}) do
			if J.IsValid(c) and J.CanBeAttacked(c) and GetUnitToUnitDistance(bot, c) <= r + 250 then
				near = true; break
			end
		end
		if not near then return false end
		Style.DiagRL(bot, "wave-watch", 5)
		return true
	end)
	tail("visual-afk", 8, "idle", "ready", function() return AIBLaneSafety.VisualAFK(runtimeCtx) end)
	tail("anti-idle", 2, "idle", "ready", function()
		Style.DiagRL(bot, "pre-aig", 3)
		return Style.AntiIdleGlobal(bot)
	end)

	local handled = AIBTopArbiter.Run(candidates, runtimeCtx)
	return handled
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
	-- Before the stages, not inside the last one: see probe v3 note at AIB_SampleDamageBySource.
	AIB_SampleDamageBySource()
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

