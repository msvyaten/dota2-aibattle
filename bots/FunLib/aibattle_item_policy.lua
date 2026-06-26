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

function M.ShouldUseMango(bot, context)
	if bot == nil then return false end
	context = context or {}
	local hp = J.GetHP(bot)
	local mp = J.GetMP(bot)
	if hp < 0.30 and mp < 0.55 then return true end
	if context.killWindow == true and mp < 0.55 then return true end
	if context.abilitySoon == true and mp < 0.42 then return true end
	if mp < 0.12 then return true end
	return false
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
