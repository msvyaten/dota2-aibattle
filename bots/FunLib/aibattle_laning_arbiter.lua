-- AIBattle top-level laning desire arbiter.
-- Candidates must be scored without issuing actions; only the winning action runs.

local M = {}

local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')

-- band drives who gets winner-hysteresis and who logs empty_action. desire/urgent (and
-- the nil default, for the pre-P1-A desire candidates) behave as before. The P1-A tail
-- candidates (lanework/position/idle) pass an explicit band: their scores strictly encode
-- code order, they must NOT get the sticky bonus, and a false action() means "this block
-- yielded" -- a silent fall-through, exactly like the old sequential tail (no empty_action).
-- capped marks a desire whose score is a no-action cap (safety/fight/recover/siege that
-- won the desire election but has no feasible action). Such a candidate must NOT receive
-- the winner-hysteresis bonus: the cap deliberately sits below CS (50-56) so a symptom-only
-- desire yields the tick to farm; +18 hysteresis would push it back to ~62 and let it beat
-- CS again -- reintroducing the "bot idles under the tower instead of farming" twitch
-- (recovery can return true via hold_position without useful work). Codex review, 10.07.
function M.Candidate(name, priority, reason, detail, action, band, capped)
	return {
		name = name,
		priority = priority or 0,
		reason = reason or "ready",
		detail = detail or "",
		action = action,
		band = band,
		capped = capped,
	}
end

local function isDesireBand(c)
	local b = c.band
	return b == nil or b == "desire" or b == "urgent"
end

local function candidateDetail(c)
	local detail = c.detail or ""
	if c.reason ~= nil and c.reason ~= "" then
		if detail ~= "" then detail = detail .. " " end
		detail = detail .. "reason=" .. tostring(c.reason)
	end
	detail = detail .. string.format(" score=%.0f", c.priority or 0)
	if c.band ~= nil then detail = detail .. " band=" .. tostring(c.band) end
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

	-- Winner hysteresis (desire/urgent bands only): the previous desire winner stays
	-- sticky for a short window so transient score spikes (e.g. the 2s recent-damage boost
	-- on safety) don't flip tick ownership every tick and cancel attack windups mid-swing.
	-- Lanework/position/idle candidates never get the bonus -- the merged tail election
	-- (P1-A) relies on their scores strictly encoding code order.
	local bot0 = ctx and ctx.bot
	if bot0 ~= nil and bot0.aib_desireWinner ~= nil and bot0.aib_desireWinnerAt ~= nil
		and DotaTime() - bot0.aib_desireWinnerAt < 1.5 then
		for _, c in ipairs(active) do
			if c.name == bot0.aib_desireWinner and isDesireBand(c) and not c.capped then
				c.priority = (c.priority or 0) + 18
				c.detail = (c.detail or "") .. " hyst=18"
				break
			end
		end
	end

	table.sort(active, function(a, b)
		if (a.priority or 0) == (b.priority or 0) then
			return tostring(a.name) < tostring(b.name)
		end
		return (a.priority or 0) > (b.priority or 0)
	end)

	local bot = ctx and ctx.bot
	for _, c in ipairs(active) do
		if isDesireBand(c) then
			Style.Intent(bot, "state-desire-" .. tostring(c.name), candidateDetail(c), 1.5)
		end
		local handled = c.action()
		if handled then
			if ctx ~= nil then ctx.last_desire = c.name end
			-- Only desire/urgent winners become sticky (feed the hysteresis above).
			if bot ~= nil and isDesireBand(c) then
				bot.aib_desireWinner = c.name
				bot.aib_desireWinnerAt = DotaTime()
			end
			Style.Intent(bot, "top-arbiter",
				string.format("winner=%s:%s losers=%s", tostring(c.name), tostring(c.priority or 0), loserText(active, c)),
				1.5)
			Style.TickOwner(bot, "desire/" .. tostring(c.name), candidateDetail(c), 2.0)
			return true, c.name
		end
		-- empty_action is the P4 signal for a DESIRE that won the election but could not
		-- act. Tail lanework/position/idle candidates fall through SILENTLY when their
		-- action yields -- they replace the old sequential tail, which logged nothing.
		if isDesireBand(c) then
			Style.Blocked(bot, "top-arbiter", "empty_action",
				string.format("winner=%s score=%.0f", tostring(c.name), c.priority or 0), 1.5)
			if bot ~= nil then
				bot.aib_topArbiterEmptyLast = DotaTime()
				-- A sticky winner that can no longer act must not keep its hysteresis
				-- bonus: otherwise a dead desire (e.g. safety after the damage window)
				-- outbids a live fight for another 1.5s and the bot half-turns without
				-- ever attacking (8882121289 t=73-80).
				if bot.aib_desireWinner == c.name then
					bot.aib_desireWinner = nil
					bot.aib_desireWinnerAt = nil
				end
			end
		end
	end
	return false, nil
end

return M
