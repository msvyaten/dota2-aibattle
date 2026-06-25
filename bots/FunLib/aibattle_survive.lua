-- AIBattle survive system: defensive_heal / regen_lane / recovery.
-- Entry: AIBSurvive.Think(bot, dials, nEnemyCreeps) returns true if action was issued.
-- Extracted from mode_laning_generic.lua to keep that file manageable.

local M = {}

local J     = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local TANGO_CD = 10.0  -- shared across all tango calls; guards re-issue while CD / modifier active
local FLASK_CD = 3.0   -- laning flask (defensiveHeal); recovery uses aib_recFlaskLast at 8s (separate context)
local BOTTLE_RUNE_MAX_DIST = 1900.0
local BOTTLE_RUNE_STAGE_MAX_DIST = 3600.0
local BOTTLE_RUNE_LANE_BUDGET = 1500.0
local WATER_RECOVERY_RUNE_MAX_DIST = 4300.0
local RECOVERY_RUNE_MAX_DIST = 3600.0
local RECOVERY_RUNE_STAGE_MAX_DIST = 4200.0
local WATER_RUNE_MID_CONTEXT_MAX = 3200.0

local function getItem(bot, name)
	local slot = bot:FindItemSlot(name)
	if slot < 0 then return nil end
	local it = bot:GetItemInSlot(slot)
	return (it ~= nil and it:IsFullyCastable()) and it or nil
end

local function hasItem(bot, name)
	local slot = bot:FindItemSlot(name)
	return slot >= 0 and bot:GetItemInSlot(slot) ~= nil
end

local function forwardTowerLoc(bot) return AIBUtils.SafeRetreatTowerLoc(bot) end

local function dist2D(a, b)
	if a == nil or b == nil then return math.huge end
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx*dx + dy*dy)
end

local function enemyTowerNearLoc(loc, extra)
	if loc == nil then return false end
	local opp = GetOpposingTeam()
	for _, id in ipairs({ TOWER_MID_1, TOWER_MID_2, TOWER_TOP_1, TOWER_BOT_1, TOWER_MID_3 }) do
		local twr = GetTower(opp, id)
		if twr ~= nil and twr:IsAlive() and dist2D(loc, twr:GetLocation()) <= twr:GetAttackRange() + (extra or 180) then
			return true
		end
	end
	return false
end

local function xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if hp < 0.28 then return AIBUtils.SafeRetreatTowerLoc(bot), "safe" end
	local fountain = J.GetTeamFountain()
	local cen = AIBUtils.EnemyCreepCentroid(nEnemyCreeps)
	if cen ~= nil and fountain ~= nil then
		local dx, dy = fountain.x - cen.x, fountain.y - cen.y
		local d = math.sqrt(dx*dx + dy*dy)
		if d > 1 then
			local back = hp < 0.42 and 1050 or 850
			local loc = Vector(cen.x + (dx/d)*back, cen.y + (dy/d)*back, cen.z)
			if not enemyTowerNearLoc(loc, 260) then return loc, "xp" end
		end
	end
	local front = GetLaneFrontLocation(bot:GetTeam(), LANE_MID, hp < 0.42 and -900 or -650)
	if front ~= nil and not enemyTowerNearLoc(front, 260) then return front, "xp" end
	return AIBUtils.SafeRetreatTowerLoc(bot), "safe"
end

local function hasFountainAura(bot)
	return bot:HasModifier("modifier_fountain_aura")
		or bot:HasModifier("modifier_fountain_aura_buff")
end

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil then return nil end
	return bottle:GetCurrentCharges()
end

local function recoveryPlan(bot, action, reason, detail, sec)
	local text = "action=" .. tostring(action) .. " reason=" .. tostring(reason)
	if detail ~= nil and detail ~= "" then text = text .. " " .. detail end
	Style.Intent(bot, "recovery-plan", text, sec or 2.0)
end

local function stateIntent(bot, name, detail, sec)
	Style.Intent(bot, "state-" .. tostring(name), detail or "", sec or 2.0)
end

local function itemCost(name)
	local ok, cost = pcall(function() return GetItemCost(name) end)
	if ok and type(cost) == "number" and cost > 0 then return cost end
	local fallback = {
		item_bottle = 675,
		item_magic_wand = 450,
		item_boots = 500,
		item_power_treads = 1400,
		item_lifesteal = 900,
		item_flask = 100,
		item_clarity = 50,
	}
	return fallback[name] or 0
end

local function missingCheckpointItem(bot)
	local checkpoints = {
		"item_bottle",
		"item_magic_wand",
		"item_power_treads",
		"item_lifesteal",
	}
	for _, name in ipairs(checkpoints) do
		if not hasItem(bot, name) then return name, itemCost(name) end
	end
	return nil, 0
end

local function consumableSpendBlocked(bot, hp, gold, itemName)
	local spend = itemCost(itemName)
	local checkpoint, cost = missingCheckpointItem(bot)
	if checkpoint == nil or cost <= 0 then return false end
	if hp >= 0.16 and spend > 0 and gold - spend < cost and gold >= cost - 160 then
		Style.Blocked(bot, "recovery-buy", "item_checkpoint", string.format("item=%s hp=%.0f gold=%d cost=%d spend=%d", checkpoint, hp*100, gold, cost, spend), 8.0)
		recoveryPlan(bot, "buy_" .. tostring(itemName), "checkpoint_block", string.format("item=%s hp=%.0f gold=%d", checkpoint, hp*100, gold), 3.0)
		return true
	end
	if hp >= 0.18 and checkpoint ~= nil and (bot.aib_recBuySpent or 0) >= 220 then
		Style.Blocked(bot, "recovery-buy", "consumable_budget", string.format("item=%s hp=%.0f spent=%d", checkpoint, hp*100, bot.aib_recBuySpent or 0), 8.0)
		recoveryPlan(bot, "buy_" .. tostring(itemName), "budget_block", string.format("item=%s hp=%.0f spent=%d", checkpoint, hp*100, bot.aib_recBuySpent or 0), 3.0)
		return true
	end
	return false
end

