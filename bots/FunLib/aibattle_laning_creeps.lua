-- AIBattle laning creep work: last-hit, push and deny.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')

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

function M.GetBestDenyCreep(creeps, attackDamage)
	if not creeps then return nil end
	for _, creep in pairs(creeps) do
		if J.IsValid(creep)
			and J.GetHP(creep) < Const.Creeps.defaultDenyHp
			and J.CanBeAttacked(creep)
			and creep:GetHealth() <= attackDamage then
			return creep
		end
	end
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
		if denyPol == "always" then
			for _, c in pairs(ctx.allyCreeps or {}) do
				if J.IsValid(c) and J.GetHP(c) < Const.Creeps.alwaysDenyHp and J.CanBeAttacked(c) then
					denyCreep = c; break
				end
			end
		elseif ctx.bestDeny ~= nil then
			denyCreep = ctx.bestDeny(ctx.allyCreeps)
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
				if GetUnitToUnitDistance(bot, denyCreep) <= attackRange + 40 then
					bot:Action_AttackUnit(denyCreep, true)
				else
					moveToAttackEdge(ctx, denyCreep, 20)
				end
				ctx.diag("deny-act")
				return true
			end
		end
	end

	return false
end

return M
