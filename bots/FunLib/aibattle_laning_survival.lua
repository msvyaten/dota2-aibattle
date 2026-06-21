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

function M.CreepAggroRelief(ctx)
	local bot = ctx.bot
	if not bot:WasRecentlyDamagedByCreep(1.0) then return nil end
	Style.DiagRL(bot, "creep-dmg", 3)

	local rules = ctx.rules or {}
	local enemyCreeps = ctx.enemyCreeps or {}
	local hp = J.GetHP(bot)
	local hpGate = rules.creep_aggro_relief_hp or 0.68
	if hp >= hpGate then
		return Engine.Blocked("creep-aggro", 90, "hp_ok", string.format("hp=%.0f creeps=%d", hp*100, #enemyCreeps))
	end

	local now = DotaTime()
	if bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < 1.2 then
		if bot.aib_creepReliefDest ~= nil then
			return Engine.Intent("creep-aggro", 70, "cooldown_hold", function()
				bot:Action_MoveToLocation(bot.aib_creepReliefDest)
			end, string.format("hp=%.0f", hp*100))
		end
		return nil
	end

	local dest = AIBUtils.ForwardSurvivingTowerLoc(bot)
	local cen = AIBUtils.EnemyCreepCentroid(enemyCreeps)
	if dest == nil and cen ~= nil then
		dest = moveAwayFrom(bot:GetLocation(), cen, 420)
	end
	if dest == nil then dest = GetLaneFrontLocation(bot:GetTeam(), ctx.assignedLane, -350) end
	if dest == nil then return nil end

	if GetUnitToLocationDistance(bot, dest) < 220 and cen ~= nil then
		dest = moveAwayFrom(bot:GetLocation(), cen, 360)
	end

	return Engine.Intent("creep-aggro", 95, "recent_creep_damage", function()
		bot.aib_creepReliefLast = DotaTime()
		bot.aib_creepReliefDest = dest
		bot:Action_MoveToLocation(dest)
		Style.Diag(bot, "creep-aggro-back")
	end, string.format("hp=%.0f dest=%.0f,%.0f", hp*100, dest.x, dest.y))
end

return M
