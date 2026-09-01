-- AIBattle laning siege window.
-- Keeps tower pressure policy out of mode_laning_generic.lua while preserving the
-- existing callbacks/diagnostics from that file.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')

function M.Commit(bot, ttl, now)
	if bot == nil then return end
	bot.aib_siegeCommitUntil = (now or DotaTime()) + (ttl or 0)
end

function M.Active(bot, now)
	return bot ~= nil and bot.aib_siegeCommitUntil ~= nil
		and (now or DotaTime()) <= bot.aib_siegeCommitUntil
end

function M.Release(bot)
	if bot ~= nil then bot.aib_siegeCommitUntil = nil end
end

-- "The tower has picked ME." Pure test, no latch written: CanAct scores candidates and must
-- not have side effects, so the latch is set only on the acting side in Think.
--
-- This exists as its own function because of where the answer has to be asked. Both CanAct
-- and Think opened with `if ctx.towerThreatening(twr) and towerAggr ~= "always" then return
-- false end`, and IsTowerActuallyThreatening returns true precisely when the tower is in range
-- of us AND is not busy shooting one of our creeps -- i.e. exactly when it is shooting us. The
-- backoff written for that case sat sixty lines the wrong side of that gate, so it could never
-- run: siege-tower-backoff reads 0 in every match on record, on every hero. The mechanism was
-- never broken. It was unreachable, and the bot's only answer to "a tower is hitting me" was
-- for siege to decline the tick and let some other owner keep standing there. 8925573332 [D]
-- took 1206 tower damage, 12% of everything it received.
--
-- Asked before the hp/desire gates too, on purpose: the lowest HP is when leaving matters most,
-- and those gates would have refused there as well.
function M.WantsTowerBackoff(bot, twr, now)
	if bot == nil or twr == nil or not twr:IsAlive() then return false end
	local target = twr:GetAttackTarget()
	-- target == bot, not "a hero on our team": here counting ourselves IS the point, and in a
	-- five-man game a tower shooting an ally is not a reason for us to walk.
	-- Three legs, one log line. The caller used to print `tower_targeting_me` whichever leg
	-- answered, so the damage leg was reported under the name of the targeting leg and could
	-- not be told apart from it -- the same shape as the capped candidates, which named the
	-- refusal and never the cause. The leg comes back as a second value; the key is unchanged
	-- so existing counters still line up.
	if target ~= nil and target == bot then return true, "targeted" end
	if bot.WasRecentlyDamagedByTower ~= nil and bot:WasRecentlyDamagedByTower(1.2)
		and GetUnitToUnitDistance(bot, twr) <= twr:GetAttackRange() + 90 then
		return true, "tower_damage"
	end
	-- Latched but ALREADY at the safe point is not a claim on the tick. Answering true there
	-- made CanAct promise an action that Think delivered as a bare `return true` with no order,
	-- so the bot stood still for the rest of the 2.5s window and lost the farm/fight it could
	-- have had (Codex's audit -- and exactly the empty-owner shape this file keeps paying for).
	local latched = M.TowerBackoffLatched(bot, now) and not M.TowerBackoffArrived(bot)
	return latched, latched and "latched" or nil
end

-- The latch's remaining time after arrival still has a job: it is what stops the siege desire
-- from turning round and walking straight back in. So it is not dropped on arrival (which is
-- what an audit reading of "release the latch once safe" would do) -- siege simply stops
-- claiming the tick and lets somebody else use it.
function M.TowerBackoffLatched(bot, now)
	return bot ~= nil and bot.aib_towerBackoffUntil ~= nil
		and (now or DotaTime()) < bot.aib_towerBackoffUntil
		and bot.aib_towerBackoffDest ~= nil
end

function M.TowerBackoffArrived(bot)
	return bot ~= nil and bot.aib_towerBackoffDest ~= nil
		and GetUnitToLocationDistance(bot, bot.aib_towerBackoffDest) <= 90
end

-- "Something of OURS is soaking the tower" -- and a hero is not that something. The team
-- test alone counted the bot ITSELF: while the tower was shooting the hero, the hero
-- concluded it had tank cover and kept sieging, which is self-reinforcing -- the longer it
-- stands there the longer the tower keeps targeting it and the longer it believes it is
-- covered. 8909602648 [D] took 319 tower damage, 18% of everything it received, and lost
-- the game on it; bee3dd8 fixed the commit latch that carried it in, this is why it thought
-- it was safe once there. Only a non-hero unit can tank, which in a 1v1 lane means a creep.
--
-- Reading the tower's target is the FACT. Everything after it is a guess, and the guess used
-- to accept any one creep standing near the tower. One creep is not cover; it is one tower
-- shot away from not being cover. 8974387496 t=423-434: Dire walked in on wave=2, kept hitting
-- the tower as the wave fell to 1, and took the retarget at 90% -> 83% with no enemy hero
-- anywhere on the lane -- the same self-reinforcing belief as above, entered through the back
-- door left open when the fact test was tightened and the guess under it was not. A guessed
-- shield needs depth, so the creep the tower is about to kill is not the only thing in the way.
--
-- Returns (tank, guessedNear): guessedNear is 0 when the fact answered, otherwise how many
-- creeps the guess counted, so Think can log a shield of exactly one. It never logs itself --
-- CanAct calls this too, and a probe that emits telemetry double-counts every tick.
local function alliedTankAt(ctx, twr)
	local target = twr:GetAttackTarget()
	if target ~= nil and target:GetTeam() == GetTeam() and not target:IsHero() then
		return true, 0
	end
	local near = 0
	for _, creep in pairs(ctx.allyCreeps or {}) do
		if J.IsValid(creep) and GetUnitToUnitDistance(creep, twr) <= twr:GetAttackRange() + 120 then
			near = near + 1
		end
	end
	return near >= 2, near
end

-- Our wave ON the tower is what makes a siege. Creeps standing near it while they trade with
-- the enemy wave are not sieging anything, and until then the tower is not our business.
local function waveIsOnTheTower(ctx, twr)
	local onIt = false
	for _, creep in pairs(ctx.allyCreeps or {}) do
		if J.IsValid(creep) and creep:GetAttackTarget() == twr then onIt = true; break end
	end
	return onIt
end

-- One owner for "there is an enemy creep in front of us, hit that". Called from two places
-- now -- ahead of the tower branches and after them -- so the two can never disagree about
-- what counts as a creep worth hitting.
local function hitCreepHere(ctx, bot, attackRange, now, key)
	local hit = false
	for _, creep in pairs(ctx.enemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep)
			and GetUnitToUnitDistance(bot, creep) <= attackRange + 40 then
			M.Commit(bot, 1.6, now)
			bot:Action_AttackUnit(creep, true)
			ctx.diag(key)
			hit = true
			break
		end
	end
	return hit
end

function M.Think(ctx)
	local bot = ctx.bot
	local dials = ctx.dials or {}
	local rules = ctx.rules or {}
	local attackRange = ctx.attackRange or bot:GetAttackRange()

	local twr = ctx.enemyTowerDanger()
	if twr == nil then
		local midT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if midT1 ~= nil and midT1:IsAlive()
			and ctx.alliedCreepsAtTower(midT1, midT1:GetAttackRange() + 220) >= 2 then
			twr = midT1
		end
	end
	if twr == nil then return false end

	-- tower_aggression: risk gates for sieging. Desire knobs (push_desire, cwp)
	-- say how much the bot wants the tower; this rule says what risk it accepts.
	local towerAggr = rules.tower_aggression or "default"
	if towerAggr == "never" then
		ctx.blocked("siege", "tower_aggression_never", string.format("tower=%.0f", GetUnitToUnitDistance(bot, twr)), 5.0)
		return false
	end

	local now = DotaTime()
	local twrDist = GetUnitToUnitDistance(bot, twr)
	-- Leaving comes before every gate below. tower_aggression="always" still buys the right to
	-- stand and eat it; everyone else walks out first and argues about desire afterwards.
	local wantsBackoff, backoffCause = M.WantsTowerBackoff(bot, twr, now)
	if towerAggr ~= "always" and wantsBackoff then
		if bot.aib_towerBackoffUntil == nil or now >= bot.aib_towerBackoffUntil then
			bot.aib_towerBackoffUntil = now + 2.5
			-- Out of the tower's range, not a fixed 420. 420 was the step that cleared a
			-- 500-range hero standing at ~560. A melee hero is at 150-330 when it hits a
			-- tower, so the same step leaves it at 570-750 -- still inside the tower's 700 --
			-- and the latch expires straight into another walk-in. That is the "runs into
			-- tower range and runs back out" the user watched. Derived from the tower now, so
			-- it is right for both classes without asking which one we are.
			--
			-- Computed ONCE and re-issued unchanged. Deriving it from the CURRENT position
			-- every tick is the bug this codebase has paid for three times -- f26c645, b4b24af,
			-- 39e3e6b -- the target walks away as fast as the bot walks toward it.
			local need = (twr:GetAttackRange() + 150) - twrDist
			bot.aib_towerBackoffDest = J.VectorAway(bot:GetLocation(), twr:GetLocation(),
				math.max(need, 250))
		end
		ctx.blocked("siege", "tower_targeting_me",
			string.format("tower=%.0f hp=%.0f cause=%s", twrDist, J.GetHP(bot) * 100,
				backoffCause or "none"), 3.0)
		ctx.diag("siege-tower-backoff")
		bot:Action_MoveToLocation(bot.aib_towerBackoffDest)
		return true
	end
	if towerAggr ~= "always" and M.TowerBackoffLatched(bot, now) then
		-- Parked at the safe point with time left on the latch: yield the tick rather than own
		-- it emptily, but do NOT fall through into the siege body, which would walk us back in.
		ctx.diag("siege-backoff-parked")
		return false
	end

	if ctx.towerThreatening(twr) and towerAggr ~= "always" then return false end

	local cwp = rules.creep_wave_priority or "last_hit_only"
	local enemy, enemyDist = ctx.nearestEnemyHero(2200)
	local enemyFarOrWeak = enemy == nil or enemyDist > 1300 or J.GetHP(enemy) < 0.28
	local waveCount = ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 180)
	local waveAtTower = waveCount >= 1
	local strongWaveAtTower = waveCount >= 3
	local advantageSiege = ctx.enemyDeadRecently() or (waveAtTower and enemyFarOrWeak)
	local wantsSiege = towerAggr == "always" or cwp == "push" or advantageSiege or (dials.push_desire or 0.5) >= 0.65
	local siegeHpFloor = ctx.enemyDeadRecently() and 0.22 or 0.35
	if towerAggr == "always" then siegeHpFloor = ctx.enemyDeadRecently() and 0.20 or 0.28 end
	local towerLethal = twr:GetHealth() <= bot:GetAttackDamage() * 1.10
	if towerLethal and twrDist <= attackRange + 60 and J.GetHP(bot) >= 0.40 then
		M.Commit(bot, 1.6, now)
		bot:Action_AttackUnit(twr, true)
		ctx.towerOpportunity("hit", string.format("phase=lethal wave=%d tower=%.0f hp=%.0f thp=%.0f",
			waveCount, twrDist, J.GetHP(bot) * 100, twr:GetHealth()), 2.0)
		ctx.diag("siege-lethal-tower")
		return true
	end
	if not wantsSiege or J.GetHP(bot) < siegeHpFloor then
		ctx.blocked("siege", "desire_or_hp", string.format("hp=%.0f adv=%s", J.GetHP(bot) * 100, tostring(advantageSiege)), 5.0)
		ctx.towerOpportunity("blocked_desire_or_hp", string.format("wave=%d hp=%.0f adv=%s", waveCount, J.GetHP(bot) * 100, tostring(advantageSiege)), 5.0)
		return false
	end

	local alliedTank, guessedShield = alliedTankAt(ctx, twr)
	if not alliedTank and guessedShield == 1 then ctx.diag("siege-thin-shield") end
	-- THE TOWER IS SHOOTING US is answered at the top of this function now, ahead of the gate
	-- that used to bury it. Measured across the era: 14 of 16 sides took tower damage, and
	-- aggregating what the bot was doing in the 31 windows where that damage grew puts the
	-- siege machinery on top by a distance (state-desire-siege 89, siege:terminal 34,
	-- siege:commit 22). So "tower pokes in almost every match" is not a stray dive -- it is
	-- this loop, standing in range and trading hits with a building.
	--
	-- An aggro-drop helper already existed (AIB_TowerAggroDrop) but only DivePolicy ever
	-- called it, never the siege path, and it works by attacking an allied creep -- which does
	-- not move tower aggro in modern Dota. Leaving the tower's range does.
	--
	-- One poke is the price of information; four is how Dire lost 8909602648.

	if not alliedTank and towerAggr ~= "always" then
		if ctx.enemyDeadRecently() and twrDist > attackRange + 60 then
			ctx.state("siege-window", string.format("ttl=2 wave=%d tower=%.0f hp=%.0f adv=%s", waveCount, twrDist, J.GetHP(bot) * 100, tostring(advantageSiege)), 2.0)
			ctx.towerOpportunity("step", string.format("phase=dead_no_tank wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-dead-no-tank-step")
			return ctx.moveToAttackEdge(twr, "siege-dead-no-tank-step", 80)
		end
		ctx.blocked("siege", "no_allied_tank", string.format("tower=%.0f", GetUnitToUnitDistance(bot, twr)), 5.0)
		ctx.towerOpportunity("blocked_no_tank", string.format("wave=%d tower=%.0f", waveCount, GetUnitToUnitDistance(bot, twr)), 5.0)
		return false
	end
	if not alliedTank then
		-- tower_aggression=always without wave cover: reckless tower hits.
		if twrDist <= attackRange + 60 then
			M.Commit(bot, 2.0, now)
			bot:Action_AttackUnit(twr, true)
			ctx.towerOpportunity("hit", string.format("phase=no_tank_always wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-no-tank-tower")
			return true
		end
		M.Commit(bot, 2.0, now)
		ctx.towerOpportunity("step", string.format("phase=no_tank_always wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		return ctx.moveToAttackEdge(twr, "siege-no-tank-step", 40)
	end

	local inTowerAttackRange = twrDist <= attackRange + 60
	ctx.state("siege-window", string.format("ttl=2 wave=%d tower=%.0f hp=%.0f adv=%s", waveCount, twrDist, J.GetHP(bot) * 100, tostring(advantageSiege)), 2.0)
	local safeHealingHit = alliedTank and inTowerAttackRange and J.GetHP(bot) >= (ctx.enemyDeadRecently() and 0.30 or 0.38)
	if ctx.healingChannelActive() and not ctx.enemyDeadRecently() and not safeHealingHit then
		ctx.blocked("siege", "healing", string.format("tower=%.0f tank=%s", twrDist, tostring(alliedTank)), 4.0)
		ctx.towerOpportunity("blocked_healing", string.format("wave=%d tower=%.0f", waveCount, twrDist), 4.0)
		return false
	end

	-- NOTE: this is the widest of the four tower-hit branches and the earliest, so it shadows the
	-- other three in practice. It reaches `attackRange + 180`; the wave branch below and the
	-- default branch after it both require `+ 60`, and by the time the bot is inside 60 it has
	-- almost always already satisfied this one and returned. Across the last three matches
	-- `siege-terminal-tower` fired 130 times while `siege-tower`, `siege-wave-tower` and
	-- `siege-no-tank-tower` never fired at all -- so the tower does get attacked, but only ever
	-- through here, and the other three exist on paper.
	-- Not resolved yet, because the two readings need live numbers to separate: either the 180
	-- band is too generous and should match the others, or the narrower branches are redundant
	-- and should go. `siege-no-tank-tower` is a third case again -- it needs
	-- tower_aggression="always", which no config in the series has ever set, so its silence says
	-- nothing about this shadowing.
	-- Two waves killing each other under a tower is not a siege, and the tower is the worst
	-- target on the screen while it lasts: it pays nothing until it falls, the enemy creep in
	-- front of us pays gold now, and killing that creep is what walks our own wave up to the
	-- tower in the first place. The rule was already written -- `siege-creep` below does
	-- exactly this -- but every tower branch sits above it and returns first, so across
	-- 8974058954, 8974086880 and 8974387496 the tower was hit 169 times and that branch fired
	-- ZERO. The order was the bug, not a missing rule.
	-- Only "our creeps are actually attacking the tower" earns the tower the tick ahead of a
	-- creep; a creep merely standing near it does not, which is the same distinction
	-- alliedTankAt draws between the fact and the guess.
	if not waveIsOnTheTower(ctx, twr)
		and hitCreepHere(ctx, bot, attackRange, now, "siege-creep-first") then
		ctx.towerOpportunity("creep_first", string.format("wave=%d tower=%.0f", waveCount, twrDist), 3.0)
		return true
	end

	if alliedTank and waveAtTower and twrDist <= attackRange + 180
		and J.GetHP(bot) >= (ctx.enemyDeadRecently() and 0.26 or 0.34) then
		M.Commit(bot, 2.4, now)
		bot:Action_AttackUnit(twr, true)
		ctx.towerOpportunity("hit", string.format("phase=terminal wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		ctx.diag("siege-terminal-tower")
		return true
	end

	if enemy ~= nil and enemy:IsAlive() and enemyDist <= attackRange + 80
		and J.GetHP(bot) >= 0.45
		and (ctx.uphillMiss == nil or not ctx.uphillMiss(enemy)) then
		local hasDamageRune = bot:HasModifier("modifier_rune_doubledamage")
		local hpAdv = J.GetHP(bot) >= J.GetHP(enemy) + 0.08
		local killWindow = J.GetHP(enemy) <= 0.60
		if hasDamageRune or hpAdv or killWindow or (rules.hero_priority or "default") == "always" then
			M.Commit(bot, 1.2, now)
			bot:Action_AttackUnit(enemy, false)
			ctx.towerOpportunity("hit", string.format("phase=hero wave=%d hero=%.0f ehp=%.0f", waveCount, enemyDist, J.GetHP(enemy) * 100), 2.0)
			ctx.diag("siege-hero")
			return true
		end
	end

	-- The commit latch must not outlive the creeps that justified it. It was set while a
	-- wave was tanking the tower, and then kept walking the bot into tower range after the
	-- wave died: 8909602648 [D] logs `phase=terminal wave=1` at 4:22 and `phase=commit
	-- wave=0` three seconds later, tower damage 319 = 18% of everything that bot took, and
	-- the user watched it eat four tower shots and lose the game on it. Same shape as the
	-- recovery-wait latch in b4b24af -- a latch re-evaluated on time alone while the world
	-- it was latched against moved on. Dropping the latch falls through to the wave/default
	-- branches below, which do their own gating, so no tick is burned.
	if M.Active(bot, now) then
		if not waveAtTower and twrDist <= attackRange + 260 then
			M.Release(bot)
			ctx.towerOpportunity("blocked_wave_gone", string.format("wave=%d tower=%.0f", waveCount, twrDist), 4.0)
			ctx.diag("siege-commit-wave-gone")
		else
			ctx.towerOpportunity(twrDist <= attackRange + 180 and "hit" or "step", string.format("phase=commit wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			return AIBEngine.AttackOrMoveToBand(ctx, twr, "siege-commit-tower", 30)
		end
	end

	if strongWaveAtTower and (cwp == "push" or ctx.enemyDeadRecently() or enemyFarOrWeak) then
		if twrDist <= attackRange + 60 then
			M.Commit(bot, 2.2, now)
			bot:Action_AttackUnit(twr, true)
			ctx.towerOpportunity("hit", string.format("phase=wave wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			ctx.diag("siege-wave-tower")
			return true
		end
		M.Commit(bot, 2.2, now)
		ctx.towerOpportunity("step", string.format("phase=wave wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		return ctx.moveToAttackEdge(twr, "siege-wave-step", 20)
	end

	if hitCreepHere(ctx, bot, attackRange, now, "siege-creep") then return true end
	if twrDist <= attackRange + 60 then
		M.Commit(bot, 1.6, now)
		bot:Action_AttackUnit(twr, true)
		ctx.towerOpportunity("hit", string.format("phase=default wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		ctx.diag("siege-tower")
		return true
	end
	-- Both step legs read moveToAttackEdge's answer before claiming the tick: it returns false,
	-- and emits no key, when there is no attack edge to walk to. The throttle and the commit are
	-- armed only after an order actually goes out -- setting them first spent a second of siege
	-- cadence and 1.6s of commit on a move that never happened.
	if bot.aib_siegeLast == nil or now - bot.aib_siegeLast >= 1.0 then
		ctx.towerOpportunity("step", string.format("phase=default wave=%d tower=%.0f", waveCount, twrDist), 2.0)
		if not ctx.moveToAttackEdge(twr, "siege-step", 30) then
			ctx.diag("siege-step-no-edge")
			return false
		end
		bot.aib_siegeLast = now
		M.Commit(bot, 1.6, now)
	else
		local pushCreep = ctx.nearestAttackableEnemyCreep(attackRange + 40)
		if pushCreep ~= nil then
			bot:Action_AttackUnit(pushCreep, true)
			ctx.diag("siege-hold-creep")
		else
			ctx.towerOpportunity("step", string.format("phase=hold wave=%d tower=%.0f", waveCount, twrDist), 2.0)
			if not ctx.moveToAttackEdge(twr, "siege-hold-step", 30) then
				ctx.diag("siege-hold-no-edge")
				return false
			end
		end
	end
	return true
end

-- Pure feasibility probe (canAct contract, P4): true only when M.Think would ACT this
-- tick. Mirrors Think's return-false gates WITHOUT any side effect (no blocked/state/diag
-- /action), so a fully-gated siege desire (no wave cover / healing tank / hp floor) stops
-- winning the tick and pacing at the tower (8888743934). Keep in lock-step with Think's
-- gate chain above; only the return-false conditions matter here.
function M.CanAct(ctx)
	local bot = ctx.bot
	local dials = ctx.dials or {}
	local rules = ctx.rules or {}
	local attackRange = ctx.attackRange or bot:GetAttackRange()

	local twr = ctx.enemyTowerDanger()
	if twr == nil then
		local midT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if midT1 ~= nil and midT1:IsAlive()
			and ctx.alliedCreepsAtTower(midT1, midT1:GetAttackRange() + 220) >= 2 then
			twr = midT1
		end
	end
	if twr == nil then return false end

	local towerAggr = rules.tower_aggression or "default"
	if towerAggr == "never" then return false end
	-- Mirrors Think: when the tower has picked us, siege is exactly the owner that must get the
	-- tick, because its job in that case is to leave. Saying "cannot act" here is what kept the
	-- backoff out of the election in the first place. Checked before the desire and hp floors
	-- below for the same reason -- at 30% hp those refuse, and 30% hp is when walking out
	-- matters most. Pure test; the latch is written only on the acting side.
	if towerAggr ~= "always" and M.WantsTowerBackoff(bot, twr) then return true end
	-- Latched but already parked at the safe point: WantsTowerBackoff answers false there (it
	-- is not a claim on the tick), and Think yields early to stop the siege body walking us
	-- back in. Without this line CanAct kept walking past -- towerThreatening is false once we
	-- are out of range, so the desire and hp gates could pass and promise an action Think then
	-- refused, which is the empty tick owner this whole change exists to remove.
	if towerAggr ~= "always" and M.TowerBackoffLatched(bot) then return false end
	if ctx.towerThreatening(twr) and towerAggr ~= "always" then return false end

	local cwp = rules.creep_wave_priority or "last_hit_only"
	local enemy, enemyDist = ctx.nearestEnemyHero(2200)
	local enemyFarOrWeak = enemy == nil or enemyDist > 1300 or J.GetHP(enemy) < 0.28
	local waveCount = ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 180)
	local waveAtTower = waveCount >= 1
	local advantageSiege = ctx.enemyDeadRecently() or (waveAtTower and enemyFarOrWeak)
	local wantsSiege = towerAggr == "always" or cwp == "push" or advantageSiege or (dials.push_desire or 0.5) >= 0.65
	local siegeHpFloor = ctx.enemyDeadRecently() and 0.22 or 0.35
	if towerAggr == "always" then siegeHpFloor = ctx.enemyDeadRecently() and 0.20 or 0.28 end
	if not wantsSiege or J.GetHP(bot) < siegeHpFloor then return false end

	local twrDist = GetUnitToUnitDistance(bot, twr)
	local alliedTank = alliedTankAt(ctx, twr)
	if not alliedTank and towerAggr ~= "always" then
		-- only the enemy-dead no-tank STEP acts; the plain no-tank case returns empty
		return ctx.enemyDeadRecently() and twrDist > attackRange + 60
	end
	if not alliedTank then return true end -- always without tank still hits/steps

	local inTowerAttackRange = twrDist <= attackRange + 60
	local safeHealingHit = inTowerAttackRange and J.GetHP(bot) >= (ctx.enemyDeadRecently() and 0.30 or 0.38)
	if ctx.healingChannelActive() and not ctx.enemyDeadRecently() and not safeHealingHit then return false end
	return true -- past every gate: Think acts (hit / step / commit)
end

return M
