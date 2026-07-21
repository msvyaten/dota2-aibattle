-- AIBattle item policy: bottle/mango/TP/purchase guards kept out of generic item files.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

local consumables = {
	item_flask = true,
	item_clarity = true,
	item_tango = true,
	item_enchanted_mango = true,
}

local checkpoints = {
	item_bottle = true,
	item_magic_wand = true,
	item_boots = true,
	item_power_treads = true,
	item_lifesteal = true,
}

local function itemCost(name)
	local ok, cost = pcall(GetItemCost, name)
	return (ok and type(cost) == "number") and cost or 0
end

function M.ItemCost(name)
	return itemCost(name)
end

function M.MissingBuildCheckpoint(bot, style)
	if bot == nil or type(style) ~= "table" or style.GetItemBuild == nil then return nil, 0 end
	local okBuild, build = pcall(style.GetItemBuild)
	if not okBuild or type(build) ~= "table" then return nil, 0 end
	for _, name in ipairs(build) do
		if checkpoints[name] and not J.HasItem(bot, name) then
			return name, itemCost(name)
		end
	end
	return nil, 0
end

function M.ProtectConsumableGold(bot, style, itemName)
	if bot == nil or not consumables[itemName] then return false end
	if type(style) ~= "table" or style.GetItemBuild == nil then return false end
	if GetGameMode() ~= GAMEMODE_1V1MID then return false end
	if (itemName == "item_flask" or itemName == "item_tango") and J.GetHP(bot) < 0.20 then return false end
	if (itemName == "item_clarity" or itemName == "item_enchanted_mango") and J.GetMP(bot) < 0.12 then return false end

	local checkpoint, checkpointCost = M.MissingBuildCheckpoint(bot, style)
	if checkpoint == nil or checkpointCost <= 0 then return false end
	local spend = itemCost(itemName)
	local gold = bot:GetGold()
	if spend > 0 and gold - spend < checkpointCost and gold >= checkpointCost - 220 then
		if style.Blocked ~= nil then
			style.Blocked(bot, "buy-consumable", "checkpoint_gold",
				string.format("item=%s checkpoint=%s gold=%d cost=%d spend=%d", itemName, checkpoint, gold, checkpointCost, spend), 8.0)
		end
		return true
	end
	if J.GetHP(bot) >= 0.25 and (bot.aib_buyConsumableSpent or 0) >= 220 then
		if style.Blocked ~= nil then
			style.Blocked(bot, "buy-consumable", "budget_cap",
				string.format("item=%s checkpoint=%s spent=%d", itemName, checkpoint, bot.aib_buyConsumableSpent or 0), 8.0)
		end
		return true
	end
	return false
end

function M.PurchaseConsumable(bot, style, itemName)
	if M.ProtectConsumableGold(bot, style, itemName) then
		if type(style) == "table" and style.DiagRL ~= nil then style.DiagRL(bot, "checkpoint-gold-protect", 8) end
		return false
	end
	local res = bot:ActionImmediate_PurchaseItem(itemName)
	if res == PURCHASE_ITEM_SUCCESS then
		bot.aib_buyConsumableSpent = (bot.aib_buyConsumableSpent or 0) + itemCost(itemName)
	end
	return res
end

-- A committed fountain trip restores HP for free in a few seconds, so a consumable spent on
-- the way is pure waste. The user has now called this out four times across two matches
-- ("пошёл на фонтан и по пути выпил фласку", 8907379308 at 3:40 / 6:10 / 8:40 / 11:00).
--
-- Why here and not in survive.lua: our own consume sites were already guarded (f942b46) and
-- read consume-blocked=0 for the whole match, while heal-item did not move during the 11:00
-- trip either. The salve is eaten by the VENDOR rule in ability_item_usage_generic, whose
-- conditions a fountain walk satisfies perfectly -- HP missing > 500, no enemy within 900,
-- no recent hero damage. It already bails inside 3000 of the fountain; this is the same idea
-- applied to the rest of the walk.
--
-- This deliberately does NOT abort the trip. The 21.07 rollback settled that a committed
-- floor trip runs to completion, because the trip also restores mana and bottle charges that
-- an HP test cannot see. The only thing being fixed is paying 110g to arrive full.
function M.SkipConsumableForFountainTrip(bot)
	if bot == nil then return false end
	if bot.aib_fountainFloorTrip ~= true and bot.aib_fountainTrip ~= true then return false end
	-- Low enough that the walk itself is in doubt: heal anyway, arriving alive beats saving.
	if J.GetHP(bot) < 0.15 then return false end
	return true
