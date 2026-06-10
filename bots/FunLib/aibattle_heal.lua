-- AIBattle heal system: defensive_heal / regen_lane / recovery.
-- Entry: AIBHeal.Think(bot, dials, nEnemyCreeps) → true if action issued (caller returns).
-- Extracted from mode_laning_generic.lua to keep that file manageable.

local M = {}

local J     = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')

local function getItem(bot, name)
	local slot = bot:FindItemSlot(name)
	if slot < 0 then return nil end
	local it = bot:GetItemInSlot(slot)
	return (it ~= nil and it:IsFullyCastable()) and it or nil
end

local function forwardTowerLoc(bot)
	local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
	for _, id in ipairs(ids) do
		local t = GetTower(bot:GetTeam(), id)
		if t ~= nil and t:IsAlive() then return t:GetLocation() end
	end
	return nil
end

local function enemyCreepCentroid(enemyCreeps)
	local cx, cy, n = 0, 0, 0
	for _, c in pairs(enemyCreeps or {}) do
		if J.IsValid(c) then
			local l = c:GetLocation(); cx = cx + l.x; cy = cy + l.y; n = n + 1
		end
	end
	return n > 0 and Vector(cx / n, cy / n, 0) or nil
end

-- ────────────────────────────────────────────────────────────
-- defensive_heal: items WITH safety gates (normal laning).
-- ────────────────────────────────────────────────────────────
local function defensiveHeal(bot, dials)
	if not Style.Imp('defensive_heal') then return false end
	local hp      = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana    = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0

	local HEAL_CD   = 2.5
	local MANA_CD   = 4.0
	local healReady = bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD
	local manaReady = bot.aib_manaLast == nil or DotaTime() - bot.aib_manaLast >= MANA_CD

	-- 1. Tango: TANGO_CD guards against rapid re-issue when bot walks to a distant tree
	--    and the next Think tick cancels the action before reaching it.
	local TANGO_CD = 10.0
	if hp < 0.65
		and (bot.aib_tangoLast == nil or DotaTime() - bot.aib_tangoLast >= TANGO_CD)
		and not bot:HasModifier("modifier_tango_heal") then
		local tango = getItem(bot, "item_tango") or getItem(bot, "item_tango_single")
		if tango then
			local trees = bot:GetNearbyTrees(700)
			if trees and #trees > 0 then
				bot.aib_tangoLast = DotaTime(); bot.aib_healLast = DotaTime()
				Style.Diag(bot, "tango-heal")
				bot:Action_UseAbilityOnTree(tango, trees[1]); return true
			end
		end
	end

	-- 2. Bottle: channel-safe; hero damage cancels it
	if (hp < 0.70 or mana < 0.40) and healReady and not bot:WasRecentlyDamagedByAnyHero(1.5) then
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

	-- 4+5. Wand (≥10 ch) / Stick (≥8 ch): instant, meaningful charge threshold only
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

	-- 8. Clarity: channel, any damage cancels — separate mana CD
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

	-- 9. Flask: channel, any damage cancels
	if hp < 0.40 and healReady then
		local safe = not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5))
		if safe then
			local flask = getItem(bot, "item_flask")
			if flask then
				bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
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

-- ────────────────────────────────────────────────────────────
-- regen_lane: step back and wait for natural regen in lane.
-- Only fires when safe (no hero dmg 2.5s + no enemy chasing).
-- ────────────────────────────────────────────────────────────
local function regenLane(bot, dials, nEnemyCreeps)
	if Style.Get().rules.low_hp_behavior ~= "regen_lane" then return false end
	-- Raised from 0.30 to 0.40 base: step back at < ~51% HP (was < ~41%) so the bot
	-- recovers more conservatively after a fight before re-engaging.
	if J.GetHP(bot) >= 0.40 + 0.15 * (dials.retreat_caution or 0.5) then return false end

	local noHeroDmg    = not bot:WasRecentlyDamagedByAnyHero(2.5)
	local nearEnemy    = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	local enemyChasing = nearEnemy and #nearEnemy > 0 and nearEnemy[1]:IsAlive()

	if noHeroDmg and not enemyChasing then
		if bot.aib_regenLast == nil or DotaTime() - bot.aib_regenLast >= 3.0 then
			local cen  = enemyCreepCentroid(nEnemyCreeps)
			local back = cen and J.VectorAway(bot:GetLocation(), cen, 400) or forwardTowerLoc(bot)
			if back then
				bot.aib_regenLast = DotaTime()
				Style.Diag(bot, "regen-lane")
				bot:Action_MoveToLocation(back); return true
			end
		end
	else
		Style.DiagRL(bot, "retreat-blocked", 3.0)
	end
	return false
end

