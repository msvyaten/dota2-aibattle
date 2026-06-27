-- AIBattle laning combat layer: hero contact, chase, abilities, rune pressure.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')

local function attackRange(ctx)
	return ctx.attackRange or ctx.bot:GetAttackRange()
end

local function powerRuneTowerTarget(ctx, range)
	local bot = ctx.bot
	local twr = ctx.enemyTowerDanger()
	if not J.IsValid(twr) then
		local midT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if J.IsValid(midT1) and GetUnitToUnitDistance(bot, midT1) <= range + 650 then
			twr = midT1
		end
	end
	if not J.IsValid(twr) then return nil, 0 end
	local wave = ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 220)
	if wave < 1 then return nil, wave end
	if ctx.towerThreatening(twr) and wave < 2 then return nil, wave end
	return twr, wave
end

function M.ContactHero(ctx)
	local bot = ctx.bot
	local rules = ctx.rules or {}
	if (rules.hero_priority or "default") == "never" then return false end

	local range = attackRange(ctx)
	local enemy, dist = ctx.nearestEnemyHero(math.max(range + 260, 780))
	if enemy == nil then return false end

	local now = DotaTime()
	if bot.aib_contactHeroLast ~= nil and now - bot.aib_contactHeroLast < 0.65 then return false end

	local hp = J.GetHP(bot)
	if hp < 0.32 then
		local safe = ctx.forwardSurvivingTowerLoc()
		if safe ~= nil and GetUnitToLocationDistance(bot, safe) > 120 then
			bot.aib_contactHeroLast = now
			Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=low_hp_kite", dist, hp * 100))
			bot:Action_MoveToLocation(safe)
			ctx.diag("hero-contact-kite")
			return true
		end
		ctx.blocked("hero-contact", "low_hp_no_safe", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
		return false
	end

	if dist <= range + 80 then
		if dist > range and ctx.uphillMiss(enemy) then
			ctx.blocked("hero-contact", "uphill", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
			return false
		end
		bot.aib_contactHeroLast = now
		bot.aib_harassLast = now
		Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=attackable_enemy", dist, hp * 100))
		bot:Action_AttackUnit(enemy, false)
		ctx.diag("hero-contact-atk")
		return true
	end

	if hp >= 0.45 and ctx.enemyTowerDanger() == nil and not ctx.uphillMiss(enemy) then
		bot.aib_contactHeroLast = now
		Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=close_enemy", dist, hp * 100))
		return ctx.moveToAttackEdge(enemy, "hero-contact-chase", 0)
	end

	ctx.blocked("hero-contact", "unsafe", string.format("dist=%.0f hp=%.0f tower=%s", dist, hp * 100, tostring(ctx.enemyTowerDanger() ~= nil)), 3.0)
	return false
end

function M.AbilityPressure(ctx)
	local bot = ctx.bot
	if J.GetHP(bot) < 0.30 then return false end
	local enemy, dist = ctx.nearestEnemyHero(900)
	if enemy == nil or not enemy:IsAlive() then return false end
	local twr = ctx.enemyTowerDanger()
	if twr ~= nil and ctx.towerThreatening(twr) and not Style.MayDive(bot) then
		ctx.blocked("ability-pressure", "tower", string.format("dist=%.0f", dist), 3.0)
		return false
	end
	if Style.AbilityExecute(bot, enemy) then return true end
	if J.GetHP(enemy) - J.GetHP(bot) > 0.35 then
		ctx.blocked("ability-pressure", "hp_disadv", string.format("dist=%.0f hp=%.0f ehp=%.0f", dist, J.GetHP(bot) * 100, J.GetHP(enemy) * 100), 3.0)
		return false
	end
	if Style.AbilityHarass(bot, enemy) then return true end
	return false
end

function M.RunePowerPressure(ctx)
	local bot = ctx.bot
	local policy = AIBEngine.RuneUsePolicy(bot, ctx.dials, ctx.rules)
	if policy == nil then return false end
	local hasDamageRune = policy.name == "double_damage"
	local hasHasteRune = policy.name == "haste"
	local hasArcaneRune = policy.name == "arcane"
	local hasActionRune = AIBEngine.IsActionPowerRune(policy.name)
	if not hasActionRune then return false end
	if J.GetHP(bot) < (policy.minFightHp or 0.38) then return false end
	local range = attackRange(ctx)
	local enemy, dist = ctx.nearestEnemyHero(policy.maxChase or (hasHasteRune and 1150 or 950))
	if enemy ~= nil and enemy:IsAlive()
		and ctx.enemyTowerDanger() == nil
		and not ctx.uphillMiss(enemy)
		and ((policy.heroPressure or 0.5) >= 0.45 or J.GetHP(enemy) <= 0.45) then
		Style.Intent(bot, "rune-pressure", string.format("rune=%s target=hero dist=%.0f hp=%.0f", policy.name, dist, J.GetHP(bot) * 100), 2.0)
		if Style.AbilityExecute(bot, enemy) then return true end
		if hasArcaneRune and Style.AbilityHarass(bot, enemy) then return true end
		if dist <= range + 80 then
			bot:Action_AttackUnit(enemy, false)
			ctx.diag("rune-pressure-atk")
			return true
		end
		return ctx.moveToAttackEdge(enemy, "rune-pressure-chase", 0)
	end
	if policy.useForTowerWithWave == true and (policy.towerPressure or 0.5) >= 0.45 then
		local twr, wave = powerRuneTowerTarget(ctx, range)
		if twr ~= nil then
			Style.Intent(bot, "rune-pressure", string.format("rune=%s target=tower tower=%.0f wave=%d", policy.name, GetUnitToUnitDistance(bot, twr), wave), 2.0)
			if GetUnitToUnitDistance(bot, twr) <= range + 160 then
				bot:Action_AttackUnit(twr, true)
				ctx.diag("rune-pressure-tower")
				return true
			end
			return ctx.moveToAttackEdge(twr, "rune-pressure-tower-step", 20)
		end
	end
	if hasDamageRune and (policy.creepPressure or 0.5) >= 0.35 then
		local creep = ctx.nearestAttackableEnemyCreep(range + 80)
		if creep ~= nil then
			Style.Intent(bot, "rune-pressure", string.format("rune=%s target=creep", policy.name), 2.0)
			bot:Action_AttackUnit(creep, true)
			ctx.diag("rune-pressure-creep")
			return true
		end
	end
	return false
end

function M.HeroOverCreep(ctx)
	local bot = ctx.bot
	local atkHero = bot:GetNearbyHeroes(attackRange(ctx) + 60, true, BOT_MODE_NONE)
	local heroPrio = ctx.rules.hero_priority or "default"
	local exec = ctx.dials.execute_threshold or 0
	local heroOverCreepHp = exec + ((heroPrio == "always") and 0.08 or 0.0)
	if atkHero and #atkHero > 0 and atkHero[1]:IsAlive()
		and heroPrio ~= "never"
		and exec > 0
		and J.GetHP(bot) >= 0.35
		and J.GetHP(atkHero[1]) <= math.min(0.65, heroOverCreepHp)
		and ctx.enemyTowerDanger() == nil
		and not ctx.uphillMiss(atkHero[1]) then
		if Style.AbilityExecute(bot, atkHero[1]) then return true end
		bot:Action_AttackUnit(atkHero[1], false)
		ctx.diag("hero-over-creep")
		return true
	end
	return false
end

function M.EmergencyKillPriority(ctx)
	local bot = ctx.bot
	if ctx.deathSurvive or (ctx.dials.execute_threshold or 0) <= 0 then return false end
	local atkHero = bot:GetNearbyHeroes(attackRange(ctx) + 50, true, BOT_MODE_NONE)
	if atkHero and #atkHero > 0 then
		local enemy = atkHero[1]
		if enemy:IsAlive() and J.GetHP(enemy) < ctx.dials.execute_threshold then
			bot:Action_AttackUnit(enemy, true)
			ctx.diag("kill-priority")
			return true
		end
	end
	return false
end

function M.UphillReposition(ctx)
	if ctx.lowHpHold then return false end
	local bot = ctx.bot
	local uphEnemy = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
	if uphEnemy and #uphEnemy > 0 and uphEnemy[1]:IsAlive()
		and ctx.uphillMiss(uphEnemy[1]) then
		local ownT1uph = GetTower(GetTeam(), TOWER_MID_1)
		local highPos = (ownT1uph ~= nil and ownT1uph:IsAlive()) and ownT1uph:GetLocation()
			or ctx.forwardSurvivingTowerLoc()
		if highPos and GetUnitToLocationDistance(bot, highPos) > 300 then
			bot:Action_MoveToLocation(highPos + RandomVector(50))
			ctx.diag("uphill-reposition")
			return true
		end
	end
	return false
end

function M.HarassAndChase(ctx)
	local bot = ctx.bot
	local heroPrio = ctx.rules.hero_priority or "default"
	if heroPrio == "never" then return false end
	local range = attackRange(ctx)
	local atkHero = bot:GetNearbyHeroes(range + 50, true, BOT_MODE_NONE)
	if atkHero and #atkHero > 0 and atkHero[1]:IsAlive() then
		if heroPrio == "always" then
			if not (ctx.csAllowed and ctx.needMove) then
				bot:Action_AttackUnit(atkHero[1], false)
				ctx.diag("hero-prio-always")
				return true
			end
		else
			local inRange = GetUnitToUnitDistance(bot, atkHero[1]) <= range
			local harassCD = 0.5 + (1.0 - (ctx.dials.harass_desire or 0.5)) * 2.0
			local harassReady = bot.aib_harassLast == nil or DotaTime() - bot.aib_harassLast >= harassCD
			if inRange and ctx.enemyTowerDanger() == nil and not ctx.deathSurvive and harassReady then
				bot.aib_harassLast = DotaTime()
				bot:Action_AttackUnit(atkHero[1], false)
				ctx.diag("harass-atk")
				return true
			elseif not inRange and math.random() > (ctx.dials.farm_focus or 0.5) then
				if math.random() < (ctx.dials.harass_desire or 0.5)
					and not ctx.uphillMiss(atkHero[1]) then
					bot:Action_AttackUnit(atkHero[1], false)
					ctx.diag("harass-seek")
					return true
				end
			end
		end
	elseif heroPrio == "always" then
		local rc = ctx.dials.retreat_caution or 0.5
		local regenThresh = 0.40 + 0.15 * rc
		local shouldRegen = ctx.rules.low_hp_behavior == "regen_lane" and J.GetHP(bot) < regenThresh
		if shouldRegen then return false end
		local chase = bot:GetNearbyHeroes(1500, true, BOT_MODE_NONE)
		if chase and #chase > 0 and chase[1]:IsAlive() then
			local chaseDist = GetUnitToUnitDistance(bot, chase[1])
			local creepNear = ctx.hasAttackableEnemyCreep(range + 120)
			local chaseSafe = ctx.enemyTowerDanger() == nil and not ctx.uphillMiss(chase[1])
			local hpAdvChase = chaseDist <= 950
				and J.GetHP(bot) >= J.GetHP(chase[1]) + 0.08
				and J.GetHP(bot) >= 0.45
				and chaseSafe
			local killPressureChase = chaseDist <= 1050
				and J.GetHP(chase[1]) <= 0.55
				and J.GetHP(bot) >= 0.38
				and chaseSafe
			local closeVisibleChase = chaseDist <= 900
				and J.GetHP(bot) >= 0.52
				and chaseSafe
			local lowFarmHeroChase = chaseDist <= 1150
				and (ctx.dials.farm_focus or 0.5) < 0.25
				and (ctx.rules.hero_priority or "default") == "always"
				and J.GetHP(bot) >= 0.42
				and J.GetHP(chase[1]) <= 0.70
				and chaseSafe
			local laneOverrideChase = chaseDist <= 950
				and J.GetHP(bot) >= 0.58
				and J.GetHP(chase[1]) <= 0.62
				and ((ctx.rules.hero_priority or "default") == "always" or J.GetHP(bot) >= J.GetHP(chase[1]) + 0.15)
				and chaseSafe
				and (not creepNear or not ctx.csAllowed)
			if hpAdvChase or killPressureChase or closeVisibleChase or lowFarmHeroChase or laneOverrideChase
				or (chaseDist <= 950 and not ctx.csAllowed and not creepNear) then
				return ctx.moveToAttackEdge(chase[1], "hero-prio-chase")
			end
			ctx.blocked("hero-prio-chase", "lane_work",
				string.format("dist=%.0f cs=%s creep=%s hp_adv=%s kill_pressure=%s close=%s low_farm=%s lane_override=%s", chaseDist, tostring(ctx.csAllowed), tostring(creepNear), tostring(hpAdvChase), tostring(killPressureChase), tostring(closeVisibleChase), tostring(lowFarmHeroChase), tostring(laneOverrideChase)), 3.0)
		end
	end
	return false
end

function M.AbilityHarass(ctx)
	local bot = ctx.bot
	local nearEnemies = bot:GetNearbyHeroes(1000, true, BOT_MODE_NONE)
	if nearEnemies and #nearEnemies > 0 and nearEnemies[1]:IsAlive() then
		local abilEnemy = nearEnemies[1]
		if Style.AbilityExecute(bot, abilEnemy) then return true end
		local hpDisadvAbil = J.GetHP(abilEnemy) - J.GetHP(bot) > 0.40
		if not hpDisadvAbil and Style.AbilityHarass(bot, abilEnemy) then return true end
	end
	return false
end

return M