function M.Reset(bot)
	if bot == nil then return end
	bot.aib_fountainTrip = false
	bot.aib_fountainTping = false
	bot.aib_fountainTpCast = nil
	bot.aib_fountainWaitLast = nil
	bot.aib_fountainFullSince = nil
	bot.aib_fountainBottleLast = nil
	bot.aib_recWaitStart = nil
	bot.aib_recMoveLast = nil
	bot.aib_recBottleLast = nil
	bot.aib_recFlaskLast = nil
	bot.aib_bottleRuneLast = nil
	bot.aib_bottleRuneStarted = nil
	bot.aib_bottleRuneTarget = nil
	bot.aib_bottleRuneId = nil
	bot.aib_bottleRunePickupUntil = nil
	bot.aib_bottleRuneCooldownUntil = nil
	bot.aib_bottleRuneStageWindow = nil
	bot.aib_bottleRuneStageUntil = nil
	bot.aib_bottleRuneStageTarget = nil
	bot.aib_bottleRuneStageFollowLast = nil
	bot.aib_bottleRuneStageBlockedWindow = nil
	bot.aib_bottleRuneStageBlockedUntil = nil
	-- Flask budget is per-life, not per-game: a bot that's behind and respawning still needs
	-- sustain (match 8862516153: stomped Dire hit the 2-flask cap and couldn't buy at 10% HP).
	bot.aib_recBuyCount = nil
	bot.aib_recBuySpent = nil
end

local function wantsBottleFromStyle(bot)
	if GetGameMode() ~= GAMEMODE_1V1MID then return false end
	if bottleCharges(bot) ~= nil then return false end
	local build = Style.GetItemBuild and Style.GetItemBuild() or nil
	if type(build) ~= "table" then return false end
	for _, name in ipairs(build) do
		if name == "item_bottle" then return true end
	end
	return false
end

local function fountainRecovery(bot)
	if DotaTime() <= 0 then return false end
	if bot.aib_fountainTping then
		if bot:HasModifier("modifier_teleporting") then return true end
		if DotaTime() - (bot.aib_fountainTpCast or 0) < 1.0 then return true end
		bot.aib_fountainTping = false
	end
	local hp = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local charges = bottleCharges(bot)
	local bottleNotFull = charges ~= nil and charges < 3
	local nearBase = bot:DistanceFromFountain() < 2600
	local inFountain = hasFountainAura(bot)
	if not inFountain and not nearBase and not bot.aib_fountainTrip then return false end
	if inFountain and charges ~= nil and charges > 0 and (hp < 0.98 or mana < 0.90)
		and (bot.aib_fountainBottleLast == nil or DotaTime() - bot.aib_fountainBottleLast >= 1.0) then
		local bottle = getItem(bot, "item_bottle")
		if bottle ~= nil then
			bot.aib_fountainBottleLast = DotaTime()
			Style.Diag(bot, "fountain-bottle")
			bot:Action_UseAbility(bottle)
			return true
		end
	end
	if hp < 0.98 or mana < 0.90 or bottleNotFull then
		bot.aib_fountainFullSince = nil
		if bot.aib_fountainWaitLast == nil or DotaTime() - bot.aib_fountainWaitLast >= 1.0 then
			bot.aib_fountainWaitLast = DotaTime()
			bot.aib_fountainTrip = true
			Style.DiagRL(bot, "fountain-wait", 3)
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end
	if bot.aib_fountainTrip and inFountain then
		if bot.aib_fountainFullSince == nil then bot.aib_fountainFullSince = DotaTime() end
		if DotaTime() - bot.aib_fountainFullSince < 2.0 then
			Style.DiagRL(bot, "fountain-stabilize", 3)
			return true
		end
	end
	bot.aib_fountainTrip = false
	bot.aib_fountainFullSince = nil

	local tp = getItem(bot, "item_tpscroll")
	local t1 = GetTower(bot:GetTeam(), TOWER_MID_1)
	if tp ~= nil and t1 ~= nil and t1:IsAlive() and nearBase then
		Style.Diag(bot, "fountain-tp-lane")
		bot:Action_UseAbilityOnLocation(tp, t1:GetLocation())
		bot.aib_fountainTping = true
		bot.aib_fountainTpCast = DotaTime()
		return true
	end
	return false
end

local function hasLastHitWindow(bot)
	local creeps = bot:GetNearbyLaneCreeps(bot:GetAttackRange() + 180, true)
	if not creeps or #creeps == 0 then return false end
	local damage = bot:GetAttackDamage()
	for _, creep in ipairs(creeps) do
		if J.IsValid(creep) and creep:IsAlive() and J.CanBeAttacked(creep)
			and creep:GetHealth() <= damage * 1.25 then
			return true
		end
	end
	return false
end

local function laneFrontDistance(bot)
	local lane = LANE_MID
	if bot.GetAssignedLane ~= nil then lane = bot:GetAssignedLane() end
	if GetGameMode() == GAMEMODE_1V1MID then lane = LANE_MID end
	local front = GetLaneFrontLocation(bot:GetTeam(), lane, 0)
	if front == nil then return 0 end
	return GetUnitToLocationDistance(bot, front)
end

local function midContextDistance(bot)
	local front = GetLaneFrontLocation(bot:GetTeam(), LANE_MID, 0)
	local t1 = GetTower(bot:GetTeam(), TOWER_MID_1)
	local best = math.huge
	if front ~= nil then best = math.min(best, GetUnitToLocationDistance(bot, front)) end
	if t1 ~= nil and t1:IsAlive() then best = math.min(best, GetUnitToUnitDistance(bot, t1)) end
	return best
end

local function waterRecoveryAllowed(bot, hp, mana, dist, forceEmptyBottle)
	if dist == nil or dist > WATER_RECOVERY_RUNE_MAX_DIST then return false end
	if not forceEmptyBottle and hp >= 0.65 and mana >= 0.35 then return false end
	return midContextDistance(bot) <= WATER_RUNE_MID_CONTEXT_MAX
end

local nextBottleRuneSpawn

local function runeMemoryUntil(now)
	local nextSpawnAt = nextBottleRuneSpawn(now)
	if nextSpawnAt == nil then return nil end
	return nextSpawnAt + 0.5
end

local function isRuneKnownEmpty(bot, runeId, now)
	if runeId == nil or bot.aib_knownEmptyRunes == nil then return false end
	local untilTime = bot.aib_knownEmptyRunes[runeId]
	return untilTime ~= nil and now ~= nil and now < untilTime
end

local function markRuneKnownEmpty(bot, runeId, now)
	if runeId == nil then return end
	local untilTime = runeMemoryUntil(now)
	if untilTime == nil then return end
	bot.aib_knownEmptyRunes = bot.aib_knownEmptyRunes or {}
	bot.aib_knownEmptyRunes[runeId] = untilTime
end

local function nearestRuneSpot(bot, now)
	local bestRune, bestLoc, bestDist = nil, nil, math.huge
	for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		local loc = GetRuneSpawnLocation(runeId)
		if loc ~= nil and not isRuneKnownEmpty(bot, runeId, now) then
			local dist = GetUnitToLocationDistance(bot, loc)
			if dist < bestDist then
				bestRune, bestLoc, bestDist = runeId, loc, dist
			end
		end
	end
	return bestRune, bestLoc, bestDist
end

function nextBottleRuneSpawn(now)
	if now == nil or now < 0 then return nil end
	if now < 120 then return 120, "water" end
	if now < 240 then return 240, "water" end
	if now < 360 then return 360, "power" end
	return (math.floor(now / 120) + 1) * 120, "power"
end

local function clearRuneAttempt(bot)
	bot.aib_bottleRuneTarget = nil
	bot.aib_bottleRuneStarted = nil
	bot.aib_bottleRuneId = nil
	bot.aib_bottleRunePickupUntil = nil
end

local function runeResult(bot, diagKey, result, detail, cooldown)
	local now = DotaTime()
	local text = "source=" .. tostring(diagKey) .. " result=" .. tostring(result)
	if detail ~= nil and detail ~= "" then text = text .. " " .. detail end
	Style.Intent(bot, "rune-result", text, 1.0)
	if cooldown ~= nil and cooldown > 0 then
		bot.aib_bottleRuneCooldownUntil = now + cooldown
	end
end

local function seekBottleRune(bot, hp, mana, diagKey, maxDist, opts)
	opts = opts or {}
	local rules = Style.Get().rules
	local laneAware = opts.lane_aware ~= false
	local forceEmptyBottle = opts.force_empty_bottle == true
	if hp >= 0.78 and mana >= 0.45 and not forceEmptyBottle then return false end

	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return false end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil or bottle:GetCurrentCharges() ~= 0 then return false end

	local now = DotaTime()
	if bot.aib_bottleRuneCooldownUntil ~= nil and now < bot.aib_bottleRuneCooldownUntil then
		Style.Blocked(bot, diagKey, "cooldown", string.format("left=%.0f", bot.aib_bottleRuneCooldownUntil - now), 4.0)
		return false
	end
	local enemyDeadWindow = bot.aib_eDeadSince ~= nil and now - bot.aib_eDeadSince < 45.0
	if enemyDeadWindow and not forceEmptyBottle and hp >= 0.70 and mana >= 0.50 then
		Style.Blocked(bot, diagKey, "enemy_dead_push", string.format("hp=%.0f", hp*100), 4.0)
		runeResult(bot, diagKey, "abort", "reason=enemy_dead_push", 6.0)
		clearRuneAttempt(bot)
		return false
	end
	if bot.aib_bottleRuneTarget ~= nil
		and bot.aib_bottleRuneStarted ~= nil
		and now - bot.aib_bottleRuneStarted < 30.0 then
		local criticalAbort = hp < 0.22 and bot:WasRecentlyDamagedByAnyHero(1.2)
		if criticalAbort then
			Style.Blocked(bot, diagKey, "critical_abort", string.format("hp=%.0f", hp*100), 4.0)
			runeResult(bot, diagKey, "abort", string.format("reason=critical hp=%.0f", hp*100), 8.0)
			clearRuneAttempt(bot)
			return false
		end
		if bottleCharges(bot) ~= 0 then
			Style.Intent(bot, diagKey, "reason=filled", 2.0)
			markRuneKnownEmpty(bot, bot.aib_bottleRuneId, now)
			runeResult(bot, diagKey, "filled", string.format("age=%.0f", now - bot.aib_bottleRuneStarted), 0)
			clearRuneAttempt(bot)
			return false
		end
		local targetDist = GetUnitToLocationDistance(bot, bot.aib_bottleRuneTarget)
		if bot.aib_bottleRuneId ~= nil
			and GetRuneStatus(bot.aib_bottleRuneId) ~= RUNE_STATUS_AVAILABLE then
			if targetDist <= 520 then
				if bot.aib_bottleRunePickupUntil == nil then
					bot.aib_bottleRunePickupUntil = now + 2.5
				end
				if now <= bot.aib_bottleRunePickupUntil then
					recoveryPlan(bot, "rune", "pickup_confirm", string.format("source=%s dist=%.0f", diagKey, targetDist), 1.0)
					stateIntent(bot, "rune-commit", string.format("source=%s ttl=2 reason=pickup_confirm dist=%.0f", diagKey, targetDist), 1.0)
					runeResult(bot, diagKey, "pickup_confirm", string.format("dist=%.0f age=%.0f", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
					if bot.Action_PickUpRune ~= nil then
						bot:Action_PickUpRune(bot.aib_bottleRuneId)
					else
						bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
					end
					return true
				end
			end
			local retargetRune, retargetLoc, retargetDist, retargetScore = nil, nil, math.huge, math.huge
			local retargetMax = math.max(maxDist or 2600, opts.stage_max_dist or 2600)
			for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
				if runeId ~= bot.aib_bottleRuneId and GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE
					and not isRuneKnownEmpty(bot, runeId, now) then
					local loc = GetRuneSpawnLocation(runeId)
					if loc ~= nil then
						local dist = GetUnitToLocationDistance(bot, loc)
						local runeType = GetRuneType(runeId)
						local score = dist + ((runeType == RUNE_WATER) and 0 or 350)
						if dist <= retargetMax and score < retargetScore then
							retargetRune, retargetLoc, retargetDist, retargetScore = runeId, loc, dist, score
						end
					end
				end
			end
			if retargetLoc ~= nil then
				bot.aib_bottleRuneId = retargetRune
				bot.aib_bottleRuneTarget = retargetLoc
				bot.aib_bottleRuneStarted = now
				bot.aib_bottleRuneLast = now
				recoveryPlan(bot, "rune", "retarget", string.format("source=%s dist=%.0f", diagKey, retargetDist), 2.0)
				stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=retarget dist=%.0f", diagKey, retargetDist), 2.0)
				Style.Intent(bot, diagKey, string.format("dist=%.0f reason=retarget", retargetDist), 2.0)
				bot:Action_MoveToLocation(retargetLoc)
				return true
			end
			Style.Intent(bot, diagKey, "reason=gone", 2.0)
			markRuneKnownEmpty(bot, bot.aib_bottleRuneId, now)
			runeResult(bot, diagKey, "gone", string.format("age=%.0f", now - bot.aib_bottleRuneStarted), 6.0)
			clearRuneAttempt(bot)
			return false
		end
		bot.aib_bottleRunePickupUntil = nil
		if targetDist > 180 then
			recoveryPlan(bot, "rune", "commit", string.format("source=%s dist=%.0f", diagKey, targetDist), 2.0)
			stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=commit dist=%.0f", diagKey, targetDist), 2.0)
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=commit", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			return true
		end
		if bot.aib_bottleRuneId ~= nil then
			recoveryPlan(bot, "rune", "pickup", string.format("source=%s dist=%.0f", diagKey, targetDist), 1.0)
			stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=pickup dist=%.0f", diagKey, targetDist), 1.0)
			runeResult(bot, diagKey, "pickup_attempt", string.format("dist=%.0f age=%.0f", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=pickup", targetDist, now - bot.aib_bottleRuneStarted), 1.0)
			if bot.Action_PickUpRune ~= nil then
				bot:Action_PickUpRune(bot.aib_bottleRuneId)
			else
				bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			end
			return true
		end
		recoveryPlan(bot, "rune", "hold", string.format("source=%s dist=%.0f", diagKey, targetDist), 1.0)
		stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=hold dist=%.0f", diagKey, targetDist), 1.0)
		Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=hold", targetDist, now - bot.aib_bottleRuneStarted), 1.0)
		bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
		return true
	end
	if bot.aib_bottleRuneStarted ~= nil then
		Style.Blocked(bot, diagKey, "commit_timeout", "age=30", 4.0)
		local combatTimeout = bot:WasRecentlyDamagedByAnyHero(4.0)
		local timeoutCd = combatTimeout and 3.0 or 6.0
		runeResult(bot, diagKey, "timeout", string.format("age=30 combat=%s", tostring(combatTimeout)), timeoutCd)
		clearRuneAttempt(bot)
	end

	local bestRune, bestLoc, bestDist, bestScore = nil, nil, math.huge, math.huge
	for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE and not isRuneKnownEmpty(bot, runeId, now) then
			local loc = GetRuneSpawnLocation(runeId)
			if loc ~= nil then
				local dist = GetUnitToLocationDistance(bot, loc)
				local runeType = GetRuneType(runeId)
				local score = dist + ((runeType == RUNE_WATER) and 0 or 350)
				local allowedDist = dist <= (maxDist or 2600)
					or (runeType == RUNE_WATER and waterRecoveryAllowed(bot, hp, mana, dist, forceEmptyBottle))
				if allowedDist and score < bestScore then
					bestRune, bestLoc, bestDist, bestScore = runeId, loc, dist, score
				end
			end
		end
	end
	if bestLoc == nil then
		if opts.stage_upcoming == true then
			local nextSpawnAt, spawnKind = nextBottleRuneSpawn(now)
			local secsToSpawn = nextSpawnAt ~= nil and (nextSpawnAt - now) or math.huge
			local stageWindow = opts.stage_window or 16.0
			local stageRune, stageLoc, stageDist = nearestRuneSpot(bot, now)
			local stageMaxDist = opts.stage_max_dist or math.max(maxDist or 2600, 2600)
			if bot.aib_bottleRuneStageBlockedWindow == nextSpawnAt
				and bot.aib_bottleRuneStageBlockedUntil ~= nil
				and now < bot.aib_bottleRuneStageBlockedUntil then
				Style.Blocked(bot, diagKey, "stage_cooldown", string.format("eta=%.0f", secsToSpawn), 4.0)
				return false
			end
			if hp < 0.24 and (secsToSpawn > 6 or stageDist > 900) then
				Style.Blocked(bot, diagKey, "critical_no_stage", string.format("hp=%.0f rune=%.0f eta=%.0f", hp*100, stageDist, secsToSpawn), 4.0)
				bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
				bot.aib_bottleRuneStageBlockedUntil = now + 3.0
				return false
			end
			local sameStageWindow = bot.aib_bottleRuneStageWindow == nextSpawnAt
			if sameStageWindow then
				if bot.aib_bottleRuneStageUntil ~= nil and now <= bot.aib_bottleRuneStageUntil
					and bot.aib_bottleRuneStageTarget ~= nil then
					local followDist = GetUnitToLocationDistance(bot, bot.aib_bottleRuneStageTarget)
					if followDist > 120 and (bot.aib_bottleRuneStageFollowLast == nil or now - bot.aib_bottleRuneStageFollowLast >= 1.0) then
						bot.aib_bottleRuneStageFollowLast = now
						recoveryPlan(bot, "rune_stage", "follow", string.format("source=%s dist=%.0f eta=%.0f", diagKey, followDist, secsToSpawn), 1.5)
						stateIntent(bot, "rune-commit", string.format("source=%s ttl=%.0f reason=stage_follow dist=%.0f", diagKey, math.max(0, secsToSpawn), followDist), 1.5)
						bot:Action_MoveToLocation(bot.aib_bottleRuneStageTarget)
						return true
					end
					if followDist <= 120 then
						recoveryPlan(bot, "rune_stage", "hold", string.format("source=%s dist=%.0f eta=%.0f", diagKey, followDist, secsToSpawn), 1.5)
						stateIntent(bot, "rune-commit", string.format("source=%s ttl=%.0f reason=stage_hold dist=%.0f", diagKey, math.max(0, secsToSpawn), followDist), 1.5)
						bot:Action_MoveToLocation(bot.aib_bottleRuneStageTarget)
						return true
					end
				end
				if secsToSpawn <= 0 and secsToSpawn >= -12 then
					local checkRune, checkLoc, checkDist, checkScore = nil, nil, math.huge, math.huge
					for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
						if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE and not isRuneKnownEmpty(bot, runeId, now) then
							local loc = GetRuneSpawnLocation(runeId)
							if loc ~= nil then
								local dist = GetUnitToLocationDistance(bot, loc)
								local runeType = GetRuneType(runeId)
								local score = dist + ((runeType == RUNE_WATER) and 0 or 350)
								if dist <= stageMaxDist and score < checkScore then
									checkRune, checkLoc, checkDist, checkScore = runeId, loc, dist, score
								end
							end
						end
					end
					if checkLoc ~= nil then
						bot.aib_bottleRuneStageWindow = nil
						bot.aib_bottleRuneStageUntil = nil
						bot.aib_bottleRuneStageTarget = nil
						bot.aib_bottleRuneStarted = now
						bot.aib_bottleRuneTarget = checkLoc
						bot.aib_bottleRuneId = checkRune
						bot.aib_bottleRuneLast = now
						bot.aib_bottleRuneStageBlockedWindow = nil
						bot.aib_bottleRuneStageBlockedUntil = nil
						recoveryPlan(bot, "rune", "stage_commit", string.format("source=%s dist=%.0f", diagKey, checkDist), 2.0)
						stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=stage_commit dist=%.0f", diagKey, checkDist), 2.0)
						Style.Intent(bot, diagKey, string.format("dist=%.0f reason=stage_commit", checkDist), 2.0)
						bot:Action_MoveToLocation(checkLoc)
						return true
					end
				end
				Style.Blocked(bot, diagKey, "stage_done", string.format("eta=%.0f", secsToSpawn), 6.0)
				bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
				bot.aib_bottleRuneStageBlockedUntil = now + math.max(3.0, math.min(8.0, secsToSpawn + 1.0))
				return false
			end
			if stageRune ~= nil and stageLoc ~= nil and secsToSpawn >= 0 and secsToSpawn <= stageWindow and stageDist <= stageMaxDist then
				if laneAware and stageDist > 700 and hp > 0.62 and hasLastHitWindow(bot) and secsToSpawn > 5 then
					Style.Blocked(bot, diagKey, "last_hit_window", string.format("stage=1 rune=%.0f hp=%.0f eta=%.0f", stageDist, hp*100, secsToSpawn), 6.0)
					return false
				end
				if stageDist > 700 and bot:WasRecentlyDamagedByAnyHero(1.0) and hp < 0.45 then
					Style.Blocked(bot, diagKey, "hero_damage", string.format("stage=1 hp=%.0f rune=%.0f eta=%.0f", hp*100, stageDist, secsToSpawn), 6.0)
					return false
				end
				bot.aib_bottleRuneStageWindow = nextSpawnAt
				bot.aib_bottleRuneStageUntil = nextSpawnAt + 7.0
				bot.aib_bottleRuneStageTarget = stageLoc
				bot.aib_bottleRuneStageFollowLast = now
				bot.aib_bottleRuneStageBlockedWindow = nil
				bot.aib_bottleRuneStageBlockedUntil = nil
				recoveryPlan(bot, "rune_stage", spawnKind or "upcoming", string.format("source=%s dist=%.0f eta=%.0f", diagKey, stageDist, secsToSpawn), 2.0)
				stateIntent(bot, "rune-commit", string.format("source=%s ttl=%.0f reason=stage dist=%.0f", diagKey, math.max(0, secsToSpawn), stageDist), 2.0)
				Style.Intent(bot, diagKey, string.format("dist=%.0f eta=%.0f reason=stage", stageDist, secsToSpawn), 2.0)
				Style.Diag(bot, diagKey)
				if stageDist > 120 then
					bot:Action_MoveToLocation(stageLoc)
				else
					bot:Action_MoveToLocation(stageLoc + RandomVector(35))
				end
				return true
			end
		end
		Style.Blocked(bot, diagKey, "no_close_rune", string.format("max=%.0f water=%.0f", maxDist or 2600, WATER_RECOVERY_RUNE_MAX_DIST), 8.0)
		return false
	end

	local visibleEnemies = bot:GetNearbyHeroes(1150, true, BOT_MODE_NONE)
	local routeEnemy = (visibleEnemies and #visibleEnemies > 0 and visibleEnemies[1]:IsAlive()) and visibleEnemies[1] or nil
	if bestDist > 700 and routeEnemy ~= nil and hp < 0.55
		and (AIBUtils.UphillMiss(bot, routeEnemy) or bot:WasRecentlyDamagedByAnyHero(2.0)) then
		Style.Blocked(bot, diagKey, "route_unsafe", string.format("enemy=%.0f rune=%.0f hp=%.0f", GetUnitToUnitDistance(bot, routeEnemy), bestDist, hp*100), 6.0)
		return false
	end

	local near = bot:GetNearbyHeroes(650, true, BOT_MODE_NONE)
	local enemyTooClose = near and #near > 0 and near[1]:IsAlive()
		and GetUnitToUnitDistance(bot, near[1]) <= bot:GetAttackRange() + 120
	if bestDist > 700 and enemyTooClose and (hp < 0.55 or bot:WasRecentlyDamagedByAnyHero(1.0)) then
		Style.Blocked(bot, diagKey, "enemy_near", string.format("enemy=%.0f rune=%.0f hp=%.0f", GetUnitToUnitDistance(bot, near[1]), bestDist, hp*100), 6.0)
		return false
	end

	if bestDist > 700 and bot:WasRecentlyDamagedByAnyHero(1.0) and hp < 0.45 then
		Style.Blocked(bot, diagKey, "hero_damage", string.format("hp=%.0f rune=%.0f", hp*100, bestDist), 6.0)
		return false
	end

	if laneAware and bestDist > 700 and hp > 0.62 and hasLastHitWindow(bot) then
		Style.Blocked(bot, diagKey, "last_hit_window", string.format("rune=%.0f hp=%.0f", bestDist, hp*100), 6.0)
		return false
	end

	if laneAware then
		local laneDist = laneFrontDistance(bot)
		local laneBudget = BOTTLE_RUNE_LANE_BUDGET
		local needsRuneRecovery = forceEmptyBottle or hp < 0.65 or mana < 0.35
		local closeEnoughRune = bestDist <= 1100
		if laneDist > laneBudget and bestDist > 700 and not needsRuneRecovery and not closeEnoughRune then
			Style.Blocked(bot, diagKey, "lane_budget", string.format("lane=%.0f max=%.0f rune=%.0f", laneDist, laneBudget, bestDist), 6.0)
			return false
		end
	end

	if bot.aib_bottleRuneLast ~= nil and now - bot.aib_bottleRuneLast < 3.0 then
		Style.Intent(bot, diagKey, string.format("dist=%.0f reason=cooldown_hold", bestDist), 2.0)
		if bestDist > 55 then
			bot:Action_MoveToLocation(bestLoc)
			return true
		end
		return false
	end

	bot.aib_bottleRuneLast = now
	bot.aib_bottleRuneStarted = now
	bot.aib_bottleRuneTarget = bestLoc
	bot.aib_bottleRuneId = bestRune
	bot.aib_bottleRuneStageWindow = nil
	bot.aib_bottleRuneStageUntil = nil
	bot.aib_bottleRuneStageTarget = nil
	bot.aib_bottleRuneStageFollowLast = nil
	recoveryPlan(bot, "rune", "start", string.format("source=%s dist=%.0f hp=%.0f mana=%.0f", diagKey, bestDist, hp*100, mana*100), 2.0)
	stateIntent(bot, "rune-commit", string.format("source=%s ttl=30 reason=start dist=%.0f hp=%.0f mana=%.0f", diagKey, bestDist, hp*100, mana*100), 2.0)
	Style.Intent(bot, diagKey, string.format("dist=%.0f hp=%.0f mana=%.0f reason=start", bestDist, hp*100, mana*100), 2.0)
	Style.Diag(bot, diagKey)
	bot:Action_MoveToLocation(bestLoc)
	return true
end

-- tryTango: unified tango logic used by defensiveHeal and recovery.
-- Returns true when tree-walk is in progress (caller must return to protect the walk).
-- Releases automatically once modifier_tango_heal appears (HasModifier check below).
local function tryTango(bot, hpThreshold, treeRadius, diagKey)
	-- Walking protection: block until modifier appears (bot reached tree) or 2s timeout.
	if bot.aib_tangoWalking ~= nil then
		if bot:HasModifier("modifier_tango_heal") then
			bot.aib_tangoWalking = nil  -- tree reached, unblock
		elseif DotaTime() - bot.aib_tangoWalking < 2.0 then
			return true  -- still walking to tree
		else
			bot.aib_tangoWalking = nil  -- timeout, give up
		end
	end
	if J.GetHP(bot) >= hpThreshold then return false end
	if bot.aib_tangoLast ~= nil and DotaTime() - bot.aib_tangoLast < TANGO_CD then return false end
	if bot:HasModifier("modifier_tango_heal") then return false end
	local item = getItem(bot, "item_tango") or getItem(bot, "item_tango_single")
	if not item then return false end
	local trees = bot:GetNearbyTrees(treeRadius)
	if not trees or #trees == 0 then return false end
	bot.aib_tangoLast   = DotaTime()
	bot.aib_tangoWalking = DotaTime()
	Style.Diag(bot, diagKey)
	bot:Action_UseAbilityOnTree(item, trees[1])
	return true
end

--
-- defensiveHeal: consumables WITH safety gates (normal laning).
--
local function defensiveHeal(bot, dials)
	local hp        = J.GetHP(bot)
	local hpMissing = bot:GetMaxHealth() - bot:GetHealth()
	local maxMana   = bot:GetMaxMana()
	local mana      = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0

	-- Proactive: fires for ALL healing styles.
	-- Returns true to protect the walk-to-tree (~1-2s). Releases as soon as modifier appears
	-- (HasModifier check in tryTango returns false; defensiveHeal falls through normally).
	if tryTango(bot, 0.70, 700, "tango-heal") then
		bot.aib_healLast = DotaTime()
		return true
	end

	if hpMissing >= 400
		and (bot.aib_flaskLast == nil or DotaTime() - bot.aib_flaskLast >= FLASK_CD)
		and not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)) then
		local flask = getItem(bot, "item_flask")
		if flask then
			bot.aib_flaskLast = DotaTime()
			Style.Diag(bot, "heal-item")
			bot:Action_UseAbilityOnEntity(flask, bot)
			return true
		end
	end

	if seekBottleRune(bot, hp, mana, "bottle-rune", BOTTLE_RUNE_MAX_DIST, {
		lane_aware = true,
		stage_upcoming = true,
		stage_window = 18.0,
		stage_max_dist = BOTTLE_RUNE_STAGE_MAX_DIST,
	}) then return true end

	if Style.Get().rules.healing_style ~= "active" then return false end

	local HEAL_CD   = 2.5
	local MANA_CD   = 4.0
	local healReady = bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD
	local manaReady = bot.aib_manaLast == nil or DotaTime() - bot.aib_manaLast >= MANA_CD

	-- 1. Tango at tighter threshold (0.65 vs 0.70 proactive); shared CD prevents double-use.
	if tryTango(bot, 0.65, 700, "tango-heal") then
		bot.aib_healLast = DotaTime()
		return true
	end

	-- 2. Bottle: channel-safe; hero damage cancels it
	if (hp < 0.70 or mana < 0.40) and healReady
		and not bot:HasModifier("modifier_bottle_regeneration")
		and not bot:WasRecentlyDamagedByAnyHero(1.5) then
		local bottle = getItem(bot, "item_bottle")
		if bottle and bottle:GetCurrentCharges() > 0 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "bottle-heal")
			bot:Action_UseAbility(bottle); return true
		end
	end

	-- 3. Mango: instant, separate mana CD; keep it for true mana emergencies.
	if mana < 0.12 and manaReady then
		local mango = getItem(bot, "item_enchanted_mango")
		if mango then
			bot.aib_manaLast = DotaTime(); Style.Diag(bot, "mana-mango")
			bot:Action_UseAbilityOnEntity(mango, bot); return true
		end
	end

	-- 4+5. Wand (>=10 ch) / Stick (>=8 ch): instant, meaningful charge threshold only
	if hp < 0.50 and healReady then
		local wand = getItem(bot, "item_magic_wand")
		if wand and wand:GetCurrentCharges() >= 10 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(wand); return true
		end
		local stick = getItem(bot, "item_magic_stick")
		if stick and stick:GetCurrentCharges() >= 8 then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(stick); return true
		end
	end

	-- 6+7. Faerie Fire / Satanic: instant emergency
	if hp < 0.45 and healReady then
		local ff = getItem(bot, "item_faerie_fire")
		if ff then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(ff); return true
		end
		local satanic = getItem(bot, "item_satanic")
		if satanic then
			bot.aib_healLast = DotaTime(); Style.Diag(bot, "heal-item")
			bot:Action_UseAbility(satanic); return true
		end
	end

	-- 8. Clarity: channel, any damage cancels -- separate mana CD.
	if mana < 0.25 and manaReady then
		local safe = not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5))
		if safe then
			local clarity = getItem(bot, "item_clarity")
			if clarity then
				bot.aib_manaLast = DotaTime(); Style.Diag(bot, "mana-clarity")
				bot:Action_UseAbilityOnEntity(clarity, bot); return true
			end
		end
	end

	-- 9. Flask at lower threshold -- not gated by healReady so tango/wand use doesn't block it.
	-- At critical HP (< 0.30) bypass recent-damage check (channel gets cancelled but worth trying).
	if hp < 0.40 and (bot.aib_flaskLast == nil or DotaTime() - bot.aib_flaskLast >= FLASK_CD) then
		local flask = getItem(bot, "item_flask")
		if flask then
			local recently_dmg = bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)
			if hp < 0.30 or not recently_dmg then
				bot.aib_healLast  = DotaTime()
				bot.aib_flaskLast = DotaTime()
				Style.Diag(bot, "heal-item")
				bot:Action_UseAbilityOnEntity(flask, bot); return true
			end
		end
	end

	-- heal-pullback: separate CD, skipped for regen_lane (has its own movement logic)
	local PULLBACK_CD = 3.0
	if hp < 0.40
		and Style.Get().rules.low_hp_behavior ~= "regen_lane"
		and (bot.aib_pullbackLast == nil or DotaTime() - bot.aib_pullbackLast >= PULLBACK_CD)
		and (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)) then
		local back = forwardTowerLoc(bot)
		if back then
			bot.aib_pullbackLast = DotaTime(); Style.Diag(bot, "heal-pullback")
			bot:Action_MoveToLocation(back); return true
		end
	end

	return false
