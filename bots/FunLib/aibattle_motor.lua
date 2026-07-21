-- AIBattle motor ownership (P2, v1).
-- One shared "who owns the bot's movement right now" record, generalizing the
-- committed-destination pattern that critical-recover / pre-duel / rune staging
-- each reimplemented locally. v1 is deliberately one-directional:
--   * recovery-class movers REGISTER their claim (they are never blocked by it);
--   * positioning-class movers (lane-line fallback, uphill reposition) YIELD
--     while a claim is active.
-- This kills the "positioner pulls forward while recovery walks back" pair by
-- construction without changing any recovery behavior.

local M = {}

-- Registers movement ownership. Higher prio overrides; same owner refreshes.
function M.Claim(bot, owner, prio, ttl)
	if bot == nil or owner == nil then return false end
	local now = DotaTime()
	if bot.aib_motorOwner ~= nil and bot.aib_motorOwner ~= owner
		and bot.aib_motorUntil ~= nil and now < bot.aib_motorUntil
		and (bot.aib_motorPrio or 0) > (prio or 0) then
		return false
	end
	bot.aib_motorOwner = owner
	bot.aib_motorPrio = prio or 0
	bot.aib_motorUntil = now + (ttl or 1.0)
	return true
end

-- Returns the active owner name and priority, or nil when expired/absent.
function M.Active(bot)
	if bot == nil or bot.aib_motorOwner == nil or bot.aib_motorUntil == nil then return nil end
	if DotaTime() >= bot.aib_motorUntil then
		bot.aib_motorOwner = nil
		bot.aib_motorPrio = nil
		bot.aib_motorUntil = nil
		return nil
	end
	return bot.aib_motorOwner, bot.aib_motorPrio or 0
end

-- M.Release removed 21.07: exported since v1 and never called by anything. That is not an
-- oversight, it follows from the design above -- claims are short-TTL and expire on their
-- own, and Active() already clears an expired record when it reads one. If an owner ever
-- needs to hand the motor back EARLY, add it back deliberately with a caller.

return M
