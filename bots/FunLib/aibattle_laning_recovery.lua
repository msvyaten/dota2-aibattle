-- AIBattle laning recovery layer: low HP gates, critical lock, recovery/kill yield.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Motor = require(GetScriptDirectory()..'/FunLib/aibattle_motor')

local function attackRange(ctx)
	return ctx.attackRange or ctx.bot:GetAttackRange()
end

function M.ShouldYieldRecoveryToKill(ctx)
	local policy = AIBEngine.RecoveryPolicy({
		bot = ctx.bot,
		dials = ctx.dials,
		rules = ctx.rules,
		attackRange = attackRange(ctx),
	})
	local win = policy.killWindow
	if policy.action == "yield_kill" and win ~= nil
		and not ctx.towerThreatening(ctx.enemyTowerDanger())
		and not ctx.uphillMiss(win.enemy) then
		Style.Intent(ctx.bot, "recovery-yield-kill", policy.detail, 1.5)
		return true
	end
	return false
end

function M.ThinkIfAllowed(ctx, hpThreshold, diagKey)
	local bot = ctx.bot
	local hp = J.GetHP(bot)
	if hp >= hpThreshold then return false end
	if diagKey == "lane-low" and hp >= 0.45
		and not bot:WasRecentlyDamagedByAnyHero(2.0)
		and not bot:WasRecentlyDamagedByCreep(1.2) then
		local range = attackRange(ctx)
		local creep = ctx.nearestAttackableEnemyCreep ~= nil and ctx.nearestAttackableEnemyCreep(range + 140) or nil
		local enemy = ctx.nearestEnemyHero ~= nil and ctx.nearestEnemyHero(range + 180) or nil
		if creep ~= nil or enemy ~= nil then
			Style.Blocked(bot, "recovery-policy", "yield_lane_work",
				string.format("hp=%.0f source=%s creep=%s hero=%s", hp * 100, diagKey, tostring(creep ~= nil), tostring(enemy ~= nil)), 2.0)
			return false
		end
	end
	if M.ShouldYieldRecoveryToKill(ctx) then
		Style.Blocked(bot, "recovery-policy", "yield_kill", string.format("hp=%.0f gate=%.0f source=%s", hp * 100, hpThreshold * 100, diagKey or "unknown"), 1.5)
		return false
	end
	Style.Intent(bot, "recovery-policy", string.format("action=recover hp=%.0f gate=%.0f source=%s", hp * 100, hpThreshold * 100, diagKey or "unknown"), 2.0)
	if ctx.surviveThink(bot, ctx.dials, ctx.enemyCreeps) then return true end
	-- No items/TP: if taking recent hero damage in the 45-55% HP gap, step back toward safety
	-- rather than stalling with empty_action and letting visual-hold suppress all movement.
	if diagKey == "lane-low" then
		return M.ActiveLowHp(ctx, hpThreshold, true)
	end
	if hp < 0.45 then return M.ActiveLowHp(ctx, 0.45, true) end
	return false
end

