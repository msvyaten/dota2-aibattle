-- AIBattle laning survival intents.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Engine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local function moveAwayFrom(loc, awayFrom, distance)
	local dx, dy = loc.x - awayFrom.x, loc.y - awayFrom.y
	local d = math.sqrt(dx*dx + dy*dy)
	if d < 1 then return loc + RandomVector(distance) end
	return Vector(loc.x + (dx/d)*distance, loc.y + (dy/d)*distance, loc.z)
end

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

	for _, creep in pairs(enemyCreeps or {}) do
		local dist = J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) or math.huge
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and (dist <= range - 60 or bot:GetAttackRange() <= 300) then
			return Engine.Intent("creep-aggro", 112, "creep_hitting", function()
				bot:Action_AttackUnit(creep, true)
				Style.Diag(bot, "creep-aggro-hit")
			end, string.format("hp=%.0f", hp*100))
		end
	end
	if hp >= 0.82 then
		return Engine.Blocked("creep-aggro", 75, "no_attackable_creep", string.format("hp=%.0f creeps=%d", hp*100, #enemyCreeps))
	end
	if hp >= 0.55 then
		return Engine.Blocked("creep-aggro", 74, "hold_position", string.format("hp=%.0f creeps=%d", hp*100, #enemyCreeps))
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
	local dest = laneRetreatLoc(bot, ctx, cen)
	if dest == nil then return nil end

	return Engine.Intent("creep-aggro", 95, "recent_creep_damage", function()
		bot.aib_creepReliefLast = DotaTime()
		bot.aib_creepReliefDest = dest
		bot:Action_MoveToLocation(dest)
		Style.Diag(bot, "creep-aggro-back")
	end, string.format("hp=%.0f dest=%.0f,%.0f", hp*100, dest.x, dest.y))
end

return M
