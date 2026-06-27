-- AIBattle laning desire policy.
-- Owns top-level desire gates and score components so mode_laning_generic.lua
-- does not accumulate unexplained thresholds.

local M = {}

M.Hp = {
	softRecovery = 0.55,      -- sustain can matter, but should not steal lane work by itself
	activeRecovery = 0.45,    -- low enough that recovery may be an independent desire
	safeLastHitMin = 0.28,    -- low-HP last-hit is allowed only above true danger
	danger = 0.35,            -- survival/safety starts winning over normal lane actions
	critical = 0.30,          -- recovery becomes urgent and rune/fight gates get stricter
	damageLockout = 0.40,     -- recent hero damage below this HP blocks greedy lane actions
	recoverDangerScore = 0.40,
	secondDeathSurvive = 0.40,
}

M.Scan = {
	noEnemyDist = 99999,
	enemyVisible = 900,
	enemyVisibleExtra = 520,
	attackExtra = 100,
	killChaseExtra = 360,
	advantageChaseExtra = 260,
	abilityThreat = 900,
	hasteChase = 1150,
	runeChase = 900,
	safetyCreepExtra = 160,
	safeCsRangeBuffer = 35,
}

M.Combat = {
	hpAdvantage = 0.12,
}

M.RecentDamage = {
	creepSeconds = 1.5,
	heroSeconds = 1.2,
}

M.Score = {
	safetyHealthy = 108,
	safetyDanger = 126,
	safetyCreepDamageBonus = 8,

	powerRuneBase = 104,
	powerRuneDoubleDamageBonus = 10,
	powerRuneHasteBonus = 6,
	powerRuneEnemyBonus = 5,

	fightBase = 78,
	fightRangeBonus = 18,
	fightHpAdvBonus = 8,
	fightExecuteBonus = 20,
	fightRuneBonus = 8,

	recoverBase = 74,
	recoverCritical = 118,
	recoverDanger = 102,
	recoverRunePenalty = -18,
	recoverCreepDamagePenalty = -14,

	siegeBase = 66,
	siegePushScale = 20,
	siegeEnemyDeadBonus = 22,
	siegeDoubleDamageBonus = 18,
	siegeLowHpPenalty = -18,
}

M.SiegeConfig = {
	candidateExtra = 560,
	alliedCreepsRequired = 2,
	towerCreepRangeExtra = 240,
}

M.Forward = {
	minUsefulMoveDist = 900,
	cooldown = 10.0,
	longMoveOverrideDist = 1600,
	suppressAfterEmptyDesire = 3.0,
}

local function add(parts, key, value)
	if value == nil or value == 0 then return end
	parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
end

