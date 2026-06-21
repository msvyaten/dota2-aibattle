-- AIBattle survive system: defensive_heal / regen_lane / recovery.
-- Entry: AIBSurvive.Think(bot, dials, nEnemyCreeps) returns true if action was issued.
-- Extracted from mode_laning_generic.lua to keep that file manageable.

local M = {}

local J     = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local TANGO_CD = 10.0  -- shared across all tango calls; guards re-issue while CD / modifier active
local FLASK_CD = 3.0   -- laning flask (defensiveHeal); recovery uses aib_recFlaskLast at 8s (separate context)

local function getItem(bot, name)
	local slot = bot:FindItemSlot(name)
	if slot < 0 then return nil end
	local it = bot:GetItemInSlot(slot)
	return (it ~= nil and it:IsFullyCastable()) and it or nil
end

local function forwardTowerLoc(bot) return AIBUtils.SafeRetreatTowerLoc(bot) end

local function hasFountainAura(bot)
	return bot:HasModifier("modifier_fountain_aura")
		or bot:HasModifier("modifier_fountain_aura_buff")
end

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil then return nil end
	return bottle:GetCurrentCharges()
end

local function fountainRecovery(bot)
	if DotaTime() <= 0 then return false end
	if bot.aib_fountainTping then
		if bot:HasModifier("modifier_teleporting") then return true end
		if DotaTime() - (bot.aib_fountainTpCast or 0) < 1.0 then return true end
		bot.aib_fountainTping = false
	end
	local hp = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local charges = bottleCharges(bot)
	local bottleNotFull = charges ~= nil and charges < 3
	local nearBase = bot:DistanceFromFountain() < 2600
	local inFountain = hasFountainAura(bot)
	if not inFountain and not nearBase and not bot.aib_fountainTrip then return false end
	if hp < 0.98 or mana < 0.90 or bottleNotFull then
		if bot.aib_fountainWaitLast == nil or DotaTime() - bot.aib_fountainWaitLast >= 1.0 then
			bot.aib_fountainWaitLast = DotaTime()
			bot.aib_fountainTrip = true
			Style.DiagRL(bot, "fountain-wait", 3)
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end
	bot.aib_fountainTrip = false

	local tp = getItem(bot, "item_tpscroll")
	local t1 = GetTower(bot:GetTeam(), TOWER_MID_1)
	if tp ~= nil and t1 ~= nil and t1:IsAlive() and nearBase then
		Style.Diag(bot, "fountain-tp-lane")
		bot:Action_UseAbilityOnLocation(tp, t1:GetLocation())
		bot.aib_fountainTping = true
		bot.aib_fountainTpCast = DotaTime()
		return true
	end
	return false
end

local function hasLastHitWindow(bot)
	local creeps = bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 180, true)
	if not creeps or #creeps == 0 then return false end
	local damage = bot:GetAttackDamage()
	for _, creep in ipairs(creeps) do
		if J.IsValid(creep) and creep:IsAlive() and J.CanBeAttacked(creep)
			and creep:GetHealth() <= damage * 1.25 then
			return true
		end
	end
	return false
end

local function laneFrontDistance(bot)
	local lane = LANE_MID
	if bot.GetAssignedLane ~= nil then lane = bot:GetAssignedLane() end
	if GetGameMode() == GAMEMODE_1V1MID then lane = LANE_MID end
	local front = GetLaneFrontLocation(bot:GetTeam(), lane, 0)
	if front == nil then return 0 end
	return GetUnitToLocationDistance(bot, front)
end

