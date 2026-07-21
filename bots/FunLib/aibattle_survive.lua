-- AIBattle survive system: defensive_heal / regen_lane / recovery.
-- Entry: AIBSurvive.Think(bot, dials, nEnemyCreeps) returns true if action was issued.
-- Extracted from mode_laning_generic.lua to keep that file manageable.

local M = {}

local J     = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local AIBRunes = require(GetScriptDirectory()..'/FunLib/aibattle_runes')

local TANGO_CD = 10.0  -- shared across all tango calls; guards re-issue while CD / modifier active
local FLASK_CD = 3.0   -- laning flask (defensiveHeal); recovery uses aib_recFlaskLast at 8s (separate context)
local BOTTLE_RUNE_MAX_DIST = Const.Rune.bottleMaxDist
local BOTTLE_RUNE_STAGE_MAX_DIST = Const.Rune.bottleStageMaxDist
local RECOVERY_RUNE_MAX_DIST = Const.Rune.recoveryMaxDist
local RECOVERY_RUNE_STAGE_MAX_DIST = Const.Rune.recoveryStageMaxDist
local WATER_EMERGENCY_STAGE_WINDOW = Const.Rune.waterEmergencyStageWindow

local function getItem(bot, name)
	local slot = bot:FindItemSlot(name)
	if slot < 0 then return nil end
	if bot:GetItemSlotType(slot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
	local it = bot:GetItemInSlot(slot)
	return (it ~= nil and it:IsFullyCastable()) and it or nil
end

local function hasItem(bot, name)
	local slot = bot:FindItemSlot(name)
	return slot >= 0 and bot:GetItemSlotType(slot) == ITEM_SLOT_TYPE_MAIN and bot:GetItemInSlot(slot) ~= nil
end

local function forwardTowerLoc(bot) return AIBUtils.SafeRetreatTowerLoc(bot) end

local function dist2D(a, b)
	if a == nil or b == nil then return math.huge end
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx*dx + dy*dy)
end

local function enemyTowerNearLoc(loc, extra)
	if loc == nil then return false end
	local opp = GetOpposingTeam()
	for _, id in ipairs({ TOWER_MID_1, TOWER_MID_2, TOWER_TOP_1, TOWER_BOT_1, TOWER_MID_3 }) do
		local twr = GetTower(opp, id)
		if twr ~= nil and twr:IsAlive() and dist2D(loc, twr:GetLocation()) <= twr:GetAttackRange() + (extra or 180) then
			return true
		end
	end
	return false
end

local function xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if hp < 0.28 then return AIBUtils.SafeRetreatTowerLoc(bot), "safe" end
	local fountain = J.GetTeamFountain()
	local cen = AIBUtils.EnemyCreepCentroid(nEnemyCreeps)
	if cen ~= nil and fountain ~= nil then
		local dx, dy = fountain.x - cen.x, fountain.y - cen.y
		local d = math.sqrt(dx*dx + dy*dy)
		if d > 1 then
			local back = hp < 0.42 and 1050 or 850
			local loc = Vector(cen.x + (dx/d)*back, cen.y + (dy/d)*back, cen.z)
			if not enemyTowerNearLoc(loc, 260) then return loc, "xp" end
		end
	end
	local front = GetLaneFrontLocation(bot:GetTeam(), LANE_MID, hp < 0.42 and -900 or -650)
	if front ~= nil and not enemyTowerNearLoc(front, 260) then return front, "xp" end
	return AIBUtils.SafeRetreatTowerLoc(bot), "safe"
end

local function hasFountainAura(bot)
	return bot:HasModifier("modifier_fountain_aura")
		or bot:HasModifier("modifier_fountain_aura_buff")
