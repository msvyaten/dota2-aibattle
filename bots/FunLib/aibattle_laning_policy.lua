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
	-- Floor below which the recover no-action cap never applies. Real sub-danger retreat
	-- is owned PRE-arbiter (early-low gate at hp<danger + critical-lock), so a no-action
	-- recover desire is redundant at any hp; the floor is paranoia for emergency overlap.
	recoverCapFloor = 0.25,
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
	-- Score cap when safety has damage SYMPTOMS but no feasible ACTION right now
	-- (creep-react on its internal throttle, hp too high for retreat, unstuck not
	-- armed). Below fightBase so a live fight takes the tick; above zero so safety
	-- still wins quiet ticks and keeps the damage-unstuck anchor upkeep running.
	safetyNoAction = 44,

	powerRuneBase = 104,
	powerRuneDoubleDamageBonus = 10,
	powerRuneHasteBonus = 6,
	powerRuneEnemyBonus = 5,

	fightBase = 78,
	fightRangeBonus = 18,
	fightHpAdvBonus = 8,
	fightExecuteBonus = 20,
	fightRuneBonus = 8,
	-- Score cap when the enemy is visible but every fight action is gated
	-- (out of range + uphill/low-hp block the approach). See safetyNoAction.
	fightNoAction = 40,

	recoverBase = 74,
	recoverCritical = 118,
	recoverDanger = 102,
	recoverRunePenalty = -18,
	recoverCreepDamagePenalty = -14,
	-- Free-farm window: while the enemy is dead the lane is safe, so a soft recover must not
	-- pull the bot off the wave -- that is the bot spending the reward it just earned.
	-- -20 drops the base band 74 -> 54, just under safe-cs 56, so CS takes the tick instead.
	recoverEnemyDeadPenalty = -20,
	-- Score cap when recover has low-HP SYMPTOMS but no feasible action: behind the safe
	-- anchor, no recovery resources and no live threat, so the retreat move just twitches
	-- under the tower (8888784979 t=118-123: recover:92 won post-fight, empty 2x+). Below
	-- CS (50-56) so a securable last-hit takes the tick instead. See safetyNoAction.
	recoverNoAction = 44,

	siegeBase = 66,
	siegePushScale = 20,
	siegeEnemyDeadBonus = 22,
	siegeDoubleDamageBonus = 18,
	siegeLowHpPenalty = -18,
	-- Score cap when the siege desire wins but every siege action is gated (no wave
	-- cover / healing tank / hp floor), so it empty-wins and paces at the tower edge
	-- (8888743934: 8x empty-win + edge-step<->lane-line pace). Below CS. See safetyNoAction.
	siegeNoAction = 42,
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
	-- The long-move override exists so a badly out-of-position bot does not wait out the 10s
	-- cooldown. It used to bypass the cooldown ENTIRELY, which reads as "re-issue the move
	-- every tick": 8907379308 [R] fwd-position went 17 -> 109 in 63s (~1.5/s) while the
	-- destination is recomputed from the moving lane front each tick, so every re-issue
	-- retargets slightly and the hero stutters in place. Same class as f26c645. Still prompt,
	-- no longer a per-tick order spam.
	longMoveCooldown = 1.5,
	suppressAfterEmptyDesire = 3.0,
	laneFallbackMinHp = 0.55,
	laneFallbackRecoveryCooldown = 2.5,
	laneFallbackCreepReliefCooldown = 1.8,
	laneFallbackFrontBackoff = 180,
	laneFallbackNoCreepMaxFwd = 0.50,
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
	local reason = "recent_damage"
	local capped = false
	-- canAct contract (P4): damage symptoms alone must not outbid a live fight when
	-- every safety action is currently infeasible/throttled. Empty safety wins were
	-- 8-14 per match (8882870342 t=0-18: safety:116 won 8x, 11 empty_action).
	if args.safetyCanAct == false and hp >= M.Hp.danger then
		score = math.min(score, M.Score.safetyNoAction)
		reason = "symptom_no_action"
		capped = true
	end
	return {
		score = score,
		reason = reason,
		capped = capped,
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
	local reason = "enemy_seen"
	local capped = false
	-- canAct contract (P4), fight side: seen-but-unreachable must not own the tick.
	if args.fightCanAct == false then
		score = math.min(score, M.Score.fightNoAction)
		reason = "seen_unreachable"
		capped = true
	end
	return {
		score = score,
		reason = reason,
		capped = capped,
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
	-- Free-farm window (8906694824 t=238: the brawler took a kill worth 463g at 19% HP and
	-- immediately walked off to regen, returning only at t=258 -- it spent its own reward).
	-- A penalty, NOT a veto, and only above critical HP: with the enemy dead the lane is safe
	-- from heroes, but the creep wave alone still kills a critical bot (proven in 8906632392).
	-- LIMIT, stated honestly: this does not cover that exact 19% case, which sits below
	-- critical. There the bot walked AWAY from its own tower toward a rune -- rune-seek eating
	-- the dead-window is a separate, already-known issue and is NOT addressed here.
	if args.enemyDeadRecently == true and hp >= M.Hp.critical then
		score = score + M.Score.recoverEnemyDeadPenalty
		add(parts, "enemy_dead", M.Score.recoverEnemyDeadPenalty)
	end
	local reason = "hp_gate"
	local capped = false
	-- canAct contract (P4), recover side: cap a symptom-only recover so it loses to CS.
	-- Floor lowered danger->recoverCapFloor (8903952032 W3: D afk'd 36s at hp=27-33 under
	-- its tower, recover 118 empty-winning -- sub-danger retreat already ran PRE-arbiter
	-- via early-low/critical-lock, so if THEY found nothing the desire has nothing either).
	-- The recoverUseless veto (mode_laning) removes the no-damage case; this cap adds the
	-- post-fight case where recentDamage keeps that veto from firing but the bot is still
	-- behind its anchor with nothing to do. See SPECS 3.6.1.
	if args.recoverCanAct == false and hp >= M.Hp.recoverCapFloor then
		score = math.min(score, M.Score.recoverNoAction)
		reason = "hp_gate_no_action"
		capped = true
	end
	return {
		score = score,
		reason = reason,
		capped = capped,
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
	local reason = "tower_window"
	local capped = false
	-- canAct contract (P4), siege side: cap a siege desire whose action is fully gated so
	-- it stops empty-winning and pacing at the tower. See safetyNoAction / SPECS 3.6.1.
	if args.siegeCanAct == false then
		score = math.min(score, M.Score.siegeNoAction)
		reason = "window_no_action"
		capped = true
	end
	return {
		score = score,
		reason = reason,
		capped = capped,
		detail = detail(base, parts, string.format("hp=%.0f", hp * 100)),
	}
end

return M
