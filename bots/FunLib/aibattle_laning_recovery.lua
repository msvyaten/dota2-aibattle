-- AIBattle laning recovery layer: low HP gates, critical lock, recovery/kill yield.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBEngine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Motor = require(GetScriptDirectory()..'/FunLib/aibattle_motor')
local AIBConst = require(GetScriptDirectory()..'/FunLib/aibattle_constants')

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
	-- 3b (23.07): this band IS what rules.low_hp_hold declares -- "the HP at which recovery
	-- holds position instead of stepping" -- so it reads the threshold rather than a literal
	-- that only matched it at the neutral retreat_caution of 0.5. Grok and DeepSeek ask for
	-- 0.44, Gemini for 0.46, and every one of them was silently given 0.45.
	if diagKey == "lane-low" and hp >= Style.LowHpHoldThreshold()
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
	-- Passing 0.45 explicitly OVERRODE the config: ActiveLowHp already falls back to
	-- Style.LowHpHoldThreshold() when given no override, and handing it a literal was the one
	-- thing that guaranteed the dial could not be heard here. Pass nothing.
	if hp < Style.LowHpHoldThreshold() then return M.ActiveLowHp(ctx, nil, true) end
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

	-- Reached the safe anchor but STILL being dived here? The anchor is not safe and
	-- holding = death (8885365845 t=291-342: Dire froze at its T1 anchor while dived,
	-- broke + bottle-empty, and died standing). Being out of gold/bottle is no reason
	-- to stand: push the destination deeper toward the fountain so the "hold" becomes a
	-- committed retreat to real safety. The 2s dest window keeps it twitch-free; when the
	-- flee point is reached and still threatened, it re-flees another step (progressive).
	local fleeing = false
	if GetUnitToLocationDistance(bot, dest) < 220 then
		local threatened = bot:WasRecentlyDamagedByAnyHero(2.5)
		if not threatened then
			local foes = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
			threatened = foes ~= nil and #foes > 0 and foes[1]:IsAlive()
		end
		if threatened then
			local flee = ctx.towardFountain(bot:GetLocation(), 700)
			if flee ~= nil then
				dest = flee
				bot.aib_criticalRecoverDest = flee
				bot.aib_criticalRecoverUntil = now + 2.0
				fleeing = true
			end
		end
	end

	if not fleeing and GetUnitToLocationDistance(bot, dest) < 220 then
		if bot.aib_criticalRecoverLast == nil or now - bot.aib_criticalRecoverLast >= 1.0 then
			bot.aib_criticalRecoverLast = now
			Style.Intent(bot, "critical-recovery", string.format("hp=%.0f dist=%.0f ttl=%.0f reason=hold", hp * 100, GetUnitToLocationDistance(bot, dest), bot.aib_criticalRecoverUntil - now), 2.0)
			ctx.diag("critical-recover-hold")
		end
		return true
	end
	if bot.aib_criticalRecoverLast == nil or now - bot.aib_criticalRecoverLast >= 0.8 then
		bot.aib_criticalRecoverLast = now
		Motor.Claim(bot, "critical-recover", 110, 1.2)
		Style.Intent(bot, "critical-recovery", string.format("hp=%.0f dist=%.0f reason=%s", hp * 100, GetUnitToLocationDistance(bot, dest), fleeing and "flee_dived" or "lock"), 2.0)
		bot:Action_MoveToLocation(dest)
		ctx.diag(fleeing and "critical-recover-flee" or "critical-recover-lock")
	end
	return true
end

