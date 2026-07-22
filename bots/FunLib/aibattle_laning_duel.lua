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

-- A stationary free hit before the creeps arrive.
-- "Do not advance to trade" had been implemented as "do not attack at all". For every
-- pregame_behavior except aggressive_mid: M.Pregame returns immediately, M.Prewave only ever
-- gives ground, and PreCreepStandoff gates each of its attack branches on aggressive too --
-- so a passive preset stands facing the enemy and never swings, even when he is already
-- inside its attack range and hitting it. Both configs in the first bettability series chose
-- "default" and the two bots stood staring at each other (user, 21.07). hero_priority="always"
-- cannot rescue it either: these three stages run BEFORE the laning arbiter and short-circuit
-- it, so the dial never gets a tick.
-- The gate that was over-applied is about ADVANCING. This branch issues no movement at all --
-- it only swings when the enemy is already within attack range -- so it cannot turn a passive
-- preset into an advancing one, which is the whole point of the aggressive gate.
function M.PreHeroFreeHit(ctx, enemy, dist, range, key)
	if enemy == nil or not enemy:IsAlive() then return false end
	if ((ctx.rules or {}).hero_priority or "default") == "never" then return false end
	-- range + 150, not range. The first attempt required the enemy to be strictly inside attack
	-- range so that no step was needed at all, and it left the exact case the user reported
	-- unsolved: 8908439030 t=0-15, both bots motionless 584 apart with a ~500 range -- 84 units
	-- too far, both refusing to move, staring at each other.
	-- The overshoot is self-limiting and cannot become a march: Action_AttackUnit closes those
	-- 84 units, and if the enemy backs off the distance leaves the band immediately and the
	-- branch stops firing. Maximum pursuit is the 150 itself, which is a fraction of a second
	-- of walking -- nothing like the river march that 9f6b6cc/4e2dee2 were written against.
	if dist == nil or dist > range + 150 then return false end
	if ctx.uphillMiss(enemy) then return false end          -- uphill misses 25%: not free
	if J.GetHP(ctx.bot) < 0.45 then return false end         -- weakened: spacing owns it
	if ctx.enemyTowerDanger() ~= nil then return false end
	ctx.bot:Action_AttackUnit(enemy, false)
	ctx.diag(key)
	return true
end

function M.Prewave(ctx)
	local now = DotaTime()
	if now < 0 or now > 45 then return false end
	local rules = ctx.rules or {}
	if (rules.hero_priority or "default") == "never" then return false end
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local enemy, dist = ctx.nearestEnemyHero(range + 360)
	if (rules.pregame_behavior or "default") == "aggressive_mid" then
		return duelState(ctx, enemy, dist, "post_horn", 0.35, 360)
	end
	if M.PreHeroFreeHit(ctx, enemy, dist, range, "prewave-free-hit") then return true end
	-- Passive prewave defend (non-aggressive_mid presets never enter the duel above): give
	-- ground to an aggressive pre-creep poker BEFORE dropping low, instead of standing on the
	-- contested line and walking into the lane phase at 36-42% HP (8903907295 W1: 14 one-sided
	-- Radiant duels, Dire=farmer/default exited prewave at 36%). Fires only while actually being
	-- hit by a close hero and below the soft floor; no CS is lost pre-creep, and laning-core
	-- recovery still owns the deeper low-HP retreat. Self-limiting: stops once out of poke range.
	if enemy ~= nil and enemy:IsAlive()
		and dist <= range + 200
		and J.GetHP(bot) < 0.60
		and bot:WasRecentlyDamagedByAnyHero(1.0)
		and ctx.enemyTowerDanger() == nil
		and not Style.MayDive(bot) then
		if bot.aib_prewaveDefendLast == nil or now - bot.aib_prewaveDefendLast >= 0.75 then
			bot.aib_prewaveDefendLast = now
			ctx.state("prewave-duel", string.format("ttl=2 phase=passive_defend dist=%.0f hp=%.0f", dist, J.GetHP(bot) * 100), 2.0)
			ctx.diag("prewave-defend")
			bot:Action_MoveToLocation(ctx.towardFountain(bot:GetLocation(), 260))
			return true
		end
	end
	return false
end

function M.Pregame(ctx)
	local rules = ctx.rules or {}
	if (rules.hero_priority or "default") == "never" then return false end
	local range = ctx.attackRange or ctx.bot:GetAttackRange()
	local enemy, dist = ctx.nearestEnemyHero(range + 420)
	if (rules.pregame_behavior or "default") ~= "aggressive_mid" then
		-- Passive before the horn still means passive about MOVING, not about standing next
		-- to the enemy doing nothing. See M.PreHeroFreeHit.
		return M.PreHeroFreeHit(ctx, enemy, dist, range, "pregame-free-hit")
	end
	return duelState(ctx, enemy, dist, "pregame", 0.42, 420)
end

return M
