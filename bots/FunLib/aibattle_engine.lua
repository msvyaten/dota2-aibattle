-- AIBattle: tiny decision-stage + intent runner.
-- Keep policy modules small: each stage either handles the current tick or yields.

local M = {}

local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')

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
				Style.Intent(bot, intent.name, intentDetail(intent), intent.sec)
				intent.action(ctx)
				if ctx ~= nil then ctx.last_intent = intent.name end
				return true, intent.name
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

return M