function M.CriticalLock(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	local hp = J.GetHP(bot)
	local powerRune = AIBEngine.PowerRuneState(bot)
	if AIBEngine.IsActionPowerRune(powerRune) and hp >= 0.30 then
		bot.aib_criticalRecoverUntil = nil
		bot.aib_criticalRecoverDest = nil
		Style.Intent(bot, "power-rune-yield", string.format("rune=%s hp=%.0f", powerRune, hp * 100), 2.0)
		return false
	end
	if M.ShouldYieldRecoveryToKill(ctx) then
		bot.aib_criticalRecoverUntil = nil
		bot.aib_criticalRecoverDest = nil
		return false
	end
	if hp >= 0.34 then
		bot.aib_criticalRecoverUntil = nil
		bot.aib_criticalRecoverDest = nil
		return false
	end
	if hp >= 0.30 and bot.aib_criticalRecoverUntil == nil then return false end
	if ctx.bottleIfUseful(0.70, 0.35, "critical-recover-bottle") then
		bot.aib_criticalRecoverUntil = now + 3.0
		return true
	end

	local dest = bot.aib_criticalRecoverDest
	if bot.aib_criticalRecoverUntil == nil or now > bot.aib_criticalRecoverUntil or dest == nil then
		dest = AIBUtils.SafeRetreatTowerLoc(bot)
			or ctx.towardFountain(bot:GetLocation(), 520)
			or GetLaneFrontLocation(GetTeam(), LANE_MID, -900)
		bot.aib_criticalRecoverDest = dest
		bot.aib_criticalRecoverUntil = now + 4.0
	end
	if dest == nil then return false end
	if GetUnitToLocationDistance(bot, dest) < 220 then
		if bot.aib_criticalRecoverLast == nil or now - bot.aib_criticalRecoverLast >= 1.0 then
			bot.aib_criticalRecoverLast = now
			Style.Intent(bot, "critical-recovery", string.format("hp=%.0f dist=%.0f ttl=%.0f reason=hold", hp * 100, GetUnitToLocationDistance(bot, dest), bot.aib_criticalRecoverUntil - now), 2.0)
			ctx.diag("critical-recover-hold")
		end
		return true
	end
	if bot.aib_criticalRecoverLast == nil or now - bot.aib_criticalRecoverLast >= 0.8 then
		bot.aib_criticalRecoverLast = now
		Motor.Claim(bot, "critical-recover", 100, 1.2)
		Style.Intent(bot, "critical-recovery", string.format("hp=%.0f dist=%.0f ttl=%.0f", hp * 100, GetUnitToLocationDistance(bot, dest), bot.aib_criticalRecoverUntil - now), 2.0)
		bot:Action_MoveToLocation(dest)
		ctx.diag("critical-recover-lock")
	end
	return true
end

-- retreatOnly=true skips the fight/CS branches and goes straight to positional retreat.
-- Used by ThinkIfAllowed's no-items fallback so the recover desire produces movement, not combat.
function M.ActiveLowHp(ctx, hpThreshOverride, retreatOnly)
	local bot = ctx.bot
	local hp = J.GetHP(bot)
	if hp >= (hpThreshOverride or ctx.rules.low_hp_hold or 0.45) then return false end
	if ctx.bottleIfUseful(0.62, 0.30, "low-hp-bottle") then return true end
	local range = attackRange(ctx)
	if not retreatOnly then
		local enemies = bot:GetNearbyHeroes(range + 60, true, BOT_MODE_NONE)
		if hp >= 0.32 and enemies and #enemies > 0 and enemies[1]:IsAlive()
			and not ctx.towerThreatening(ctx.enemyTowerDanger()) then
			bot:Action_AttackUnit(enemies[1], false)
			ctx.diag("low-hp-fight")
			return true
		end
		for _, creep in pairs(ctx.enemyCreeps or {}) do
			if J.IsValid(creep) and J.CanBeAttacked(creep)
				and GetUnitToUnitDistance(bot, creep) <= range + 40 then
				if hp >= 0.35 or (hp >= 0.28 and bot:WasRecentlyDamagedByCreep(1.5)) then
					bot:Action_AttackUnit(creep, true)
					ctx.diag("low-hp-creep")
					return true
				end
				break
			end
		end
	end
	local back = AIBUtils.SafeRetreatTowerLoc(bot)
	local alreadyBehindBack = back ~= nil and AIBUtils.IsCloserToFountain(bot, back)
	if back ~= nil and (bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0))
		and (bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 3.0) then
		local farBack = alreadyBehindBack and ctx.towardFountain(bot:GetLocation(), 260)
			or ctx.towardFountain(bot:GetLocation(), 430)
			or (back + RandomVector(260))
		bot.aib_lowHpActiveLast = DotaTime()
		Motor.Claim(bot, "low-hp", 80, 1.2)
		bot:Action_MoveToLocation(farBack)
		ctx.diag("low-hp-safe-step")
		return true
	end
	if back ~= nil and alreadyBehindBack then
		Style.DiagRL(bot, "low-hp-behind-safe", 3.0)
		return false
	end
	if back ~= nil and GetUnitToLocationDistance(bot, back) > 140 then
		Motor.Claim(bot, "low-hp", 80, 1.2)
		if bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 0.8 then
			bot.aib_lowHpActiveLast = DotaTime()
			bot:Action_MoveToLocation(back)
			ctx.diag("low-hp-back")
		else
			local nudge = ctx.towardFountain(bot:GetLocation(), 220)
			if nudge ~= nil then
				bot:Action_MoveToLocation(nudge)
				ctx.diag("low-hp-nudge")
			end
		end
		return true
	end
	if back ~= nil then
		local dangerNear = false
		local nearHeroes = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
		if nearHeroes and #nearHeroes > 0 and nearHeroes[1]:IsAlive() then dangerNear = true end
		if not dangerNear then
			for _, creep in pairs(ctx.enemyCreeps or {}) do
				if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= range + 180 then
					dangerNear = true; break
				end
			end
		end
		if dangerNear
			and (bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 1.2) then
			bot.aib_lowHpActiveLast = DotaTime()
			bot:Action_MoveToLocation((ctx.towardFountain(bot:GetLocation(), 300) or back) + RandomVector(35))
			ctx.diag("low-hp-watch-step")
			return true
		end
	end
	return false