local function seekBottleRune(bot, hp, mana, diagKey, maxDist, opts)
	opts = opts or {}
	local rules = Style.Get().rules
	local laneAware = opts.lane_aware ~= false
	if hp >= 0.78 and mana >= 0.45 then return false end

	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return false end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil or bottle:GetCurrentCharges() ~= 0 then return false end

	local now = DotaTime()
	if bot.aib_bottleRuneTarget ~= nil
		and bot.aib_bottleRuneStarted ~= nil
		and now - bot.aib_bottleRuneStarted < 14.0 then
		local targetDist = GetUnitToLocationDistance(bot, bot.aib_bottleRuneTarget)
		if targetDist > 180 then
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=commit", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			return true
		end
		Style.Intent(bot, diagKey, string.format("dist=%.0f reason=arrived", targetDist), 2.0)
		bot.aib_bottleRuneTarget = nil
		bot.aib_bottleRuneStarted = nil
	end

	local bestLoc, bestDist, bestScore = nil, math.huge, math.huge
	for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE then
			local loc = GetRuneSpawnLocation(runeId)
			if loc ~= nil then
				local dist = GetUnitToLocationDistance(bot, loc)
				local runeType = GetRuneType(runeId)
				local score = dist + ((runeType == RUNE_WATER) and 0 or 350)
				if dist <= (maxDist or 2600) and score < bestScore then
					bestLoc, bestDist, bestScore = loc, dist, score
				end
			end
		end
	end
	if bestLoc == nil then
		Style.Blocked(bot, diagKey, "no_close_rune", string.format("max=%.0f", maxDist or 2600), 8.0)
		return false
	end

	local near = bot:GetNearbyHeroes(650, true, BOT_MODE_NONE)
	local enemyTooClose = near and #near > 0 and near[1]:IsAlive()
		and GetUnitToUnitDistance(bot, near[1]) <= bot:GetAttackRange() + 120
	if bestDist > 700 and enemyTooClose and (hp < 0.55 or bot:WasRecentlyDamagedByAnyHero(1.0)) then
		Style.Blocked(bot, diagKey, "enemy_near", string.format("enemy=%.0f rune=%.0f hp=%.0f", GetUnitToUnitDistance(bot, near[1]), bestDist, hp*100), 6.0)
		return false
	end

	if bestDist > 700 and bot:WasRecentlyDamagedByAnyHero(1.0) and hp < 0.45 then
		Style.Blocked(bot, diagKey, "hero_damage", string.format("hp=%.0f rune=%.0f", hp*100, bestDist), 6.0)
		return false
	end

	if laneAware and bestDist > 700 and hp > 0.62 and hasLastHitWindow(bot) then
		Style.Blocked(bot, diagKey, "last_hit_window", string.format("rune=%.0f hp=%.0f", bestDist, hp*100), 6.0)
		return false
	end

	if laneAware then
		local laneDist = laneFrontDistance(bot)
		local laneBudget = rules.bottle_rune_lane_budget or 1500
		if laneDist > laneBudget and bestDist > 700 then
			Style.Blocked(bot, diagKey, "lane_budget", string.format("lane=%.0f max=%.0f rune=%.0f", laneDist, laneBudget, bestDist), 6.0)
			return false
		end
	end

	if bot.aib_bottleRuneLast ~= nil and now - bot.aib_bottleRuneLast < 3.0 then
		Style.Intent(bot, diagKey, string.format("dist=%.0f reason=cooldown_hold", bestDist), 2.0)
		return bestDist > 180
	end

	bot.aib_bottleRuneLast = now
	bot.aib_bottleRuneStarted = now
	bot.aib_bottleRuneTarget = bestLoc
	Style.Intent(bot, diagKey, string.format("dist=%.0f hp=%.0f mana=%.0f reason=start", bestDist, hp*100, mana*100), 2.0)
	Style.Diag(bot, diagKey)
	bot:Action_MoveToLocation(bestLoc)
	return true
end

-- tryTango: unified tango logic used by defensiveHeal and recovery.
-- Returns true when tree-walk is in progress (caller must return to protect the walk).
-- Releases automatically once modifier_tango_heal appears (HasModifier check below).
local function tryTango(bot, hpThreshold, treeRadius, diagKey)
	-- Walking protection: block until modifier appears (bot reached tree) or 2s timeout.
	if bot.aib_tangoWalking ~= nil then
		if bot:HasModifier("modifier_tango_heal") then
			bot.aib_tangoWalking = nil  -- tree reached, unblock
		elseif DotaTime() - bot.aib_tangoWalking < 2.0 then
			return true  -- still walking to tree
		else
			bot.aib_tangoWalking = nil  -- timeout, give up
		end
	end
	if J.GetHP(bot) >= hpThreshold then return false end
	if bot.aib_tangoLast ~= nil and DotaTime() - bot.aib_tangoLast < TANGO_CD then return false end
	if bot:HasModifier("modifier_tango_heal") then return false end
	local item = getItem(bot, "item_tango") or getItem(bot, "item_tango_single")
	if not item then return false end
	local trees = bot:GetNearbyTrees(treeRadius)
	if not trees or #trees == 0 then return false end
	bot.aib_tangoLast   = DotaTime()
	bot.aib_tangoWalking = DotaTime()
	Style.Diag(bot, diagKey)
	bot:Action_UseAbilityOnTree(item, trees[1])
	return true