end

function M.HasSufficientTp(bot, itemApi)
	local charges = itemApi.GetItemCharges(bot, "item_tpscroll")
	return charges >= 2
		or (charges >= 1 and itemApi.HasItem(bot, "item_travel_boots"))
		or (charges >= 1 and itemApi.HasItem(bot, "item_travel_boots_2"))
end

function M.ShouldDelaySpareTpPurchase(bot, style, itemApi)
	if bot == nil or GetGameMode() ~= GAMEMODE_1V1MID then return false end
	local lastTp = bot.aib_fountainTpCast or bot.aib_tpCastTime
	if lastTp == nil then return false end
	local since = DotaTime() - lastTp
	if since < 0 or since > 75 then return false end
	if bot:GetGold() >= 1200 and itemApi.GetItemCharges(bot, "item_tpscroll") <= 0 then return false end
	if type(style) == "table" and style.Blocked ~= nil then
		style.Blocked(bot, "buy-tp", "recent_tp", string.format("since=%.0f", since), 8.0)
	end
	return true
end

function M.ShouldUseMango(bot, style, context)
	if bot == nil then return false end
	-- Tolerate the old 2-arg form in case another caller appears.
	if context == nil and type(style) == "table" and style.Get == nil then
		context = style; style = nil
	end
	context = context or {}

	-- RULE (user, 21.07): a mango is a MANA item. The ONLY reason to eat one is that mana is
	-- short for a skill we are about to cast. Taking damage must NEVER be a trigger -- the
	-- mango's HP regen applies only while the item is still held, so eating it under fire
	-- strictly worsens the situation it was supposed to help.
	-- Removed accordingly: the old `hp < 0.30 and mp < 0.55` rule (ate on damage), the later
	-- `hp < 0.30 -> mp < 0.12` remnant (still keyed on HP), the standalone `mp < 0.12`
	-- (low mana with nothing to cast buys nothing), and the bare killWindow branch at
	-- mp < 0.55 (an enemy being killable is not by itself a mana shortage).
	--
	-- abilitySoon is exactly the wanted condition: the caller sets it when an ability is off
	-- cooldown within 3s, costs more mana than we have, and one mango would cover the gap.
	if context.abilitySoon ~= true then return false end

	-- Which skill is it short for? The caller cannot tell us, so use the kill window as the
	-- proxy for "this is the finisher": that is always worth a mango, including for
	-- save_for_execute builds. Otherwise the mana is for harassment, which is only worth a
	-- mango when harass abilities can actually fire -- a farmer on save_for_execute has
	-- AbilityHarass disabled outright (style.lua:907), so it would be buying a raze that
	-- never happens at the cost of its regen.
	if context.killWindow == true then return true end
	local mrules = (type(style) == "table" and style.Get ~= nil) and (style.Get().rules or {}) or {}
	return mrules.ability_usage == "aggressive"
		and mrules.ability_timing ~= "save_for_execute"
end

function M.ShouldUseBottle(bot, item, context)
	if bot == nil or item == nil or item:GetCurrentCharges() == 0 then return false end
	if bot:HasModifier("modifier_bottle_regeneration") then return false end
	context = context or {}
	if bot:HasModifier("modifier_fountain_aura") then return true, "fountain" end
	if bot:WasRecentlyDamagedByAnyHero(3.0) then return false end
	local lostMana = bot:GetMaxMana() - bot:GetMana()
	local lostHealth = bot:OriginalGetMaxHealth() - bot:OriginalGetHealth()
	if lostHealth > 150 and lostMana > 90 then return true, "health_mana" end
	if lostHealth > 500 and J.GetHP(bot) < 0.5 then return true, "health" end
	if lostMana > 280 and J.GetMP(bot) < 0.4 then return true, "mana" end
	return false
end

return M
