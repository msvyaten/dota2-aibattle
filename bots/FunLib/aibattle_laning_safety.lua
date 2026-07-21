-- AIBattle laning safety layer: visual hold/AFK, creep damage relief, stuck recovery.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local AIBCreeps = require(GetScriptDirectory()..'/FunLib/aibattle_laning_creeps')

local function dist2D(a, b)
	if a == nil or b == nil then return math.huge end
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local function resetVisualAFK(bot, now, loc)
	bot.aib_afkAnchorLoc = loc
	bot.aib_afkAnchorTime = now
end

local function attackRange(ctx)
	return ctx.attackRange or ctx.bot:GetAttackRange()
end

function M.VisualAFK(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now <= 0 then return false end
	local limit = Const.Visual.afkSeconds
	if limit <= 0 then return false end
	local loc = bot:GetLocation()
	local moveDist = Const.Visual.afkDistance
	if bot.aib_afkAnchorLoc == nil or bot.aib_afkAnchorTime == nil then
		resetVisualAFK(bot, now, loc)
		return false
	end
	if dist2D(loc, bot.aib_afkAnchorLoc) >= moveDist then
		resetVisualAFK(bot, now, loc)
		return false
	end
	if now - bot.aib_afkAnchorTime < limit then return false end
	if bot.aib_afkLast ~= nil and now - bot.aib_afkLast < 2.5 then return false end
	for _, creep in pairs(ctx.enemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= attackRange(ctx) + 40 then
			return false
		end
	end

	local dest = nil
	local key = "anti-afk-step"
	local twr = ctx.enemyTowerDanger()
	if twr ~= nil and not Style.MayDive(bot) then
		dest = ctx.moveAwayFrom(loc, twr:GetLocation(), 260)
		key = "anti-afk-back"
	elseif J.GetHP(bot) < 0.30 then
		dest = ctx.forwardSurvivingTowerLoc()
		key = "anti-afk-safe"
	else
		local enemies = bot:GetNearbyHeroes(1400, true, BOT_MODE_NONE)
		if enemies and #enemies > 0 and enemies[1]:IsAlive() then
			local enemy = enemies[1]
			local enemyLoc = enemy:GetLocation()
			local dist = GetUnitToUnitDistance(bot, enemy)
			if dist <= attackRange(ctx) + 80 then return false end
			if dist > attackRange(ctx) + 120 then
				Style.DiagRL(bot, "anti-afk-no-chase", 5)
				return false
			end
			local dx, dy = loc.x - enemyLoc.x, loc.y - enemyLoc.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d > 1 then
				local side = (math.floor(now / limit) % 2 == 0) and 1 or -1
				dest = Vector(loc.x + (-dy / d) * 220 * side, loc.y + (dx / d) * 220 * side, loc.z)
				key = "anti-afk-strafe"
			end
		end
	end
	if dest == nil and ctx.enemyCreeps and #ctx.enemyCreeps > 0 then
		local cen = ctx.enemyCreepCentroid(ctx.enemyCreeps)
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		if cen ~= nil and ownT1 ~= nil then
			local anch = ownT1:GetLocation()
			local dx, dy = anch.x - cen.x, anch.y - cen.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d > 1 then
				local safe = math.max(220, attackRange(ctx) - 120)
				dest = Vector(cen.x + (dx / d) * safe, cen.y + (dy / d) * safe, cen.z)
				key = "anti-afk-wave"
			end
		end
	end
	if dest == nil then
		dest = GetLaneFrontLocation(GetTeam(), ctx.assignedLane or LANE_MID, 0)
		key = "anti-afk-lane"
	end
	if dest == nil then return false end
	if GetUnitToLocationDistance(bot, dest) < 120 then dest = dest + RandomVector(220) end
	bot:Action_MoveToLocation(dest)
	bot.aib_afkLast = now
	resetVisualAFK(bot, now, loc)
	ctx.diag(key)
	return true
end

function M.RangedMeleePackSpacing(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	local range = attackRange(ctx)
	if now <= 0 or range <= 350 then return false end
	-- Detect the melee pack a bit further out (was 300) so a ranged hero holds the edge
	-- before it is standing deep inside the creeps, not only once already surrounded.
	local cen, count = ctx.meleeCreepCentroid(ctx.enemyCreeps, 380)
	if cen == nil or count < 2 then return false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local away = ownT1 ~= nil and ownT1:GetLocation() or bot:GetLocation()
	local dx, dy = away.x - cen.x, away.y - cen.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 1 then return false end
	local safe = math.max(360, range - 90)
	local dest = Vector(cen.x + (dx / d) * safe, cen.y + (dy / d) * safe, cen.z)

	-- At the safe edge: OWN the tick instead of releasing it. Releasing here let creep-work
	-- (score 38, below this candidate at 41) walk the ranged hero BACK toward an out-of-range
	-- creep deep in the pack (cs-walk, creeps.lua) -- then spacing pushed out again next tick:
	-- the "ranged bots stand inside the creeps" oscillation (user 20.07, x2). Hold the edge so
	-- the walk-in never fires. Two yields keep it CS/aggression-neutral: (a) a last-hit already
	-- in range is left to cs-inrange (score 50, secures it without moving); (b) an enemy hero in
	-- range is left to auto-harass (score 40). A ranged hero should not chase into a melee pack
	-- for a creep -- it holds max range and waits for creeps to enter it.
	if GetUnitToLocationDistance(bot, dest) < 120 then
		local hitCreep = AIBCreeps.GetBestLastHitCreep(bot, ctx.enemyCreeps, bot:GetAttackDamage())
		if hitCreep ~= nil and GetUnitToUnitDistance(bot, hitCreep) <= range then return false end
		local foes = bot:GetNearbyHeroes(range + 100, true, BOT_MODE_NONE)
		if foes ~= nil and #foes > 0 and foes[1]:IsAlive() then return false end
		Style.DiagRL(bot, "melee-pack-hold", 5)
		return true
	end

	-- Not at the edge yet: throttled step out toward it (throttle gates the MOVE only, so the
	-- at-edge hold above can own the tick every frame and not lapse into the walk-in window).
	if bot.aib_meleeSpaceLast ~= nil and now - bot.aib_meleeSpaceLast < 1.4 then return false end
	bot.aib_meleeSpaceLast = now
	Style.Intent(bot, "melee-pack-space", string.format("count=%d dist=%.0f", count, GetUnitToLocationDistance(bot, dest)), 1.5)
	bot:Action_MoveToLocation(dest)
	ctx.diag("melee-pack-space")
	return true
end

function M.CreepHitReact(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now <= 0 or bot:HasModifier("modifier_teleporting") then return false end
	if not bot:WasRecentlyDamagedByCreep(1.2) then return false end
	if bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < 1.2 then return false end
	if bot.aib_creepReactLast ~= nil and now - bot.aib_creepReactLast < 0.75 then return false end

	local hp = J.GetHP(bot)
	local range = attackRange(ctx)
	if bot.aib_creepReactSeen == nil or now - bot.aib_creepReactSeen > 3.0 then
		bot.aib_creepReactCount = 0
	end
	if bot.aib_creepReactTick == nil or now - bot.aib_creepReactTick >= 0.6 then
		bot.aib_creepReactTick = now
		bot.aib_creepReactSeen = now
		bot.aib_creepReactCount = (bot.aib_creepReactCount or 0) + 1
	end
	local creep, dist = ctx.nearestAttackableEnemyCreep(range + 160)
	if creep == nil then
		ctx.blocked("creep-hit-react", "no_creep", string.format("hp=%.0f", hp * 100), 3.0)
		return false
	end
	-- Sticky target: retargeting the nearest creep on every 0.75s throttle tick made
	-- the bot walk between wind-ups (target dist jumping 41->238->289 in 8883083476
	-- t=245-251) and never land a hit. Keep the same creep for 2s while it's valid.
	if bot.aib_creepReactTgt ~= nil and bot.aib_creepReactTgtUntil ~= nil
		and now < bot.aib_creepReactTgtUntil
		and J.IsValid(bot.aib_creepReactTgt) and bot.aib_creepReactTgt:IsAlive()
		and J.CanBeAttacked(bot.aib_creepReactTgt)
		and GetUnitToUnitDistance(bot, bot.aib_creepReactTgt) <= range + 160 then
		creep = bot.aib_creepReactTgt
		dist = GetUnitToUnitDistance(bot, creep)
	else
		bot.aib_creepReactTgt = creep
		bot.aib_creepReactTgtUntil = now + 2.0
	end

	-- Re-issuing Action_AttackUnit every 0.75s cancels the attack windup: standing
	-- inside the enemy wave the bot "tries to swing but never hits" and LH stalls
	-- (8882969763 t=186-196: idle=30s at cw=push). If a swing is already underway,
	-- own the tick without touching the order.
	local alreadySwinging = bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK

	-- secure-LH v2 RETIRED (19.07, Fable investigation): a securable exact last-hit
	-- ("creep dies to this hit now") is owned at the arbiter level by the last-hit-urgent
	-- candidate (score 140), which preempts this safety-desire handler (score <=134) on
	-- exactly the ticks it would have fired. So CreepHitReact only runs when NO exact
	-- last-hit exists -> the old secure_lh branch was structurally unreachable
	-- (creep-hit-react-lh=0 for 4 matches straight). Its original under-tower case
	-- (8885499372) was also gated off by enemyTowerDanger==nil. Purpose absorbed by
	-- last-hit-urgent; the trade/edge/step branches below own the creep-damage reaction.

	local repeatedDamage = (bot.aib_creepReactCount or 0) >= 3
	local safeToTrade = hp >= 0.55 and dist <= range + 80 and ctx.enemyTowerDanger() == nil
	if safeToTrade then
		bot.aib_creepReactLast = now
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=attack", dist, hp * 100, bot.aib_creepReactCount or 0), 1.5)
		if not alreadySwinging then
			bot:Action_AttackUnit(creep, true)
		end
		ctx.diag("creep-hit-react-atk")
		return true
	end

	-- A committed recovery outranks trading with the wave. The bot was already walking home
	-- after a fight when the creeps caught it, and forced_attack kept stopping it to swing
	-- back: 8906632392 t=262-278 logs recovery-plan action=back reason=post_fight_regen and
	-- recovery-owner mode=safe-step while safety:116 outbid recover:60-78 on every tick --
	-- hp went 61 -> 41 -> 11 -> 0, killed by creeps with no enemy hero involved. Same
	-- committed-transaction class as the rune-commit yield guard (laning_recovery.lua:234):
	-- a creep landing a hit must not cancel an in-progress retreat.
	-- Above 0.55 the safeToTrade branch already owned the tick, so this only releases the
	-- below-0.55 trade branches (forced_attack / edge_attack). MUST stay mirrored by
	-- creepReactReady in mode_laning_generic.lua, or safety keeps winning at 116 and returns
	-- empty instead of trading -- which starves recover even harder (lesson of 140aaa5).
	if bot.aib_recoveryEpisode ~= nil and hp < 0.55 then
		Style.Blocked(bot, "creep-hit-react", "recovery_commit",
			string.format("hp=%.0f band=%s", hp * 100,
				tostring((bot.aib_recoveryEpisode or {}).band)), 3.0)
		return false
	end

	local hasted = bot:HasModifier("modifier_rune_haste")
	local forcedAttackHp = hasted and 0.24 or 0.30
	if hp >= forcedAttackHp and repeatedDamage and dist <= range + 110 and ctx.enemyTowerDanger() == nil then
		bot.aib_creepReactLast = now
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=forced_attack", dist, hp * 100, bot.aib_creepReactCount or 0), 1.0)
		if not alreadySwinging then
			bot:Action_AttackUnit(creep, true)
		end
		ctx.diag("creep-hit-react-force-atk")
		return true
	end

	if hp >= 0.38 and dist <= range + 160 and ctx.enemyTowerDanger() == nil then
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=edge_attack", dist, hp * 100, bot.aib_creepReactCount or 0), 1.5)
		if ctx.moveToAttackEdge(creep, "creep-hit-react-step", 35) then
			bot.aib_creepReactLast = now
			return true
		end
	end

	local safe = nil
	if hp < 0.26 then safe = AIBUtils.SafeRetreatTowerLoc(bot) end
	if safe == nil then
		safe = ctx.towardFountain(bot:GetLocation(), repeatedDamage and 260 or 180)
		if safe == nil then
			local cen = ctx.enemyCreepCentroid(ctx.enemyCreeps)
			if cen ~= nil then safe = ctx.moveAwayFrom(bot:GetLocation(), cen, repeatedDamage and 240 or 160) end
		end
	end
	if safe ~= nil then
		bot.aib_creepReliefLast = now
		bot.aib_creepReactLast = now
		bot.aib_creepReliefDest = safe
		Style.Intent(bot, "creep-hit-react", string.format("dist=%.0f hp=%.0f hits=%d reason=short_step", dist, hp * 100, bot.aib_creepReactCount or 0), 1.0)
		bot:Action_MoveToLocation(safe)
		ctx.diag("creep-hit-react-back")
		return true
	end

	ctx.blocked("creep-hit-react", "no_safe_dest", string.format("dist=%.0f hp=%.0f", dist, hp * 100), 3.0)
	return false
end

function M.DamageUnstuck(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now <= 0 or bot:HasModifier("modifier_teleporting") then return false end
	local loc = bot:GetLocation()
	local hpPct = J.GetHP(bot) * 100
	if bot.aib_damageAnchorLoc == nil or bot.aib_damageAnchorTime == nil then
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		return false
	end
	if dist2D(loc, bot.aib_damageAnchorLoc) > 100 then
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		return false
	end
	local elapsed = now - bot.aib_damageAnchorTime
	local hpDrop = (bot.aib_damageAnchorHp or hpPct) - hpPct
	if elapsed < 4.0 or hpDrop < 6.0 then return false end
	if bot.aib_damageUnstuckLast ~= nil and now - bot.aib_damageUnstuckLast < 3.0 then return false end
	if bot:WasRecentlyDamagedByCreep(1.5)
		and bot.aib_creepReliefLast ~= nil and now - bot.aib_creepReliefLast < 1.6 then return false end

	if ctx.bottleIfUseful(0.72, 0.35, "damage-unstuck-bottle") then
		bot.aib_damageUnstuckLast = now
		bot.aib_damageAnchorLoc = loc
		bot.aib_damageAnchorTime = now
		bot.aib_damageAnchorHp = hpPct
		Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f reason=bottle", hpDrop, elapsed), 2.0)
		return true
	end

	if bot:WasRecentlyDamagedByCreep(1.5) and J.GetHP(bot) >= 0.28 then
		local creep, dist = ctx.nearestAttackableEnemyCreep(attackRange(ctx) + 80)
		if creep ~= nil and dist <= attackRange(ctx) + 40 then
			bot.aib_damageUnstuckLast = now
			bot.aib_damageAnchorLoc = loc
			bot.aib_damageAnchorTime = now
			bot.aib_damageAnchorHp = hpPct
			Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f reason=creep_atk", hpDrop, elapsed), 2.0)
			bot:Action_AttackUnit(creep, true)
			ctx.diag("damage-unstuck-atk")
			return true
		end
	end

	local dest = AIBUtils.SafeRetreatTowerLoc(bot)
	local cen = ctx.enemyCreepCentroid(ctx.enemyCreeps)
	if dest == nil and cen ~= nil then dest = ctx.moveAwayFrom(loc, cen, 420) end
	if dest == nil then return false end
	if GetUnitToLocationDistance(bot, dest) < 220 then
		dest = ctx.towardFountain(loc, 460) or (dest + RandomVector(260))
	end

	bot.aib_damageUnstuckLast = now
	bot.aib_damageAnchorLoc = loc
	bot.aib_damageAnchorTime = now
	bot.aib_damageAnchorHp = hpPct
	Style.Intent(bot, "damage-unstuck", string.format("drop=%.0f elapsed=%.0f", hpDrop, elapsed), 2.0)
	bot:Action_MoveToLocation(dest)
	ctx.diag("damage-unstuck")
	return true
end

function M.LastHitWatchdog(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now < 65 or now > 8 * 60 then return false end
	local lh = ctx.safeCounter("GetLastHits")
	if lh == nil then return false end
	if bot.aib_csWatchLastCheck == nil or now - bot.aib_csWatchLastCheck >= 10.0 then
		if bot.aib_csWatchLH == nil or lh > bot.aib_csWatchLH then
			bot.aib_csWatchLH = lh
			bot.aib_csWatchNoGainSince = now
		elseif bot.aib_csWatchNoGainSince == nil then
			bot.aib_csWatchNoGainSince = now
		end
		bot.aib_csWatchLastCheck = now
	end
	local noGainFor = now - (bot.aib_csWatchNoGainSince or now)
	-- 18s: a full free wave dies in ~20s, so 40s meant the watchdog slept through an
	-- entire farmable wave (bot stood in creeps 21s with 0 LH in 8880652189 t=175-196).
	if lh > 0 and noGainFor < 18.0 then return false end
	if lh == 0 and now < 80 then return false end
	if bot.aib_csWatchLast ~= nil and now - bot.aib_csWatchLast < 1.2 then return false end
	if ctx.enemyTowerDanger() ~= nil and ctx.towerThreatening(ctx.enemyTowerDanger()) then return false end

	local range = attackRange(ctx)
	local creep, dist, hp = ctx.weakestAttackableEnemyCreep(range * 1.65)
	if creep == nil then
		ctx.blocked("cs-watchdog", "no_creep", string.format("lh=%d idle=%.0f", lh, noGainFor), 5.0)
		return false
	end
	bot.aib_csWatchLast = now
	Style.Intent(bot, "cs-watchdog", string.format("lh=%d idle=%.0f creep_hp=%.0f dist=%.0f", lh, noGainFor, hp or -1, dist or -1), 2.0)
	-- Only swing at creeps that are actually finishable; whacking a full-HP creep in
	-- place looks like a frozen bot (8880823408 t~160: creep_hp=550) and breaks the
	-- last_hit_only equilibrium. Otherwise just close distance to the wave.
	local finishable = (hp or math.huge) <= (bot:GetAttackDamage() or 50) * 2
	if dist <= range + 35 and finishable then
		bot:Action_AttackUnit(creep, true)
		ctx.diag("cs-watchdog-atk")
	else
		ctx.moveToAttackEdge(creep, "cs-watchdog-step", 30)
	end
	return true
end

function M.VisualHoldHeartbeat(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now <= 0 then return false end
	local loc = bot:GetLocation()
	if bot.aib_holdAnchorLoc == nil or bot.aib_holdAnchorTime == nil
		or dist2D(loc, bot.aib_holdAnchorLoc) > Const.Visual.holdDistance then
		bot.aib_holdAnchorLoc = loc
		bot.aib_holdAnchorTime = now
		bot.aib_holdSpot = nil        -- hold episode ended: drop the committed stand-still spot
		bot.aib_holdSpotBase = nil
		bot.aib_holdSpotOffset = nil
		return false
	end
	if now - bot.aib_holdAnchorTime < Const.Visual.holdSeconds then return false end
	if bot.aib_holdLast ~= nil and now - bot.aib_holdLast < 1.0 then return false end

	local range = attackRange(ctx)
	local enemy, enemyDist = ctx.nearestEnemyHero(range + 140)
	local creep, creepDist = ctx.nearestAttackableEnemyCreep(range + 140)
	local reason = "empty"
	if bot:WasRecentlyDamagedByCreep(2.0) then reason = "creep_damage"
	elseif enemy ~= nil then reason = "hero_in_range"
	elseif creep ~= nil then reason = "creep_in_range"
	elseif ctx.enemyTowerDanger() ~= nil then reason = "tower" end
	if bot.aib_holdLastReason == reason then
		bot.aib_holdRepeat = (bot.aib_holdRepeat or 0) + 1
	else
		bot.aib_holdLastReason = reason
		bot.aib_holdRepeat = 1
	end
	local hardHold = (bot.aib_holdRepeat or 0) >= 3 or (now - bot.aib_holdAnchorTime) >= 5.0
	if reason == "empty" and J.GetHP(bot) >= 0.55 then
		hardHold = (bot.aib_holdRepeat or 0) >= 2 or (now - bot.aib_holdAnchorTime) >= 3.0
	end
	Style.Blocked(bot, "visual-hold", reason,
		string.format("held=%.1f hp=%.0f repeat=%d hard=%s", now - bot.aib_holdAnchorTime, J.GetHP(bot) * 100, bot.aib_holdRepeat or 0, tostring(hardHold)), 2.0)

	bot.aib_holdLast = now
	if reason == "tower" then
		local twr = ctx.enemyTowerDanger()
		if twr ~= nil and not ctx.towerThreatening(twr)
			and (ctx.rules or {}).tower_aggression ~= "never"
			and ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 120) >= 1
			and J.GetHP(bot) >= 0.35 then
			if GetUnitToUnitDistance(bot, twr) <= range + 60 then
				bot:Action_AttackUnit(twr, true)
				ctx.diag("visual-hold-tower")
				return true
			end
			if ctx.moveToAttackEdge(twr, "visual-hold-tower-step", 30) then return true end
		end
	end
	if reason == "hero_in_range" and enemy ~= nil and J.GetHP(bot) >= 0.35
		and ctx.enemyTowerDanger() == nil and not ctx.uphillMiss(enemy) then
		if enemyDist <= range + 80 then
			bot:Action_AttackUnit(enemy, false)
			ctx.diag("visual-hold-hero")
			return true
		end
		if enemyDist <= range + 180 then return ctx.moveToAttackEdge(enemy, "visual-hold-hero-step", 0) end
	end
	if (reason == "creep_damage" or reason == "creep_in_range") and creep ~= nil then
		if creepDist <= range + (hardHold and 100 or 45) then
			bot:Action_AttackUnit(creep, true)
			ctx.diag("visual-hold-creep")
			return true
		end
		return ctx.moveToAttackEdge(creep, "visual-hold-creep-step", 35)
	end
	if hardHold and (reason == "creep_damage" or reason == "creep_in_range" or reason == "empty") then
		local weakCreep = ctx.weakestAttackableEnemyCreep(range * 1.8)
		if weakCreep ~= nil then return ctx.moveToAttackEdge(weakCreep, "visual-hold-hard-creep", 35) end
	end
	if reason == "creep_damage" then
		local cen = ctx.enemyCreepCentroid(ctx.enemyCreeps)
		if cen ~= nil then
			bot:Action_MoveToLocation(ctx.moveAwayFrom(loc, cen, 260))
			ctx.diag("visual-hold-creep-back")
			return true
		end
	end
	local front = GetLaneFrontLocation(GetTeam(), LANE_MID, 0)
	if front ~= nil then
		local offset = (reason == "tower" or J.GetHP(bot) < 0.38) and -420 or 0
		local dest = GetLaneFrontLocation(GetTeam(), LANE_MID, offset) or front
		-- The user-visible "hangs and twitches in place" (8906632392 at 6:38-6:40 and
		-- 10:12-10:14, visual-hold-lane=15) was a two-part loop, both halves right here:
		--   1. RandomVector(35) was re-rolled EVERY tick, so a bot already standing at the
		--      lane front got a new target ~35u away each tick and vibrated on the spot.
		--   2. Two opposite rolls drift up to 70u > Const.Visual.holdDistance (55), which
		--      resets the anchor above and makes this function return false -- the tick then
		--      falls to visual-afk:8 / anti-idle:2, which move the bot, and the hold re-arms.
		--      That is exactly the winner=visual-hold <-> visual-afk alternation in the log.
		-- Fix: commit the spot for the whole hold episode, and once we are on it, own the tick
		-- STANDING STILL rather than re-issuing a move (standing is the correct visual for a
		-- hold, and it keeps the bot inside holdDistance so the anchor survives). Re-roll only
		-- if the offset flips or the lane front itself has moved.
		local reroll = (bot.aib_holdSpot == nil) or (bot.aib_holdSpotOffset ~= offset)
		if not reroll and bot.aib_holdSpotBase ~= nil then
			if dist2D(dest, bot.aib_holdSpotBase) > 250 then reroll = true end
		end
		if reroll then
			bot.aib_holdSpotBase = dest
			bot.aib_holdSpot = dest + RandomVector(35)
			bot.aib_holdSpotOffset = offset
		end
		if GetUnitToLocationDistance(bot, bot.aib_holdSpot) > 100 then
			bot:Action_MoveToLocation(bot.aib_holdSpot)
			ctx.diag(reason == "tower" and "visual-hold-safe" or "visual-hold-lane")
		else
			ctx.diag("visual-hold-still")
		end
		return true
	end
	return false
end

return M