end

-- regen_lane: retreat to forward tower when HP is low AND enemy hero is nearby.
-- Returns true only while walking back; once at safe position returns false so normal
-- farming/healing runs. aib_lowHpHold in mode_laning_generic already blocks fwd at HP<0.45.
local function regenLane(bot, dials, nEnemyCreeps)
	if Style.Get().rules.low_hp_behavior ~= "regen_lane" then return false end
	local holdThresh = Style.Get().rules.low_hp_hold or 0.45
	if J.GetHP(bot) >= holdThresh then return false end

	local near = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if not (near and #near > 0 and near[1]:IsAlive()) then return false end

	local hp = J.GetHP(bot)
	local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if back == nil or GetUnitToLocationDistance(bot, back) <= 200 then return false end

	if bot.aib_regenMoveLast == nil or DotaTime() - bot.aib_regenMoveLast >= 1.5 then
		bot.aib_regenMoveLast = DotaTime()
		Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
		stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
			string.format("ttl=2 reason=regen_lane hp=%.0f dist=%.0f", hp*100, GetUnitToLocationDistance(bot, back)), 2.0)
		Style.Diag(bot, "regen-walk")
		bot:Action_MoveToLocation(back)
	end
	return true
end

--
-- recovery: post-fight heal WITHOUT safety gates.
-- Enemy is dead/gone -- no need to wait for "safe" windows.
--
local function recovery(bot, dials, nEnemyCreeps)
	if Style.Get().rules.healing_style ~= "active" or not bot:IsAlive() then return false end

	local hp      = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana    = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local near    = bot:GetNearbyHeroes(900, true, BOT_MODE_NONE)
	if near and #near > 0 and near[1]:IsAlive() then return false end

	-- 1. Tango: 800u radius (wider than laning -- enemy gone, safe to step to farther tree).
	if tryTango(bot, 0.65, 800, "recovery-tango") then return true end

	-- 2. Bottle: no WasRecentlyDamagedByAnyHero check. Empty bottle may stage
	-- around rune windows, but outside those windows it yields back to lane play.
	do
		local bSlot = bot:FindItemSlot("item_bottle")
		if bSlot >= 0 then
			local bItem = bot:GetItemInSlot(bSlot)
			if bItem ~= nil then
				if bot:HasModifier("modifier_bottle_regeneration") then
					Style.DiagRL(bot, "recovery-bottle-active", 3)
				elseif (hp < 0.80 or mana < 0.50) and bItem:GetCurrentCharges() > 0 and bItem:IsFullyCastable()
					and (bot.aib_recBottleLast == nil or DotaTime() - bot.aib_recBottleLast >= 3.0) then
					bot.aib_recBottleLast = DotaTime()
					recoveryPlan(bot, "bottle", "charges", string.format("hp=%.0f mana=%.0f charges=%d", hp*100, mana*100, bItem:GetCurrentCharges()), 2.0)
					Style.Diag(bot, "recovery-bottle"); bot:Action_UseAbility(bItem); return true
				elseif bItem:GetCurrentCharges() == 0 then
					if seekBottleRune(bot, hp, mana, "recovery-rune-bottle", RECOVERY_RUNE_MAX_DIST, {
						lane_aware = false,
						force_empty_bottle = true,
						stage_upcoming = true,
						stage_window = 24.0,
						stage_max_dist = RECOVERY_RUNE_STAGE_MAX_DIST,
					}) then return true end
					if hp < 0.65 or mana < 0.45 then
						recoveryPlan(bot, "lane", "empty_bottle_no_rune", string.format("hp=%.0f mana=%.0f", hp*100, mana*100), 8.0)
					else
						Style.DiagRL(bot, "empty-bottle-ok", 8)
					end
					if hp >= 0.24 then bot.aib_recWaitStart = nil end
				end
			end
		end
	end

	-- 3. Flask: 8s CD guards against channel-interrupt re-spam (damage cancels channel -> item stays
	--    castable -> next tick retries). aib_recFlaskLast is separate from aib_flaskLast so laning
	--    (3s CD, enemy present) and recovery (8s CD, enemy gone) don't block each other.
	--    Don't return true when on CD; laning should continue during the cooldown window.
	if hp < 0.70 then
		local flask = getItem(bot, "item_flask")
		if flask then
			if bot.aib_recFlaskLast == nil or DotaTime() - bot.aib_recFlaskLast >= 8.0 then
				bot.aib_recFlaskLast = DotaTime()
				recoveryPlan(bot, "flask", "inventory", string.format("hp=%.0f", hp*100), 2.0)
				Style.Diag(bot, "recovery-flask"); bot:Action_UseAbilityOnEntity(flask, bot)
				return true  -- protect first tick after cast
			end
			-- CD active (channel was interrupted): fall through to laning
		end
	end

	-- Post-fight step-back: enemy gone, recently took hero damage, HP still suboptimal and
	-- all items exhausted. Back off near forward tower so natural regen works during
	-- the enemy's respawn window.
	do
		local postFightBack = 0.45 + 0.20 * (dials.retreat_caution or 0.5)
		local tangoWalk = bot.aib_tangoLast ~= nil and DotaTime() - bot.aib_tangoLast < 12.0
		if hp < postFightBack
			and bot:WasRecentlyDamagedByAnyHero(8.0)
			and not bot:HasModifier("modifier_tango_heal")
			and not tangoWalk then
			local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
			if back then
				if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
					bot.aib_recMoveLast = DotaTime()
					recoveryPlan(bot, "back", "post_fight_regen", string.format("hp=%.0f", hp*100), 2.0)
					Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
					stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
						string.format("ttl=5 reason=post_fight_regen hp=%.0f dist=%.0f", hp*100, GetUnitToLocationDistance(bot, back)), 2.0)
					Style.Diag(bot, "recovery-regen")
					bot:Action_MoveToLocation(back)
				end
				-- Don't block laning: move command issued, let Think() continue normally.
			end
		end
	end

	-- Fallback chain: only when critically low and items exhausted
	local threshold = 0.20 + 0.20 * (dials.retreat_caution or 0.5)
	                + (GetHeroDeaths(bot:GetPlayerID()) >= 1 and 0.08 or 0.0)
	if hp >= threshold then bot.aib_recWaitStart = nil; return false end

	local behavior = Style.Get().rules.low_hp_behavior or "tp_fountain"
	local gold     = bot:GetGold()

	-- a. Buy flask + courier (rate-limited 15s)
	if gold >= 55 and (bot.aib_recBuyLast == nil or DotaTime() - bot.aib_recBuyLast >= 15.0) then
		if hasItem(bot, "item_flask") then
			Style.Blocked(bot, "recovery-buy", "flask_in_inventory", string.format("hp=%.0f", hp*100), 8.0)
			return false
		end
		if (bot.aib_recBuyCount or 0) >= 2 then
			Style.Blocked(bot, "recovery-buy", "budget_cap", string.format("hp=%.0f gold=%d", hp*100, gold), 8.0)
			return false
		end
		if wantsBottleFromStyle(bot) and hp >= 0.22 then
			Style.DiagRL(bot, "bottle-gold-protect", 8)
			return false
		end
		if consumableSpendBlocked(bot, hp, gold, "item_flask") then
			return false
		end
		bot.aib_recBuyLast = DotaTime()
		bot.aib_recBuyCount = (bot.aib_recBuyCount or 0) + 1
		bot.aib_recBuySpent = (bot.aib_recBuySpent or 0) + itemCost("item_flask")
		recoveryPlan(bot, "buy_flask", "critical", string.format("hp=%.0f gold=%d count=%d", hp*100, gold, bot.aib_recBuyCount or 0), 2.0)
		bot:ActionImmediate_PurchaseItem("item_flask")
		Style.Diag(bot, "recovery-buy")
		return true
	end

	-- b. TP to fountain
	local tp = getItem(bot, "item_tpscroll")
	if tp and (behavior == "tp_fountain" or behavior == "walk_fountain") then
		bot.aib_fountainTrip = true
		recoveryPlan(bot, "tp_fountain", "critical", string.format("hp=%.0f", hp*100), 2.0)
		Style.Diag(bot, "recovery-tp"); bot:Action_UseAbility(tp); return true
	end

	-- c. Walk to fountain (walk_fountain, or tp_fountain with no scroll)
	if behavior == "walk_fountain" or (behavior == "tp_fountain" and not tp) then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			bot.aib_fountainTrip = true
			recoveryPlan(bot, "walk_fountain", "no_tp", string.format("hp=%.0f", hp*100), 2.0)
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- d. Water rune (regen_lane only)
	if behavior == "regen_lane" then
		local now = DotaTime()
		local bestRune, bestLoc, bestDist = nil, nil, math.huge
		for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
			if GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE and GetRuneType(runeId) == RUNE_WATER
				and not isRuneKnownEmpty(bot, runeId, now) then
				local loc = GetRuneSpawnLocation(runeId)
				local dist = loc ~= nil and GetUnitToLocationDistance(bot, loc) or math.huge
				if waterRecoveryAllowed(bot, hp, mana, dist, false) and dist < bestDist then
					bestRune, bestLoc, bestDist = runeId, loc, dist
				end
			end
		end
		if bestLoc ~= nil then
			if bot.aib_recMoveLast == nil or now - bot.aib_recMoveLast >= 5.0 then
				recoveryPlan(bot, "water_rune", "regen_lane", string.format("hp=%.0f mana=%.0f dist=%.0f", hp*100, mana*100, bestDist), 2.0)
				bot.aib_recMoveLast = now; Style.Diag(bot, "recovery-rune")
				bot:Action_MoveToLocation(bestLoc)
			end
			return true
		else
			recoveryPlan(bot, "water_rune", "blocked", string.format("hp=%.0f mana=%.0f", hp*100, mana*100), 4.0)
		end
	end

	-- e. No-resource recovery: move toward XP/safety once, then yield back to laning.
	-- Passive regen is context, not a terminal action; standing still here looks like AFK.
	local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if back then
		if bot.aib_recWaitStart == nil then bot.aib_recWaitStart = DotaTime() end
		if DotaTime() - bot.aib_recWaitStart < 10.0 then
			local backDist = GetUnitToLocationDistance(bot, back)
			if backDist <= 220 then
				Style.DiagRL(bot, "recovery-yield", 5)
				return false
			end
			if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 1.5 then
				bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-wait")
				Style.Diag(bot, backKind == "xp" and "recover-xp" or "recover-safe")
				stateIntent(bot, backKind == "xp" and "recover-xp" or "recover-safe",
					string.format("ttl=2 reason=no_resources hp=%.0f dist=%.0f", hp*100, backDist), 2.0)
				recoveryPlan(bot, "wait_safe", "no_resources", string.format("hp=%.0f", hp*100), 2.0)
				bot:Action_MoveToLocation(back)
				return true
			end
			Style.DiagRL(bot, "recovery-yield", 5)
			return false
		end
		-- Timeout elapsed with no items: go to lane at reduced HP rather than staying AFK.
		bot.aib_recWaitStart = nil
		Style.DiagRL(bot, "recovery-timeout", 10)
	end

	return false
end

--

function M.Think(bot, dials, nEnemyCreeps)
	if fountainRecovery(bot)              then return true end
	if defensiveHeal(bot, dials)           then return true end
	if regenLane(bot, dials, nEnemyCreeps) then return true end
	if recovery(bot, dials, nEnemyCreeps)  then return true end
	return false
end

return M
