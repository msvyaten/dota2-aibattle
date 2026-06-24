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
local _buildOk, AIBBuild = pcall(require, GetScriptDirectory()..'/FunLib/aibattle_build')
if not _buildOk then AIBBuild = { sha = "unknown" } end
local _healOk, _healResult = pcall(require, GetScriptDirectory()..'/FunLib/aibattle_survive')
local AIBSurvive = _healOk and _healResult or { Think = function() return false end }
local AIBLaneSurvival = require(GetScriptDirectory()..'/FunLib/aibattle_laning_survival')
local AIBLaneTrade = require(GetScriptDirectory()..'/FunLib/aibattle_laning_trade')

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
local AIB_VISUAL_AFK_SECONDS = 5.0
local AIB_VISUAL_AFK_DISTANCE = 90.0
local AIB_VISUAL_HOLD_SECONDS = 2.0
local AIB_VISUAL_HOLD_DISTANCE = 55.0
-- Delegates to the shared counter (FunLib/aibattle_style M.Diag); kept as a thin local
-- wrapper so existing call sites stay unchanged. Counters live on the bot handle, so
-- laning + team-mode diags merge into the same summary line.
local function AIB_Diag(key)
	Style.Diag(bot, key)
end

local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

-- Utility wrappers: logic lives in aibattle_utils.lua, these close over module-level `bot`.
local function AIB_EnemyTowerDanger()          return AIBUtils.EnemyTowerDanger(bot) end
local function AIB_ForwardSurvivingTowerLoc()  return AIBUtils.ForwardSurvivingTowerLoc(bot) end
local function AIB_EnemyCreepCentroid(creeps)  return AIBUtils.EnemyCreepCentroid(creeps) end
local function AIB_UphillMiss(target)          return AIBUtils.UphillMiss(bot, target) end

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
		local tpStill = bot:GetItemInSlot(bot:FindItemSlot("item_tpscroll"))
		if tpStill ~= nil then return false end   -- scroll intact: retry TP on next tick
		bot.aib_wasDead = false; return false     -- scroll consumed: channel done, walk normally
	end

	-- already left base without TPing (no scroll / gave up) -> stop trying
	if bot:DistanceFromFountain() > 1500 then bot.aib_wasDead = false; return false end

	local behavior = GetRules().respawn_behavior
	if behavior == "walk_back" then bot.aib_wasDead = false; return false end

	local tp = bot:GetItemInSlot(bot:FindItemSlot("item_tpscroll"))
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

	if J.GetEnemiesAroundAncient(bot, 3200) > 0 then
		return BOT_MODE_DESIRE_NONE
	end

	if bot:WasRecentlyDamagedByAnyHero(5)
	and #J.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
		local nLaneFrontLocation = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
		local nDistFromLane = GetUnitToLocationDistance(bot, nLaneFrontLocation)
		if not J.WeAreStronger(bot, 1200) or (nDistFromLane > 700 and J.GetHP(bot) < 0.7) then
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

	-- AIBattle 1v1: laning is the ONLY useful mode here. Keep desire high the whole game so the
	-- bot never defers to OHA retreat/jungle modes -- after ~12 min the fallbacks below collapse
	-- to 0.2/0.01, which let retreat-mode win and walk the bot to fountain, abandoning the lane
	-- and tower (match 8862431491). All retreat/regen is handled inside ThinkLaningCore.
	if GetGameMode() == GAMEMODE_1V1MID then return 0.7 end

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
	if not hCreepList then return nil end
	-- dmgDelta=1.5: wider window so bot pursues creeps at ~150 HP (0.7 missed 100-130 HP range).
	local dmgDelta = attackDamage * 1.5

	local moveToCreep = nil
	for _, creep in pairs(hCreepList) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep, false
			end
			if J.WillKillTarget(creep, attackDamage + dmgDelta, DAMAGE_TYPE_PHYSICAL, nDelay) then
				moveToCreep = creep
			end
		end
	end
	if moveToCreep then
		return moveToCreep, true
	end

	return nil
end

function GetBestDenyCreep(hCreepList)
	if not hCreepList then return nil end
	for _, creep in pairs(hCreepList)
	do
		if J.IsValid(creep)
		and J.GetHP(creep) < 0.49
		and J.CanBeAttacked(creep)
		and creep:GetHealth() <= attackDamage
		then
			return creep
		end
	end

	return nil
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
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return false end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil or not bottle:IsFullyCastable() or bottle:GetCurrentCharges() <= 0 then return false end
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	if J.GetHP(bot) > hpLimit and mana > manaLimit then return false end
	bot:Action_UseAbility(bottle)
	AIB_Diag(diagKey or "bottle-heal")
	return true
end

local function AIB_VisualAFKStep(rules)
	local now = DotaTime()
	if now <= 0 then return false end
	local limit = AIB_VISUAL_AFK_SECONDS
	if limit <= 0 then return false end
	local loc = bot:GetLocation()
	local moveDist = AIB_VISUAL_AFK_DISTANCE
	if bot.aib_afkAnchorLoc == nil or bot.aib_afkAnchorTime == nil then
		AIB_ResetVisualAFK(now, loc)
		return false
	end
	if AIB_Dist2D(loc, bot.aib_afkAnchorLoc) >= moveDist then
		AIB_ResetVisualAFK(now, loc)
		return false
	end
	if now - bot.aib_afkAnchorTime < limit then return false end
	if bot.aib_afkLast ~= nil and now - bot.aib_afkLast < 2.5 then return false end
	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= botAttackRange + 40 then
			return false
		end
	end

	local dest = nil
	local key = "anti-afk-step"
	local twr = AIB_EnemyTowerDanger()
	if twr ~= nil and not Style.MayDive(bot) then
		dest = AIB_MoveAwayFrom(loc, twr:GetLocation(), 260)
		key = "anti-afk-back"
	elseif J.GetHP(bot) < 0.30 then
		dest = AIB_ForwardSurvivingTowerLoc()
		key = "anti-afk-safe"
	else
		local enemies = bot:GetNearbyHeroes(1400, true, BOT_MODE_NONE)
		if enemies and #enemies > 0 and enemies[1]:IsAlive() then
			local enemy = enemies[1]
			local enemyLoc = enemy:GetLocation()
			local dist = GetUnitToUnitDistance(bot, enemy)
			if dist <= botAttackRange + 80 then
				return false
			end
			if dist > botAttackRange + 120 then
				Style.DiagRL(bot, "anti-afk-no-chase", 5)
				return false
			end
			local dx, dy = loc.x - enemyLoc.x, loc.y - enemyLoc.y
			local d = math.sqrt(dx*dx + dy*dy)
			if d > 1 then
				local side = (math.floor(now / limit) % 2 == 0) and 1 or -1
				dest = Vector(loc.x + (-dy/d)*220*side, loc.y + (dx/d)*220*side, loc.z)
				key = "anti-afk-strafe"
			end
		end
	end
	if dest == nil and nEnemyCreeps and #nEnemyCreeps > 0 then
		local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		if cen ~= nil and ownT1 ~= nil then
			local anch = ownT1:GetLocation()
			local dx, dy = anch.x - cen.x, anch.y - cen.y
			local d = math.sqrt(dx*dx + dy*dy)
			if d > 1 then
				local safe = math.max(220, botAttackRange - 120)
				dest = Vector(cen.x + (dx/d)*safe, cen.y + (dy/d)*safe, cen.z)
				key = "anti-afk-wave"
			end
		end
	end
	if dest == nil then
		dest = GetLaneFrontLocation(GetTeam(), botAssignedLane, 0)
		key = "anti-afk-lane"
	end
	if dest == nil then return false end
	if GetUnitToLocationDistance(bot, dest) < 120 then dest = dest + RandomVector(220) end
	bot:Action_MoveToLocation(dest)
	bot.aib_afkLast = now
	AIB_ResetVisualAFK(now, loc)
	AIB_Diag(key)
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