-- ────────────────────────────────────────────────────────────
-- recovery: post-fight heal WITHOUT safety gates.
-- Enemy is dead/gone — no need to wait for "safe" windows.
-- ────────────────────────────────────────────────────────────
local function recovery(bot, dials)
	if not Style.Imp('defensive_heal') or not bot:IsAlive() then return false end

	local hp      = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana    = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local near    = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if near and #near > 0 and near[1]:IsAlive() then return false end

	-- 1. Tango: aib_tangoLast CD prevents double-use while bot walks to the first tree
	--    (modifier_tango_heal only appears AFTER reaching the tree, so HasModifier alone isn't enough).
	if hp < 0.65
		and (bot.aib_tangoLast == nil or DotaTime() - bot.aib_tangoLast >= 10.0)
		and not bot:HasModifier("modifier_tango_heal") then
		local tango = getItem(bot, "item_tango") or getItem(bot, "item_tango_single")
		if tango then
			local trees = bot:GetNearbyTrees(800)
			if trees and #trees > 0 then
				bot.aib_tangoLast = DotaTime(); Style.Diag(bot, "recovery-tango")
				bot:Action_UseAbilityOnTree(tango, trees[1]); return true
			end
		end
	end

	-- 2. Bottle: no WasRecentlyDamagedByAnyHero check.
	-- Empty bottle (0 charges): seek water rune to refill; don't fountain just for empty bottle.
	if hp < 0.80 or mana < 0.50 then
		local bSlot = bot:FindItemSlot("item_bottle")
		if bSlot >= 0 then
			local bItem = bot:GetItemInSlot(bSlot)
			if bItem ~= nil then
				if bItem:GetCurrentCharges() > 0 and bItem:IsFullyCastable() then
					Style.Diag(bot, "recovery-bottle"); bot:Action_UseAbility(bItem); return true
				elseif bItem:GetCurrentCharges() == 0 then
					-- Empty: grab a water rune if available (refills 2 charges)
					for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
						if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE and GetRuneType(runeId) == RUNE_WATER then
							if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
								bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-rune-bottle")
								bot:Action_MoveToLocation(GetRuneSpawnLocation(runeId))
							end
							return true
						end
					end
					-- No rune: fall through to threshold check (fountain only if HP critically low)
				end
			end
		end
	end

	-- 3. Flask: no hpSafe check
	if hp < 0.70 then
		local flask = getItem(bot, "item_flask")
		if flask then
			Style.Diag(bot, "recovery-flask"); bot:Action_UseAbilityOnEntity(flask, bot); return true
		end
	end

	-- Post-fight step-back: enemy gone, recently took hero damage, HP still suboptimal and
	-- all items exhausted. Back off near forward tower so natural regen works during
	-- the enemy's respawn window. 8s window: 15s caused the bot to idle near its own
	-- tower for the entire enemy respawn timer even after a successful kill.
	-- Threshold 0.45+0.20*rc → at rc=0.75: 0.60; at rc=0.60: 0.57.
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
				return true
			end
		end
	end

	-- Fallback chain: only when critically low and items exhausted
	local threshold = 0.25 + 0.30 * (dials.retreat_caution or 0.5)
	                + (bot:GetDeaths() >= 1 and 0.15 or 0.0)
	if hp >= threshold then return false end

	local behavior = Style.Get().rules.low_hp_behavior or "tp_fountain"
	local gold     = bot:GetGold()

	-- a. Buy flask + courier (rate-limited 15s)
	if gold >= 55 and (bot.aib_recBuyLast == nil or DotaTime() - bot.aib_recBuyLast >= 15.0) then
		bot.aib_recBuyLast = DotaTime()
		bot:ActionImmediate_PurchaseItem("item_flask")
		Style.Diag(bot, "recovery-buy")
		local courier = GetCourier(0)
		if courier then courier:Action_Deliver() end
		return true
	end

	-- b. TP to fountain
	local tp = getItem(bot, "item_tpscroll")
	if tp and (behavior == "tp_fountain" or behavior == "walk_fountain") then
		Style.Diag(bot, "recovery-tp"); bot:Action_UseAbility(tp); return true
	end

	-- c. Walk to fountain (walk_fountain, or tp_fountain with no scroll)
	if behavior == "walk_fountain" or (behavior == "tp_fountain" and not tp) then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
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

	-- e. Stand near tower (passive regen)
	local back = forwardTowerLoc(bot)
	if back then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-wait")
			bot:Action_MoveToLocation(back)
		end
		return true
	end

	return false
end

-- ────────────────────────────────────────────────────────────

function M.Think(bot, dials, nEnemyCreeps)
	if defensiveHeal(bot, dials)           then return true end
	if regenLane(bot, dials, nEnemyCreeps) then return true end
	if recovery(bot, dials)                then return true end
	return false
end

return M