local function detail(base, parts, extra)
	local out = { "base=" .. tostring(base) }
	for _, p in ipairs(parts or {}) do out[#out + 1] = p end
	if extra ~= nil and extra ~= "" then out[#out + 1] = extra end
	return table.concat(out, " ")
end

function M.EnemyScanRange(range)
	return math.max((range or 0) + M.Scan.enemyVisibleExtra, M.Scan.enemyVisible)
end

function M.EnemyActionable(args)
	if args == nil or args.enemy == nil then return false end
	local range = args.range or 0
	local dist = args.enemyDist or M.Scan.noEnemyDist
	local hp = args.hp or 0
	local enemyHp = args.enemyHp or 1
	local execHp = math.max(args.executeThreshold or 0, M.Hp.activeRecovery)
	local powerRune = args.powerRune
	local combatRune = args.actionPowerRune == true
	return dist <= range + M.Scan.attackExtra
		or (hp >= M.Hp.critical and dist <= M.Scan.abilityThreat)
		or (enemyHp <= execHp and dist <= range + M.Scan.killChaseExtra)
		or (hp >= enemyHp + M.Combat.hpAdvantage and dist <= range + M.Scan.advantageChaseExtra)
		or (combatRune and hp >= M.Hp.danger and dist <= ((powerRune == "haste") and M.Scan.hasteChase or M.Scan.runeChase))
end

function M.Safety(args)
	local recentCreepDamage = args.recentCreepDamage == true
	local recentHeroDamage = args.recentHeroDamage == true
	local hp = args.hp or 1
	if not ((recentCreepDamage and (args.attackableCreep == true or hp < M.Hp.danger))
		or (recentHeroDamage and hp < M.Hp.activeRecovery)) then
		return nil
	end
	local base = hp < M.Hp.danger and M.Score.safetyDanger or M.Score.safetyHealthy
	local score = base
	local parts = {}
	if recentCreepDamage then
		score = score + M.Score.safetyCreepDamageBonus
		add(parts, "creep_dmg", M.Score.safetyCreepDamageBonus)
	end
	return {
		score = score,
		reason = "recent_damage",
		detail = detail(base, parts, string.format("hp=%.0f creep=%s hero=%s", hp * 100, tostring(recentCreepDamage), tostring(recentHeroDamage))),
	}
end

function M.PowerRune(args)
	local powerRune = args.powerRune
	if args.actionPowerRune ~= true then return nil end
	local hp = args.hp or 1
	if hp < M.Hp.critical then return nil end
	local base = M.Score.powerRuneBase
	local score = base
	local parts = {}
	if powerRune == "double_damage" then
		score = score + M.Score.powerRuneDoubleDamageBonus
		add(parts, "dd", M.Score.powerRuneDoubleDamageBonus)
	end
	if powerRune == "haste" then
		score = score + M.Score.powerRuneHasteBonus
		add(parts, "haste", M.Score.powerRuneHasteBonus)
	end
	if args.enemy ~= nil then
		score = score + M.Score.powerRuneEnemyBonus
		add(parts, "enemy", M.Score.powerRuneEnemyBonus)
	end
	return {
		score = score,
		reason = powerRune,
		detail = detail(base, parts, string.format("hp=%.0f enemy=%s", hp * 100, tostring(args.enemy ~= nil))),
	}
end

function M.Fight(args)
	if args.enemy == nil or not M.EnemyActionable(args) then return nil end
	local hp = args.hp or 0
	if hp < M.Hp.critical then return nil end
	local range = args.range or 0
	local enemyDist = args.enemyDist or M.Scan.noEnemyDist
	local enemyHp = args.enemyHp or 1
	local execHp = math.max(args.executeThreshold or 0, M.Hp.activeRecovery)
	local base = M.Score.fightBase
	local score = base
	local parts = {}
	if enemyDist <= range + M.Scan.attackExtra then
		score = score + M.Score.fightRangeBonus
		add(parts, "range", M.Score.fightRangeBonus)
	end
	if hp >= enemyHp + M.Combat.hpAdvantage then
		score = score + M.Score.fightHpAdvBonus
		add(parts, "hp_adv", M.Score.fightHpAdvBonus)
	end
	if enemyHp <= execHp then
		score = score + M.Score.fightExecuteBonus
		add(parts, "execute", M.Score.fightExecuteBonus)
	end
	if args.actionPowerRune == true then
		score = score + M.Score.fightRuneBonus
		add(parts, "rune", M.Score.fightRuneBonus)
	end
	return {
		score = score,
		reason = "enemy_seen",
		detail = detail(base, parts, string.format("dist=%.0f hp=%.0f ehp=%.0f", enemyDist, hp * 100, enemyHp * 100)),
	}
end

function M.Recover(args)
	local hp = args.hp or 1
	local recentDamage = args.recentHeroDamage == true or args.recentCreepDamage == true
	if not (hp < M.Hp.softRecovery and (hp < M.Hp.activeRecovery or recentDamage)) then return nil end
	local base = M.Score.recoverBase
	local score = base
	local parts = {}
	if hp < M.Hp.critical then
		score = M.Score.recoverCritical
		add(parts, "critical", M.Score.recoverCritical - base)
	elseif hp < M.Hp.recoverDangerScore then
		score = M.Score.recoverDanger
		add(parts, "danger", M.Score.recoverDanger - base)
	end
	if args.actionPowerRune == true and hp >= M.Hp.danger then
		score = score + M.Score.recoverRunePenalty
		add(parts, "rune", M.Score.recoverRunePenalty)
	end
	if args.recentCreepDamage == true then
		score = score + M.Score.recoverCreepDamagePenalty
		add(parts, "creep_dmg", M.Score.recoverCreepDamagePenalty)
	end
	return {
		score = score,
		reason = "hp_gate",
		detail = detail(base, parts, string.format("hp=%.0f", hp * 100)),
	}
end

function M.Siege(args)
	if args.hasSiegeCandidate ~= true then return nil end
	local hp = args.hp or 1
	local base = M.Score.siegeBase
	local score = base + math.floor(M.Score.siegePushScale * ((args.dials or {}).push_desire or 0.5))
	local parts = { "push=" .. tostring(score - base) }
	if args.enemyDeadRecently == true then
		score = score + M.Score.siegeEnemyDeadBonus
		add(parts, "enemy_dead", M.Score.siegeEnemyDeadBonus)
	end
	if args.powerRune == "double_damage" then
		score = score + M.Score.siegeDoubleDamageBonus
		add(parts, "dd", M.Score.siegeDoubleDamageBonus)
	end
	if hp < M.Hp.activeRecovery then
		score = score + M.Score.siegeLowHpPenalty
		add(parts, "low_hp", M.Score.siegeLowHpPenalty)
	end
	return {
		score = score,
		reason = "tower_window",
		detail = detail(base, parts, string.format("hp=%.0f", hp * 100)),
	}
end

return M