local function AIB_MoveToAttackEdge(target, diagKey)
	return AIB_MoveToAttackEdgeOf(target, diagKey, 0)
end

local function AIB_AttackEdgeLocation(target, extraBack)
	if target == nil then return nil end
	local range = botAttackRange or bot:GetAttackRange()
	if range <= 300 then return target:GetLocation() end
	local tl = target:GetLocation()
	local bl = bot:GetLocation()
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

local function AIB_RangedMeleePackSpacingStep()
	local now = DotaTime()
	if now <= 0 or (botAttackRange or bot:GetAttackRange()) <= 350 then return false end
	if bot.aib_meleeSpaceLast ~= nil and now - bot.aib_meleeSpaceLast < 1.4 then return false end
	local cen, count = AIB_MeleeCreepCentroid(nEnemyCreeps, 300)
	if cen == nil or count < 2 then return false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local away = ownT1 ~= nil and ownT1:GetLocation() or bot:GetLocation()
	local dx, dy = away.x - cen.x, away.y - cen.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then return false end
	local safe = math.max(360, (botAttackRange or bot:GetAttackRange()) - 90)
	local dest = Vector(cen.x + (dx/d)*safe, cen.y + (dy/d)*safe, cen.z)
	if GetUnitToLocationDistance(bot, dest) < 120 then return false end
	bot.aib_meleeSpaceLast = now
	Style.Intent(bot, "melee-pack-space", string.format("count=%d dist=%.0f", count, GetUnitToLocationDistance(bot, dest)), 1.5)
	bot:Action_MoveToLocation(dest)
	AIB_Diag("melee-pack-space")
	return true
end

local function AIB_NearestAttackableEnemyCreep(range)
	local best = nil
	local bestDist = range or math.huge
	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local dist = GetUnitToUnitDistance(bot, creep)
			if dist <= bestDist then
				best = creep
				bestDist = dist
			end
		end
	end
	return best, bestDist
end

local function AIB_WeakestAttackableEnemyCreep(maxDist)
	local best = nil
	local bestHp = math.huge
	local bestDist = math.huge
	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local dist = GetUnitToUnitDistance(bot, creep)
			local hp = creep:GetHealth()
			if dist <= (maxDist or math.huge) and hp < bestHp then
				best = creep
				bestHp = hp
				bestDist = dist
			end
		end
	end
	return best, bestDist, bestHp
end

local function AIB_WantBlocked(name, reason, detail, sec)
	Style.Blocked(bot, name, reason, detail, sec or 3.0)
end

local function AIB_CreepHitReactStep()
	local now = DotaTime()
	if now <= 0 or bot:HasModifier("modifier_teleporting") then return false end
	if not bot:WasRecentlyDamagedByCreep(1.2) then return false end
	if bot.aib_creepReactLast ~= nil and now - bot.aib_creepReactLast < 0.75 then return false end

	local hp = J.GetHP(bot)
	local range = botAttackRange or bot:GetAttackRange()
	if bot.aib_creepReactSeen == nil or now - bot.aib_creepReactSeen > 3.0 then
		bot.aib_creepReactCount = 0
	end
	if bot.aib_creepReactTick == nil or now - bot.aib_creepReactTick >= 0.6 then
		bot.aib_creepReactTick = now
		bot.aib_creepReactSeen = now
		bot.aib_creepReactCount = (bot.aib_creepReactCount or 0) + 1
	end
	local creep, dist = AIB_NearestAttackableEnemyCreep(range + 160)
	if creep == nil then
		AIB_WantBlocked("creep-hit-react", "no_creep", string.format("hp=%.0f", hp * 100), 3.0)
		return false
	end

	bot.aib_creepReactLast = now
	local repeatedDamage = (bot.aib_creepReactCount or 0) >= 2
	local safeToTrade = hp >= 0.70 and not repeatedDamage
		and dist <= range + 25 and AIB_EnemyTowerDanger() == nil
	if safeToTrade then
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=attack", dist, hp * 100, bot.aib_creepReactCount or 0), 1.5)
		bot:Action_AttackUnit(creep, true)
		AIB_Diag("creep-hit-react-atk")
		return true
	end

	local safe = AIBUtils.SafeRetreatTowerLoc(bot)
	if safe == nil then
		local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
		if cen ~= nil then safe = AIB_MoveAwayFrom(bot:GetLocation(), cen, 360) end
	end
	if safe ~= nil then
		bot.aib_creepReliefLast = now
		bot.aib_creepReliefDest = safe
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=kite", dist, hp * 100, bot.aib_creepReactCount or 0), 1.5)
		bot:Action_MoveToLocation(safe)
		AIB_Diag("creep-hit-react-kite")
		return true
	end

	AIB_WantBlocked("creep-hit-react", "no_safe_dest", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
	return false
end

local function AIB_DamageUnstuckStep()
	local now = DotaTime()
	if now <= 0 or bot:HasModifier("modifier_teleporting") then return false end
	local loc = bot:GetLocation()
	local hpPct = J.GetHP(bot) * 100
	if bot.aib_damageAnchorLoc == nil or bot.aib_damageAnchorTime == nil then
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		return false
	end
	if AIB_Dist2D(loc, bot.aib_damageAnchorLoc) > 100 then
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		return false
	end
	local elapsed = now - bot.aib_damageAnchorTime
	local hpDrop = (bot.aib_damageAnchorHp or hpPct) - hpPct
	if elapsed < 4.0 or hpDrop < 6.0 then return false end
	if bot.aib_damageUnstuckLast ~= nil and now - bot.aib_damageUnstuckLast < 3.0 then return false end

	if AIB_BottleIfUseful(0.72, 0.35, "damage-unstuck-bottle") then
		bot.aib_damageUnstuckLast = now
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f reason=bottle", hpDrop, elapsed), 2.0)
		return true
	end

	if bot:WasRecentlyDamagedByCreep(1.5) and J.GetHP(bot) >= 0.28 then
		local creep, dist = AIB_NearestAttackableEnemyCreep((botAttackRange or bot:GetAttackRange()) + 80)
		if creep ~= nil and dist <= (botAttackRange or bot:GetAttackRange()) + 40 then
			bot.aib_damageUnstuckLast = now
			bot.aib_damageAnchorLoc = loc
			bot.aib_damageAnchorTime = now
			bot.aib_damageAnchorHp = hpPct
			Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f reason=creep_atk", hpDrop, elapsed), 2.0)
			bot:Action_AttackUnit(creep, true)
			AIB_Diag("damage-unstuck-atk")
			return true
		end
	end

	local dest = AIBUtils.SafeRetreatTowerLoc(bot)
	local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
	if dest == nil and cen ~= nil then
		dest = AIB_MoveAwayFrom(loc, cen, 420)
	end
	if dest == nil then return false end
	if GetUnitToLocationDistance(bot, dest) < 220 then
		dest = AIB_TowardFountainFrom(loc, 460) or (dest + RandomVector(260))
	end

	bot.aib_damageUnstuckLast = now
	bot.aib_damageAnchorLoc = loc
	bot.aib_damageAnchorTime = now
	bot.aib_damageAnchorHp = hpPct
	Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f", hpDrop, elapsed), 2.0)
	bot:Action_MoveToLocation(dest)
	AIB_Diag("damage-unstuck")
	return true
end

local function AIB_ActiveLowHpStep()
	local hp = J.GetHP(bot)
	if hp >= (GetRules().low_hp_hold or 0.45) then return false end
	if AIB_BottleIfUseful(0.62, 0.30, "low-hp-bottle") then return true end
	local range = botAttackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(range + 60, true, BOT_MODE_NONE)
	if hp >= 0.32 and enemies and #enemies > 0 and enemies[1]:IsAlive()
		and not AIB_TowerActuallyThreatening(AIB_EnemyTowerDanger()) then
		bot:Action_AttackUnit(enemies[1], false)
		AIB_Diag("low-hp-fight")
		return true
	end
	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= range + 40 then
			if hp >= 0.35 or (hp >= 0.28 and bot:WasRecentlyDamagedByCreep(1.5)) then
				bot:Action_AttackUnit(creep, true)
				AIB_Diag("low-hp-creep")
				return true
			end
			break
		end
	end
	local back = AIBUtils.SafeRetreatTowerLoc(bot)
	if back ~= nil and (bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0)) then
		local farBack = AIB_TowardFountainFrom(bot:GetLocation(), 430) or (back + RandomVector(260))
		bot.aib_lowHpActiveLast = DotaTime()
		bot:Action_MoveToLocation(farBack)
		AIB_Diag("low-hp-safe-step")
		return true
	end
	if back ~= nil and GetUnitToLocationDistance(bot, back) > 140 then
		if bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 0.8 then
			bot.aib_lowHpActiveLast = DotaTime()
			bot:Action_MoveToLocation(back)
			AIB_Diag("low-hp-back")
		else
			local nudge = AIB_TowardFountainFrom(bot:GetLocation(), 220)
			if nudge ~= nil then
				bot:Action_MoveToLocation(nudge)
				AIB_Diag("low-hp-nudge")
			end
		end
		return true
	end
	if back ~= nil then
		local dangerNear = false
		local nearHeroes = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
		if nearHeroes and #nearHeroes > 0 and nearHeroes[1]:IsAlive() then dangerNear = true end
		if not dangerNear then
			for _, creep in pairs(nEnemyCreeps or {}) do
				if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= range + 180 then
					dangerNear = true; break
				end
			end
		end
		if dangerNear
			and (bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 1.2) then
			bot.aib_lowHpActiveLast = DotaTime()
			bot:Action_MoveToLocation((AIB_TowardFountainFrom(bot:GetLocation(), 300) or back) + RandomVector(35))
			AIB_Diag("low-hp-watch-step")
			return true
		end
	end
	return false
