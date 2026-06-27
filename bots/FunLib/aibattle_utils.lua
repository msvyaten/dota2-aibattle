-- AIBattle shared utilities: pure/near-pure functions used across laning, survive, style.
-- All functions take bot explicitly; no module-level state, safe to require from any file.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

-- Nearest alive enemy tower within real danger range of bot. Returns handle or nil.
function M.EnemyTowerDanger(bot)
	local opp = GetOpposingTeam()
	local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_TOP_1, TOWER_BOT_1, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
	for _, id in ipairs(ids) do
		local t = GetTower(opp, id)
		if t ~= nil and t:IsAlive()
			and GetUnitToUnitDistance(bot, t) < t:GetAttackRange() + 120 then
			return t
		end
	end
	return nil
end

function M.IsTowerActuallyThreatening(bot, tower)
	if tower == nil or not tower:IsAlive() then return false end
	if GetUnitToUnitDistance(bot, tower) > tower:GetAttackRange() + 80 then return false end
	local target = tower:GetAttackTarget()
	if target ~= nil and target ~= bot and target:GetTeam() == bot:GetTeam() then
		return false
	end
	return true
end

-- 350 units in front of the nearest surviving friendly tower toward the enemy T1.
-- Falls back to tower location if geometry fails.
function M.ForwardSurvivingTowerLoc(bot)
	local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
	for _, id in ipairs(ids) do
		local t = GetTower(bot:GetTeam(), id)
		if t ~= nil and t:IsAlive() then
			local oppT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
			if oppT1 ~= nil then
				local tl, el = t:GetLocation(), oppT1:GetLocation()
				local d = math.sqrt((el.x-tl.x)^2 + (el.y-tl.y)^2)
				if d > 1 then
					return Vector(tl.x + (el.x-tl.x)/d * 350, tl.y + (el.y-tl.y)/d * 350, tl.z)
				end
			end
			return t:GetLocation()
		end
	end
	return nil
end

function M.SafeRetreatTowerLoc(bot)
	local ids = { TOWER_MID_1, TOWER_MID_2, TOWER_MID_3, TOWER_BASE_1, TOWER_BASE_2 }
	for _, id in ipairs(ids) do
		local t = GetTower(bot:GetTeam(), id)
		if t ~= nil and t:IsAlive() then
			local tl = t:GetLocation()
			local fl = J.GetTeamFountain()
			if fl ~= nil then
				local d = math.sqrt((fl.x-tl.x)^2 + (fl.y-tl.y)^2)
				if d > 1 then
					return Vector(tl.x + (fl.x-tl.x)/d * 520, tl.y + (fl.y-tl.y)/d * 520, tl.z)
				end
			end
			return t:GetLocation()
		end
	end
	return J.GetTeamFountain()
end

-- Centroid of nearby enemy lane creeps. Returns Vector or nil.
function M.EnemyCreepCentroid(enemyCreeps)
	local cx, cy, n = 0, 0, 0
	for _, c in pairs(enemyCreeps or {}) do
		if J.IsValid(c) then
			local l = c:GetLocation(); cx = cx + l.x; cy = cy + l.y; n = n + 1
		end
	end
	return n > 0 and Vector(cx / n, cy / n, 0) or nil
end

-- True when bot (ranged) is on lower terrain than target by >30 units; 25% miss applies.
function M.UphillMiss(bot, target)
	if (bot:GetAttackRange() or 0) <= 310 then return false end
	return GetHeightLevel(target:GetLocation()) > GetHeightLevel(bot:GetLocation())
end

return M
