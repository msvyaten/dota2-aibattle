local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local Version      = require(GetScriptDirectory()..'/FunLib/version')
local Localization = require(GetScriptDirectory()..'/FunLib/localization')


local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end

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

if Utils.BuggyHeroesDueToValveTooLazy[botName] then local_mode_laning_generic = dofile( GetScriptDirectory().."/FunLib/override_generic/mode_laning_generic" ) end

-- AIBattle Schema v2: shared loader (dials + rules), with safe defaults/clamping.
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local function GetDials() return Style.Get().dials end
local function GetRules() return Style.Get().rules end
local function GetImp(name) return Style.Imp(name) end

-- AIBattle diag: count each branch firing silently, then emit ONE combined summary line at most
-- once per minute (only when something fired) so a TEST GAME yields measurable numbers without
-- spamming chat. Format 'AIB[R] anti-afk=15 heal-item=7'; the LAST such line in console.<id>.log
-- carries the cumulative totals. (print() is invisible in console.log, so chat is the only
-- logging channel — keep it sparse.)
local AIB_SIDE = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
-- Delegates to the shared counter (FunLib/aibattle_style M.Diag); kept as a thin local
-- wrapper so existing call sites stay unchanged. Counters live on the bot handle, so
-- laning + team-mode diags merge into the same summary line.
local function AIB_Diag(key)
	Style.Diag(bot, key)
end

-- AIBattle improvement helper: nearest ALIVE enemy tower whose attack range threatens the bot
-- (range ~700 + buffer). Returns the tower handle or nil.
local function AIB_EnemyTowerDanger()
	local opp = GetOpposingTeam()
	local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_TOP_1, TOWER_BOT_1, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
	for _, id in ipairs(ids) do
		local t = GetTower(opp, id)
		if t ~= nil and t:IsAlive() and GetUnitToUnitDistance(bot, t) < 900 then
			return t
		end
	end
	return nil
end

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

-- AIBattle: centroid of nearby enemy lane creeps (the threat to step away from). nil if none.
local function AIB_EnemyCreepCentroid(enemyCreeps)
	local cx, cy, n = 0, 0, 0
	for _, c in pairs(enemyCreeps or {}) do
		if J.IsValid(c) then
			local l = c:GetLocation()
			cx = cx + l.x; cy = cy + l.y; n = n + 1
		end
	end
	if n == 0 then return nil end
	return Vector(cx / n, cy / n, 0)
end

-- AIBattle: on death->alive transition, act per rules.respawn_behavior. Returns true if it issued an action.
local function AIB_HandleRespawn()
	if not bot:IsAlive() then bot.aib_wasDead = true; bot.aib_tping = false; return false end
	if not bot.aib_wasDead then return false end

	-- We already issued our TP: PROTECT THE CHANNEL so normal Think can't move the bot mid-cast
	-- (this was the tp_to_tower bug: clearing the flag on the cast tick let Think walk the bot
	-- toward creeps and cancel the 3s channel to a rear tower). Hold until the channel resolves.
	if bot.aib_tping then
		if bot:HasModifier("modifier_teleporting") then return true end          -- channelling: hold
		if (DotaTime() - (bot.aib_tpCastTime or 0)) < 1.0 then return true end    -- grace: modifier not applied yet
		bot.aib_wasDead = false; bot.aib_tping = false; return false             -- channel ended/interrupted
	end

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
	if bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
	if bot:IsAlive() and bot.aib_wasDead then return BOT_MODE_DESIRE_ABSOLUTE end
	local botLV = bot:GetLevel()
	local currentTime = DotaTime()

	botAttackRange = bot:GetAttackRange()
	nAllyCreeps = bot:GetNearbyLaneCreeps(1200, false)
	nEnemyCreeps = bot:GetNearbyLaneCreeps(800, true)
	nInRangeEnemy = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
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
	if currentTime < 0 then return BOT_ACTION_DESIRE_NONE end

	if J.GetEnemiesAroundAncient(bot, 3200) > 0 then
		return BOT_MODE_DESIRE_NONE
	end

	if bot:WasRecentlyDamagedByAnyHero(5)
	and #J.Utils.GetLastSeenEnemyIdsNearLocation(bot:GetLocation(), 800) > 0 then
		local nLaneFrontLocation = GetLaneFrontLocation(GetTeam(), bot:GetAssignedLane(), 0)
		local nDistFromLane = GetUnitToLocationDistance(bot, nLaneFrontLocation)
		if not J.WeAreStronger(bot, 1200) or (nDistFromLane > 700 and J.GetHP(bot) < 0.7) then
			return BOT_MODE_DESIRE_NONE
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

	if GetGameMode() == GAMEMODE_1V1MID or GetGameMode() == GAMEMODE_MO then
		return 1
	end

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
	local dmgDelta = attackDamage * 0.7

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

