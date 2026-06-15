local Utils = require( GetScriptDirectory()..'/FunLib/utils')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')

local Version      = require(GetScriptDirectory()..'/FunLib/version')
local Localization = require(GetScriptDirectory()..'/FunLib/localization')


local bot = GetBot()
local botName = bot:GetUnitName()
-- IsInvulnerable убрано из guard: в прегейме бот invulnerable на фонтане, что ломало
-- загрузку модуля целиком (GetDesire/Think никогда не определялись).
-- Invulnerability проверяется в runtime внутри GetDesire() для нормальных случаев.
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
local _healOk, _healResult = pcall(require, GetScriptDirectory()..'/FunLib/aibattle_heal')
local AIBHeal = _healOk and _healResult or { Think = function() return false end }
if not _healOk then
    -- Emit once to all-chat so it shows in console.log during test matches
    local _b = GetBot(); if _b then _b:ActionImmediate_Chat("AIB HEAL LOAD ERR: " .. tostring(_healResult), true) end
end
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

-- AIBattle: tower aggro drop cooldown (per bot instance)
local aib_lastAggroDrop = 0

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

-- AIBattle: tower aggro drop — attack an allied creep to redirect enemy tower fire onto it.
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
	if tp == nil then Style.DiagRL(bot, "respawn-no-tp", 5); return false end
	if not tp:IsFullyCastable() then Style.DiagRL(bot, "respawn-tp-cd", 5); return false end

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
	-- IsInvulnerable убрано: бот у фонтана invulnerable → DESIRE_NONE → Think() не вызывается →
	-- AIB_ThinkPreGame() не срабатывает → бот никогда не уходит с фонтана (catch-22).
	-- Invulnerability во время боя (BKB и т.п.) не мешает лейнинг-логике.
	if not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return BOT_MODE_DESIRE_NONE end
	if bot:IsAlive() and bot.aib_wasDead then return BOT_MODE_DESIRE_ABSOLUTE end
	local botLV = bot:GetLevel()
	local currentTime = DotaTime()

	botAttackRange = bot:GetAttackRange()
	local _ok, _res
	_ok, _res = pcall(function() return bot:GetNearbyLaneCreeps(1200, false) end)
	nAllyCreeps  = (_ok and type(_res) == "table") and _res or {}
	_ok, _res = pcall(function() return bot:GetNearbyLaneCreeps(800, true) end)
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
			-- AIBattle: regen_lane handles its own retreat logic in Think() — keep laning active
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
	if not hCreepList then return nil end
	-- dmgDelta=1.5: wider window so bot pursues creeps at ~150 HP (was 0.7 → missed 100-130 HP range).
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
	-- Split into two messages: Dota silently drops chat messages > ~160 chars.
	if not bot.aib_announced then
		bot.aib_announced = true
		-- Name announce: public chat (false), fixes spectator UI nickname quirk.
		bot:ActionImmediate_Chat("▶ " .. bot:GetName() .. " [" .. AIB_SIDE .. "]", false)
		-- MSG1: combat dials (~105 chars)
		bot:ActionImmediate_Chat(string.format(
			"AIB[%s] harass=%.2f farm=%.2f fwd=%.2f abil=%.2f rune=%.2f retreat=%.2f exec=%.2f gank=%.2f push=%.2f",
			AIB_SIDE,
			dials.harass_desire, dials.farm_focus, dials.forwardness, dials.ability_aggro,
			dials.rune_control, dials.retreat_caution, dials.execute_threshold,
			dials.gank_desire, dials.push_desire), true)
		-- MSG2: secondary dials + rules (~115 chars)
		local r = Style.Get().rules
		bot:ActionImmediate_Chat(string.format(
			"AIB[%s] defend=%.2f ward=%.2f roshan=%.2f dive=%s heal=%s abil=%s cw=%s at=%s",
			AIB_SIDE,
			dials.defend_desire, dials.ward_desire, dials.roshan_desire,
			tostring(r.dive_policy or "finish_only"),
			tostring(r.healing_style or "default"),
			tostring(r.ability_usage or "default"),
			tostring(r.creep_wave_priority or "last_hit_only"),
			tostring(r.ability_timing or "on_cooldown")), true)
	end

	-- Pre-game 1v1: position before the horn based on pregame_behavior rule.
	-- safe_tower=0.15 (own T1 front), aggressive_mid=0.45 (river), jungle_pressure=0.70 (deep).
	-- Falls back to dials.forwardness if rule is unset.
	if DotaTime() < 0 and GetGameMode() == GAMEMODE_1V1MID then
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if ownT1 ~= nil and enmT1 ~= nil then
			local pgb = GetRules().pregame_behavior
			local t
			if     pgb == "safe_tower"       then t = 0.15
			elseif pgb == "aggressive_mid"   then t = 0.45
			elseif pgb == "jungle_pressure"  then t = 0.70
			else                                  t = dials.forwardness or 0.5
			end
			local a, b = ownT1:GetLocation(), enmT1:GetLocation()
			local target = Vector(a.x + (b.x-a.x)*t, a.y + (b.y-a.y)*t, a.z)
			if GetUnitToLocationDistance(bot, target) > 100 then
				bot:Action_MoveToLocation(target)
			end
		end
		return
	end

	-- AIBattle rule (dive_policy): don't sit in enemy tower range unless the rule + situation allow
	-- it. Fixes bots farming/standing under the tower and burning for no reason. Laning-only —
	-- push/siege runs in another mode, so this never blocks taking towers. Style.MayDive applies the
	-- policy (never/finish_only/when_grouped/when_ahead/always). Diag 'no-dive' counts pull-outs.
	do
		local twr = AIB_EnemyTowerDanger()
		if twr ~= nil and not Style.MayDive(bot) then
			AIB_Diag("no-dive")
			bot:Action_MoveToLocation(J.VectorAway(bot:GetLocation(), twr:GetLocation(), 350))
			return
		end
		-- AIBattle: if staying under enemy tower (dive allowed), attack an allied creep to redirect tower fire
		if twr ~= nil and AIB_TowerAggroDrop(twr) then return end
	end

	local cwp = Style.Get().rules.creep_wave_priority or "last_hit_only"

	local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)

	-- Last-hit / harass interleave (AIBattle): secure an IN-RANGE last-hit BEFORE heal check —
	-- attack is instant and safe even at low HP; heal can fire next tick if still needed.
	-- needMove simplified: only move when TRULY out of attack range (was: 0.8× caused bot to
	-- walk toward a creep already in range, wasting the last-hit window).
	local csLaneCheck = J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700)
	-- freeze: never use the push block, but still last-hit (wave stays frozen without proactive attacks)
	local csAllowed = J.IsValid(hitCreep) and csLaneCheck
	local needMove = csAllowed and (GetUnitToUnitDistance(bot, hitCreep) > botAttackRange)

	-- 1) grab a securable last-hit that's already in range
	if csAllowed and not needMove then
		bot:SetTarget(hitCreep)
		bot:Action_AttackUnit(hitCreep, true)
		return
	end

	if AIBHeal.Think(bot, dials, nEnemyCreeps) then return end

	-- AIBattle: kill-priority — враг HP < execute_threshold → всегда атаковать, без броска кубика.
	-- Перехватывает до harass (не тратить тик на крипа когда враг убиваем).
	-- Opt-in: работает только если execute_threshold > 0.
	if (dials.execute_threshold or 0) > 0 then
		local atkHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if atkHero and #atkHero > 0 then
			local enemy = atkHero[1]
			if enemy:IsAlive() and J.GetHP(enemy) < dials.execute_threshold then
				bot:Action_AttackUnit(enemy, true)
				AIB_Diag("kill-priority"); return
			end
		end
	end

	-- 2) Harass hero BEFORE kite: prevents kite-400 from pushing bot outside attack range.
	--    hero_priority=never  → skip entirely (pure creep focus).
	--    hero_priority=always → bypass farm_focus roll and hp-disadvantage gate.
	--    hero_priority=default → original probabilistic behaviour.
	local heroPrio = Style.Get().rules.hero_priority or "default"
	if heroPrio ~= "never" then
		local atkHero = bot:GetNearbyHeroes(botAttackRange + 50, true, BOT_MODE_NONE)
		if atkHero and #atkHero > 0 and atkHero[1]:IsAlive() then
			if heroPrio == "always" then
				-- yield to last-hit movement so hero attacks don't block securing creeps
				if not (csAllowed and needMove) then
					bot:Action_AttackUnit(atkHero[1], false)
					AIB_Diag("hero-prio-always"); return
				end
			elseif math.random() > (dials.farm_focus or 0.5) then
				if math.random() < (dials.harass_desire or 0.5) then
					bot:Action_AttackUnit(atkHero[1], false)
					return
				end
			end
		end
	end

	-- Kite melee creeps: ranged hero (attack range > 300) must not stand in melee attack range.
	-- CD 1.5s prevents jitter; "kite-creep" diag counts triggers.
	if botAttackRange > 300 then
		for _, c in pairs(nEnemyCreeps or {}) do
			if J.IsValid(c) and GetUnitToUnitDistance(bot, c) < 150 then
				if bot.aib_kiteLast == nil or DotaTime() - bot.aib_kiteLast >= 1.5 then
					bot.aib_kiteLast = DotaTime()
					local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
					local back = cen and J.VectorAway(bot:GetLocation(), cen, 400) or AIB_ForwardSurvivingTowerLoc()
					if back then AIB_Diag("kite-creep"); bot:Action_MoveToLocation(back); return end
				end
				break
			end
		end
	end

	-- 3) not harassing -> walk to the creep to secure it
	if csAllowed and needMove then
		bot:Action_MoveToUnit(hitCreep)
		return
	end

	-- creep_wave_priority = push: attack any in-range enemy creep (not just last-hit window).
	-- Guard: only push when allied creeps are nearby (<500) so aggro is shared with the wave.
	-- Without this, the bot pulls the entire enemy wave alone and takes constant creep damage.
	if cwp == "push" then
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

	-- deny_policy: never = skip; always = wider window (HP<60%); default = kill-guarantee only.
	local denyPol = Style.Get().rules.deny_policy or "default"
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
			bot:SetTarget(denyCreep)
			bot:Action_AttackUnit(denyCreep, true)
			AIB_Diag("deny-act"); return
		end
	end

	local fLaneFrontAmount = GetLaneFrontAmount(GetTeam(), botAssignedLane, false)
	local fLaneFrontAmount_enemy = GetLaneFrontAmount(GetOpposingTeam(), botAssignedLane, false)
	local nLongestAttackRange = math.max(botAttackRange, 250, nFurthestEnemyAttackRange)
	local target_loc = GetLaneFrontLocation(GetTeam(), botAssignedLane, -nLongestAttackRange)
	if fLaneFrontAmount_enemy < fLaneFrontAmount then
		target_loc = GetLaneFrontLocation(GetOpposingTeam(), botAssignedLane, -nLongestAttackRange)
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
			local hpDisadvAbil = J.GetHP(abilEnemy) - J.GetHP(bot) > 0.25
			if not hpDisadvAbil and Style.AbilityHarass(bot, abilEnemy) then return end
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

	-- forwardness: controls desired depth in lane (offset from creep front).
	-- Tower-lerp fallback fires when GetLaneFrontLocation returns nil (t=0-5, before creeps register).
	do
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
		if dest ~= nil then
			bot:Action_MoveToLocation(dest + RandomVector(50))
		end
	end

	-- AIBattle: anti-idle fallback — fires when laning mode has nothing to do (late game, empty
	-- lane, bot already at assigned position). Attack a visible enemy or move to assist an ally
	-- in combat. Covers the "bot stands under own T2 doing nothing for 2+ min" pattern.
	Style.AntiIdleGlobal(bot)
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

