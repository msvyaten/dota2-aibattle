-- AIBattle laning creep work: last-hit, push and deny.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

function M.GetBestLastHitCreep(bot, creeps, attackDamage)
	if not creeps then return nil end
	local dmgDelta = attackDamage * Const.Creeps.lastHitDamageWindow
	for _, creep in pairs(creeps) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep, false
			end
		end
	end
	for _, creep in pairs(creeps) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage + dmgDelta, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep, true
			end
		end
	end
	return nil
end

-- One owner for "is this ally creep actually denyable".
--
-- The last-hit side has always asked the predictive question -- J.WillKillTarget with the
-- attack delay, i.e. "will my hit land while it is still alive, and will it kill". The deny
-- side asked a static one (GetHealth() <= attackDamage, no delay, no check that somebody
-- else finishes it first), and deny_policy="always" asked no damage question at all: it took
-- the first ally creep under 60% hp and swung at it. 8925573332 [D, always]: deny-act=462
-- (atk 163 + walk 299) against dn=5 -- most of a match spent walking at, and swinging on, own
-- creeps it could not kill. R on "default" read 224/8 with the same missing delay model.
--
-- The policy is only allowed to move the hp ceiling. Whether the swing lands is physics, not
-- policy, so it lives here for every caller.
function M.GetBestDenyCreep(bot, creeps, attackDamage, hpCeil)
	if bot == nil or not creeps then return nil end
	hpCeil = hpCeil or Const.Creeps.defaultDenyHp
	local rejected = nil
	for _, creep in pairs(creeps) do
		if J.IsValid(creep)
			and J.GetHP(creep) < hpCeil
			and J.CanBeAttacked(creep) then
			local nDelay = J.GetAttackProDelayTime(bot, creep)
			if J.WillKillTarget(creep, attackDamage, DAMAGE_TYPE_PHYSICAL, nDelay) then
				return creep
			end
			-- Which half of the old predicate was doing the damage: 'doomed' = it dies to
			-- somebody else before our swing lands, 'tanky' = our hit does not kill it at all.
			-- Labelled once per call, not once per creep, so the count stays comparable to
			-- deny-act instead of scaling with wave size.
			if rejected ~= "doomed" then
				rejected = (J.GetTotalAttackWillRealDamage(creep, nDelay) >= creep:GetHealth())
					and "doomed" or "tanky"
			end
		end
	end
	if rejected ~= nil then Style.Diag(bot, "deny-cand-"..rejected) end
	return nil
end