-- AIBattle: Think() defined unconditionally so the engine always has a callable function.
-- Vanilla only defined it inside a condition that's false for normal heroes in all-bot games,
-- causing EXC_GUARD when the engine tried to call nil.
function Think()
	if local_mode_laning_generic then
		local_mode_laning_generic.Think()
		return
	end

	if AIB_HandleRespawn() then return end
	local dials = GetDials()

	-- AIBattle: announce the loaded config once in chat (visible in console.log).
	if not bot.aib_announced then
		bot.aib_announced = true
		bot:ActionImmediate_Chat(string.format("AIB[%s] harass=%.2f farm=%.2f fwd=%.2f abil=%.2f rune=%.2f retreat=%.2f exec=%.2f gank=%.2f push=%.2f defend=%.2f ward=%.2f heal=%d afk=%d tower=%d abildial=%d",
			AIB_SIDE,
			dials.harass_desire, dials.farm_focus, dials.forwardness, dials.ability_aggro,
			dials.rune_control, dials.retreat_caution, dials.execute_threshold,
			dials.gank_desire, dials.push_desire, dials.defend_desire, dials.ward_desire,
			GetImp('defensive_heal') and 1 or 0, GetImp('anti_afk') and 1 or 0,
			GetImp('tower_avoid') and 1 or 0, GetImp('ability_on_dials') and 1 or 0), true)
	end

	-- AIBattle improvement (opt-in tower_avoid): don't sit in enemy tower range without a kill
	-- in progress. If inside an alive enemy tower's range and NOT finishing a low-HP hero, step
	-- out. Fixes bots walking under the tower and dying to it for no reason.
	if GetImp('tower_avoid') then
		local twr = AIB_EnemyTowerDanger()
		if twr ~= nil then
			local he = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
			local finishing = he and #he > 0 and he[1]:IsAlive() and J.GetHP(he[1]) < 0.35
			if not finishing then
				bot:Action_MoveToLocation(J.VectorAway(bot:GetLocation(), twr:GetLocation(), 350))
				return
			end
		end
	end

	-- AIBattle improvement (opt-in defensive_heal, HERO-AGNOSTIC): at low HP recover IN LANE via
	-- inventory items + pull back to safety, instead of plodding to fountain (which bleeds farm).
	-- Threshold scales with retreat_caution (cautious heals earlier). No hero spells — items only.
	-- Anti-thrash (fix for heal-item firing ~2x/s and starving farm): at most one heal attempt per
	-- HEAL_CD seconds, and NEVER skip a securable in-range last-hit to heal (free CS > a wand tick).
	-- Diag: 'heal-item' / 'heal-pullback'. NOTE: hitCreep/moveToCreep are computed once here and
	-- reused by the last-hit/harass interleave below.
	local HEAL_CD = 2.5
	local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)
	local lhSecurable = J.IsValid(hitCreep) and not moveToCreep
		and GetUnitToUnitDistance(bot, hitCreep) <= botAttackRange
	if GetImp('defensive_heal') and not lhSecurable
		and J.GetHP(bot) < (0.30 + 0.20 * (dials.retreat_caution or 0.5))
		and (bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD) then
		-- instant items: safe to pop any time
		for _, nm in ipairs({ "item_magic_wand", "item_magic_stick", "item_faerie_fire", "item_satanic" }) do
			local it = bot:GetItemInSlot(bot:FindItemSlot(nm))
			if it ~= nil and it:IsFullyCastable() then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(it); return
			end
		end
		local safe = not (bot:WasRecentlyDamagedByAnyHero(1.0) or bot:WasRecentlyDamagedByCreep(1.0))
		if safe then
			-- channel items (break on damage): only when not being hit
			local salve = bot:GetItemInSlot(bot:FindItemSlot("item_flask"))
			if salve ~= nil and salve:IsFullyCastable() then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbilityOnEntity(salve, bot); return
			end
			local bottle = bot:GetItemInSlot(bot:FindItemSlot("item_bottle"))
			if bottle ~= nil and bottle:IsFullyCastable() then
				bot.aib_healLast = DotaTime()
				bot:Action_UseAbility(bottle); return
			end
		else
			-- being hit, no instant heal -> pull back toward own tower to regen, don't keep fighting
			local back = AIB_ForwardSurvivingTowerLoc()
			if back then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-pullback")
				bot:Action_MoveToLocation(back); return
			end
		end
	end

	-- Last-hit / harass interleave (AIBattle): secure an IN-RANGE last-hit first (free CS,
	-- no repositioning), THEN harass with probability harass_desire, and only WALK to a
	-- creep when not harassing. Lets the bot farm AND harass instead of one killing the other.
	local csAllowed = J.IsValid(hitCreep) and (J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700))
	local needMove = csAllowed and (GetUnitToUnitDistance(bot, hitCreep) > botAttackRange
		or (moveToCreep and GetUnitToUnitDistance(bot, hitCreep) > botAttackRange * 0.8))

	-- 1) grab a securable last-hit that's already in range
	if csAllowed and not needMove then
		bot:SetTarget(hitCreep)
		bot:Action_AttackUnit(hitCreep, true)
		return
	end

	-- 2) harass the hero instead of walking off to a creep
	if math.random() > (dials.farm_focus or 0.5) then
		local atkHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if atkHero and #atkHero > 0 and atkHero[1]:IsAlive() and math.random() < (dials.harass_desire or 0.5) then
			bot:Action_AttackUnit(atkHero[1], true)
			return
		end
	end

	-- 3) not harassing -> walk to the creep to secure it
	if csAllowed and needMove then
		bot:Action_MoveToUnit(hitCreep)
		return
	end

	local denyCreep = GetBestDenyCreep(nAllyCreeps)
	if J.IsValid(denyCreep) then
		bot:SetTarget(denyCreep)
		bot:Action_AttackUnit(denyCreep, true)
		return
	end

	local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
	local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
	local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
	if fLaneFrontAmount_enemy < fLaneFrontAmount then
		target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
	end

	-- AIBattle Schema v2: dial-driven behaviour (0..1 dimmers)
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

	-- AIBattle improvement (opt-in ability_on_dials): generalize ability use beyond Sniper.
	-- Juggernaut Blade Fury (no-target AOE) — cast to harass a nearby enemy hero (harass_desire)
	-- or to push/farm a creep pack (farm_focus), so non-Sniper abilities are dial-driven instead
	-- of relying only on OHA's native (conservative) gating.
	if GetImp('ability_on_dials') then
		local bf = bot:GetAbilityByName("juggernaut_blade_fury")
		if bf and bf:IsFullyCastable() then
			local foe = bot:GetNearbyHeroes(280, true, BOT_MODE_NONE)
			if foe and #foe > 0 and foe[1]:IsAlive() and math.random() < (dials.harass_desire or 0.5) then
				bot:Action_UseAbility(bf); return
			end
			local creeps = bot:GetNearbyCreeps(280, true)
			if creeps and #creeps >= 3 and math.random() < (dials.farm_focus or 0.5) then
				bot:Action_UseAbility(bf); return
			end
		end
	end

	-- AIBattle: don't stand and tank enemy creep fire while idle. We only reach here when no
	-- in-range last-hit, walkable last-hit, or deny was available (those returned above), so the
	-- bot would otherwise just stand. If it's taking creep damage, step out of creep attack range.
	-- Gated on retreat_caution: aggressive bots (low caution) hold the line, cautious/passive bots
	-- back off; math.random()<rc makes it kite (step back / drift in) instead of robotically pinging.
	local rc = dials.retreat_caution or 0.5
	if rc >= 0.4 and bot:WasRecentlyDamagedByCreep(1.5) and math.random() < rc then
		local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
		local back = cen and J.VectorAway(bot:GetLocation(), cen, 400) or AIB_ForwardSurvivingTowerLoc()
		if back then bot:Action_MoveToLocation(back); return end
	end

	-- AIBattle: don't just stand facing the enemy between last-hits — act per dials so the
	-- matchup reads naturally. Aggressor (high harass) attacks the enemy hero when in range;
	-- farmer (high farm) auto-attacks creeps to keep busy/pushing instead of idling for the
	-- next last-hit window. Hero approach is left to forwardness below to avoid tower dives.
	do
		local antiAfk = GetImp('anti_afk')
		local enemyHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if enemyHero and #enemyHero > 0 and enemyHero[1]:IsAlive()
			and math.random() < (dials.harass_desire or 0.5) then
			bot:Action_AttackUnit(enemyHero[1], true)
			return
		end
		-- anti_afk: always act (prob 1.0); otherwise gated by farm_focus.
		local creepProb = antiAfk and 1.0 or (dials.farm_focus or 0.5)
		if nEnemyCreeps and #nEnemyCreeps > 0 and math.random() < creepProb then
			local nearest, nd = nil, 1e9
			for _, c in pairs(nEnemyCreeps) do
				if J.IsValid(c) and J.CanBeAttacked(c) then
					local d = GetUnitToUnitDistance(bot, c)
					if d <= botAttackRange then
						bot:Action_AttackUnit(c, true); return
					end
					if d < nd then nearest, nd = c, d end
				end
			end
			-- anti_afk: nothing in range -> walk to the nearest creep instead of standing idle
			if antiAfk and nearest then
				AIB_Diag("anti-afk")
				bot:Action_MoveToUnit(nearest); return
			end
		end
	end

	-- forwardness: high pushes to the lane front (validated v1 aggressive move);
	-- low holds position (no forced move -> bot last-hits / holds instead of ramming its tower).
	local fwd = dials.forwardness or 0.5
	if fwd >= 0.5 then
		bot:Action_MoveToLocation(target_loc + RandomVector(50))
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
