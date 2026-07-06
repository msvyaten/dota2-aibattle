-- AIBattle laning hero-trade intents.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Engine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local function hasCancelableHealModifier(unit)
	if unit == nil then return false end
	return unit:HasModifier("modifier_flask_healing")
		or unit:HasModifier("modifier_bottle_regeneration")
		or unit:HasModifier("modifier_clarity_potion")
end

local function towerDanger(ctx)
	return AIBUtils.EnemyTowerDanger(ctx.bot)
end

local function towerThreat(ctx)
	return AIBUtils.IsTowerActuallyThreatening(ctx.bot, towerDanger(ctx))
end

local function isChanneling(unit)
	if unit == nil then return false end
	if unit:HasModifier("modifier_teleporting") then return true end
	local ok, res = pcall(function() return unit:IsChanneling() end)
	return ok and res == true
end

local function isKillable(bot, enemy, dials)
	if enemy == nil or not enemy:IsAlive() then return false end
	local exec = dials and dials.execute_threshold or 0
	if exec > 0 and J.GetHP(enemy) <= exec then return true end
	-- 3.0x (not 2.2x): GetAttackDamage ignores Raze/Requiem burst, so 2.2x under-counted SF's
	-- real kill range and the bot passed on winnable commits (15 kill windows -> 2 kills/match).
	return enemy:GetHealth() <= bot:GetAttackDamage() * 3.0
end

local function moveToAttackEdge(bot, target, range)
	if bot == nil or target == nil then return false end
	range = range or bot:GetAttackRange()
	if range <= 300 then
		bot:Action_MoveToUnit(target)
		return true
	end
	if target.GetLocation == nil or bot.GetLocation == nil then return false end
	local okTarget, tl = pcall(function() return target:GetLocation() end)
	local okBot, bl = pcall(function() return bot:GetLocation() end)
	if not okTarget or not okBot or tl == nil or bl == nil then return false end
	local dx, dy = bl.x - tl.x, bl.y - tl.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then
		bot:Action_MoveToLocation(bl + RandomVector(160))
		return true
	end
	local safe = math.max(260, range - 80)
	bot:Action_MoveToLocation(Vector(tl.x + (dx/d)*safe, tl.y + (dy/d)*safe, tl.z))
	return true
end

