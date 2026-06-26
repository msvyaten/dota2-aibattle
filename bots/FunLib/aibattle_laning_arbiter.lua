-- AIBattle top-level laning desire arbiter.
-- Candidates must be scored without issuing actions; only the winning action runs.

local M = {}

local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')

function M.Candidate(name, priority, reason, detail, action)
	return {
		name = name,
		priority = priority or 0,
		reason = reason or "ready",
		detail = detail or "",
		action = action,
	}
end

local function candidateDetail(c)
	local detail = c.detail or ""
	if c.reason ~= nil and c.reason ~= "" then
		if detail ~= "" then detail = detail .. " " end
		detail = detail .. "reason=" .. tostring(c.reason)
	end
	detail = detail .. string.format(" score=%.0f", c.priority or 0)
	return detail
end

local function loserText(candidates, winner)
	local losers = {}
	for _, c in ipairs(candidates or {}) do
		if c ~= winner and c ~= nil and c.name ~= nil then
			losers[#losers + 1] = tostring(c.name) .. ":" .. tostring(c.priority or 0)
			if #losers >= 5 then break end
		end
	end
	return table.concat(losers, ",")
end

function M.Run(candidates, ctx)
	local active = {}
	for _, c in ipairs(candidates or {}) do
		if c ~= nil and c.name ~= nil and c.action ~= nil and (c.priority or 0) > 0 then
			active[#active + 1] = c
		end
	end
	if #active == 0 then return false, nil end
	table.sort(active, function(a, b)
		if (a.priority or 0) == (b.priority or 0) then
			return tostring(a.name) < tostring(b.name)
		end
		return (a.priority or 0) > (b.priority or 0)
	end)

	local bot = ctx and ctx.bot
	for _, c in ipairs(active) do
		Style.Intent(bot, "top-arbiter",
			string.format("winner=%s:%s losers=%s", tostring(c.name), tostring(c.priority or 0), loserText(active, c)),
			1.5)
		Style.Intent(bot, "state-desire-" .. tostring(c.name), candidateDetail(c), 1.5)
		local handled = c.action()
		if handled then
			if ctx ~= nil then ctx.last_desire = c.name end
			Style.TickOwner(bot, "desire/" .. tostring(c.name), candidateDetail(c), 2.0)
			return true, c.name
		end
		Style.Blocked(bot, "top-arbiter", "empty_action",
			string.format("winner=%s score=%.0f", tostring(c.name), c.priority or 0), 1.5)
		if bot ~= nil then bot.aib_topArbiterEmptyLast = DotaTime() end
	end
	return false, nil
end

return M
