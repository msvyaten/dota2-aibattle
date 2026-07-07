-- AIBattle prewave duel state.
-- Handles the short 1v1 interaction before and just after creeps arrive.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Motor = require(GetScriptDirectory()..'/FunLib/aibattle_motor')

local function duelState(ctx, enemy, dist, phase, hpFloor, approachExtra)
	local bot = ctx.bot
	if enemy == nil or not enemy:IsAlive() then return false end
	local range = ctx.attackRange or bot:GetAttackRange()
	local hp = J.GetHP(bot)
	local keyPrefix = (phase == "pregame") and "pg-duel" or "prewave-duel"
	ctx.state("prewave-duel", string.format("ttl=2 phase=%s dist=%.0f hp=%.0f", phase, dist, hp * 100), 2.0)

	-- Concede-when-losing (engine robustness for aggressive_mid): don't re-enter the duel
	-- right after a death, and don't keep trading when clearly behind. Feeds the same
	-- laning-core-holds-the-safe-line path as the uphill disengage below.
	local concede, concedeReason = AIBUtils.ShouldConcedeLane(bot, enemy)
	if concede then
		ctx.blocked("prewave-duel", "concede_" .. tostring(concedeReason),
			string.format("phase=%s dist=%.0f hp=%.0f", phase, dist, hp * 100), 4.0)
		return false
	end

	-- Post-horn: after 2 uphill retreats, stop feeding the retreat/re-approach loop.
	-- Yield to laning-core so the bot settles at the (downhill) creep line and last-hits
	-- instead of being stepped back 300u every second by the unwinnable uphill duel.
	if phase ~= "pregame" and bot.aib_phDisengageUntil ~= nil
		and DotaTime() < bot.aib_phDisengageUntil then
		ctx.blocked("prewave-duel", "uphill_disengage", string.format("dist=%.0f", dist), 3.0)
		return false
	end

	if hp < hpFloor then
		ctx.blocked("prewave-duel", "low_hp", string.format("phase=%s dist=%.0f hp=%.0f", phase, dist, hp * 100), 3.0)
		return false
	end
	if ctx.enemyTowerDanger() ~= nil then
		ctx.blocked("prewave-duel", "tower", string.format("phase=%s dist=%.0f", phase, dist), 3.0)
		return false
	end
	if dist > range and AIBUtils.UphillMiss(bot, enemy) then
		ctx.blocked("prewave-duel", "uphill", string.format("phase=%s dist=%.0f", phase, dist), 3.0)
		local now = DotaTime()
		if bot.aib_preDuelBackUntil ~= nil and now < bot.aib_preDuelBackUntil then
			local dest = bot.aib_preDuelBackDest
			if dest ~= nil and GetUnitToLocationDistance(bot, dest) > 90 then
				Motor.Claim(bot, "prewave-duel", 70, 1.5)
				bot:Action_MoveToLocation(dest)
				ctx.diag(keyPrefix .. "-uphill-back")
			else
				ctx.diag(keyPrefix .. "-uphill-hold")
			end
			return true
		end
		local back = ctx.towardFountain(bot:GetLocation(), (phase == "pregame") and 360 or 300)
		if back ~= nil then
			bot.aib_preDuelBackDest = back
			bot.aib_preDuelBackUntil = now + ((phase == "pregame") and 1.6 or 1.0)
			-- Uphill hysteresis: UphillMiss flickers while both bots move across the
			-- river ramps, so without this hold the duel alternates retreat/approach
			-- every ~2s all pregame (pg-duel-uphill-back=172-179 per match).
			bot.aib_duelUphillHoldUntil = now + 5.0
			if phase == "pregame" then
				-- Two uphill retreats in one pregame = the river duel is unwinnable
				-- from low ground; disengage fully (tempo parks us at the safe spot).
				bot.aib_pgUphillEpisodes = (bot.aib_pgUphillEpisodes or 0) + 1
				if bot.aib_pgUphillEpisodes >= 2 then
					bot.aib_pgDisengaged = true
				end
			else
				-- Post-horn equivalent: count episodes in a rolling window; after 2,
				-- disengage from the duel for 6s and let laning-core hold the creep line.
				if bot.aib_phUphillWindowStart == nil or now - bot.aib_phUphillWindowStart > 8.0 then
					bot.aib_phUphillWindowStart = now
					bot.aib_phUphillEpisodes = 0
				end
				bot.aib_phUphillEpisodes = (bot.aib_phUphillEpisodes or 0) + 1
				if bot.aib_phUphillEpisodes >= 2 then
					bot.aib_phDisengageUntil = now + 6.0
				end
			end
			if phase == "pregame" then
				-- Freeze the pregame anchor here. Otherwise the retreat drops the enemy
				-- out of the duel scan, tower-line positioning pulls us forward again,
				-- and the uphill-retreat loop repeats all pregame (pg-duel-uphill-back
				-- was ~177 events per pregame in mirror matches).
				bot.aib_pgUphillBackAnchor = back
			end
			Motor.Claim(bot, "prewave-duel", 70, 1.5)
			bot:Action_MoveToLocation(back)
			ctx.diag(keyPrefix .. "-uphill-back")
			return true
		end
		return false
	end
	if Style.AbilityExecute(bot, enemy) then return true end
	if Style.AbilityHarass(bot, enemy) then return true end

	if range > 350 and dist < range * 0.62 and hp < 0.80 then
		if ctx.moveToAttackEdge(enemy, keyPrefix .. "-space", 30) then return true end
	end
	if dist <= range + 80 then
		bot:Action_AttackUnit(enemy, false)
		ctx.diag(keyPrefix .. "-trade")
		return true
	end
	if hp >= hpFloor + 0.10 and dist <= range + (approachExtra or 300) then
		-- Recently retreated from an uphill spot: hold instead of walking straight
		-- back up. Enemy entering our attack range is handled by the trade branch above.
		if bot.aib_duelUphillHoldUntil ~= nil and DotaTime() < bot.aib_duelUphillHoldUntil then
			ctx.blocked("prewave-duel", "uphill_hold", string.format("phase=%s dist=%.0f", phase, dist), 3.0)
			return true
		end
		return ctx.moveToAttackEdge(enemy, keyPrefix .. "-approach", 0)
	end
	ctx.blocked("prewave-duel", "too_far", string.format("phase=%s dist=%.0f", phase, dist), 3.0)
	return false
end

function M.Prewave(ctx)
	local now = DotaTime()
	if now < 0 or now > 45 then return false end
	local rules = ctx.rules or {}
	if (rules.hero_priority or "default") == "never" then return false end
	if (rules.pregame_behavior or "default") ~= "aggressive_mid" then return false end
	local range = ctx.attackRange or ctx.bot:GetAttackRange()
	local enemy, dist = ctx.nearestEnemyHero(range + 360)
	return duelState(ctx, enemy, dist, "post_horn", 0.35, 360)
end

function M.Pregame(ctx)
	local rules = ctx.rules or {}
	if (rules.hero_priority or "default") == "never" then return false end
	if (rules.pregame_behavior or "default") ~= "aggressive_mid" then return false end
	local range = ctx.attackRange or ctx.bot:GetAttackRange()
	local enemy, dist = ctx.nearestEnemyHero(range + 420)
	return duelState(ctx, enemy, dist, "pregame", 0.42, 420)
end

return M