function M.KillLock(ctx)
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local win = Engine.KillWindow(ctx)
	if win == nil then return nil end
	local enemy = win.enemy
	if enemy == nil or not enemy:IsAlive() then return nil end
	if win.hp < 0.30 and win.dist > range + 60 and not win.mutualLow then
		return Engine.Blocked("kill-lock", 120, "self_critical", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	-- Attacking a hero in tower range draws the tower onto the bot, so a tower
	-- currently on creeps is NOT safe for a committed kill-lock (this is how the bot
	-- kept walking into a tower switch and dying). Use the aggro-aware range check.
	if AIBUtils.IsTowerActuallyThreatening(bot, towerDanger(ctx), true) then
		return Engine.Blocked("kill-lock", 90, "tower", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	if AIBUtils.UphillMiss(bot, enemy) then
		return Engine.Blocked("kill-lock", 90, "uphill", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	if not win.inCommitRange then
		return Engine.Blocked("kill-lock", 90, "far", string.format("dist=%.0f max=%.0f hp=%.0f", win.dist, win.maxDist, win.hp*100))
	end

	local reason = win.mutualLow and "mutual_low_finish" or "killable_enemy"
	local priority = win.mutualLow and 145 or (win.inRange and 135 or 125)
	return Engine.Intent("kill-lock", priority, reason, function()
		if Style.AbilityExecute(bot, enemy) then return end
		if win.dist <= range + 80 then
			bot:Action_AttackUnit(enemy, true)
			Style.Diag(bot, win.mutualLow and "mutual-low-finish-atk" or "kill-lock-atk")
		else
			if not moveToAttackEdge(bot, enemy, range) then return false end
			Style.Diag(bot, win.mutualLow and "mutual-low-finish-chase" or "kill-lock-chase")
		end
	end, string.format("dist=%.0f ehp=%.0f hp=%.0f exec=%s atk=%s mutual=%s",
		win.dist, win.ehp*100, win.hp*100, tostring(win.execute), tostring(win.attackKill), tostring(win.mutualLow)))
end

function M.HealInterrupt(ctx)
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(math.max(1100, range + 520), true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0) then return nil end
	local hp = J.GetHP(bot)
	for _, enemy in ipairs(enemies) do
		local isHeal = enemy:IsAlive() and hasCancelableHealModifier(enemy)
		if enemy:IsAlive() and (isHeal or isChanneling(enemy)) then
			local channelKey = isHeal and "heal" or (enemy:HasModifier("modifier_teleporting") and "tp" or "channel")
			local dist = GetUnitToUnitDistance(bot, enemy)
			if hp < 0.18 and dist > range + 80 and not isKillable(bot, enemy, ctx.dials or {}) then
				return Engine.Blocked("channel-interrupt", 85, "low_hp", string.format("hp=%.0f kind=%s", hp*100, channelKey))
			end
			local towerIsThreat = towerThreat(ctx)
			if dist <= range + 120 and (not towerIsThreat or (isHeal and hp >= 0.45)) then
				return Engine.Intent("channel-interrupt", isHeal and 150 or 132, "enemy_" .. channelKey, function()
					bot:Action_AttackUnit(enemy, true)
					Style.Diag(bot, "channel-interrupt-atk")
				end, string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
			end
			local chaseMinHp = isHeal and 0.32 or 0.45
			if dist <= math.max(isHeal and 1050 or 900, range + (isHeal and 560 or 300))
				and not AIBUtils.UphillMiss(bot, enemy)
				and hp >= chaseMinHp
				and (not towerIsThreat or (isHeal and hp >= 0.45)) then
				return Engine.Intent("channel-interrupt", isHeal and 138 or 118, "enemy_" .. channelKey, function()
					if not moveToAttackEdge(bot, enemy, range) then return false end
					Style.Diag(bot, "channel-interrupt-chase")
				end, string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
			end
			return Engine.Blocked("channel-interrupt", 80, "unsafe", string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
		end
	end
	return nil
end

function M.PassingHeroTrade(ctx)
	local bot = ctx.bot
	local rules = ctx.rules or {}
	local dials = ctx.dials or {}
	if (rules.hero_priority or "default") == "never" then return nil end

	local range = ctx.attackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(range + 220, true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0 and enemies[1]:IsAlive()) then return nil end

	local hp = J.GetHP(bot)
	if hp < 0.45 then
		return Engine.Blocked("hero-pass", 60, "low_hp", string.format("hp=%.0f", hp*100))
	end
	if towerThreat(ctx) then
		return Engine.Blocked("hero-pass", 60, "tower", string.format("hp=%.0f", hp*100))
	end

	local enemy = enemies[1]
	if AIBUtils.UphillMiss(bot, enemy) then
		return Engine.Blocked("hero-pass", 60, "uphill", string.format("hp=%.0f", hp*100))
	end

	local now = DotaTime()
	local heroPrio = rules.hero_priority or "default"
	local cd = (heroPrio == "always") and 0.6 or (1.8 - 0.8 * (dials.harass_desire or 0.5))
	if bot.aib_passHeroLast ~= nil and now - bot.aib_passHeroLast < cd then return nil end

	local dist = GetUnitToUnitDistance(bot, enemy)
	if dist <= range + 50 then
		return Engine.Intent("hero-pass", 105, "nearby_enemy", function()
			bot.aib_passHeroLast = DotaTime()
			bot.aib_harassLast = DotaTime()
			bot:Action_AttackUnit(enemy, false)
			Style.Diag(bot, "hero-pass-atk")
		end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
	end

	return Engine.Intent("hero-pass", 90, "nearby_enemy", function()
		if not moveToAttackEdge(bot, enemy, range) then return false end
		bot.aib_passHeroLast = DotaTime()
		Style.Diag(bot, "hero-pass-chase")
	end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
end

return M