function M.NearestAttackableEnemyCreep(bot, enemyCreeps, range)
	local best = nil
	local bestDist = range or math.huge
	for _, creep in pairs(enemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local dist = GetUnitToUnitDistance(bot, creep)
			if dist <= bestDist then
				best = creep
				bestDist = dist
			end
		end
	end
	return best, bestDist
end

function M.WeakestAttackableEnemyCreep(bot, enemyCreeps, maxDist)
	local best = nil
	local bestHp = math.huge
	local bestDist = math.huge
	for _, creep in pairs(enemyCreeps or {}) do
		if J.IsValid(creep) and J.CanBeAttacked(creep) then
			local dist = GetUnitToUnitDistance(bot, creep)
			local hp = creep:GetHealth()
			if dist <= (maxDist or math.huge) and hp < bestHp then
				best = creep
				bestHp = hp
				bestDist = dist
			end
		end
	end
	return best, bestDist, bestHp
end

function M.AlliedCreepsAtTower(allyCreeps, tower, distLimit)
	if tower == nil then return 0 end
	local count = 0
	for _, creep in pairs(allyCreeps or {}) do
		if J.IsValid(creep) and GetUnitToUnitDistance(creep, tower) <= (distLimit or tower:GetAttackRange() + 180) then
			count = count + 1
		end
	end
	return count
end

local function moveToAttackEdge(ctx, creep, extraBack)
	if ctx.moveToAttackEdge ~= nil then
		ctx.moveToAttackEdge(creep, nil, extraBack or 20)
	else
		ctx.bot:Action_MoveToUnit(creep)
	end
end

function M.HandleCreepWork(ctx)
	local bot = ctx.bot
	local rules = ctx.rules or {}
	local cwp = rules.creep_wave_priority or "last_hit_only"
	local attackRange = ctx.attackRange or bot:GetAttackRange()
	local hitCreep, csSoon = ctx.hitCreep, ctx.csSoon
	local csAllowed = ctx.csAllowed
	local csDistNow = ctx.csDistNow
	local needMove = ctx.needMove

	local csDist = csAllowed and needMove and (csDistNow or GetUnitToUnitDistance(bot, hitCreep))
	if csAllowed and needMove and csDist <= attackRange * 1.5 then
		if csSoon == true and csDist <= attackRange - 35 then
			local now = DotaTime()
			if bot.aib_csWaitStart == nil or bot.aib_csWaitTarget ~= hitCreep then
				bot.aib_csWaitStart = now
				bot.aib_csWaitTarget = hitCreep
			end
			if now - bot.aib_csWaitStart < 0.8 then
				Style.DiagRL(bot, "cs-wait", 2)
				return true
			end
			bot:SetTarget(hitCreep)
			bot:Action_AttackUnit(hitCreep, true)
			ctx.diag("cs-wait-release")
			return true
		end
		bot.aib_csWaitStart = nil
		bot.aib_csWaitTarget = nil
		ctx.diag("cs-walk")
		-- MEASUREMENT ONLY (21.07) -- no behaviour change. In 8906632392 the farmer fired
		-- cs-walk 275x against the brawler's 90x for the same CS output (lh 48 vs 45), i.e.
		-- it pays a walk-in for most last hits. Established: it is NOT an absence problem
		-- (87% of the match in lane) and NOT wave-watch parking (only 13% of wave-watch holds
		-- are followed by cs-walk, vs 16% for the brawler). What is still unknown is HOW FAR
		-- out of position it stands and therefore which handler parks it there.
		-- Bucket the gap into plain Diag counters: Intent lines are rate-limited and
		-- under-report, which already produced one wrong diagnosis this session.
		if csDist <= attackRange then
			ctx.diag("cs-walk-inrange")       -- micro-adjust, not a real walk-in
		elseif csDist <= attackRange * 1.2 then
			ctx.diag("cs-walk-gap-small")
		else
			ctx.diag("cs-walk-gap-large")     -- parked well outside attack range
		end
		-- A RANGED hero does not walk into the enemy melee pack for a creep. This is the cause
		-- of the statue, not a detail of it: ranged-spacing (41) sits above creep-work (38) and
		-- holds the safe edge, but during its own 1.4s move throttle it yields the tick, and
		-- creep-work took those windows to walk the hero back in -- after which spacing pushed
		-- out again. The oscillation was cured by making the hold OWN the tick and issue no
		-- order at all, which is why a Shadow Fiend stands still: ranged-spacing was the top
		-- tick owner at 57 of 260 in 8964741391, most of it melee-pack-hold.
		--
		-- Refusing the walk-in removes the reason the hold has to freeze, so the two changes go
		-- together. It costs no CS the hero could actually take: cs-walk correlates +0.35 with
		-- lh/min because it collects creeps that come to us, and this only refuses the ones
		-- sitting inside the pack, which a ranged hero should wait for rather than fetch.
		if AIBUtils.LocInsideMeleePack(ctx, hitCreep:GetLocation()) then
			ctx.diag("cs-walk-into-pack")
			return false
		end
		moveToAttackEdge(ctx, hitCreep, 20)
		return true
	end
	bot.aib_csWaitStart = nil
	bot.aib_csWaitTarget = nil

	if ctx.rangedSpacing ~= nil and ctx.rangedSpacing() then return true end
	if ctx.lastHitWatchdog ~= nil and ctx.lastHitWatchdog() then return true end

	if cwp == "push" and ctx.enemyTowerDanger() == nil then
		if csAllowed and csSoon == true and csDistNow ~= nil and csDistNow <= attackRange * 1.55 then
			if csDistNow <= attackRange + 40 then
				Style.DiagRL(bot, "cw-push-protect-cs", 2)
				return true
			end
			ctx.diag("cw-push-cs-step")
			moveToAttackEdge(ctx, hitCreep, 20)
			return true
		end
		local allyNear = false
		for _, a in pairs(ctx.allyCreeps or {}) do
			if J.IsValid(a) and GetUnitToUnitDistance(bot, a) <= Const.Creeps.pushAllyNear then
				allyNear = true; break
			end
		end
		if allyNear then
			local pushCreep, pushHp = nil, -1
			for _, c in pairs(ctx.enemyCreeps or {}) do
				if J.IsValid(c) and J.CanBeAttacked(c)
					and GetUnitToUnitDistance(bot, c) <= attackRange then
					local hp = c:GetHealth()
					if (not csAllowed or c ~= hitCreep or csSoon ~= true) and hp > pushHp then
						pushCreep, pushHp = c, hp
					end
				end
			end
			if pushCreep ~= nil then
				bot:Action_AttackUnit(pushCreep, true)
				ctx.diag("cw-push")
				return true
			end
		end
	end

	if ctx.siegeIntent ~= nil and ctx.siegeIntent() then return true end

	local denyPol = rules.deny_policy or "default"
	if denyPol ~= "never" then
		local denyCreep
		if ctx.bestDeny ~= nil then
			-- "always" buys a wider hp window, nothing else. It used to buy the right to
			-- swing at creeps the hero cannot kill; see GetBestDenyCreep.
			denyCreep = ctx.bestDeny(ctx.allyCreeps,
				denyPol == "always" and Const.Creeps.alwaysDenyHp or Const.Creeps.defaultDenyHp)
		end
		if J.IsValid(denyCreep) then
			local skipDeny = false
			local ownT1 = GetTower(bot:GetTeam(), TOWER_MID_1)
			if ownT1 ~= nil then
				local botDistT1  = GetUnitToUnitDistance(bot, ownT1)
				local creepDistT1 = GetUnitToUnitDistance(denyCreep, ownT1)
				if creepDistT1 < botDistT1 - Const.Creeps.denyBacktrackSkip then
					skipDeny = true
				end
			end
			if not skipDeny then
				bot:SetTarget(denyCreep)
				-- MEASUREMENT ONLY (21.07) -- no behaviour change. deny-act reads 34-42 per
				-- match against 3 denies, which looks like 8% conversion. It is not safe to
				-- read it that way: deny-act counts a TICK, and a tick can be an approach.
				-- That is exactly the mistake cs-walk cost us -- a high count was read as
				-- wasted effort when it actually correlates +0.35 with lh/min. So split the
				-- counter before anyone proposes a deny fix: -atk is a real swing at a
				-- denyable creep, -walk is an approach, -skip is the backtrack guard
				-- declining. Only -atk is comparable to the dn stat.
				if GetUnitToUnitDistance(bot, denyCreep) <= attackRange + 40 then
					bot:Action_AttackUnit(denyCreep, true)
					ctx.diag("deny-act-atk")
				else
					moveToAttackEdge(ctx, denyCreep, 20)
					ctx.diag("deny-act-walk")
				end
				ctx.diag("deny-act")
				return true
			end
			Style.DiagRL(bot, "deny-skip-backtrack", 5)
		end
	end

	return false
end

return M