end

--
-- defensiveHeal: consumables WITH safety gates (normal laning).
--
local function defensiveHeal(bot, dials)
	local hp        = J.GetHP(bot)
	local hpMissing = bot:GetMaxHealth() - bot:GetHealth()
	local maxMana   = bot:GetMaxMana()
	local mana      = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0

	-- Proactive: fires for ALL healing styles.
	-- Returns true to protect the walk-to-tree (~1-2s). Releases as soon as modifier appears
	-- (HasModifier check in tryTango returns false; defensiveHeal falls through normally).
	if tryTango(bot, 0.70, 700, "tango-heal") then
		bot.aib_healLast = DotaTime()
		return true
	end

	if hpMissing >= 400
		and (bot.aib_flaskLast == nil or DotaTime() - bot.aib_flaskLast >= FLASK_CD)
		and not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)) then
		local flask = getItem(bot, "item_flask")
		if flask then
			bot.aib_flaskLast = DotaTime()
			Style.Diag(bot, "heal-item")
			bot:Action_UseAbilityOnEntity(flask, bot)
			return true
		end
	end

	local rules = Style.Get().rules
	if seekBottleRune(bot, hp, mana, "bottle-rune", rules.bottle_rune_max_dist or 1900, { lane_aware = true }) then return true end

	if Style.Get().rules.healing_style ~= "active" then return false end

	local HEAL_CD   = 2.5
	local MANA_CD   = 4.0
	local healReady = bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD
	local manaReady = bot.aib_manaLast == nil or DotaTime() - bot.aib_manaLast >= MANA_CD

	-- 1. Tango at tighter threshold (0.65 vs 0.70 proactive); shared CD prevents double-use.
	if tryTango(bot, 0.65, 700, "tango-heal") then
		bot.aib_healLast = DotaTime()
		return true
	end

	-- 2. Bottle: channel-safe; hero damage cancels it
	if (hp < 0.70 or mana < 0.40) and healReady
		and not bot:HasModifier("modifier_bottle_regeneration")
		and not bot:WasRecentlyDamagedByAnyHero(1.5) then
		local bottle = getItem(bot, "item_bottle")
		if bottle and bottle:GetCurrentCharges() > 0 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "bottle-heal")
			bot:Action_UseAbility(bottle); return true
		end
	end

	-- 3. Mango: instant, separate mana CD
	if mana < 0.20 and manaReady then
		local mango = getItem(bot, "item_enchanted_mango")
		if mango then
			bot.aib_manaLast = DotaTime(); Style.Diag(bot, "mana-mango")
			bot:Action_UseAbilityOnEntity(mango, bot); return true
		end
	end

	-- 4+5. Wand (>=10 ch) / Stick (>=8 ch): instant, meaningful charge threshold only
	if hp < 0.50 and healReady then
		local wand = getItem(bot, "item_magic_wand")
		if wand and wand:GetCurrentCharges() >= 10 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(wand); return true
		end
		local stick = getItem(bot, "item_magic_stick")
		if stick and stick:GetCurrentCharges() >= 8 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(stick); return true
		end
	end

	-- 6+7. Faerie Fire / Satanic: instant emergency
	if hp < 0.45 and healReady then
		local ff = getItem(bot, "item_faerie_fire")
		if ff then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(ff); return true
		end
		local satanic = getItem(bot, "item_satanic")
		if satanic then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(satanic); return true
		end
	end

	-- 8. Clarity: channel, any damage cancels -- separate mana CD
	if mana < 0.40 and manaReady then
		local safe = not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5))
		if safe then
			local clarity = getItem(bot, "item_clarity")
			if clarity then
				bot.aib_manaLast = DotaTime(); Style.Diag(bot, "mana-clarity")
				bot:Action_UseAbilityOnEntity(clarity, bot); return true
			end
		end
	end

	-- 9. Flask at lower threshold -- not gated by healReady so tango/wand use doesn't block it.
	-- At critical HP (< 0.30) bypass recent-damage check (channel gets cancelled but worth trying).
	if hp < 0.40 and (bot.aib_flaskLast == nil or DotaTime() - bot.aib_flaskLast >= FLASK_CD) then
		local flask = getItem(bot, "item_flask")
		if flask then
			local recently_dmg = bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)
			if hp < 0.30 or not recently_dmg then
				bot.aib_healLast  = DotaTime()
				bot.aib_flaskLast = DotaTime()
				Style.Diag(bot, "heal-item")
				bot:Action_UseAbilityOnEntity(flask, bot); return true
			end
		end
	end

	-- heal-pullback: separate CD, skipped for regen_lane (has its own movement logic)
	local PULLBACK_CD = 3.0
	if hp < 0.40
		and Style.Get().rules.low_hp_behavior ~= "regen_lane"
		and (bot.aib_pullbackLast == nil or DotaTime() - bot.aib_pullbackLast >= PULLBACK_CD)
		and (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)) then
		local back = forwardTowerLoc(bot)
		if back then
			bot.aib_pullbackLast = DotaTime(); Style.Diag(bot, "heal-pullback")
			bot:Action_MoveToLocation(back); return true
		end
	end

	return false