end

function M.EmergencyRetreat(ctx)
	local bot = ctx.bot
	if J.GetHP(bot) >= 0.25 then return false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	if ownT1 == nil or GetUnitToUnitDistance(bot, ownT1) <= 900 then return false end
	local back = ctx.forwardSurvivingTowerLoc()
	if back == nil then return false end
	if bot.aib_emergLast ~= nil and DotaTime() - bot.aib_emergLast < 1.5 then return false end
	bot.aib_emergLast = DotaTime()
	ctx.diag("emerg-retreat")
	if J.GetHP(bot) > 0.15 then
		local emergEnemies = bot:GetNearbyHeroes(800, true, BOT_MODE_NONE)
		if emergEnemies and #emergEnemies > 0 and emergEnemies[1]:IsAlive() then
			if Style.AbilityHarass(bot, emergEnemies[1]) then return true end
		end
	end
	bot:Action_MoveToLocation(back)
	return true
end

function M.ForwardLowHpPullback(ctx)
	if ctx.debugSkeleton then return false end
	local bot = ctx.bot
	local holdThresh = ctx.rules.low_hp_hold or 0.45
	local hpNow = J.GetHP(bot)
	local enemyDeadSafeSiege = ctx.enemyDeadRecently() and hpNow >= 0.35 and not ctx.healingChannelActive()
	if hpNow >= holdThresh or enemyDeadSafeSiege then return false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
	if ownT1 == nil or enmT1 == nil then return false end
	if GetUnitToUnitDistance(bot, enmT1) >= GetUnitToUnitDistance(bot, ownT1) then return false end
	local back = ctx.forwardSurvivingTowerLoc()
	if back == nil or GetUnitToLocationDistance(bot, back) <= 200 then return false end
	if bot.aib_fwdPullLast == nil or DotaTime() - bot.aib_fwdPullLast >= 1.2 then
		bot.aib_fwdPullLast = DotaTime()
		ctx.diag("fwd-lowhp-pull")
		bot:Action_MoveToLocation(back)
	end
	return true
end

function M.LowHpHoldState(ctx)
	if ctx.debugSkeleton then return false, false end
	local bot = ctx.bot
	local holdThresh = ctx.rules.low_hp_hold or 0.45
	if holdThresh <= 0 or J.GetHP(bot) >= holdThresh then return false, false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	if ownT1 == nil or GetUnitToUnitDistance(bot, ownT1) >= 900 then return false, false end
	Style.DiagRL(bot, "low-hp-limit", 3)
	local danger = bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0)
	if not danger then
		local nearHeroes = bot:GetNearbyHeroes(math.max(attackRange(ctx) + 180, 850), true, BOT_MODE_NONE)
		danger = nearHeroes and #nearHeroes > 0 and nearHeroes[1]:IsAlive()
		if not danger then
			for _, creep in pairs(ctx.enemyCreeps or {}) do
				if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= attackRange(ctx) + 180 then
					danger = true; break
				end
			end
		end
	end
	return true, danger
end

return M
