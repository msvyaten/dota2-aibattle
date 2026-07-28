-- AIBattle laning combat layer: hero contact, chase, abilities, rune pressure.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local Motor = require(GetScriptDirectory()..'/FunLib/aibattle_motor')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local function attackRange(ctx)
	return ctx.attackRange or ctx.bot:GetAttackRange()
end

local function powerRuneTowerTarget(ctx, range)
	local bot = ctx.bot
	if (ctx.rules or {}).tower_aggression == "never" then return nil, 0 end
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
		Style.Intent(bot, "hero-contact", string.format("dist=%.0f hp=%.0f reason=close_enemy", dist, hp * 100))
		if ctx.moveToAttackEdge(enemy, "hero-contact-chase", 0) then
			bot.aib_contactHeroLast = now
			return true
		end
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

-- Pure feasibility probe for the power-rune candidate (canAct contract, same as
-- AIBLaneSiege.CanAct). Mirrors the return-false gates of RunePowerPressure above WITHOUT
-- side effects -- no Intent, no diag, no orders.
-- Why: the candidate's ONLY entry test was args.actionPowerRune, i.e. "do I hold an action
-- rune", while the action checks seven further conditions. So it entered the election at
-- score 104-114 -- above safe-cs 56 and creep-work 38 -- and empty-won 19 times in
-- 8906632392 [R] while the bot stood doing nothing with a rune in the bottle.
-- NOTE: absence of an enemy is NOT a veto -- the tower and creep branches run without one.
-- Keep in sync with RunePowerPressure; if that grows a target path, add it here too.
function M.RunePowerCanAct(ctx)
	local bot = ctx.bot
	local policy = AIBEngine.RuneUsePolicy(bot, ctx.dials, ctx.rules)
	if policy == nil then return false end
	if not AIBEngine.IsActionPowerRune(policy.name) then return false end
	if J.GetHP(bot) < (policy.minFightHp or 0.38) then return false end
	local hasDamageRune = policy.name == "double_damage"
	local hasHasteRune = policy.name == "haste"
	local range = attackRange(ctx)
	local enemy = ctx.nearestEnemyHero(policy.maxChase or (hasHasteRune and 1150 or 950))
	if enemy ~= nil and enemy:IsAlive()
		and ctx.enemyTowerDanger() == nil
		and not ctx.uphillMiss(enemy)
		and ((policy.heroPressure or 0.5) >= 0.45 or J.GetHP(enemy) <= 0.45) then
		return true
	end
	if policy.useForTowerWithWave == true and (policy.towerPressure or 0.5) >= 0.45 then
		if powerRuneTowerTarget(ctx, range) ~= nil then return true end
	end
	if hasDamageRune and (policy.creepPressure or 0.5) >= 0.35 then
		if ctx.nearestAttackableEnemyCreep(range + 80) ~= nil then return true end
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
		if Style.FightAbilities(bot, atkHero[1]) then return true end
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
			-- This owner asked for NO ability at all before right-clicking.
			if Style.FightAbilities(bot, enemy) then return true end
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
	-- Positioning yields while a recovery-class mover owns the motor (P2 v1).
	if Motor.Active(bot) ~= nil then return false end
	-- 6-second cooldown prevents oscillation with lane-line-fallback when bot repeatedly
	-- enters the low-ground ramp at the enemy side of mid.
	if bot.aib_uphillRepoLast ~= nil and DotaTime() - bot.aib_uphillRepoLast < 6.0 then
		return false
	end
	local uphEnemy = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
	if uphEnemy and #uphEnemy > 0 and uphEnemy[1]:IsAlive()
		and ctx.uphillMiss(uphEnemy[1]) then
		-- ROOT of "it twitches while standing in the creeps" (user, 8917945764). The gate above
		-- asks "is a hero within 1200 and uphill" and never "am I fighting him". In mid the enemy
		-- is across the ramp essentially all the time, so this fired every 6s forever -- including
		-- while the bot was farming -- and each firing claims the motor for 1.5s and pulls it off
		-- the creep line. It was 14 of Radiant's 21 jitter episodes (3.3/min, up from 2.0/min:
		-- capping the step in a235833 cut the amplitude but RAISED the frequency, because the bot
		-- now returns to the ramp inside the 6s cooldown instead of trekking home).
		-- The uphill miss chance is a cost of SWINGING AT THE HERO. It does nothing to a last-hit,
		-- so farming is not a reason to reposition at all.
		local atkTgt = bot:GetAttackTarget()
		local trading = bot:WasRecentlyDamagedByAnyHero(2.0)
			or (atkTgt ~= nil and atkTgt == uphEnemy[1])
		if not trading then
			ctx.blocked("uphill-repo", "not_trading", "", 4.0)
			return false
		end
		-- Never walk away from a last-hit that is already in range.
		if ctx.csAllowed and not ctx.needMove then
			ctx.blocked("uphill-repo", "last_hit_ready", "", 4.0)
			return false
		end
		local ownT1uph = GetTower(GetTeam(), TOWER_MID_1)
		local highPos = (ownT1uph ~= nil and ownT1uph:IsAlive()) and ownT1uph:GetLocation()
			or ctx.forwardSurvivingTowerLoc()
		if highPos and GetUnitToLocationDistance(bot, highPos) > 300 then
			bot.aib_uphillRepoLast = DotaTime()
			-- Claim the motor so the opposite puller (lane-line-fallback) yields for 1.5s
			-- instead of dragging the bot forward next tick = the forward<->back twitch.
			--
			-- Step OFF the ramp, do not trek home. highPos is our own T1: walking the whole way
			-- there is a ~2000-unit round trip that abandons the wave, and the 1.5s claim expires
			-- long before that walk ends -- so lane-line-fallback grabs the bot mid-way and drags
			-- it forward again. That is the forward<->back walk the user watched at 2:20 in
			-- 8914820239 ("stepped back with a creep right there to last-hit"), and
			-- uphill-reposition was 16 of the 20 jitter episodes on the Radiant side -- the only
			-- side that fights uphill in mid, which is why only Radiant showed it. Clearing the
			-- low ground does not require going home, so cap the move: the claim now covers the
			-- whole (short) walk instead of a fraction of it.
			local bl = bot:GetLocation()
			local dxr, dyr = highPos.x - bl.x, highPos.y - bl.y
			local dr = math.sqrt(dxr * dxr + dyr * dyr)
			local repoDest = highPos
			if dr > 400 then
				repoDest = Vector(bl.x + dxr / dr * 400, bl.y + dyr / dr * 400, bl.z)
			end
			Motor.Claim(bot, "uphill-repo", 20, 1.5)
			bot:Action_MoveToLocation(repoDest + RandomVector(50))
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
	-- Concede-when-losing floor: don't INITIATE harass/chase right after a death or when
	-- clearly behind, even for hero_priority=always. Kill-lock (finishing a killable
	-- enemy) and recovery run elsewhere and are unaffected -- this only stops feeding an
	-- unfavorable lane. Overrides "always" on purpose: no LLM config should re-engage the
	-- hero that just killed it (8885447129 farmer fed 4x in laning t=61-122).
	if atkHero and #atkHero > 0 and AIBUtils.ShouldConcedeLane(bot, atkHero[1]) then
		ctx.blocked("harass", "concede_lane", "", 4.0)
		return false
	end
	-- Do not START a trade while our own salve is ticking: any damage cancels it, so the
	-- 110g buys a fraction of its healing and the trade is paid for twice. The codebase
	-- already knew this shape -- trade.lua uses exactly these modifiers to decide when to
	-- interrupt the ENEMY's heal -- and simply never applied it to our own. User's rule,
	-- open since 21.07.
	-- INITIATE is the operative word: if the enemy is already hitting us the salve is
	-- cancelled either way, and refusing to answer would just be the uphill mistake in a new
	-- costume. Same escape hatch as there.
	if (bot:HasModifier("modifier_flask_healing")
		or bot:HasModifier("modifier_bottle_regeneration")
		or bot:HasModifier("modifier_clarity_potion"))
		and not bot:WasRecentlyDamagedByAnyHero(2.0) then
		ctx.blocked("harass", "own_heal_running", "", 4.0)
		return false
	end
	-- Uphill awareness: a ranged hero attacking uphill misses 25%. Climbing the ramp
	-- to level ground is a bad dive for SF, so instead of standing and feeding whiffs
	-- (how Radiant lost a duel it should have won, 8883124473) yield the tick to lane
	-- work / farming until the enemy comes down. Melee (range<=300) never misses
	-- uphill, so it keeps attacking.
	-- Being hit right now voids the uphill argument. The 25% whiff is a reason to prefer
	-- not to OPEN a trade up the ramp; it was never a reason to stand still and be
	-- free-hit, which is what the bot did for a whole minute in 8909602648 (user: "Radiant
	-- does NOTHING while it is simply being beaten and losing health"). 75% of your damage
	-- beats 0% of it, and the alternative the comment below assumes -- yield the tick to
	-- lane work -- is empty when there is no creep to work: that match logged creep-work
	-- winning the arbiter on identical coordinates for 8 seconds straight.
	local function beingHitBy(enemy)
		return enemy ~= nil and bot:WasRecentlyDamagedByAnyHero(2.0)
			and GetUnitToUnitDistance(bot, enemy) <= range + 120
	end
	local function uphillWhiff(enemy)
		return range > 300 and ctx.uphillMiss(enemy) and ctx.enemyTowerDanger() == nil
			and not beingHitBy(enemy)
	end
	if atkHero and #atkHero > 0 and atkHero[1]:IsAlive() then
		if heroPrio == "always" then
			if uphillWhiff(atkHero[1]) then
				ctx.blocked("hero-prio-always", "uphill", "", 3.0)
				return false
			end
			-- Even 'always' must not keep trading in range a fight it's LOSING on HP:
			-- an over-aggressive brawler fed the safe farmer exactly this way
			-- (8886772891: R=brawler over-traded in range and died). A killable enemy
			-- or an action power rune still fights (HpDisadvantaged returns false).
			if AIBUtils.HpDisadvantaged(bot, atkHero[1], ctx.dials.execute_threshold,
				AIBEngine.IsActionPowerRune(AIBEngine.PowerRuneState(bot))) then
				ctx.blocked("hero-prio-always", "hp_behind", "", 3.0)
				return false
			end
			if not (ctx.csAllowed and ctx.needMove) then
				bot:Action_AttackUnit(atkHero[1], false)
				ctx.diag("hero-prio-always")
				return true
			end
		else
			local inRange = GetUnitToUnitDistance(bot, atkHero[1]) <= range
			local harassCD = 0.5 + (1.0 - (ctx.dials.harass_desire or 0.5)) * 2.0
			local harassReady = bot.aib_harassLast == nil or DotaTime() - bot.aib_harassLast >= harassCD
			if inRange and ctx.enemyTowerDanger() == nil and not ctx.deathSurvive and harassReady
				and not uphillWhiff(atkHero[1]) then
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
				-- Re-issuing the chase every tick retargets the attack edge as the enemy
				-- drifts, which reads as a stutter rather than a chase: 8907379308 [R] hit
				-- hero-prio-chase 88 times in the first 93 seconds (~1/s) and 166 by the end,
				-- and the user reported the hero "twitching in place" across exactly those
				-- windows. A 0.4s throttle is invisible to a real chase and removes the
				-- per-tick order spam. Own the tick while throttled -- releasing it would let
				-- a positioner move the hero instead, which is the bug one layer down.
				local nowChase = DotaTime()
				if bot.aib_chaseLast ~= nil and nowChase - bot.aib_chaseLast < 0.4 then
					Style.DiagRL(bot, "hero-prio-chase-hold", 5)
					return true
				end
				bot.aib_chaseLast = nowChase
				-- Above the positioners (20) and below the recovery movers (90-110).
				Motor.Claim(bot, "hero-prio-chase", 30, 1.0)
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