-- P3-A skeleton (single low-HP owner), slice 1 -- BEHAVIOR-PRESERVING.
-- Establishes the Recovery.Owner entry point + episode telemetry that later P3 slices
-- grow into. This slice ONLY classifies band/threat, records an episode, and delegates
-- to the existing CriticalLock logic unchanged -- no thresholds gate behavior yet, so
-- nothing changes on the field. Later slices migrate EmergencyRetreat / ForwardLowHpPullback
-- / ActiveLowHp / regenLane into the band actions here (SPECS section 2).
-- Bands are TELEMETRY-ONLY for now (delegation keeps CriticalLock's own hp<0.34 gate);
-- do NOT read them as behavior thresholds until the migration slice that reconciles them.
local RecoveryBands = { critical = 0.25, soft = 0.45, caution = 0.55 }

local function classifyBand(hp)
	if hp < RecoveryBands.critical then return "critical" end
	if hp < RecoveryBands.soft then return "soft" end
	if hp < RecoveryBands.caution then return "caution" end
	return "healthy"
end

local function recoveryThreatened(bot)
	if bot:WasRecentlyDamagedByAnyHero(2.5) then return true end
	local foes = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	return foes ~= nil and #foes > 0 and foes[1]:IsAlive()
end

-- One episode record per coherent recovery stretch; emit a diag only on TRANSITION
-- (band / threat / mode change), never per tick, so the counter measures decisions not
-- move re-issues. This is the honest jitter proxy P3 replaces low-hp-back etc. with.
local function noteRecoveryEpisode(bot, band, threat, mode)
	local ep = bot.aib_recoveryEpisode
	if ep == nil or ep.band ~= band or ep.threat ~= threat or ep.mode ~= mode then
		bot.aib_recoveryEpisode = { band = band, threat = threat, mode = mode, at = DotaTime() }
		Style.Intent(bot, "recovery-owner",
			string.format("band=%s threat=%s mode=%s hp=%.0f", band, tostring(threat), mode, J.GetHP(bot) * 100), 2.0)
	end
end

function M.Owner(ctx)
	local bot = ctx.bot
	local band = classifyBand(J.GetHP(bot))
	if band == "healthy" then
		bot.aib_recoveryEpisode = nil
		return false
	end
	-- Slice 1: the CRITICAL committed-retreat/flee logic is the only migrated owner.
	-- CriticalLock self-gates (hp<0.34) so calling it across critical/soft/caution is
	-- identical to the pre-refactor direct call at mode_laning:972.
	local handled = M.CriticalLock(ctx)
	if handled then
		noteRecoveryEpisode(bot, band, recoveryThreatened(bot), "critical-lock")
	end
	return handled
end

-- retreatOnly=true skips the fight/CS branches and goes straight to positional retreat.
-- Used by ThinkIfAllowed's no-items fallback so the recover desire produces movement, not combat.
function M.ActiveLowHp(ctx, hpThreshOverride, retreatOnly)
	local bot = ctx.bot
	local hp = J.GetHP(bot)
	if hp >= (hpThreshOverride or Style.LowHpHoldThreshold()) then return false end
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
	-- P3-C down-payment (SPECS 2.2 rune-seek in SOFT x safe): while a bottle-rune pickup is
	-- committed (same 30s window as the forwardness-suppress, mode_laning:1135) and we're not
	-- critical and not threatened, yield the positional retreat so the persisting pickup move
	-- completes. Without this, mode=back overrode the pickup on interleaved ticks (8888664145
	-- D: dist stuck at 91, rune aged 8->12 -> gone -> bottle stayed empty). CRITICAL and
	-- threatened never yield -- survival always wins over a rune.
	if hp >= RecoveryBands.critical and not recoveryThreatened(bot)
		and bot.aib_bottleRuneStarted ~= nil
		and DotaTime() - bot.aib_bottleRuneStarted < AIBConst.Rune.commitSeconds then
		if bot.aib_recRuneYieldLast == nil or DotaTime() - bot.aib_recRuneYieldLast >= 1.0 then
			bot.aib_recRuneYieldLast = DotaTime()
			Style.Blocked(bot, "recovery-owner", "rune_commit", string.format("hp=%.0f", hp * 100), 2.0)
		end
		return false
	end
	local back = AIBUtils.SafeRetreatTowerLoc(bot)
	local alreadyBehindBack = back ~= nil and AIBUtils.IsCloserToFountain(bot, back)
	if back ~= nil and (bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0))
		and (bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 3.0) then
		local farBack = alreadyBehindBack and ctx.towardFountain(bot:GetLocation(), 260)
			or ctx.towardFountain(bot:GetLocation(), 430)
			or (back + RandomVector(260))
		bot.aib_lowHpActiveLast = DotaTime()
		Motor.Claim(bot, "low-hp", 90, 1.2)
		bot:Action_MoveToLocation(farBack)
		-- P3-B.1: per-move diag replaced by episode transition (honest jitter proxy). The
		-- move throttle above still rate-limits the ACTION; noteRecoveryEpisode emits a diag
		-- only when band/threat/mode changes, so the counter measures decisions not re-issues.
		noteRecoveryEpisode(bot, classifyBand(hp), recoveryThreatened(bot), "safe-step")
		return true
	end
	if back ~= nil and alreadyBehindBack then
		-- Already behind the safe anchor. Under danger, COMMIT to a hold instead of
		-- returning empty_action: recover keeps acting -> arbiter hysteresis holds ->
		-- the fight<->recover half-turn twitch under the tower stops, and the bot reads
		-- as an intentional regen hold. Claim the motor so positioners yield too.
		-- When safe, still yield (return false) so the free window goes to lane work/farm.
		local holdDanger = bot:WasRecentlyDamagedByCreep(2.0) or bot:WasRecentlyDamagedByAnyHero(2.0)
		if not holdDanger then
			local holdHeroes = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
			holdDanger = holdHeroes and #holdHeroes > 0 and holdHeroes[1]:IsAlive()
		end
		if holdDanger then
			Motor.Claim(bot, "low-hp-hold", 90, 1.2)
			if bot.aib_lowHpHoldLast == nil or DotaTime() - bot.aib_lowHpHoldLast >= 1.0 then
				bot.aib_lowHpHoldLast = DotaTime()
				-- P3-B.1: committed-hold diag -> episode (mode=hold). See safe-step note.
				noteRecoveryEpisode(bot, classifyBand(hp), recoveryThreatened(bot), "hold")
			end
			return true
		end
		Style.DiagRL(bot, "low-hp-behind-safe", 3.0)
		return false
	end
	if back ~= nil and GetUnitToLocationDistance(bot, back) > 140 then
		Motor.Claim(bot, "low-hp", 90, 1.2)
		-- Committed retreat to the single anchor. The old else-branch re-issued a
		-- divergent fountain-ward "nudge" between the rate-limited back-steps, so the
		-- bot re-pathed anchor<->fountain every tick = the twitch under the tower. The
		-- move to `back` persists between ticks; no divergent nudge needed.
		if bot.aib_lowHpActiveLast == nil or DotaTime() - bot.aib_lowHpActiveLast >= 0.8 then
			bot.aib_lowHpActiveLast = DotaTime()
			bot:Action_MoveToLocation(back)
			-- P3-B.1: low-hp-back diag -> episode (mode=back). Dominant baseline jitter key
			-- (123/69 in 8886970304); now counts episodes, not per-tick re-issues.
			noteRecoveryEpisode(bot, classifyBand(hp), recoveryThreatened(bot), "back")
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
			-- Head to the SAME committed anchor, not a divergent fountain point. Pushing
			-- toward fountain+random when already near the anchor shoved the bot off the
			-- spot it just reached, restarting the anchor<->fountain zigzag every tick.
			bot:Action_MoveToLocation(back)
			-- P3-B.1: watch-step diag -> episode (mode=watch-step). See back note.
			noteRecoveryEpisode(bot, classifyBand(hp), recoveryThreatened(bot), "watch-step")
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
	Motor.Claim(bot, "emerg-retreat", 110, 1.6)
	-- P3-A slice 2: register this recovery mover on the Owner episode model (dual-emit,
	-- behavior unchanged). Later P3-B moves the decision itself into the band owner.
	noteRecoveryEpisode(bot, "critical", recoveryThreatened(bot), "emerg-retreat")
	bot:Action_MoveToLocation(back)
	return true
