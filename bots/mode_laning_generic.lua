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

-- AIBattle: pre-game positioning (DotaTime < 0). Handles rules.pregame_behavior.
--
-- ⚠️  THIS MODULE IS 1v1 ONLY.
-- In 1v1 Solo Mid: no bounty runes spawn at 0:00, neutrals almost never attack →
-- OHA's default "go to runes" is useless, so we override with explicit positioning.
--
-- FOR 5v5: a SEPARATE team-coordinated module is needed (don't extend this one).
-- Key differences vs 1v1:
--   • Bounty runes DO spawn → pos4/pos5 should contest them (need role-based routing,
--     not all 5 bots going to the same point)
--   • Team options: rune_contest (pos4→top rune, pos5→bot rune), stack_camps (pos4
--     stacks a neutral camp before 0:00), ward_setup (pos5 places obs ward), lane_default
--     (everyone walks to their assigned lane). These require coordination between bots,
--     not just per-bot positioning.
--   • Implementation hint: read GetPosition(bot) and assign each bot a role-specific
--     target; share state via a team-global table if needed.
--
-- Current 1v1 options:
--   safe_tower       — hold 350 units in front of own mid T1 (15% toward enemy T1)
--   aggressive_mid   — hold river crossing (45% toward enemy T1)
--   jungle_pressure  — deep into enemy half (70% toward enemy T1); neutrals passive in 1v1
-- Only moves if >150 units away (avoids jitter). Rate-limits move commands to every 2s.
-- Diag: 'pregame-<value>' (rate-limited 5s).
local function AIB_ThinkPreGame()
	local pgb = GetRules().pregame_behavior
	if pgb == nil then Style.DiagRL(bot, "pg-no-pgb", 5.0); return false end

	-- Reference points for the lerp: try exact tower positions first (may be nil before game start),
	-- fall back to GetLaneFrontLocation which is geometry-based and always available.
	local a, b
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetEnemyTeam(), TOWER_MID_1)
	if ownT1 ~= nil and enmT1 ~= nil then
		a = ownT1:GetLocation()
		b = enmT1:GetLocation()
		Style.DiagRL(bot, "pg-ref-tower", 5.0)
	else
		a = GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
		b = GetLaneFrontLocation(GetEnemyTeam(), LANE_MID, 0)
		if a == nil or b == nil then Style.DiagRL(bot, "pg-ref-nil", 5.0); return false end
		Style.DiagRL(bot, "pg-ref-lane", 5.0)
	end

	-- lerp factor: fraction of the way from own reference toward enemy reference
	local t = 0.15
	if pgb == "aggressive_mid"    then t = 0.45
	elseif pgb == "jungle_pressure" then t = 0.70 end
	local target = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z)
	if GetUnitToLocationDistance(bot, target) > 150 then
		if bot.aib_pgLast == nil or DotaTime() - bot.aib_pgLast >= 2.0 then
			bot.aib_pgLast = DotaTime()
			bot:Action_MoveToLocation(target)
		end
	end
	Style.DiagRL(bot, "pregame-" .. pgb, 5.0)
	return true
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

	-- AIBattle: pregame positioning — first 45s of game (before creep wave reaches mid ~0:35).
	-- GetNearbyLaneCreeps is unreliable during invulnerable/PRE_GAME and can throw VScript errors,
	-- so we use only DotaTime as the guard. At t=45 laning takes over unconditionally.
	do
		local t0 = DotaTime()
		if GetGameMode() == 23 then t0 = t0 * 1.65 end
		if t0 >= 0 and t0 < 45 then
			local rules = GetRules()
			if rules ~= nil and rules.pregame_behavior ~= nil then
				return 0.95
			end
		end
	end

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
		-- Name announce: visible to all spectators (false = public chat), fixes client render quirk
		-- where bot nickname sometimes doesn't display in the observer UI.
		bot:ActionImmediate_Chat("▶ " .. bot:GetName() .. " [" .. AIB_SIDE .. "]", false)
		bot:ActionImmediate_Chat(string.format("AIB[%s] harass=%.2f farm=%.2f lane=%.2f fwd=%.2f abil=%.2f rune=%.2f retreat=%.2f exec=%.2f gank=%.2f push=%.2f defend=%.2f ward=%.2f roshan=%.2f dive=%s heal=%d afk=%d tower=%d abildial=%d",
			AIB_SIDE,
			dials.harass_desire, dials.farm_focus, dials.lane_activity, dials.forwardness, dials.ability_aggro,
			dials.rune_control, dials.retreat_caution, dials.execute_threshold,
			dials.gank_desire, dials.push_desire, dials.defend_desire, dials.ward_desire,
			dials.roshan_desire, tostring(Style.Get().rules.dive_policy) .. " smoke=" .. tostring(Style.Get().rules.smoke_usage) .. " bb=" .. tostring(Style.Get().rules.buyback_policy),
			GetImp('defensive_heal') and 1 or 0, GetImp('anti_afk') and 1 or 0,
			GetImp('tower_avoid') and 1 or 0, GetImp('ability_on_dials') and 1 or 0), true)
	end

	-- AIBattle: pre-game positioning — first 45s of game only.
	do
		local t0 = DotaTime()
		if GetGameMode() == 23 then t0 = t0 * 1.65 end
		if t0 >= 0 and t0 < 45 then
			AIB_ThinkPreGame(); return
		end
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

	-- AIBattle improvement (opt-in defensive_heal, HERO-AGNOSTIC): at low HP recover IN LANE via
	-- inventory items + pull back to safety, instead of plodding to fountain (which bleeds farm).
	-- Threshold scales with retreat_caution (cautious heals earlier). No hero spells — items only.
	-- Anti-thrash (fix for heal-item firing ~2x/s and starving farm): at most one heal attempt per
	-- HEAL_CD seconds, and NEVER skip a securable in-range last-hit to heal (free CS > a wand tick).
	-- Diag: 'heal-item' / 'heal-pullback'. NOTE: hitCreep/moveToCreep are computed once here and
	-- reused by the last-hit/harass interleave below.
	local HEAL_CD = 2.5
	local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)

	-- ============================================================
	-- AIBattle: хил-система (defensive_heal, opt-in).
	-- Каждый предмет — своя логика и свой порог. Враги НЕ условие для хила.
	-- Два CD-трека: HEAL_CD (HP-предметы) и MANA_CD (мана-предметы) — не мешают друг другу.
	-- Порядок: tango (проактив 65%) → bottle (HP+mana) → mango (mana крит) →
	--   wand/stick (instant mid) → ff/satanic (emergency) → clarity (mana safe) → flask (HP safe).
	-- ============================================================
	if GetImp('defensive_heal') then
		local hp      = J.GetHP(bot)
		local maxMana = bot:GetMaxMana()
		local mana    = (maxMana > 0) and (bot:GetMana() / maxMana) or 1.0

		local HEAL_CD   = 2.5
		local MANA_CD   = 4.0
		local healReady = (bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD)
		local manaReady = (bot.aib_manaLast == nil or DotaTime() - bot.aib_manaLast >= MANA_CD)

		local function getItem(name)
			local slot = bot:FindItemSlot(name)
			if slot < 0 then return nil end
			local it = bot:GetItemInSlot(slot)
			return (it ~= nil and it:IsFullyCastable()) and it or nil
		end

		-- 1. TANGO: проактивный хил при HP < 65%. Отменяется только уроном ГЕРОЕВ — не крипов.
		--    Можно есть в любой момент, даже в крипах (бафф не отменяется атаками крипов).
		--    TANGO_CD = 10s на случай если Action_UseAbilityOnTree был выдан но отменён
		--    следующим Think-тиком нашего же кода (move/attack). Без этого CD возможны
		--    быстрые повторные попытки если дерево далеко и бот не дошёл до него.
		local TANGO_CD = 10.0
		local tangoReady = (bot.aib_tangoLast == nil or DotaTime() - bot.aib_tangoLast >= TANGO_CD)
		if hp < 0.65 and tangoReady and not bot:HasModifier("modifier_tango_heal") then
			-- item_tango_single = разделённая тангу (1 заряд), та же механика
			local tango = getItem("item_tango") or getItem("item_tango_single")
			if tango then
				local trees = bot:GetNearbyTrees(700)
				if trees and #trees > 0 then
					bot.aib_tangoLast = DotaTime(); bot.aib_healLast = DotaTime(); AIB_Diag("tango-heal")
					bot:Action_UseAbilityOnTree(tango, trees[1]); return
				end
			end
		end

		-- 2. BOTTLE: HP < 70% ИЛИ мана < 40%. Отменяется только уроном героев.
		--    Восстанавливает и HP и ману — пить раньше, не ждать критического HP.
		if (hp < 0.70 or mana < 0.40) and healReady then
			if not bot:WasRecentlyDamagedByAnyHero(1.5) then
				local bottle = getItem("item_bottle")
				if bottle then
					bot.aib_healLast = DotaTime(); AIB_Diag("bottle-heal")
					bot:Action_UseAbility(bottle); return
				end
			end
		end

		-- 3. MANGO: крит мана < 20%, instant, без условий. Отдельный MANA_CD.
		if mana < 0.20 and manaReady then
			local mango = getItem("item_enchanted_mango")
			if mango then
				bot.aib_manaLast = DotaTime(); AIB_Diag("mana-mango")
				bot:Action_UseAbilityOnEntity(mango, bot); return
			end
		end

		-- 4. WAND: HP < 50%, минимум 10 зарядов (5 HP/заряд × 10 = 50 HP реального хила).
		-- 5. STICK: HP < 50%, минимум 8 зарядов. Нет экстренного "any charges" режима —
		--    при hp < 30% + 1-2 заряда = 5-10 HP хила каждые 2.5s → спам диагов без смысла.
		if hp < 0.50 and healReady then
			local wand = getItem("item_magic_wand")
			if wand and wand:GetCurrentCharges() >= 10 then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(wand); return
			end
			local stick = getItem("item_magic_stick")
			if stick and stick:GetCurrentCharges() >= 8 then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(stick); return
			end
		end

		-- 6. FAERIE FIRE: экстренный instant HP < 45%, без условий.
		-- 7. SATANIC: экстренный instant HP < 45%, без условий.
		if hp < 0.45 and healReady then
			local ff = getItem("item_faerie_fire")
			if ff then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(ff); return
			end
			local satanic = getItem("item_satanic")
			if satanic then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(satanic); return
			end
		end

		-- 8. CLARITY: мана < 40%, только когда безопасно (канальный предмет, любой урон отменяет).
		--    Отдельный MANA_CD — не конкурирует с HP-предметами.
		if mana < 0.40 and manaReady then
			local manaSafe = not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5))
			if manaSafe then
				local clarity = getItem("item_clarity")
				if clarity then
					bot.aib_manaLast = DotaTime(); AIB_Diag("mana-clarity")
					bot:Action_UseAbilityOnEntity(clarity, bot); return
				end
			end
		end

		-- 9. FLASK/SALVE: HP < 40%, только когда безопасно (любой урон отменяет).
		--    Если небезопасно → heal-pullback к башне (кроме regen_lane — у него своя логика).
		if hp < 0.40 and healReady then
			local hpSafe = not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5))
			if hpSafe then
				local flask = getItem("item_flask")
				if flask then
					bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
					bot:Action_UseAbilityOnEntity(flask, bot); return
				end
			else
				if Style.Get().rules.low_hp_behavior ~= "regen_lane" then
					local back = AIB_ForwardSurvivingTowerLoc()
					if back then
						bot.aib_healLast = DotaTime(); AIB_Diag("heal-pullback")
						bot:Action_MoveToLocation(back); return
					end
				end
			end
		end
	end

	-- AIBattle: regen_lane — when HP is critically low, step back and wait for regen in lane.
	-- Safety gate: only fires when not being hit by hero (2.5s window) and enemy not chasing.
	-- Prevents the bot from turning mid-fight. Move rate-limited 3s to avoid jitter.
	-- Diag: 'regen-lane' (fired safely) / 'retreat-blocked' (wanted to but fight still active).
	if Style.Get().rules.low_hp_behavior == "regen_lane"
		and J.GetHP(bot) < (0.30 + 0.15 * (dials.retreat_caution or 0.5)) then
		-- safe = no hero damage in last 2.5s AND no nearby live enemy within 900 units
		local recentHeroDmg = bot:WasRecentlyDamagedByAnyHero(2.5)
		local nearEnemy = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
		local enemyChasing = nearEnemy and #nearEnemy > 0 and nearEnemy[1]:IsAlive()
		if not recentHeroDmg and not enemyChasing then
			-- safe: rate-limit the actual move to avoid jitter
			if bot.aib_regenLast == nil or DotaTime() - bot.aib_regenLast >= 3.0 then
				local cen = AIB_EnemyCreepCentroid(nEnemyCreeps)
				local back = cen and J.VectorAway(bot:GetLocation(), cen, 400) or AIB_ForwardSurvivingTowerLoc()
				if back then
					bot.aib_regenLast = DotaTime()
					Style.Diag(bot, "regen-lane")
					bot:Action_MoveToLocation(back)
					return
				end
			end
		else
			-- wanted to regen but fight is still active — count for monitoring
			Style.DiagRL(bot, "retreat-blocked", 3.0)
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

	-- AIBattle: hero-specific ability harass + execute, driven by ability_aggro / execute_threshold dials.
	-- Covers all targeting types (unit, point, directional, no_target) via HeroAbilityConfig in
	-- aibattle_style.lua. Heroes not in the config return false and fall through silently.
	-- Execute is checked first (higher priority: kill a fleeing enemy over general harassment).
	do
		local nearEnemies = bot:GetNearbyHeroes(1000, true, BOT_MODE_NONE)
		if nearEnemies and #nearEnemies > 0 and nearEnemies[1]:IsAlive() then
			if Style.AbilityExecute(bot, nearEnemies[1]) then return end
			if Style.AbilityHarass(bot, nearEnemies[1]) then return end
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
		-- lane_activity: hit any nearby creep (not just last-hit kill-shot) to stay active.
		-- 1.0 = always act; 0.0 = only last-hit (freeze lane). anti_afk overrides to 1.0.
		-- Walks to nearest creep if lane_activity >= 0.5 and nothing in attack range.
		local laneAct = antiAfk and 1.0 or (dials.lane_activity or 0.7)
		if nEnemyCreeps and #nEnemyCreeps > 0 and math.random() < laneAct then
			local nearest, nd = nil, 1e9
			for _, c in pairs(nEnemyCreeps) do
				if J.IsValid(c) and J.CanBeAttacked(c) then
					local d = GetUnitToUnitDistance(bot, c)
					if d <= botAttackRange then
						AIB_Diag("lane-active")
						bot:Action_AttackUnit(c, true); return
					end
					if d < nd then nearest, nd = c, d end
				end
			end
			-- walk to nearest creep if active enough (not just anti_afk)
			if nearest and laneAct >= 0.5 then
				AIB_Diag("lane-active")
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
