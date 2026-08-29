-- AIBattle shared internal constants.
-- These are engine/runtime guards, not LLM-facing rules.

local M = {}

M.Visual = {
	afkSeconds = 3.5,
	afkDistance = 90.0,
	holdSeconds = 2.0,
	holdDistance = 55.0,
}

M.Rune = {
	commitSeconds = 30.0,
	bottleMaxDist = 1900.0,
	bottleStageMaxDist = 4300.0,
	bottleLaneBudget = 1500.0,
	waterRecoveryMaxDist = 4700.0,
	recoveryMaxDist = 3600.0,
	recoveryStageMaxDist = 4700.0,
	waterEmergencyStageWindow = 20.0,
	waterMidContextMax = 4200.0,
}

M.Recovery = {
	emergencyHp = 0.22,
	trueEmergencyHp = 0.14,
	earlyLowHp = 0.35,
	laneLowHp = 0.55,
	criticalLockClearHp = 0.34,
	criticalRuneYieldHp = 0.30,
	noActionFloor = 0.30,
}

M.Fight = {
	minExecuteHp = 0.24,
	mutualEnemyHp = 0.35,
	mutualSelfHp = 0.38,
	minSelfHp = 0.14,
	hpAdvantage = 0.14,
	lowFarmEnemyHp = 0.60,
}

M.Creeps = {
	lastHitDamageWindow = 1.5,
	defaultDenyHp = 0.49,
	alwaysDenyHp = 0.60,
	pushAllyNear = 500,
	denyBacktrackSkip = 250,
}

return M