end

function M.ForwardLowHpPullback(ctx)
	if ctx.debugSkeleton then return false end
	local bot = ctx.bot
	local holdThresh = Style.LowHpHoldThreshold()
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
		Motor.Claim(bot, "fwd-lowhp-pull", 90, 1.3)
		ctx.diag("fwd-lowhp-pull")
		-- P3-A slice 2: register on the Owner episode model (dual-emit, behavior unchanged).
		noteRecoveryEpisode(bot, classifyBand(hpNow), recoveryThreatened(bot), "fwd-pullback")
		bot:Action_MoveToLocation(back)
	end
	return true
end

-- Pure classifier: (hold, danger). Emits NO diag -- the low-hp-limit signature is emitted
-- only by M.LowHpHoldState below, kept lazy in the tail arbiter so its per-match count
-- matches baseline (SPECS 3.6.1 telemetry-equivalence trap). The election facts-builder
-- calls this probe to decide the ActiveLowHp candidate without inflating low-hp-limit.
function M.LowHpHoldProbe(ctx)
	if ctx.debugSkeleton then return false, false end
	local bot = ctx.bot
	local holdThresh = Style.LowHpHoldThreshold()
	if holdThresh <= 0 or J.GetHP(bot) >= holdThresh then return false, false end
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	if ownT1 == nil or GetUnitToUnitDistance(bot, ownT1) >= 900 then return false, false end
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

function M.LowHpHoldState(ctx)
	local hold, danger = M.LowHpHoldProbe(ctx)
	if hold then Style.DiagRL(ctx.bot, "low-hp-limit", 3) end
	return hold, danger
end

return M
