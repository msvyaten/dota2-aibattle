-- AIBattle: tiny decision-stage + intent runner.
-- Keep policy modules small: each stage either handles the current tick or yields.

local M = {}

local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local J = require(GetScriptDirectory()..'/FunLib/jmz_func')

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
					Style.Intent(bot, "arbiter", string.format("winner=%s:%s losers=%s",
						tostring(intent.name), tostring(intent.priority or 0), table.concat(losers, ",")), 1.5)
				end
				Style.Intent(bot, intent.name, intentDetail(intent), intent.sec)
				local handled = intent.action(ctx)
				if handled ~= false then
					if ctx ~= nil then ctx.last_intent = intent.name end
					return true, intent.name
				end
				Style.Blocked(bot, intent.name, "empty_action", intent.detail, intent.sec)
			end
		end
	end
	return false, nil
end

function M.Run(stages, ctx)
	for _, stage in ipairs(stages or {}) do
		if stage ~= nil and stage.run ~= nil and stage.run(ctx) then
			if ctx ~= nil then ctx.last_stage = stage.name end
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
	if bot == nil then return false end
	context = context or {}
	local hp = J.GetHP(bot)
	local mp = J.GetMP(bot)
	if hp < 0.30 and mp < 0.55 then return true end
	if context.killWindow == true and mp < 0.55 then return true end
	if context.abilitySoon == true and mp < 0.42 then return true end
	if mp < 0.12 then return true end
	return false
end

return M