end

local function AIB_LastHitWatchdogStep()
	local now = DotaTime()
	if now < 85 or now > 8 * 60 then return false end
	local lh = AIB_SafeCounter("GetLastHits")
	if lh == nil then return false end
	if bot.aib_csWatchLastCheck == nil or now - bot.aib_csWatchLastCheck >= 20.0 then
		if bot.aib_csWatchLH == nil or lh > bot.aib_csWatchLH then
			bot.aib_csWatchLH = lh
			bot.aib_csWatchNoGainSince = now
		elseif bot.aib_csWatchNoGainSince == nil then
			bot.aib_csWatchNoGainSince = now
		end
		bot.aib_csWatchLastCheck = now
	end
	local noGainFor = now - (bot.aib_csWatchNoGainSince or now)
	if lh > 0 and noGainFor < 55.0 then return false end
	if lh == 0 and now < 115 then return false end
	if bot.aib_csWatchLast ~= nil and now - bot.aib_csWatchLast < 1.2 then return false end
	if AIB_EnemyTowerDanger() ~= nil and AIB_TowerActuallyThreatening(AIB_EnemyTowerDanger()) then return false end

	local range = botAttackRange or bot:GetAttackRange()
	local creep, dist, hp = AIB_WeakestAttackableEnemyCreep(range * 1.65)
	if creep == nil then
		AIB_WantBlocked("cs-watchdog", "no_creep", string.format("lh=%d idle=%.0f", lh, noGainFor), 5.0)
		return false
	end
	bot.aib_csWatchLast = now
	Style.Intent(bot, "cs-watchdog", string.format("lh=%d idle=%.0f creep_hp=%.0f dist=%.0f", lh, noGainFor, hp or -1, dist or -1), 2.0)
	if dist <= range + 35 then
		bot:Action_AttackUnit(creep, true)
		AIB_Diag("cs-watchdog-atk")
	else
		AIB_MoveToAttackEdgeOf(creep, "cs-watchdog-step", 30)
	end
	return true
end

local function AIB_VisualHoldHeartbeatStep()
	local now = DotaTime()
	if now <= 0 then return false end
	local loc = bot:GetLocation()
	if bot.aib_holdAnchorLoc == nil or bot.aib_holdAnchorTime == nil
		or AIB_Dist2D(loc, bot.aib_holdAnchorLoc) > AIB_VISUAL_HOLD_DISTANCE then
		bot.aib_holdAnchorLoc = loc
		bot.aib_holdAnchorTime = now
		return false
	end
	if now - bot.aib_holdAnchorTime < AIB_VISUAL_HOLD_SECONDS then return false end
	if bot.aib_holdLast ~= nil and now - bot.aib_holdLast < 1.0 then return false end

	local range = botAttackRange or bot:GetAttackRange()
	local enemy, enemyDist = AIB_NearestEnemyHero(range + 70)
	local creep, creepDist = AIB_NearestAttackableEnemyCreep(range + 70)
	local reason = "empty"
	if bot:WasRecentlyDamagedByCreep(2.0) then reason = "creep_damage"
	elseif enemy ~= nil then reason = "hero_in_range"
	elseif creep ~= nil then reason = "creep_in_range"
	elseif AIB_EnemyTowerDanger() ~= nil then reason = "tower"
	end
	Style.Blocked(bot, "visual-hold", reason,
		string.format("held=%.1f hp=%.0f", now - bot.aib_holdAnchorTime, J.GetHP(bot) * 100), 2.0)

	bot.aib_holdLast = now
	if enemy ~= nil and enemyDist <= range + 40 and J.GetHP(bot) >= 0.30 and not AIB_UphillMiss(enemy) then
		bot:Action_AttackUnit(enemy, false)
		AIB_Diag("visual-hold-hero")
		bot.aib_holdAnchorLoc = loc; bot.aib_holdAnchorTime = now
		return true
	end
	if creep ~= nil and creepDist <= range + 45 then
		bot:Action_AttackUnit(creep, true)
		AIB_Diag("visual-hold-creep")
		bot.aib_holdAnchorLoc = loc; bot.aib_holdAnchorTime = now
		return true
	end
	if bot:WasRecentlyDamagedByCreep(2.0) and AIB_RangedMeleePackSpacingStep() then
		AIB_Diag("visual-hold-dmg")
		bot.aib_holdAnchorLoc = loc; bot.aib_holdAnchorTime = now
		return true
	end
	if reason == "empty" then
		local dest = GetLaneFrontLocation(GetTeam(), botAssignedLane, 0)
		if dest == nil then
			local twr = GetTower(GetOpposingTeam(), TOWER_MID_1)
			if twr ~= nil and twr:IsAlive() then dest = twr:GetLocation() end
		end
		if dest ~= nil and GetUnitToLocationDistance(bot, dest) > 260 then
			bot:Action_MoveToLocation(dest)
			AIB_Diag("visual-hold-lane")
			bot.aib_holdAnchorLoc = loc; bot.aib_holdAnchorTime = now
			return true
		end
	end
	return false
