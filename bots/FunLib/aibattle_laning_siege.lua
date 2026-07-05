-- AIBattle laning siege window.
-- Keeps tower pressure policy out of mode_laning_generic.lua while preserving the
-- existing callbacks/diagnostics from that file.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')

function M.Think(ctx)
	local bot = ctx.bot
	local dials = ctx.dials or {}
	local rules = ctx.rules or {}
	local attackRange = ctx.attackRange or bot:GetAttackRange()

	local twr = ctx.enemyTowerDanger()
	if twr == nil then
		local midT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if midT1 ~= nil and midT1:IsAlive()
			and ctx.alliedCreepsAtTower(midT1, midT1:GetAttackRange() + 220) >= 2 then
			twr = midT1
		end
	end
	if twr == nil then return false end

	-- tower_aggression: risk gates for sieging. Desire knobs (push_desire, cwp)
	-- say how much the bot wants the tower; this rule says what risk it accepts.
	local towerAggr = rules.tower_aggression or "default"
	if towerAggr == "never" then
		ctx.blocked("siege", "tower_aggression_never", string.format("tower=%.0f", GetUnitToUnitDistance(bot, twr)), 5.0)
		return false
	end
	if ctx.towerThreatening(twr) and towerAggr ~= "always" then return false end

	local cwp = rules.creep_wave_priority or "last_hit_only"
	local enemy, enemyDist = ctx.nearestEnemyHero(2200)
	local enemyFarOrWeak = enemy == nil or enemyDist > 1300 or J.GetHP(enemy) < 0.28
	local waveCount = ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 180)
	local waveAtTower = waveCount >= 1
	local strongWaveAtTower = waveCount >= 3
	local advantageSiege = ctx.enemyDeadRecently() or (waveAtTower and enemyFarOrWeak)
	local wantsSiege = towerAggr == "always" or cwp == "push" or advantageSiege or (dials.push_desire or 0.5) >= 0.65
	local siegeHpFloor = ctx.enemyDeadRecently() and 0.22 or 0.35
	if towerAggr == "always" then siegeHpFloor = ctx.enemyDeadRecently() and 0.20 or 0.28 end
	if not wantsSiege or J.GetHP(bot) < siegeHpFloor then
		ctx.blocked("siege", "desire_or_hp", string.format("hp=%.0f adv=%s", J.GetHP(bot) * 100, tostring(advantageSiege)), 5.0)
		ctx.towerOpportunity("blocked_desire_or_hp", string.format("wave=%d hp=%.0f adv=%s", waveCount, J.GetHP(bot) * 100, tostring(advantageSiege)), 5.0)
		return false
	end

	local now = DotaTime()
	local twrDist = GetUnitToUnitDistance(bot, twr)
	local alliedTank = false
	local target = twr:GetAttackTarget()
	if target ~= nil and target:GetTeam() == GetTeam() then alliedTank = true end
	if not alliedTank then
		for _, creep in pairs(ctx.allyCreeps or {}) do
			if J.IsValid(creep) and GetUnitToUnitDistance(creep, twr) <= twr:GetAttackRange() + 120 then
				alliedTank = true; break
			end
		end
	end
	if not alliedTank and towerAggr ~= "always" then
		if ctx.enemyDeadRecently() and twrDist > attackRange + 60 then
			ctx.state("siege-window", string.format("ttl=2 wave=%d tower=%.0f hp=%.0f adv=%s", waveCount, twrDist, J.GetHP(bot) * 100, tostring(advantageSiege)), 2.0)
			ctx.towerOpportunity("step", string.format("phase=dead_no_tank wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-dead-no-tank-step")
			return ctx.moveToAttackEdge(twr, "siege-dead-no-tank-step", 80)
		end
		ctx.blocked("siege", "no_allied_tank", string.format("tower=%.0f", GetUnitToUnitDistance(bot, twr)), 5.0)
		ctx.towerOpportunity("blocked_no_tank", string.format("wave=%d tower=%.0f", waveCount, GetUnitToUnitDistance(bot, twr)), 5.0)
		return false
	end
	if not alliedTank then
		-- tower_aggression=always without wave cover: reckless tower hits.
		if twrDist <= attackRange + 60 then
			bot.aib_siegeCommitUntil = now + 2.0
			bot:Action_AttackUnit(twr, true)
			ctx.towerOpportunity("hit", string.format("phase=no_tank_always wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-no-tank-tower")
			return true
		end
		bot.aib_siegeCommitUntil = now + 2.0
		ctx.towerOpportunity("step", string.format("phase=no_tank_always wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		return ctx.moveToAttackEdge(twr, "siege-no-tank-step", 40)
	end

	local inTowerAttackRange = twrDist <= attackRange + 60
	ctx.state("siege-window", string.format("ttl=2 wave=%d tower=%.0f hp=%.0f adv=%s", waveCount, twrDist, J.GetHP(bot) * 100, tostring(advantageSiege)), 2.0)
	local safeHealingHit = alliedTank and inTowerAttackRange and J.GetHP(bot) >= (ctx.enemyDeadRecently() and 0.30 or 0.38)
	if ctx.healingChannelActive() and not ctx.enemyDeadRecently() and not safeHealingHit then
		ctx.blocked("siege", "healing", string.format("tower=%.0f tank=%s", twrDist, tostring(alliedTank)), 4.0)
		ctx.towerOpportunity("blocked_healing", string.format("wave=%d tower=%.0f", waveCount, twrDist), 4.0)
		return false
	end

	if alliedTank and waveAtTower and twrDist <= attackRange + 180
		and J.GetHP(bot) >= (ctx.enemyDeadRecently() and 0.26 or 0.34) then
		bot.aib_siegeCommitUntil = now + 2.4
		bot:Action_AttackUnit(twr, true)
		ctx.towerOpportunity("hit", string.format("phase=terminal wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		ctx.diag("siege-terminal-tower")
		return true
	end

	if enemy ~= nil and enemy:IsAlive() and enemyDist <= attackRange + 80
		and J.GetHP(bot) >= 0.45
		and (ctx.uphillMiss == nil or not ctx.uphillMiss(enemy)) then
		local hasDamageRune = bot:HasModifier("modifier_rune_doubledamage")
		local hpAdv = J.GetHP(bot) >= J.GetHP(enemy) + 0.08
		local killWindow = J.GetHP(enemy) <= 0.60
		if hasDamageRune or hpAdv or killWindow or (rules.hero_priority or "default") == "always" then
			bot.aib_siegeCommitUntil = now + 1.2
			bot:Action_AttackUnit(enemy, false)
			ctx.towerOpportunity("hit", string.format("phase=hero wave=%d hero=%.0f ehp=%.0f", waveCount, enemyDist, J.GetHP(enemy) * 100), 2.0)
			ctx.diag("siege-hero")
			return true
		end
	end

	if bot.aib_siegeCommitUntil ~= nil and now <= bot.aib_siegeCommitUntil then
		ctx.towerOpportunity(twrDist <= attackRange + 180 and "hit" or "step", string.format("phase=commit wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		return AIBEngine.AttackOrMoveToBand(ctx, twr, "siege-commit-tower", 30)
	end

	if strongWaveAtTower and (cwp == "push" or ctx.enemyDeadRecently() or enemyFarOrWeak) then
		if twrDist <= attackRange + 60 then
			bot.aib_siegeCommitUntil = now + 2.2
			bot:Action_AttackUnit(twr, true)
			ctx.towerOpportunity("hit", string.format("phase=wave wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-wave-tower")
			return true
		end
		bot.aib_siegeCommitUntil = now + 2.2
		ctx.towerOpportunity("step", string.format("phase=wave wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		return ctx.moveToAttackEdge(twr, "siege-wave-step", 20)
	end

	for _, creep in pairs(ctx.enemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= attackRange + 40 then
			bot.aib_siegeCommitUntil = now + 1.6
			bot:Action_AttackUnit(creep, true)
			ctx.diag("siege-creep")
			return true
		end
	end
	if twrDist <= attackRange + 60 then
		bot.aib_siegeCommitUntil = now + 1.6
		bot:Action_AttackUnit(twr, true)
		ctx.towerOpportunity("hit", string.format("phase=default wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		ctx.diag("siege-tower")
		return true
	end
	if bot.aib_siegeLast == nil or now - bot.aib_siegeLast >= 1.0 then
		bot.aib_siegeLast = now
		bot.aib_siegeCommitUntil = now + 1.6
		ctx.towerOpportunity("step", string.format("phase=default wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		ctx.moveToAttackEdge(twr, "siege-step", 30)
	else
		local pushCreep = ctx.nearestAttackableEnemyCreep(attackRange + 40)
		if pushCreep ~= nil then
			bot:Action_AttackUnit(pushCreep, true)
			ctx.diag("siege-hold-creep")
		else
			ctx.towerOpportunity("step", string.format("phase=hold wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.moveToAttackEdge(twr, "siege-hold-step", 30)
		end
	end
	return true
end

return M