--[[
================================================================================
ARCHIVE: AIB_ThinkPreGame (disabled 2026-06-11, to rewrite from scratch)
--------------------------------------------------------------------------------
Purpose: custom pregame positioning based on rules.pregame_behavior dial.
  safe_tower       — 15% toward enemy T1 (in front of own tower)
  aggressive_mid   — 45% toward enemy T1 (river crossing)
  jungle_pressure  — 70% toward enemy T1 (deep into enemy half)
History: multiple iterations failed to fix bots standing AFK. Removed to restore
OHA default walk-to-lane behaviour. Preserve for future rewrite.
Notes:
  - GetEnemyTeam() may be undefined in OHA; use GetOpposingTeam() instead
  - GetLaneFrontLocation returns nil at t=0..5 before creeps register
  - In 1v1: no bounty runes; for 5v5 a role-based module is needed
--------------------------------------------------------------------------------

local function AIB_ThinkPreGame()
	AIB_Diag("pg-called")
	if not bot.aib_pgf then
		bot.aib_pgf = true
		bot:ActionImmediate_Chat("AIB-PGF t=" .. math.floor(DotaTime()), true)
	end
	local pgb = GetRules().pregame_behavior
	if pgb == nil then AIB_Diag("pg-no-pgb"); return false end

	local a, b
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)  -- NB: GetOpposingTeam() not GetEnemyTeam()
	if ownT1 ~= nil and enmT1 ~= nil then
		a = ownT1:GetLocation()
		b = enmT1:GetLocation()
	else
		a = GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
		b = GetLaneFrontLocation(GetOpposingTeam(), LANE_MID, 0)
		if a == nil or b == nil then AIB_Diag("pg-ref-nil"); return false end
	end

	local t = 0.15
	if pgb == "aggressive_mid"    then t = 0.45
	elseif pgb == "jungle_pressure" then t = 0.70 end
	local target = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z)

	if not bot.aib_pgDiag then bot.aib_pgDiag = true; AIB_Diag("pregame-" .. pgb) end

	if DotaTime() < 0 then
		if GetUnitToLocationDistance(bot, target) > 150 then
			if bot.aib_pgLast == nil or DotaTime() - bot.aib_pgLast >= 2.0 then
				bot.aib_pgLast = DotaTime(); bot:Action_MoveToLocation(target)
			end
		end
		return true
	end

	-- t >= 0: walk ahead of creep wave; falls back to deeper lerp until creeps register
	local advOffset = math.max(botAttackRange, 400)
	local walkTarget = GetLaneFrontLocation(GetTeam(), LANE_MID, advOffset)
	if walkTarget == nil then
		local tDeep = math.min(t + 0.20, 0.70)
		walkTarget = Vector(a.x + (b.x - a.x) * tDeep, a.y + (b.y - a.y) * tDeep, a.z)
	end
	if GetUnitToLocationDistance(bot, walkTarget) > 150 then
		if bot.aib_pgLast == nil or DotaTime() - bot.aib_pgLast >= 2.0 then
			bot.aib_pgLast = DotaTime(); bot:Action_MoveToLocation(walkTarget)
		end
		return true
	end
	return false
end

-- To re-enable: uncomment this function, then in Think() add:
--   if AIB_ThinkPreGame() then return end
-- and in GetDesire() add:
--   if DotaTime() < 0 then return 0.95 end
================================================================================
]]
