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

function M.IsTowerActuallyThreatening(bot, tower, drawsAggro)
	if tower == nil or not tower:IsAlive() then return false end
	if GetUnitToUnitDistance(bot, tower) > tower:GetAttackRange() + 80 then return false end
	-- drawsAggro=true: the bot is about to attack an enemy hero in tower range, which
	-- makes the tower retarget from creeps to the bot (Dota aggro rule). A tower
	-- currently on an allied creep is NOT safe for that action -- range alone = threat.
	if drawsAggro then return true end
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

function M.IsCloserToFountain(bot, loc)
	if bot == nil or loc == nil then return false end
	local fl = J.GetTeamFountain()
	if fl == nil then return false end
	local bl = bot:GetLocation()
	local botDist = math.sqrt((fl.x-bl.x)^2 + (fl.y-bl.y)^2)
	local locDist = math.sqrt((fl.x-loc.x)^2 + (fl.y-loc.y)^2)
	return botDist + 80 < locDist
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

local function safeHeightLevel(loc)
	if loc == nil or GetHeightLevel == nil then return nil end
	local ok, height = pcall(GetHeightLevel, loc)
	if ok and type(height) == "number" then return height end
	return nil
end

-- True when bot (ranged) is on lower terrain than target; 25% miss applies.
function M.UphillMiss(bot, target)
	if bot == nil or target == nil then return false end
	if (bot:GetAttackRange() or 0) <= 310 then return false end
	if bot.GetLocation == nil or target.GetLocation == nil then return false end
	local okBot, botLoc = pcall(function() return bot:GetLocation() end)
	local okTarget, targetLoc = pcall(function() return target:GetLocation() end)
	if not okBot or not okTarget then return false end
	local botHeight = safeHeightLevel(botLoc)
	local targetHeight = safeHeightLevel(targetLoc)
	return botHeight ~= nil and targetHeight ~= nil and targetHeight > botHeight
end

return M
