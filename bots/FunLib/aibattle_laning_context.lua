-- AIBattle laning per-tick context snapshot.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local function manaPct(bot)
	local maxMana = bot:GetMaxMana()
	if maxMana <= 0 then return 1.0 end
	return bot:GetMana() / maxMana
end

function M.Build(bot, dials, rules, enemyCreeps, allyCreeps, assignedLane, attackRange)
	local range = attackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(math.max(900, range + 520), true, BOT_MODE_NONE)
	local enemy = (enemies and #enemies > 0 and enemies[1]:IsAlive()) and enemies[1] or nil
	local tower = AIBUtils.EnemyTowerDanger(bot)
	return {
		bot = bot,
		dials = dials or {},
		rules = rules or {},
		enemyCreeps = enemyCreeps,
		allyCreeps = allyCreeps,
		assignedLane = assignedLane,
		attackRange = range,
		now = DotaTime(),
		hp = J.GetHP(bot),
		mana = manaPct(bot),
		enemy = enemy,
		enemyDist = enemy ~= nil and GetUnitToUnitDistance(bot, enemy) or math.huge,
		enemyTower = tower,
		towerThreat = AIBUtils.IsTowerActuallyThreatening(bot, tower),
	}
end

return M