end

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	if bot:GetItemSlotType(bSlot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil then return nil end
	return bottle:GetCurrentCharges()
end

local function recoveryPlan(bot, action, reason, detail, sec)
	local text = "action=" .. tostring(action) .. " reason=" .. tostring(reason)
	if detail ~= nil and detail ~= "" then text = text .. " " .. detail end
	Style.Intent(bot, "recovery-plan", text, sec or 2.0)
end

local function stateIntent(bot, name, detail, sec)
	Style.Intent(bot, "state-" .. tostring(name), detail or "", sec or 2.0)
end

local function itemCost(name)
	local ok, cost = pcall(function() return GetItemCost(name) end)
	if ok and type(cost) == "number" and cost > 0 then return cost end
	local fallback = {
		item_bottle = 675,
		item_magic_wand = 450,
		item_boots = 500,
		item_power_treads = 1400,
		item_lifesteal = 900,
		item_flask = 100,
		item_clarity = 50,
	}
	return fallback[name] or 0
end

local function missingCheckpointItem(bot)
	local checkpoints = {
		"item_bottle",
		"item_magic_wand",
		"item_power_treads",
		"item_lifesteal",
	}
	for _, name in ipairs(checkpoints) do
		if not hasItem(bot, name) then return name, itemCost(name) end
	end
	return nil, 0
end

local function consumableSpendBlocked(bot, hp, gold, itemName)
	local spend = itemCost(itemName)
	local checkpoint, cost = missingCheckpointItem(bot)
	if checkpoint == nil or cost <= 0 then return false end
	if hp >= 0.16 and spend > 0 and gold - spend < cost and gold >= cost - 160 then
		Style.Blocked(bot, "recovery-buy", "item_checkpoint", string.format("item=%s hp=%.0f gold=%d cost=%d spend=%d", checkpoint, hp*100, gold, cost, spend), 8.0)
		recoveryPlan(bot, "buy_" .. tostring(itemName), "checkpoint_block", string.format("item=%s hp=%.0f gold=%d", checkpoint, hp*100, gold), 3.0)
		return true
	end
	if hp >= 0.18 and checkpoint ~= nil and (bot.aib_recBuySpent or 0) >= 220 then
		Style.Blocked(bot, "recovery-buy", "consumable_budget", string.format("item=%s hp=%.0f spent=%d", checkpoint, hp*100, bot.aib_recBuySpent or 0), 8.0)
		recoveryPlan(bot, "buy_" .. tostring(itemName), "budget_block", string.format("item=%s hp=%.0f spent=%d", checkpoint, hp*100, bot.aib_recBuySpent or 0), 3.0)
		return true
	end
	return false
end

function M.Reset(bot)
	if bot == nil then return end
	bot.aib_fountainTrip = false
	bot.aib_fountainFloorTrip = false
	bot.aib_fountainTping = false
	bot.aib_fountainTpCast = nil
	bot.aib_fountainWaitLast = nil
	bot.aib_fountainFullSince = nil
	bot.aib_fountainBottleLast = nil
	bot.aib_recWaitStart = nil
	bot.aib_recWaitDest = nil
	bot.aib_recWaitKind = nil
	bot.aib_recMoveLast = nil
	bot.aib_recBottleLast = nil
	bot.aib_recFlaskLast = nil
	AIBRunes.Reset(bot)
	-- Flask budget is per-life, not per-game: a bot that's behind and respawning still needs
	-- sustain (match 8862516153: stomped Dire hit the 2-flask cap and couldn't buy at 10% HP).
	bot.aib_recBuyCount = nil
	bot.aib_recBuySpent = nil
end

local function wantsBottleFromStyle(bot)
	if GetGameMode() ~= GAMEMODE_1V1MID then return false end
	if bottleCharges(bot) ~= nil then return false end
	local build = Style.GetItemBuild and Style.GetItemBuild() or nil
	if type(build) ~= "table" then return false end
	for _, name in ipairs(build) do
		if name == "item_bottle" then return true end
	end
	return false
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
	-- fountainRecovery must NOT initiate or SUSTAIN a trip from lane.
	-- obs 8905797602 t~300 killed the nearBase self-init. obs 8906495087 t=154-179 showed the
	-- rest of the class: aib_fountainTrip is set by this function itself (below), and it only
	-- clears once hp>=0.98 AND mana>=0.90 -- but a raze-spamming SF is never at 90% mana, so the
	-- latch never opened and the bot kept walking home. Trace: hp 28%->100% (flask landed) while
	-- loc marched 1730,1499 -> 6928,6372, fountain-wait=37 with trip_init=0.
	-- Fix: only a floor/config-initiated trip (aib_fountainFloorTrip) survives away from base.
	-- A self-issued top-off is confined to the fountain aura or the base area, and the latch is
	-- dropped the moment the bot is out in the lane.
	local floorTrip = bot.aib_fountainFloorTrip == true
	if not (inFountain or floorTrip or (bot.aib_fountainTrip and nearBase)) then
		if bot.aib_fountainTrip then
			bot.aib_fountainTrip = false
			bot.aib_fountainFullSince = nil
			Style.DiagRL(bot, "fountain-latch-drop", 5)
		end
		if nearBase and (hp < 0.98 or mana < 0.90 or bottleNotFull) then
			Style.DiagRL(bot, "fountain-init-skip", 5)
		end
		return false
	end
	if inFountain and charges ~= nil and charges > 0 and (hp < 0.98 or mana < 0.90)
		and (bot.aib_fountainBottleLast == nil or DotaTime() - bot.aib_fountainBottleLast >= 1.0) then
		local bottle = getItem(bot, "item_bottle")
		if bottle ~= nil then
			bot.aib_fountainBottleLast = DotaTime()
			Style.Diag(bot, "fountain-bottle")
			bot:Action_UseAbility(bottle)
			return true
		end
	end
	-- bottleNotFull no longer forces a fountain wait: the bottle refills instantly in the
	-- fountain aura and via rune/courier in lane, and gating the wait on it kept the bot looping
	-- here so it never reached the TP-back below -> it walked home on foot.
	-- Mana alone must NEVER drive the walk: SF sits at 40-80% mana permanently, so `mana<0.90`
	-- as a trip reason meant "always go home" (8906495087). Mana tops off only while already
	-- standing in the aura; out on a floor trip only HP keeps the walk alive.
	if hp < 0.98 or (mana < 0.90 and inFountain) then
		bot.aib_fountainFullSince = nil
		if bot.aib_fountainWaitLast == nil or DotaTime() - bot.aib_fountainWaitLast >= 1.0 then
			bot.aib_fountainWaitLast = DotaTime()
			bot.aib_fountainTrip = true
			Style.DiagRL(bot, "fountain-wait", 3)
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end
	if bot.aib_fountainTrip and inFountain then
		if bot.aib_fountainFullSince == nil then bot.aib_fountainFullSince = DotaTime() end
		if DotaTime() - bot.aib_fountainFullSince < 2.0 then
			Style.DiagRL(bot, "fountain-stabilize", 3)
			return true
		end
	end
	bot.aib_fountainTrip = false
	bot.aib_fountainFloorTrip = false
	bot.aib_fountainFullSince = nil

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

-- Rune transaction logic lives in FunLib/aibattle_runes.lua.

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

	if AIBRunes.SeekBottleRune(bot, hp, mana, "bottle-rune", BOTTLE_RUNE_MAX_DIST, {
		lane_aware = true,
		stage_upcoming = true,
		stage_window = 18.0,
		stage_max_dist = BOTTLE_RUNE_STAGE_MAX_DIST,
	}) then return true end

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

	-- 3. Mango: instant, separate mana CD; keep it for true mana emergencies.
	if mana < 0.12 and manaReady then
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

	-- 8. Clarity: channel, any damage cancels -- separate mana CD.
	if mana < 0.25 and manaReady then
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

	local hp = J.GetHP(bot)
	local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if back == nil or GetUnitToLocationDistance(bot, back) <= 200 then return false end

	if bot.aib_regenMoveLast == nil or DotaTime() - bot.aib_regenMoveLast >= 1.5 then
		bot.aib_regenMoveLast = DotaTime()
		Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
		stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
			string.format("ttl=2 reason=regen_lane hp=%.0f dist=%.0f", hp*100, GetUnitToLocationDistance(bot, back)), 2.0)
		Style.Diag(bot, "regen-walk")
		bot:Action_MoveToLocation(back)
	end
	return true
end

--
-- recovery: post-fight heal WITHOUT safety gates.
-- Enemy is dead/gone -- no need to wait for "safe" windows.
--
local function recovery(bot, dials, nEnemyCreeps)
	if Style.Get().rules.healing_style ~= "active" or not bot:IsAlive() then return false end

	local hp      = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana    = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local near    = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if near and #near > 0 and near[1]:IsAlive() then return false end

	-- 1. Tango: 800u radius (wider than laning -- enemy gone, safe to step to farther tree).
	if tryTango(bot, 0.65, 800, "recovery-tango") then return true end

	-- 2. Bottle: no WasRecentlyDamagedByAnyHero check. Empty bottle may stage
	-- around rune windows, but outside those windows it yields back to lane play.
	do
		local bSlot = bot:FindItemSlot("item_bottle")
		if bSlot >= 0 and bot:GetItemSlotType(bSlot) == ITEM_SLOT_TYPE_MAIN then
			local bItem = bot:GetItemInSlot(bSlot)
			if bItem ~= nil then
				if bot:HasModifier("modifier_bottle_regeneration") then
					Style.DiagRL(bot, "recovery-bottle-active", 3)
				elseif (hp < 0.80 or mana < 0.50) and bItem:GetCurrentCharges() > 0 and bItem:IsFullyCastable()
					and (bot.aib_recBottleLast == nil or DotaTime() - bot.aib_recBottleLast >= 3.0) then
					bot.aib_recBottleLast = DotaTime()
					recoveryPlan(bot, "bottle", "charges", string.format("hp=%.0f mana=%.0f charges=%d", hp*100, mana*100, bItem:GetCurrentCharges()), 2.0)
					Style.Diag(bot, "recovery-bottle"); bot:Action_UseAbility(bItem); return true
				elseif bItem:GetCurrentCharges() == 0 then
					if AIBRunes.SeekBottleRune(bot, hp, mana, "recovery-rune-bottle", RECOVERY_RUNE_MAX_DIST, {
						lane_aware = false,
						force_empty_bottle = true,
						stage_upcoming = true,
						stage_window = WATER_EMERGENCY_STAGE_WINDOW,
						stage_max_dist = RECOVERY_RUNE_STAGE_MAX_DIST,
					}) then return true end
					if hp < 0.65 or mana < 0.45 then
						recoveryPlan(bot, "lane", "empty_bottle_no_rune", string.format("hp=%.0f mana=%.0f", hp*100, mana*100), 8.0)
					else
						Style.DiagRL(bot, "empty-bottle-ok", 8)
					end
					if hp >= 0.24 then bot.aib_recWaitStart = nil end
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
				recoveryPlan(bot, "flask", "inventory", string.format("hp=%.0f", hp*100), 2.0)
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
		local enemyDeadWindow = bot.aib_eDeadSince ~= nil and DotaTime() - bot.aib_eDeadSince < 24.0
		if hp < postFightBack
			and bot:WasRecentlyDamagedByAnyHero(8.0)
			and not (enemyDeadWindow and hp >= Const.Recovery.earlyLowHp)
			and not bot:HasModifier("modifier_tango_heal")
			and not tangoWalk then
			local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
			if back then
				if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
					bot.aib_recMoveLast = DotaTime()
					recoveryPlan(bot, "back", "post_fight_regen", string.format("hp=%.0f", hp*100), 2.0)
					Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
					stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
						string.format("ttl=5 reason=post_fight_regen hp=%.0f dist=%.0f", hp*100, GetUnitToLocationDistance(bot, back)), 2.0)
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
	if hp >= threshold then
		bot.aib_recWaitStart = nil
		bot.aib_recWaitDest = nil
		bot.aib_recWaitKind = nil
		return false
	end

	local behavior = Style.Get().rules.low_hp_behavior or "tp_fountain"
	local gold     = bot:GetGold()

	-- a. Buy flask + courier (rate-limited 15s)
	-- Don't buy sustain the fountain is about to give away for free (user rule, 21.07): the
	-- buy at (a) runs BEFORE the hp<0.22 fountain floor at (d2), so a bot that is already
	-- going home was spending 110g per flask on the way -- 3 flasks per side in 8906537715
	-- while bottle_empty FAILed at 57/58 (the flask-loop that starves the bottle). If the
	-- floor is going to fire anyway and nobody is hitting us, walk home and heal for free.
	-- Under hero fire the buy stays available: surviving the walk beats saving the gold.
	-- NOTE: must NOT return here -- the floor lives further down in this same function, so an
	-- early return would stop the trip as well as the buy. Skip only the purchase block.
	local floorWillSendHome = hp < 0.22 and not bot:WasRecentlyDamagedByAnyHero(2.0)
	if floorWillSendHome and not hasItem(bot, "item_flask") then
		Style.Blocked(bot, "recovery-buy", "fountain_floor_free_heal", string.format("hp=%.0f gold=%d", hp*100, gold), 8.0)
		Style.DiagRL(bot, "buy-skip-fountain-floor", 5)
	end
	if gold >= 55 and not floorWillSendHome
		and (bot.aib_recBuyLast == nil or DotaTime() - bot.aib_recBuyLast >= 15.0) then
		if hasItem(bot, "item_flask") then
			Style.Blocked(bot, "recovery-buy", "flask_in_inventory", string.format("hp=%.0f", hp*100), 8.0)
			return false
		end
		-- Critical-stuck escape (8884639175 t=410-436): the bot froze at its anchor for
		-- ~26s at 26-29% HP while its tower was sieged, with 136 idle gold, because
		-- budget_cap AND bottle-gold-protect both blocked the one buy that would un-stick
		-- it (no bottle charge, no reachable rune, no second TP). When in-lane sustain is
		-- genuinely exhausted, survival > saving: allow ONE flask past both caps. Cannot
		-- runaway -- each buy spends gold and the 15s rate limit above still holds.
		local charges = bottleCharges(bot)
		local criticalStuck = hp < 0.30
			and (charges == nil or charges <= 0)
			and gold >= itemCost("item_flask")
			and not bot:HasModifier("modifier_flask_healing")
		if not criticalStuck then
			if (bot.aib_recBuyCount or 0) >= 2 then
				Style.Blocked(bot, "recovery-buy", "budget_cap", string.format("hp=%.0f gold=%d", hp*100, gold), 8.0)
				return false
			end
			if wantsBottleFromStyle(bot) and hp >= 0.22 then
				Style.DiagRL(bot, "bottle-gold-protect", 8)
				return false
			end
			if consumableSpendBlocked(bot, hp, gold, "item_flask") then
				return false
			end
		end
		bot.aib_recBuyLast = DotaTime()
		bot.aib_recBuyCount = (bot.aib_recBuyCount or 0) + 1
		bot.aib_recBuySpent = (bot.aib_recBuySpent or 0) + itemCost("item_flask")
		recoveryPlan(bot, "buy_flask", criticalStuck and "critical_stuck" or "critical", string.format("hp=%.0f gold=%d count=%d", hp*100, gold, bot.aib_recBuyCount or 0), 2.0)
		bot:ActionImmediate_PurchaseItem("item_flask")
		Style.Diag(bot, criticalStuck and "recovery-buy-critical" or "recovery-buy")
		return true
	end

	-- b. TP to fountain
	local tp = getItem(bot, "item_tpscroll")
	if tp and (behavior == "tp_fountain" or behavior == "walk_fountain") then
		bot.aib_fountainTrip = true
		bot.aib_fountainFloorTrip = true
		recoveryPlan(bot, "tp_fountain", "critical", string.format("hp=%.0f", hp*100), 2.0)
		Style.Diag(bot, "recovery-tp"); bot:Action_UseAbility(tp); return true
	end

	-- c. Walk to fountain (walk_fountain, or tp_fountain with no scroll)
	if behavior == "walk_fountain" or (behavior == "tp_fountain" and not tp) then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			bot.aib_fountainTrip = true
			bot.aib_fountainFloorTrip = true
			recoveryPlan(bot, "walk_fountain", "no_tp", string.format("hp=%.0f", hp*100), 2.0)
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- d. Water rune (regen_lane only)
	if behavior == "regen_lane" then
		local now = DotaTime()
		local bestRune, bestLoc, bestDist = AIBRunes.FindWaterRecoveryRune(bot, hp, mana, now)
		if bestLoc ~= nil then
			if bot.aib_recMoveLast == nil or now - bot.aib_recMoveLast >= 5.0 then
				recoveryPlan(bot, "water_rune", "regen_lane", string.format("hp=%.0f mana=%.0f dist=%.0f", hp*100, mana*100, bestDist), 2.0)
				bot.aib_recMoveLast = now; Style.Diag(bot, "recovery-rune")
				bot:Action_MoveToLocation(bestLoc)
			end
			return true
		else
			recoveryPlan(bot, "water_rune", "blocked", string.format("hp=%.0f mana=%.0f", hp*100, mana*100), 4.0)
		end
	end

	-- d2. Engine survival floor (beats the regen_lane config -- same principle as
	-- MayDive/concede): regen_lane has NO fountain leg, so a bot with zero sustain at
	-- 5-22% HP bought a flask and stood under its tower waiting for the courier for 30s
	-- (8905066151 t=252-285, user: "he could just TP to base and heal"). When in-lane
	-- sustain is exhausted and HP is critical, go to the fountain regardless of style:
	-- TP if the scroll is up and we are not being hit (channel would break), else walk
	-- (walking toward the fountain is also the flee direction).
	-- Extended floor (obs 8905797602 t=446, user "back-and-forth under the tower"): 22-35% HP with an
	-- empty bottle, no active flask/tango heal, and its per-life flask budget already spent has
	-- NO in-lane way to recover -- path (e) below just paces it back-and-forth under the tower.
	-- Commit to the fountain instead of pacing (same engine-over-config principle as the hp<0.22
	-- floor). Tightly gated: a bot with a bottle charge, mid-heal, or an affordable flask never
	-- reaches here (paths a/d handle it first), so farm is not regressed.
	local fcharges  = bottleCharges(bot)
	local noSustain = (fcharges == nil or fcharges <= 0)
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_tango_heal")
		and (bot.aib_recBuyCount or 0) >= 2
	local floorReason = hp < 0.22 and "regen_lane_floor" or "no_sustain_floor"
	if hp < 0.22 or (hp < 0.35 and noSustain) then
		local tpFloor = getItem(bot, "item_tpscroll")
		if tpFloor ~= nil and not bot:WasRecentlyDamagedByAnyHero(1.5) then
			bot.aib_fountainTrip = true
			bot.aib_fountainFloorTrip = true
			recoveryPlan(bot, "tp_fountain", floorReason, string.format("hp=%.0f", hp*100), 2.0)
			Style.Diag(bot, "recovery-tp")
			bot:Action_UseAbility(tpFloor)
			return true
		end
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			bot.aib_fountainTrip = true
			bot.aib_fountainFloorTrip = true
			recoveryPlan(bot, "walk_fountain", floorReason, string.format("hp=%.0f", hp*100), 2.0)
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- e. No-resource recovery: move toward XP/safety once, then yield back to laning.
	-- Passive regen is context, not a terminal action; standing still here looks like AFK.
	local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if back then
		if bot.aib_recWaitStart == nil then
			bot.aib_recWaitStart = DotaTime()
			bot.aib_recWaitDest = back
			bot.aib_recWaitKind = backKind
		end
		back = bot.aib_recWaitDest or back
		backKind = bot.aib_recWaitKind or backKind
		if DotaTime() - bot.aib_recWaitStart < 10.0 then
			local backDist = GetUnitToLocationDistance(bot, back)
			if backDist <= 220 then
				Style.DiagRL(bot, "recovery-yield", 5)
				recoveryPlan(bot, "wait_safe", "hold_position", string.format("hp=%.0f", hp*100), 4.0)
				return true
			end
			if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 1.5 then
				bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-wait")
				Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
				stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
					string.format("ttl=2 reason=no_resources hp=%.0f dist=%.0f", hp*100, backDist), 2.0)
				recoveryPlan(bot, "wait_safe", "no_resources", string.format("hp=%.0f", hp*100), 2.0)
				bot:Action_MoveToLocation(back)
				return true
			end
			Style.DiagRL(bot, "recovery-yield", 5)
			return false
		end
		-- Timeout elapsed with no items: go to lane at reduced HP rather than staying AFK.
		bot.aib_recWaitStart = nil
		bot.aib_recWaitDest = nil
		bot.aib_recWaitKind = nil
		Style.DiagRL(bot, "recovery-timeout", 10)
	end

	return false
end

--

function M.Think(bot, dials, nEnemyCreeps)
	if fountainRecovery(bot)              then return true end
	if defensiveHeal(bot, dials)           then return true end
	if regenLane(bot, dials, nEnemyCreeps) then return true end
	if recovery(bot, dials, nEnemyCreeps)  then return true end
	return false
end

return M
