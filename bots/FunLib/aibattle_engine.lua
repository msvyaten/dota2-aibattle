-- AIBattle: tiny decision-stage + intent runner.
-- Keep policy modules small: each stage either handles the current tick or yields.

local M = {}

local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local ItemPolicy = require(GetScriptDirectory()..'/FunLib/aibattle_item_policy')

function M.Stage(name, run)
	return { name = name, run = run }
end

function M.Intent(name, priority, reason, action, detail)
	return {
		name = name,
		priority = priority or 0,
		reason = reason,
		action = action,
		detail = detail,
		blocked = false,
	}
end

function M.Blocked(name, priority, reason, detail)
	return {
		name = name,
		priority = priority or 0,
		reason = reason,
		detail = detail,
		blocked = true,
	}
end

local function intentDetail(intent)
	local detail = intent.detail or ""
	if intent.reason ~= nil and intent.reason ~= "" then
		if detail ~= "" then detail = detail .. " " end
		detail = detail .. "reason=" .. tostring(intent.reason)
	end
	return detail
end

function M.Resolve(intents, ctx)
	table.sort(intents or {}, function(a, b)
		return (a.priority or 0) > (b.priority or 0)
	end)
	for _, intent in ipairs(intents or {}) do
		if intent ~= nil and intent.name ~= nil then
			local bot = ctx and ctx.bot
			if intent.blocked then
				Style.Blocked(bot, intent.name, intent.reason, intent.detail, intent.sec)
			elseif intent.action ~= nil then
				if #(intents or {}) > 1 then
					local losers = {}
					for _, other in ipairs(intents or {}) do
						if other ~= intent and other ~= nil and other.name ~= nil then
							losers[#losers + 1] = tostring(other.name) .. ":" .. tostring(other.priority or 0)
							if #losers >= 4 then break end
						end
					end
					local family = (ctx and (ctx.arbiter or ctx.family or ctx.phase)) or "generic"
					Style.Intent(bot, "arbiter", string.format("family=%s winner=%s:%s losers=%s",
						tostring(family), tostring(intent.name), tostring(intent.priority or 0), table.concat(losers, ",")), 1.5)
				end
				Style.Intent(bot, intent.name, intentDetail(intent), intent.sec)
				local handled = intent.action(ctx)
				if handled ~= false then
					if ctx ~= nil then ctx.last_intent = intent.name end
					Style.TickOwner(bot, tostring((ctx and (ctx.arbiter or ctx.family or ctx.phase)) or "intent"), "intent=" .. tostring(intent.name), 2.0)
					return true, intent.name
				end
				Style.Blocked(bot, intent.name, "empty_action", intent.detail, intent.sec)
			end
		end
	end
	return false, nil
end

function M.KillWindow(ctx)
	if ctx == nil or ctx.bot == nil then return nil end
	local bot = ctx.bot
	local dials = ctx.dials or {}
	local range = ctx.attackRange or bot:GetAttackRange()
	local scan = ctx.scanRange or math.max(900, range + 520)
	local enemies = bot:GetNearbyHeroes(scan, true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0) then return nil end

	for _, enemy in ipairs(enemies) do
		if enemy ~= nil and enemy:IsAlive()
			and enemy.GetHealth ~= nil and enemy:GetHealth() > 0
			and enemy.GetMaxHealth ~= nil and enemy:GetMaxHealth() > 0
			and not J.IsSuspiciousIllusion(enemy) then
			local hp = J.GetHP(bot)
			local ehp = J.GetHP(enemy)
			local dist = GetUnitToUnitDistance(bot, enemy)
			local exec = dials.execute_threshold or 0
			-- Denominator. Without it the leg counters below are unreadable: 8926148548 read
			-- killwin-atk 0-2 per side, which says nothing at all until you know whether the
			-- question was asked twice or two thousand times.
			Style.Diag(bot, "killwin-scan")
			local atkDmg = bot:GetAttackDamage()
			local killMult = ctx.attackDamageMult or Style.AttackDamageMult(bot, enemy)
			local attackKill = enemy:GetHealth() <= atkDmg * killMult
			-- The multiplier's acceptance, measured directly instead of inferred from outcomes:
			-- count the enemies the OLD Shadow Fiend constant would have called killable and
			-- this hero's own number does not. Zero here means the change did nothing at all --
			-- either the hero declares no kill_mult, or the band never comes up in play.
			if not attackKill and enemy:GetHealth() <= atkDmg * 3.0 then
				Style.Diag(bot, "killwin-atk-narrowed")
			end
			-- An HP number alone is not a kill window: see Style.ExecuteReady. Without the
			-- readiness test this leg made every enemy under execute_threshold permanently
			-- "killable" and handed the tick to a 1045-unit chase, starving last-hits.
			local execute = exec > 0 and ehp <= math.max(exec, ctx.minExecuteHp or Const.Fight.minExecuteHp)
				and Style.ExecuteReady(bot, enemy)
			local mutualLow = ehp <= (ctx.mutualEnemyHp or Const.Fight.mutualEnemyHp)
				and hp <= (ctx.mutualSelfHp or Const.Fight.mutualSelfHp)
				and hp >= (ctx.minSelfHp or Const.Fight.minSelfHp)
			local hpAdv = hp >= ehp + (ctx.hpAdvantage or Const.Fight.hpAdvantage)
			local lowFarmAlways = (dials.farm_focus or 0.5) < 0.25
				and ((ctx.rules or {}).hero_priority or "default") == "always"
			local maxDist = range + 360
			if mutualLow then maxDist = math.max(maxDist, math.max(700, range + 260)) end
			if lowFarmAlways or hpAdv then maxDist = math.max(maxDist, range + 520) end
			if execute or attackKill or mutualLow or (lowFarmAlways and ehp <= Const.Fight.lowFarmEnemyHp and hp >= 0.34 and hpAdv) then
				-- Which leg opened the window: killwin-atk is the one the multiplier narrows,
				-- exec and mutual are the controls it must NOT touch. Plain Diag, not DiagRL --
				-- these have to be comparable to killwin-scan above and to each other, and a
				-- 3-second limit on all three made them look like a handful of events in a
				-- match where the question is asked continuously.
				Style.Diag(bot, attackKill and "killwin-atk"
					or (execute and "killwin-exec" or "killwin-mutual"))
				return {
					enemy = enemy,
					hp = hp,
					ehp = ehp,
					dist = dist,
					range = range,
					execute = execute,
					attackKill = attackKill,
					mutualLow = mutualLow,
					hpAdv = hpAdv,
					lowFarmAlways = lowFarmAlways,
					inRange = dist <= range + 80,
					inCommitRange = dist <= maxDist,
					maxDist = maxDist,
				}
			end
		end
	end
	return nil
end

function M.RecoveryPolicy(ctx)
	local win = M.KillWindow(ctx)
	if win ~= nil and win.inCommitRange == true then
		return {
			action = "yield_kill",
			killWindow = win,
			detail = string.format("dist=%.0f hp=%.0f ehp=%.0f exec=%s atk=%s mutual=%s",
				win.dist, win.hp * 100, win.ehp * 100, tostring(win.execute),
				tostring(win.attackKill), tostring(win.mutualLow)),
		}
	end
	return { action = "recover" }
end

function M.Run(stages, ctx)
	for _, stage in ipairs(stages or {}) do
		if stage ~= nil and stage.run ~= nil and stage.run(ctx) then
			if ctx ~= nil then ctx.last_stage = stage.name end
			if ctx ~= nil and ctx.bot ~= nil then Style.TickOwner(ctx.bot, stage.name, "", 2.0) end
			return true, stage.name
		end
	end
	return false, nil
end

function M.PowerRuneState(bot)
	if bot == nil then return nil end
	if bot:HasModifier("modifier_rune_doubledamage") then return "double_damage" end
	if bot:HasModifier("modifier_rune_haste") then return "haste" end
	if bot:HasModifier("modifier_rune_arcane") then return "arcane" end
	if bot:HasModifier("modifier_rune_regen") then return "regen" end
	if bot:HasModifier("modifier_rune_invis") then return "invis" end
	if bot:HasModifier("modifier_rune_illusion") then return "illusion" end
	return nil
end

function M.IsActionPowerRune(rune)
	return rune == "double_damage"
		or rune == "haste"
		or rune == "arcane"
		or rune == "regen"
		or rune == "invis"
		or rune == "illusion"
end

function M.RuneUsePolicy(bot, dials, rules)
	local rune = M.PowerRuneState(bot)
	if rune == nil then return nil end
	dials = dials or {}
	rules = rules or {}
	local pressure = dials.rune_control or 0.5
	local heroPriority = rules.hero_priority or "default"
	local configured = (type(rules.rune_use_policy) == "table") and rules.rune_use_policy or {}
	local ddRules = (type(configured.double_damage) == "table") and configured.double_damage or {}
	local fightHp = 0.42
	if heroPriority == "always" then fightHp = 0.36 end
	if rune == "double_damage" then
		return {
			name = rune,
			heroPressure = math.max(ddRules.hero_pressure or 0.70, pressure),
			towerPressure = math.max(ddRules.tower_pressure or 0.65, dials.push_desire or 0.5),
			creepPressure = math.max(ddRules.creep_pressure or 0.45, dials.farm_focus or 0.5),
			minFightHp = ddRules.min_hp_fight or fightHp,
			maxChase = ddRules.max_chase or ((heroPriority == "always") and 1050 or 900),
			useForTowerWithWave = ddRules.use_for_tower_with_wave ~= false,
		}
	elseif rune == "haste" then
		return {
			name = rune,
			heroPressure = math.max(0.65, pressure),
			towerPressure = dials.push_desire or 0.5,
			creepPressure = 0.30,
			minFightHp = math.max(0.34, fightHp - 0.04),
			maxChase = 1450,
			useForTowerWithWave = false,
		}
	elseif rune == "arcane" then
		return {
			name = rune,
			heroPressure = math.max(0.55, pressure),
			towerPressure = dials.push_desire or 0.5,
			creepPressure = 0.35,
			minFightHp = fightHp,
			maxChase = 850,
			useForTowerWithWave = false,
		}
	end
	return {
		name = rune,
		heroPressure = pressure,
		towerPressure = dials.push_desire or 0.5,
		creepPressure = dials.farm_focus or 0.5,
		minFightHp = fightHp,
		maxChase = 750,
		useForTowerWithWave = false,
	}
end

function M.AttackOrMoveToBand(ctx, target, diagKey, extraBack)
	if ctx == nil or ctx.bot == nil or target == nil then return false end
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local dist = GetUnitToUnitDistance(bot, target)
	if dist <= range + 55 then
		bot:Action_AttackUnit(target, true)
		if ctx.diag ~= nil and diagKey ~= nil then ctx.diag(diagKey .. "-atk") end
		return true
	end
	if ctx.moveToAttackEdge ~= nil then
		return ctx.moveToAttackEdge(target, diagKey, extraBack or 0)
	end
	return false
end

function M.ShouldUseMango(bot, context)
	return ItemPolicy.ShouldUseMango(bot, context)
end

return M