end

-- regen_lane: retreat to forward tower when HP is low AND enemy hero is nearby.
-- Returns true only while walking back; once at safe position returns false so normal
-- farming/healing runs. aib_lowHpHold in mode_laning_generic already blocks fwd at HP<0.45.
local function regenLane(bot, dials, nEnemyCreeps)
	if Style.Get().rules.low_hp_behavior ~= "regen_lane" then return false end
	local holdThresh = Style.Get().rules.low_hp_hold or 0.45
	if J.GetHP(bot) >= holdThresh then return false end

	local near = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if not (near and #near > 0 and near[1]:IsAlive()) then return false end

	local back = forwardTowerLoc(bot)
	if back == nil or GetUnitToLocationDistance(bot, back) <= 200 then return false end

	if bot.aib_regenMoveLast == nil or DotaTime() - bot.aib_regenMoveLast >= 1.5 then
		bot.aib_regenMoveLast = DotaTime()
		Style.Diag(bot, "regen-walk")
		bot:Action_MoveToLocation(back)
	end
	return true
end

--
-- recovery: post-fight heal WITHOUT safety gates.
-- Enemy is dead/gone -- no need to wait for "safe" windows.
--
local function recovery(bot, dials)
	if Style.Get().rules.healing_style ~= "active" or not bot:IsAlive() then return false end

	local hp      = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana    = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local near    = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if near and #near > 0 and near[1]:IsAlive() then return false end

	-- 1. Tango: 800u radius (wider than laning -- enemy gone, safe to step to farther tree).
	if tryTango(bot, 0.65, 800, "recovery-tango") then return true end

	-- 2. Bottle: no WasRecentlyDamagedByAnyHero check.
	-- Empty bottle (0 charges): seek water rune to refill; don't fountain just for empty bottle.
	if hp < 0.80 or mana < 0.50 then
		local bSlot = bot:FindItemSlot("item_bottle")
		if bSlot >= 0 then
			local bItem = bot:GetItemInSlot(bSlot)
			if bItem ~= nil then
				if bot:HasModifier("modifier_bottle_regeneration") then
					return true
				elseif bItem:GetCurrentCharges() > 0 and bItem:IsFullyCastable()
					and (bot.aib_recBottleLast == nil or DotaTime() - bot.aib_recBottleLast >= 3.0) then
					bot.aib_recBottleLast = DotaTime()
					Style.Diag(bot, "recovery-bottle"); bot:Action_UseAbility(bItem); return true
				elseif bItem:GetCurrentCharges() == 0 then
					if seekBottleRune(bot, hp, mana, "recovery-rune-bottle", 2600, { lane_aware = false }) then return true end
					-- No rune: fall through to threshold check (fountain only if HP critically low)
				end
			end
		end
	end

	-- 3. Flask: 8s CD guards against channel-interrupt re-spam (damage cancels channel -> item stays
	--    castable -> next tick retries). aib_recFlaskLast is separate from aib_flaskLast so laning
	--    (3s CD, enemy present) and recovery (8s CD, enemy gone) don't block each other.
	--    Don't return true when on CD; laning should continue during the cooldown window.
	if hp < 0.70 then
		local flask = getItem(bot, "item_flask")
		if flask then
			if bot.aib_recFlaskLast == nil or DotaTime() - bot.aib_recFlaskLast >= 8.0 then
				bot.aib_recFlaskLast = DotaTime()
				Style.Diag(bot, "recovery-flask"); bot:Action_UseAbilityOnEntity(flask, bot)
				return true  -- protect first tick after cast
			end
			-- CD active (channel was interrupted): fall through to laning
		end
	end

	-- Post-fight step-back: enemy gone, recently took hero damage, HP still suboptimal and
	-- all items exhausted. Back off near forward tower so natural regen works during
	-- the enemy's respawn window.
	do
		local postFightBack = 0.45 + 0.20 * (dials.retreat_caution or 0.5)
		local tangoWalk = bot.aib_tangoLast ~= nil and DotaTime() - bot.aib_tangoLast < 12.0
		if hp < postFightBack
			and bot:WasRecentlyDamagedByAnyHero(8.0)
			and not bot:HasModifier("modifier_tango_heal")
			and not tangoWalk then
			local back = forwardTowerLoc(bot)
			if back then
				if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
					bot.aib_recMoveLast = DotaTime()
					Style.Diag(bot, "recovery-regen")
					bot:Action_MoveToLocation(back)
				end
				-- Don't block laning: move command issued, let Think() continue normally.
			end
		end
	end

	-- Fallback chain: only when critically low and items exhausted
	local threshold = 0.20 + 0.20 * (dials.retreat_caution or 0.5)
	                + (GetHeroDeaths(bot:GetPlayerID()) >= 1 and 0.08 or 0.0)
	if hp >= threshold then bot.aib_recWaitStart = nil; return false end

	local behavior = Style.Get().rules.low_hp_behavior or "tp_fountain"
	local gold     = bot:GetGold()

	-- a. Buy flask + courier (rate-limited 15s)
	if gold >= 55 and (bot.aib_recBuyLast == nil or DotaTime() - bot.aib_recBuyLast >= 15.0) then
		bot.aib_recBuyLast = DotaTime()
		bot:ActionImmediate_PurchaseItem("item_flask")
		Style.Diag(bot, "recovery-buy")
		return true
	end

	-- b. TP to fountain
	local tp = getItem(bot, "item_tpscroll")
	if tp and (behavior == "tp_fountain" or behavior == "walk_fountain") then
		bot.aib_fountainTrip = true
		Style.Diag(bot, "recovery-tp"); bot:Action_UseAbility(tp); return true
	end

	-- c. Walk to fountain (walk_fountain, or tp_fountain with no scroll)
	if behavior == "walk_fountain" or (behavior == "tp_fountain" and not tp) then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			bot.aib_fountainTrip = true
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- d. Water rune (regen_lane only)
	if behavior == "regen_lane" then
		for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
			if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE and GetRuneType(runeId) == RUNE_WATER then
				if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
					bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-rune")
					bot:Action_MoveToLocation(GetRuneSpawnLocation(runeId))
				end
				return true
			end
		end
	end

	-- e. Stand near tower (passive regen) -- 30s cap to prevent indefinite AFK when items exhausted.
	local back = forwardTowerLoc(bot)
	if back then
		if bot.aib_recWaitStart == nil then bot.aib_recWaitStart = DotaTime() end
		if DotaTime() - bot.aib_recWaitStart < 10.0 then
			if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
				bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-wait")
				bot:Action_MoveToLocation(back)
			end
			return true
		end
		-- 30s elapsed with no items: go to lane at reduced HP rather than staying AFK.
		bot.aib_recWaitStart = nil
		Style.DiagRL(bot, "recovery-timeout", 10)
	end

	return false
end

--

function M.Think(bot, dials, nEnemyCreeps)
	if fountainRecovery(bot)              then return true end
	if defensiveHeal(bot, dials)           then return true end
	if regenLane(bot, dials, nEnemyCreeps) then return true end
	if recovery(bot, dials)                then return true end
	return false
end

return M
