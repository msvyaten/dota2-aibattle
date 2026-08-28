-- AIBattle laning survival intents.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Engine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local moveAwayFrom = AIBUtils.MoveAwayFrom

local function laneRetreatLoc(bot, ctx, fallbackCen)
	local lane = ctx.assignedLane or LANE_MID
	local dest = AIBUtils.ForwardSurvivingTowerLoc(bot)
		or GetLaneFrontLocation(bot:GetTeam(), lane, -450)
	if dest ~= nil then return dest end
	if fallbackCen ~= nil then return moveAwayFrom(bot:GetLocation(), fallbackCen, 360) end
	return nil
end

function M.CreepAggroRelief(ctx)
	local bot = ctx.bot
	if not bot:WasRecentlyDamagedByCreep(1.0) then return nil end
	Style.DiagRL(bot, "creep-dmg", 3)

	local enemyCreeps = ctx.enemyCreeps or {}
	local hp = J.GetHP(bot)
	local range = ctx.attackRange or bot:GetAttackRange()
	local now = DotaTime()
	if bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < 1.2
		and bot.aib_creepReliefDest ~= nil then
		return Engine.Intent("creep-aggro", 72, "react_followup", function()
			bot:Action_MoveToLocation(bot.aib_creepReliefDest)
		end, string.format("hp=%.0f", hp*100))
	end
	if bot.aib_creepDmgSeen == nil or now - bot.aib_creepDmgSeen > 3.0 then
		bot.aib_creepDmgCount = 0
	end
	if bot.aib_creepDmgTick == nil or now - bot.aib_creepDmgTick >= 0.6 then
		bot.aib_creepDmgTick = now
		bot.aib_creepDmgSeen = now
		bot.aib_creepDmgCount = (bot.aib_creepDmgCount or 0) + 1
	end
	local repeatedDamage = (bot.aib_creepDmgCount or 0) >= 2

	-- Punishing the chip is only correct while nobody bigger is on us. 8969965270 t=159-165:
	-- Dire fell 67% -> 10% in six seconds with this branch owning every tick -- a creep was
	-- chipping it (hits=7, then 9, inside_melee_pack count=2) and the enemy SF stood at 582-602
	-- free-hitting, so `winner=creep-aggro:112 losers=hero-pass:60` repeated and the bot answered
	-- the CREEP. Hitting a creep back does not drop creep aggro -- only walking away does, which
	-- is the step-out branch BELOW -- and it does not answer the hero either, so the exchange was
	-- one-sided by construction. Yield the shortcut while a hero is actually trading with us and
	-- let the rest of the ladder own the tick: above the relief threshold that means `chip_ignored`
	-- at 10 and hero-pass takes the trade at 105/90, below it the step-out at 95 leaves the wave.
	-- Same hero-in-band idiom as PassingHeroTrade, so the two candidates agree on "a hero is here".
	local heroTrading = bot:WasRecentlyDamagedByAnyHero(2.0)
	if heroTrading then
		local nearby = bot:GetNearbyHeroes(range + 220, true, BOT_MODE_NONE)
		heroTrading = nearby ~= nil and #nearby > 0 and nearby[1]:IsAlive()
	end

	if heroTrading then
		-- Plain counter, same scale as creep-aggro-hit, so the pair is directly comparable.
		Style.Diag(bot, "creep-aggro-hero-yield")
		Style.Blocked(bot, "creep-aggro", "hero_trading",
			string.format("hp=%.0f hits=%d", hp * 100, bot.aib_creepDmgCount or 0), 3.0)
	else
		for _, creep in pairs(enemyCreeps or {}) do
			local dist = J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) or math.huge
			if J.IsValid(creep) and J.CanBeAttacked(creep)
				and (dist <= range - 60 or AIBUtils.IsMelee(bot) or (repeatedDamage and dist <= range + 80)) then
				return Engine.Intent("creep-aggro", 112, "creep_hitting", function()
					bot:Action_AttackUnit(creep, true)
					Style.Diag(bot, "creep-aggro-hit")
				end, string.format("hp=%.0f", hp*100))
			end
		end
	end
	if bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < 1.2 then
		if bot.aib_creepReliefDest ~= nil then
			return Engine.Intent("creep-aggro", 70, "cooldown_hold", function()
				bot:Action_MoveToLocation(bot.aib_creepReliefDest)
			end, string.format("hp=%.0f", hp*100))
		end
		return nil
	end

	local cen = AIBUtils.EnemyCreepCentroid(enemyCreeps)
	-- 0.74 was the only place this threshold existed; the creep_aggro_relief_hp rule that
	-- is supposed to own it went unread since it was added. See Style.CreepAggroReliefThreshold.
	if hp >= Style.CreepAggroReliefThreshold() and not repeatedDamage then
		return Engine.Blocked("creep-aggro", 10, "chip_ignored",
			string.format("hp=%.0f hits=%d", hp * 100, bot.aib_creepDmgCount or 0))
	end
	local dest = laneRetreatLoc(bot, ctx, cen)
	if dest == nil then return nil end

	local prio = 95
	local reason = "recent_creep_damage"
	local distToDest = GetUnitToLocationDistance(bot, dest)
	if hp >= 0.55 then
		prio = 82
		reason = "chip_step"
		if distToDest < 180 and cen ~= nil then
			dest = moveAwayFrom(bot:GetLocation(), cen, 190)
		end
	end

	return Engine.Intent("creep-aggro", prio, reason, function()
		bot.aib_creepReliefLast = DotaTime()
		bot.aib_creepReliefDest = dest
		bot:Action_MoveToLocation(dest)
		Style.Diag(bot, "creep-aggro-back")
	end, string.format("hp=%.0f dest=%.0f,%.0f", hp*100, dest.x, dest.y))
end

return M