end

local function AIB_EnemyDeadRecently()
	return bot.aib_eDeadSince ~= nil and DotaTime() - bot.aib_eDeadSince < 45.0
end

local function AIB_SiegeIntent(dials, rules)
	local twr = AIB_EnemyTowerDanger()
	if twr == nil or AIB_TowerActuallyThreatening(twr) then return false end
	local cwp = rules.creep_wave_priority or "last_hit_only"
	local enemy, enemyDist = AIB_NearestEnemyHero(2200)
	local enemyFarOrWeak = enemy == nil or enemyDist > 1300 or J.GetHP(enemy) < 0.28
	local waveAtTower = false
	for _, creep in pairs(nAllyCreeps or {}) do
		if J.IsValid(creep) and GetUnitToUnitDistance(creep, twr) <= twr:GetAttackRange() + 180 then
			waveAtTower = true; break
		end
	end
	local advantageSiege = AIB_EnemyDeadRecently() or (waveAtTower and enemyFarOrWeak)
	local wantsSiege = cwp == "push" or advantageSiege or (dials.push_desire or 0.5) >= 0.65
	-- When the enemy is dead the tower is undefended, so keep sieging at lower HP rather than
	-- aborting and walking off (match 8862431491: pusher bailed mid-window and lost its own tower).
	local siegeHpFloor = AIB_EnemyDeadRecently() and 0.22 or 0.35
	if not wantsSiege or J.GetHP(bot) < siegeHpFloor then
		AIB_WantBlocked("siege", "desire_or_hp", string.format("hp=%.0f adv=%s", J.GetHP(bot) * 100, tostring(advantageSiege)), 5.0)
		return false
	end

	local alliedTank = false
	local target = twr:GetAttackTarget()
	if target ~= nil and target:GetTeam() == GetTeam() then alliedTank = true end
	if not alliedTank then
		for _, creep in pairs(nAllyCreeps or {}) do
			if J.IsValid(creep) and GetUnitToUnitDistance(creep, twr) <= twr:GetAttackRange() + 120 then
				alliedTank = true; break
			end
		end
	end
	if not alliedTank then
		AIB_WantBlocked("siege", "no_allied_tank", string.format("tower=%.0f", GetUnitToUnitDistance(bot, twr)), 5.0)
		return false
	end

	local now = DotaTime()
	if bot.aib_siegeCommitUntil ~= nil and now <= bot.aib_siegeCommitUntil then
		if GetUnitToUnitDistance(bot, twr) <= (botAttackRange or bot:GetAttackRange()) + 60 then
			bot:Action_AttackUnit(twr, true)
			AIB_Diag("siege-commit-tower")
			return true
		end
		return AIB_MoveToAttackEdgeOf(twr, "siege-commit-step", 30)
	end

	for _, creep in pairs(nEnemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= (botAttackRange or bot:GetAttackRange()) + 40 then
			bot.aib_siegeCommitUntil = now + 1.6
			bot:Action_AttackUnit(creep, true)
			AIB_Diag("siege-creep")
			return true
		end
	end
	if GetUnitToUnitDistance(bot, twr) <= (botAttackRange or bot:GetAttackRange()) + 60 then
		bot.aib_siegeCommitUntil = now + 1.6
		bot:Action_AttackUnit(twr, true)
		AIB_Diag("siege-tower")
		return true
	end
	if bot.aib_siegeLast == nil or now - bot.aib_siegeLast >= 1.0 then
		bot.aib_siegeLast = now
		bot.aib_siegeCommitUntil = now + 1.6
		AIB_MoveToAttackEdgeOf(twr, "siege-step", 30)
	else
		Style.DiagRL(bot, "siege-hold", 5)
	end
	return true
end

local function AIB_ContactHeroStep(rules)
	rules = rules or {}
	if (rules.hero_priority or "default") == "never" then return false end

	local range = botAttackRange or bot:GetAttackRange()
	local enemy, dist = AIB_NearestEnemyHero(math.max(range + 140, 650))
	if enemy == nil then return false end

	local now = DotaTime()
	if bot.aib_contactHeroLast ~= nil and now - bot.aib_contactHeroLast < 0.65 then
		return false
	end

	local hp = J.GetHP(bot)
	if hp < 0.32 then
		local safe = AIB_ForwardSurvivingTowerLoc()
		if safe ~= nil and GetUnitToLocationDistance(bot, safe) > 120 then
			bot.aib_contactHeroLast = now
			Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=low_hp_kite", dist, hp * 100))
			bot:Action_MoveToLocation(safe)
			AIB_Diag("hero-contact-kite")
			return true
		end
		AIB_WantBlocked("hero-contact", "low_hp_no_safe", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
		return false
	end

	if dist <= range + 80 then
		if dist > range and AIB_UphillMiss(enemy) then
			AIB_WantBlocked("hero-contact", "uphill", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
			return false
		end
		bot.aib_contactHeroLast = now
		bot.aib_harassLast = now
		Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=attackable_enemy", dist, hp * 100))
		bot:Action_AttackUnit(enemy, false)
		AIB_Diag("hero-contact-atk")
		return true
	end

	if hp >= 0.45 and AIB_EnemyTowerDanger() == nil and not AIB_UphillMiss(enemy) then
		bot.aib_contactHeroLast = now
		Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=close_enemy", dist, hp * 100))
		return AIB_MoveToAttackEdgeOf(enemy, "hero-contact-chase", 0)
	end

	AIB_WantBlocked("hero-contact", "unsafe", string.format("dist=%.0f hp=%.0f tower=%s", dist, hp * 100, tostring(AIB_EnemyTowerDanger() ~= nil)), 3.0)
	return false
end

local function AIB_AbilityPressureStep()
	if J.GetHP(bot) < 0.30 then return false end
	local enemy, dist = AIB_NearestEnemyHero(900)
	if enemy == nil or not enemy:IsAlive() then return false end
	local twr = AIB_EnemyTowerDanger()
	if twr ~= nil and AIB_TowerActuallyThreatening(twr) and not Style.MayDive(bot) then
		AIB_WantBlocked("ability-pressure", "tower", string.format("dist=%.0f", dist), 3.0)
		return false
	end
	if Style.AbilityExecute(bot, enemy) then return true end
	if J.GetHP(enemy) - J.GetHP(bot) > 0.35 then
		AIB_WantBlocked("ability-pressure", "hp_disadv", string.format("dist=%.0f hp=%.0f ehp=%.0f", dist, J.GetHP(bot)*100, J.GetHP(enemy)*100), 3.0)
		return false
	end
	if Style.AbilityHarass(bot, enemy) then return true end
	return false
end

local function AIB_PreCreepStandoffStep()
	local now = DotaTime()
	if now < 0 or now > 45 then return false end
	local function hasNearbyLaneCreep(list)
		for _, creep in pairs(list or {}) do
			if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= 900 then
				return true
			end
		end
		return false
	end
	if hasNearbyLaneCreep(nEnemyCreeps) or hasNearbyLaneCreep(nAllyCreeps) then return false end

	local range = botAttackRange or bot:GetAttackRange()
	local enemy, dist = AIB_NearestEnemyHero(range + 80)
	local preMode = GetRules().pregame_behavior or "default"
	if preMode == "aggressive_mid" and enemy ~= nil and dist <= range + 20
		and not AIB_UphillMiss(enemy) and J.GetHP(bot) >= 0.70 then
		bot:Action_AttackUnit(enemy, false)
		AIB_Diag("precreep-trade")
		return true
	end

	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
	if ownT1 ~= nil and enmT1 ~= nil then
		local a, b = ownT1:GetLocation(), enmT1:GetLocation()
		local totalDist = math.sqrt((b.x-a.x)^2 + (b.y-a.y)^2)
		if totalDist > 1 then
			local dirX, dirY = (b.x-a.x)/totalDist, (b.y-a.y)/totalDist
			local anchorDist = math.min(totalDist * 0.46, totalDist - range - 250)
			local anchor = Vector(a.x + dirX * anchorDist, a.y + dirY * anchorDist, a.z)
			local anchorGap = GetUnitToLocationDistance(bot, anchor)
			if anchorGap <= 160 then
				if enemy ~= nil and dist < range * 0.70 then
					local back = AIB_TowardFountainFrom(bot:GetLocation(), 260)
					if back ~= nil then
						bot:Action_MoveToLocation(back)
						AIB_Diag("precreep-space")
						return true
					end
				end
				Style.DiagRL(bot, "precreep-hold", 5)
				return true
			end
			bot:Action_MoveToLocation(anchor)
			AIB_Diag("precreep-anchor")
			return true
		end
	end
	return false
end

local function ThinkPregame(dials)
	if DotaTime() >= 0 or GetGameMode() ~= GAMEMODE_1V1MID then return false end
	if AIBSurvive.Think(bot, dials, nil) then return true end
	Style.DiagRL(bot, "pg-pos", 5)
	local pgb = GetRules().pregame_behavior
	if pgb == "water_rune" then
		local runeLoc, minD = nil, math.huge
		for _, rid in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
			local loc = GetRuneSpawnLocation(rid)
			if loc then
				local d = GetUnitToLocationDistance(bot, loc)
				if d < minD then minD = d; runeLoc = loc end
			end
		end
		if runeLoc and GetUnitToLocationDistance(bot, runeLoc) > 100 then
			bot:Action_MoveToLocation(runeLoc)
		end
	else
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if ownT1 ~= nil and enmT1 ~= nil then
			local a, b = ownT1:GetLocation(), enmT1:GetLocation()
			local totalDist = math.sqrt((b.x-a.x)^2 + (b.y-a.y)^2)
			local dirX, dirY = (b.x-a.x)/totalDist, (b.y-a.y)/totalDist
			local dist
			if     pgb == "safe_tower"       then dist = 500
			elseif pgb == "aggressive_mid"   then dist = totalDist * 0.45
			elseif pgb == "jungle_pressure"  then dist = totalDist * 0.70
			else                                  dist = totalDist * (dials.forwardness or 0.5)
			end
			local target = Vector(a.x + dirX*dist, a.y + dirY*dist, a.z)
			if GetUnitToLocationDistance(bot, target) > 100 then
				bot:Action_MoveToLocation(target)
			end
		end
	end
	return true
end

-- Enemy tower: pull back when dive policy forbids it; redirect tower aggro when diving.
-- Returns true when Think() should exit.
local function ThinkDivePolicy()
	local twr = AIB_EnemyTowerDanger()
	if twr == nil then return false end
	if not Style.MayDive(bot) and AIB_TowerActuallyThreatening(twr) then
		AIB_Diag("no-dive")
		bot:Action_MoveToLocation(J.VectorAway(bot:GetLocation(), twr:GetLocation(), 350))
		return true
	end
	if AIB_TowerAggroDrop(twr) then return true end
	return false
end

-- Enemy is dead: heal up, farm aggressively, push the lane. Returns true when Think() should exit.
local function ThinkDeathWindow()
	-- Cache enemy PID when first seen alive, then track deaths via GetHeroDeaths.
	-- GetTeamMember returns nil for dead bots; IsAlive() approach is unreliable.
	if bot.aib_ePID == nil then
		local allNear = bot:GetNearbyHeroes(2000, true, BOT_MODE_NONE)
		if allNear then
			for _, h in ipairs(allNear) do
				if h:IsHero() and not h:IsIllusion() then
					for pid = 0, 9 do
						if GetTeamMember(pid) == h then
							bot.aib_ePID = pid
							bot.aib_eDeathCount = GetHeroDeaths(pid)
							break
						end
					end
					if bot.aib_ePID then break end
				end
			end
		end
	end
	local eIsDead = false
	if bot.aib_ePID ~= nil then
		local deaths = GetHeroDeaths(bot.aib_ePID)
		if deaths > (bot.aib_eDeathCount or 0) then
			bot.aib_eDeathCount = deaths
			bot.aib_eDeadSince  = DotaTime()
		end
		local respawnWindow = 8 + 4 * (GetHeroLevel and GetHeroLevel(bot.aib_ePID) or 1)
		eIsDead = bot.aib_eDeadSince ~= nil
			and DotaTime() - bot.aib_eDeadSince < respawnWindow
	end
	if GetHeroKills ~= nil then
		local ok, kills = pcall(GetHeroKills, bot:GetPlayerID())
		if ok and type(kills) == "number" then
			if bot.aib_myKillCount == nil then
				bot.aib_myKillCount = kills
			elseif kills > bot.aib_myKillCount then
				bot.aib_myKillCount = kills
				bot.aib_eDeadSince = DotaTime()
				eIsDead = true
			end
		end
	end
	if not eIsDead then return false end
	Style.DiagRL(bot, "dw-active", 3)
	AIB_ClearRecoveryState()
	-- Heal only when the death window would still be dangerous. Otherwise spend the window
	-- on free farm and tower damage; passive recovery can happen between attacks.
	if J.GetHP(bot) < 0.38 or (J.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(4.0)) then
		for s = 0, 5 do
			local it = bot:GetItemInSlot(s)
			if it ~= nil and it:IsFullyCastable() then
				local nm = it:GetName()
				if nm == "item_flask" then
					bot:Action_UseAbilityOnEntity(it, bot)
					AIB_Diag("dw-heal"); return true
				elseif nm == "item_tango" then
					local trees = bot:GetNearbyTrees(400)
					if trees and trees[1] then
						bot:Action_UseAbilityOnTree(it, trees[1])
						AIB_Diag("dw-heal"); return true
					end
				end
			end
		end
	end
	-- Farm: attack any enemy creep in attack range (push the wave)
	local ec = bot:GetNearbyCreeps(botAttackRange + 50, true)
	if ec and #ec > 0 then
		for _, c in ipairs(ec) do
			if c:IsAlive() and J.CanBeAttacked(c) then
				bot:Action_AttackUnit(c, true)
				AIB_Diag("dw-farm"); return true
			end
		end
	end
	local twr = AIB_EnemyTowerDanger()
	if twr ~= nil and J.GetHP(bot) >= 0.25 and not AIB_TowerActuallyThreatening(twr) then
		if GetUnitToUnitDistance(bot, twr) <= (botAttackRange or bot:GetAttackRange()) + 60 then
			bot:Action_AttackUnit(twr, true)
			AIB_Diag("dw-tower"); return true
		end
		if AIB_MoveToAttackEdgeOf(twr, "dw-tower-step", 30) then return true end
	end
	-- No creeps in range: advance toward lane front (override botAhead)
	local dwDest = GetLaneFrontLocation(GetTeam(), botAssignedLane, 0)
	if dwDest == nil then
		local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if enmT1 ~= nil then dwDest = enmT1:GetLocation() end
	end
	if dwDest ~= nil and GetUnitToLocationDistance(bot, dwDest) > 150 then
		bot:Action_MoveToLocation(dwDest + RandomVector(50))
		Style.DiagRL(bot, "dw-fwd", 5)
		return true
	end
	return false
end

-- Main laning policy. Think() below only schedules high-level stages.
local function ThinkLaningCore(dials, rules)
	local cwp = rules.creep_wave_priority or "last_hit_only"
	local debugSkeleton = rules.debug_skeleton_laning == true
	local debugNoForward = debugSkeleton or rules.debug_disable_forwardness_fallbacks == true
	if debugSkeleton then
		Style.DiagRL(bot, "dbg-skeleton", 10)
	elseif debugNoForward then
		Style.DiagRL(bot, "dbg-no-fwd", 10)
	end
	local intentCtx = {
		bot = bot,
		dials = dials,
		rules = rules,
		enemyCreeps = nEnemyCreeps,
		assignedLane = botAssignedLane,
		attackRange = botAttackRange,
	}
	if J.GetHP(bot) < 0.22 and AIBSurvive.Think(bot, dials, nEnemyCreeps) then return end
	local urgentIntents = {}
	local urgentKill = AIBLaneTrade.KillLock(intentCtx)
	if urgentKill ~= nil then urgentIntents[#urgentIntents + 1] = urgentKill end
	local urgentInterrupt = AIBLaneTrade.HealInterrupt(intentCtx)
	if urgentInterrupt ~= nil then urgentIntents[#urgentIntents + 1] = urgentInterrupt end
	if AIBEngine.Resolve(urgentIntents, intentCtx) then return end

	if AIB_PreCreepStandoffStep() then return end
	if AIB_AbilityPressureStep() then return end
	if AIB_ContactHeroStep(rules) then return end
	if AIB_CreepHitReactStep() then return end
	if AIB_DamageUnstuckStep() then return end
	if J.GetHP(bot) < 0.55 and AIBSurvive.Think(bot, dials, nEnemyCreeps) then return end
	local intents = {}
	local killIntent = AIBLaneTrade.KillLock(intentCtx)
	if killIntent ~= nil then intents[#intents + 1] = killIntent end
	local creepIntent = AIBLaneSurvival.CreepAggroRelief(intentCtx)
	if creepIntent ~= nil then intents[#intents + 1] = creepIntent end
	local healInterruptIntent = AIBLaneTrade.HealInterrupt(intentCtx)
	if healInterruptIntent ~= nil then intents[#intents + 1] = healInterruptIntent end
	local passingHeroIntent = AIBLaneTrade.PassingHeroTrade(intentCtx)
	if passingHeroIntent ~= nil then intents[#intents + 1] = passingHeroIntent end
	if AIBEngine.Resolve(intents, intentCtx) then return end

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

	-- 1) grab a securable last-hit that's already in range
	if csAllowed and not needMove and csSoon ~= true then
		bot:SetTarget(hitCreep)
		bot:Action_AttackUnit(hitCreep, true)
		AIB_Diag("cs-inrange")
		return
	end

	if AIBSurvive.Think(bot, dials, nEnemyCreeps) then return end

	-- Global emergency retreat: critically low HP (<25%) and far from tower means go back now.
	-- Only fires at true emergency level; regen_lane handles the normal 25-45% range.
	do
		local holdThresh = 0.25
		if J.GetHP(bot) < holdThresh then
			local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
			if ownT1 ~= nil and GetUnitToUnitDistance(bot, ownT1) > 900 then
				local back = AIB_ForwardSurvivingTowerLoc()
				if back then
					if bot.aib_emergLast == nil or DotaTime() - bot.aib_emergLast >= 1.5 then
						bot.aib_emergLast = DotaTime()
						AIB_Diag("emerg-retreat")
						-- Shoot-and-scoot: fire ability at enemy before retreating (e.g. Raze while backing off).
						-- Only when HP > 15% so we don't waste cast time at death's door.
						if J.GetHP(bot) > 0.15 then
							local emergEnemies = bot:GetNearbyHeroes(800, true, BOT_MODE_NONE)
							if emergEnemies and #emergEnemies > 0 and emergEnemies[1]:IsAlive() then
								if Style.AbilityHarass(bot, emergEnemies[1]) then return end
							end
						end
						bot:Action_MoveToLocation(back); return
					end
				end
			end
		end
	end

	-- Forward low-HP pullback: being low on the ENEMY's half is the gap that emergency-retreat
	-- (HP<25%) and low-hp-hold (near OWN tower) both miss. Match 8862516153: the bot pushed onto
	-- the enemy side at 25-30% HP and was killed by the respawned enemy. Skip during the enemy-dead
	-- window -- that's a safe siege (fix #5), not an overextension.
	do
		local holdThresh = rules.low_hp_hold or 0.45
		if not debugSkeleton and J.GetHP(bot) < holdThresh and not AIB_EnemyDeadRecently() then
			local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
			local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
			if ownT1 ~= nil and enmT1 ~= nil
				and GetUnitToUnitDistance(bot, enmT1) < GetUnitToUnitDistance(bot, ownT1) then
				local back = AIB_ForwardSurvivingTowerLoc()
				if back and GetUnitToLocationDistance(bot, back) > 200 then
					if bot.aib_fwdPullLast == nil or DotaTime() - bot.aib_fwdPullLast >= 1.2 then
						bot.aib_fwdPullLast = DotaTime()
						AIB_Diag("fwd-lowhp-pull")
						bot:Action_MoveToLocation(back)
					end
					return
				end
			end
		end
	end

	-- Survival gate: if already died once, don't risk a second death at low HP.
	-- Second death = game over in 1v1 mid. Retreat instead of fighting.
	local aib_deathSurvive = GetHeroDeaths(bot:GetPlayerID()) >= 1 and J.GetHP(bot) < 0.40

	-- AIBattle: kill-priority. Enemy HP below execute_threshold means always attack.
	-- Runs before harass so a killable enemy is not ignored for a creep action.
	-- Opt-in: active only when execute_threshold > 0.
	if not aib_deathSurvive and (dials.execute_threshold or 0) > 0 then
		local atkHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if atkHero and #atkHero > 0 then
			local enemy = atkHero[1]
			if enemy:IsAlive() and J.GetHP(enemy) < dials.execute_threshold then
				bot:Action_AttackUnit(enemy, true)
				AIB_Diag("kill-priority"); return
			end
		end
	end

	-- Survival baseline: low HP near own tower limits risky actions, but it must not
	-- consume the tick by itself. Only take an active low-HP step when danger is present.
	local aib_lowHpHold = false
	local aib_lowHpDanger = false
	do
		local holdThresh = rules.low_hp_hold or 0.45
		if not debugSkeleton and holdThresh > 0 and J.GetHP(bot) < holdThresh then
			local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
			if ownT1 ~= nil and GetUnitToUnitDistance(bot, ownT1) < 900 then
				aib_lowHpHold = true
				Style.DiagRL(bot, "low-hp-limit", 3)
				if bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0) then
					aib_lowHpDanger = true
				else
					local nearHeroes = bot:GetNearbyHeroes(math.max(botAttackRange + 180, 850), true, BOT_MODE_NONE)
					aib_lowHpDanger = nearHeroes and #nearHeroes > 0 and nearHeroes[1]:IsAlive()
					if not aib_lowHpDanger then
						for _, creep in pairs(nEnemyCreeps or {}) do
							if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= botAttackRange + 180 then
								aib_lowHpDanger = true; break
							end
						end
					end
				end
			end
		end
	end
	if aib_lowHpHold and aib_lowHpDanger and AIB_ActiveLowHpStep() then return end

	-- Uphill repositioning: fires BEFORE harass; no trading from low ground.
	-- Target = own T1 location (guaranteed high ground). 350u-ahead offset overshoots the ramp.
	if not aib_lowHpHold then
		local uphEnemy = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
		if uphEnemy and #uphEnemy > 0 and uphEnemy[1]:IsAlive()
			and AIB_UphillMiss(uphEnemy[1]) then
			local ownT1uph = GetTower(GetTeam(), TOWER_MID_1)
			local highPos = (ownT1uph ~= nil and ownT1uph:IsAlive()) and ownT1uph:GetLocation()
				or AIB_ForwardSurvivingTowerLoc()
			if highPos and GetUnitToLocationDistance(bot, highPos) > 300 then
				bot:Action_MoveToLocation(highPos + RandomVector(50))
				AIB_Diag("uphill-reposition")
				return
			end
		end
	end

	-- 2) Harass hero (uphill already handled above; bot is on own ramp or has no terrain disadvantage).
	--    hero_priority=never skips entirely (pure creep focus).
	--    hero_priority=always bypasses farm_focus roll and hp-disadvantage gate.
	--    hero_priority=default attacks immediately when in range; farm_focus+harass_desire
	--                            gate only applies when enemy is out of range (seeking behaviour).
	local heroPrio = rules.hero_priority or "default"
	if heroPrio ~= "never" then
		local atkHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if atkHero and #atkHero > 0 and atkHero[1]:IsAlive() then
			if heroPrio == "always" then
				-- yield to last-hit movement so hero attacks don't block securing creeps
				if not (csAllowed and needMove) then
					bot:Action_AttackUnit(atkHero[1], false)
					AIB_Diag("hero-prio-always"); return
				end
			else
				local inRange = GetUnitToUnitDistance(bot, atkHero[1]) <= botAttackRange
				-- harass_desire controls rate: hd=1.0 gives 0.5s CD, hd=0.0 gives 2.5s CD.
				local harassCD = 0.5 + (1.0 - (dials.harass_desire or 0.5)) * 2.0
				local harassReady = bot.aib_harassLast == nil
					or DotaTime() - bot.aib_harassLast >= harassCD
				if inRange and AIB_EnemyTowerDanger() == nil and not aib_deathSurvive
					and harassReady then
					bot.aib_harassLast = DotaTime()
					bot:Action_AttackUnit(atkHero[1], false)
					AIB_Diag("harass-atk")
					return
				elseif not inRange and math.random() > (dials.farm_focus or 0.5) then
					if math.random() < (dials.harass_desire or 0.5)
						and not AIB_UphillMiss(atkHero[1]) then
						bot:Action_AttackUnit(atkHero[1], false)
						AIB_Diag("harass-seek")
						return
					end
				end
			end
		elseif heroPrio == "always" then
			-- suppress chase when regen_lane should be retreating (HP below its threshold)
			local rc = dials.retreat_caution or 0.5
			local regenThresh = 0.40 + 0.15 * rc
			local shouldRegen = rules.low_hp_behavior == "regen_lane"
				and J.GetHP(bot) < regenThresh
			if not shouldRegen then
				local chase = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
				if chase and #chase > 0 and chase[1]:IsAlive() then
					local chaseDist = GetUnitToUnitDistance(bot, chase[1])
					local creepNear = AIB_HasAttackableEnemyCreep(botAttackRange + 120)
					local hpAdvChase = chaseDist <= 700
						and J.GetHP(bot) >= J.GetHP(chase[1]) + 0.08
						and J.GetHP(bot) >= 0.45
						and AIB_EnemyTowerDanger() == nil
						and not AIB_UphillMiss(chase[1])
					if hpAdvChase or (chaseDist <= 950 and not csAllowed and not creepNear) then
						AIB_MoveToAttackEdge(chase[1], "hero-prio-chase"); return
					end
					AIB_WantBlocked("hero-prio-chase", "lane_work", string.format("dist=%.0f cs=%s creep=%s hp_adv=%s", chaseDist, tostring(csAllowed), tostring(creepNear), tostring(hpAdvChase)), 3.0)
				end
			end
		end
	end

	-- 3) walk toward last-hit creep, but stop at attack-range edge (not inside pack).
	-- For ranged heroes: calculate a safe point at (attackRange-50) from the creep in our direction.
	-- Melee heroes: walk directly (Action_MoveToUnit), engine handles range.
	-- Cap: don't chase killable creep beyond 1.5x attack range so positioning can still recover.
	-- when bot is returning from death and a pushed creep wave sits just out of range.
	local csDist = csAllowed and needMove and (csDistNow or GetUnitToUnitDistance(bot, hitCreep))
	if csAllowed and needMove and csDist <= botAttackRange * 1.5 then
		if csSoon == true and csDist <= botAttackRange - 35 then
			Style.DiagRL(bot, "cs-wait", 2)
			return
		end
		AIB_Diag("cs-walk")
		AIB_MoveToAttackEdgeOf(hitCreep, nil, 20)
		return
	end
	if AIB_RangedMeleePackSpacingStep() then return end
	if AIB_LastHitWatchdogStep() then return end

	-- creep_wave_priority = push: attack any in-range enemy creep (not just last-hit window).
	-- Guard: only push when allied creeps are nearby (<500) so aggro is shared with the wave.
	-- Without this, the bot pulls the entire enemy wave alone and takes constant creep damage.
	if cwp == "push" and AIB_EnemyTowerDanger() == nil then
		local allyNear = false
		for _, a in pairs(nAllyCreeps or {}) do
			if J.IsValid(a) and GetUnitToUnitDistance(bot, a) <= 500 then
				allyNear = true; break
			end
		end
		if allyNear then
			for _, c in pairs(nEnemyCreeps or {}) do
				if J.IsValid(c) and J.CanBeAttacked(c)
					and GetUnitToUnitDistance(bot, c) <= botAttackRange then
					bot:Action_AttackUnit(c, true)
					AIB_Diag("cw-push"); return
				end
			end
		end
	end
	if AIB_SiegeIntent(dials, rules) then return end

	-- deny_policy: never = skip; always = wider window (HP<60%); default = kill-guarantee only.
	local denyPol = rules.deny_policy or "default"
	if denyPol ~= "never" then
		local denyCreep
		if denyPol == "always" then
			for _, c in pairs(nAllyCreeps or {}) do
				if J.IsValid(c) and J.GetHP(c) < 0.60 and J.CanBeAttacked(c) then
					denyCreep = c; break
				end
			end
		else
			denyCreep = GetBestDenyCreep(nAllyCreeps)
		end
		if J.IsValid(denyCreep) then
			-- Skip deny if the target would pull the bot backward toward own tower.
			-- Threshold: creep is 250+ units closer to own T1 than the bot, so it is not worth going back.
			local skipDeny = false
			local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
			if ownT1 ~= nil then
				local botDistT1  = GetUnitToUnitDistance(bot, ownT1)
				local creepDistT1 = GetUnitToUnitDistance(denyCreep, ownT1)
				if creepDistT1 < botDistT1 - 250 then
					skipDeny = true
				end
			end
			if not skipDeny then
				bot:SetTarget(denyCreep)
				if GetUnitToUnitDistance(bot, denyCreep) <= botAttackRange + 40 then
					bot:Action_AttackUnit(denyCreep, true)
				else
					AIB_MoveToAttackEdgeOf(denyCreep, nil, 20)
				end
				AIB_Diag("deny-act"); return
			end
		end
	end

	local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
	local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
	-- HP-aware safe offset: at full HP push closer to creep front (200u); at low HP stay further back (600u).
	-- Stops bots from camping defensively near T1 when healthy with enemy not immediately threatening.
	local hpScale    = math.max(0.0, math.min(1.0, (J.GetHP(bot) - 0.5) / 0.5))  -- 0 at HP<=50%, 1 at HP=100%
	local safeOffset = math.floor(nLongestAttackRange * (1.0 - 0.65 * hpScale))   -- 600u at 50% HP, ~210u at 100%
	local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -safeOffset)
	if fLaneFrontAmount_enemy < fLaneFrontAmount then
		target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -safeOffset)
	end

	-- AIBattle: hero-specific ability harass + execute, driven by ability_aggro / execute_threshold dials.
	-- Covers all targeting types (unit, point, directional, no_target) via HeroAbilityConfig in
	-- aibattle_style.lua. Heroes not in the config return false and fall through silently.
	-- Execute is checked first (higher priority: kill a fleeing enemy over general harassment).
	-- AbilityHarass shares the same HP-disadvantage gate as auto-attack harass above.
	do
		local nearEnemies = bot:GetNearbyHeroes(1000, true, BOT_MODE_NONE)
		if nearEnemies and #nearEnemies > 0 and nearEnemies[1]:IsAlive() then
			local abilEnemy = nearEnemies[1]
			if Style.AbilityExecute(bot, abilEnemy) then return end
			local hpDisadvAbil = J.GetHP(abilEnemy) - J.GetHP(bot) > 0.40
			if not hpDisadvAbil and Style.AbilityHarass(bot, abilEnemy) then return end
		end
	end

	-- Forwardness is only a final lane-positioning preference. Keep it rare and
	-- quiet: it must yield to combat, creep damage, recovery/rune commits, CS,
	-- low-HP limits, siege commits, and tower safety.
	local pressureEnemy = AIB_NearestEnemyHero(math.max(botAttackRange + 180, 700))
	local attackableCreep = AIB_HasAttackableEnemyCreep(botAttackRange + 30)
	local nowFwd = DotaTime()
	local pendingLastHit = csAllowed and (csDistNow or math.huge) <= botAttackRange * 1.8
	local recentRecovery = bot.aib_recMoveLast ~= nil and nowFwd - bot.aib_recMoveLast < 2.5
	local recentCreepRelief = bot.aib_creepReliefLast ~= nil and nowFwd - bot.aib_creepReliefLast < 1.8
	local runeCommit = bot.aib_bottleRuneStarted ~= nil and nowFwd - bot.aib_bottleRuneStarted < 22.0
	local siegeCommit = bot.aib_siegeCommitUntil ~= nil and nowFwd <= bot.aib_siegeCommitUntil
	local suppressForward = pressureEnemy ~= nil
		or attackableCreep
		or pendingLastHit
		or aib_lowHpHold
		or recentRecovery
		or recentCreepRelief
		or runeCommit
		or siegeCommit
		or bot:WasRecentlyDamagedByCreep(2.0)
		or (J.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(2.0))
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
		if dest ~= nil and GetUnitToLocationDistance(bot, dest) > 520 then
			if bot.aib_fwdLast == nil or nowFwd - bot.aib_fwdLast >= 3.5
				or GetUnitToLocationDistance(bot, dest) > 1050 then
				bot.aib_fwdLast = nowFwd
				bot:Action_MoveToLocation(dest)
				AIB_Diag("fwd-position")
			else
				Style.DiagRL(bot, "fwd-hold", 5)
			end
			return
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
		else
			Style.DiagRL(bot, "fwd-suppressed-tower", 5)
		end
	end

	-- AIBattle: anti-idle fallback - reached when forwardness had no dest OR bot is already at target.
	-- Attack a visible enemy or move to assist an ally in combat.
	if AIB_VisualHoldHeartbeatStep() then return end
	if AIB_VisualAFKStep(rules) then return end
	Style.DiagRL(bot, "pre-aig", 3)
	Style.AntiIdleGlobal(bot)
end

local LANING_STAGES = {
	AIBEngine.Stage("pregame", function(ctx) return ThinkPregame(ctx.dials) end),
	AIBEngine.Stage("dive", function() return ThinkDivePolicy() end),
	AIBEngine.Stage("death-window", function() return ThinkDeathWindow() end),
	AIBEngine.Stage("laning-core", function(ctx)
		ThinkLaningCore(ctx.dials, ctx.rules)
		return true
	end),
}

-- AIBattle: Think() defined unconditionally so the engine always has a callable function.
-- Vanilla only defined it inside a condition that's false for normal heroes in all-bot games,
-- causing EXC_GUARD when the engine tried to call nil.
function Think()
	if local_mode_laning_generic then local_mode_laning_generic.Think(); return end
	if AIB_HandleRespawn() then return end

	local style = Style.Get()
	local ctx = {
		dials = style.dials,
		rules = style.rules,
		bot = bot,
	}

	ThinkAnnounce(ctx.dials)
	ThinkLocationReport()
	AIBEngine.Run(LANING_STAGES, ctx)
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

