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

function M.HealInterrupt(ctx)
	local bot = ctx.bot
	local enemies = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0) then return nil end
	local hp = J.GetHP(bot)
	for _, enemy in ipairs(enemies) do
		if enemy:IsAlive() and hasCancelableHealModifier(enemy) then
			if hp < 0.35 then
				return Engine.Blocked("heal-interrupt", 85, "low_hp", string.format("hp=%.0f", hp*100))
			end
			local dist = GetUnitToUnitDistance(bot, enemy)
			local range = ctx.attackRange or bot:GetAttackRange()
			if dist <= range + 50 and towerDanger(ctx) == nil then
				return Engine.Intent("heal-interrupt", 85, "enemy_channel_heal", function()
					bot:Action_AttackUnit(enemy, true)
					Style.Diag(bot, "heal-interrupt-atk")
				end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
			end
			if dist <= math.max(700, range + 260)
				and not AIBUtils.UphillMiss(bot, enemy)
				and not bot:WasRecentlyDamagedByAnyHero(1.0) then
				return Engine.Intent("heal-interrupt", 80, "enemy_channel_heal", function()
					bot:Action_MoveToUnit(enemy)
					Style.Diag(bot, "heal-interrupt-chase")
				end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
			end
			return Engine.Blocked("heal-interrupt", 80, "unsafe", string.format("dist=%.0f hp=%.0f", dist, hp*100))
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
	if towerDanger(ctx) ~= nil then
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
		return Engine.Intent("hero-pass", 60, "nearby_enemy", function()
			bot.aib_passHeroLast = DotaTime()
			bot.aib_harassLast = DotaTime()
			bot:Action_AttackUnit(enemy, false)
			Style.Diag(bot, "hero-pass-atk")
		end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
	end

	return Engine.Intent("hero-pass", 55, "nearby_enemy", function()
		bot.aib_passHeroLast = DotaTime()
		bot:Action_MoveToUnit(enemy)
		Style.Diag(bot, "hero-pass-chase")
	end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
end

return M
