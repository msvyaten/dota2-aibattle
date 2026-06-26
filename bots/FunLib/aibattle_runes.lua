-- AIBattle rune transaction engine: bottle rune commit/staging/pickup memory.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil then return nil end
	return bottle:GetCurrentCharges()
end

local function recoveryPlan(bot, action, reason, detail, sec)
	local text = "action=" .. tostring(action) .. " reason=" .. tostring(reason)
	if detail ~= nil and detail ~= "" then text = text .. " " end
	if detail ~= nil and detail ~= "" then text = text .. detail end
	Style.Intent(bot, "recovery-plan", text, sec or 2.0)
end

local function stateIntent(bot, name, detail, sec)
	Style.Intent(bot, "state-" .. tostring(name), detail or "", sec or 2.0)
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
	if dist == nil or dist > Const.Rune.waterRecoveryMaxDist then return false end
	if not forceEmptyBottle and hp >= 0.65 and mana >= 0.35 then return false end
	return midContextDistance(bot) <= Const.Rune.waterMidContextMax
end

local function waterRuneEmergency(bot, hp, mana, dist, spawnKind, forceEmptyBottle)
	if spawnKind ~= "water" then return false end
	if not waterRecoveryAllowed(bot, hp, mana, dist, forceEmptyBottle) then return false end
	local now = DotaTime()
	local emptyFor = now - (bot.aib_emptyBottleSince or now)
	return forceEmptyBottle or hp < 0.65 or mana < 0.35 or emptyFor >= 20.0
end

local function nextBottleRuneSpawn(now)
	if now == nil or now < 0 then return nil end
	if now < 120 then return 120, "water" end
	if now < 240 then return 240, "water" end
	if now < 360 then return 360, "power" end
	return (math.floor(now / 120) + 1) * 120, "power"
end

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

local function clearRuneAttempt(bot)
	bot.aib_bottleRuneTarget = nil
	bot.aib_bottleRuneStarted = nil
	bot.aib_bottleRuneId = nil
	bot.aib_bottleRunePickupUntil = nil
	bot.aib_bottleRuneGoneGraceUntil = nil
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

local function runeTxn(bot, action, phase, diagKey, detail, ttl, sec)
	local text = "source=" .. tostring(diagKey) .. " phase=" .. tostring(phase)
	if ttl ~= nil then text = text .. string.format(" ttl=%.0f", ttl) end
	if detail ~= nil and detail ~= "" then text = text .. " " .. detail end
	recoveryPlan(bot, action or "rune", phase, "source=" .. tostring(diagKey) .. " " .. (detail or ""), sec or 2.0)
	stateIntent(bot, "rune-commit", text, sec or 2.0)
	Style.Intent(bot, "rune-transaction", text, sec or 2.0)
end

function M.Reset(bot)
	if bot == nil then return end
	bot.aib_bottleRuneLast = nil
	bot.aib_bottleRuneStarted = nil
	bot.aib_bottleRuneTarget = nil
	bot.aib_bottleRuneId = nil
	bot.aib_bottleRunePickupUntil = nil
	bot.aib_bottleRuneGoneGraceUntil = nil
	bot.aib_bottleRuneCooldownUntil = nil
	bot.aib_bottleRuneStageWindow = nil
	bot.aib_bottleRuneStageUntil = nil
	bot.aib_bottleRuneStageTarget = nil
	bot.aib_bottleRuneStageFollowLast = nil
	bot.aib_bottleRuneStageBlockedWindow = nil
	bot.aib_bottleRuneStageBlockedUntil = nil
	bot.aib_emptyBottleSince = nil
end

function M.FindWaterRecoveryRune(bot, hp, mana, now)
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
	return bestRune, bestLoc, bestDist
end

function M.SeekBottleRune(bot, hp, mana, diagKey, maxDist, opts)
	opts = opts or {}
	local laneAware = opts.lane_aware ~= false
	local forceEmptyBottle = opts.force_empty_bottle == true

	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return false end
	local bottle = bot:GetItemInSlot(bSlot)
	local now = DotaTime()
	if bottle == nil then return false end
	if bottle:GetCurrentCharges() ~= 0 then
		bot.aib_emptyBottleSince = nil
		return false
	end
	bot.aib_emptyBottleSince = bot.aib_emptyBottleSince or now
	if hp >= 0.78 and mana >= 0.45 and not forceEmptyBottle then return false end
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
		and now - bot.aib_bottleRuneStarted < Const.Rune.commitSeconds then
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
			if targetDist <= 120 then
				if bot.aib_bottleRunePickupUntil == nil then
					bot.aib_bottleRunePickupUntil = now + 2.5
				end
				if now <= bot.aib_bottleRunePickupUntil then
					runeTxn(bot, "rune", "pickup_confirm", diagKey, string.format("dist=%.0f", targetDist), 2, 1.0)
					runeResult(bot, diagKey, "pickup_confirm", string.format("dist=%.0f age=%.0f", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
					if bot.Action_PickUpRune ~= nil then
						bot:Action_PickUpRune(bot.aib_bottleRuneId)
					else
						bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
					end
					return true
				end
			end
			if targetDist <= 260 then
				if bot.aib_bottleRuneGoneGraceUntil == nil then
					bot.aib_bottleRuneGoneGraceUntil = now + 3.0
				end
				if now <= bot.aib_bottleRuneGoneGraceUntil then
					runeTxn(bot, "rune", "gone_grace", diagKey, string.format("dist=%.0f", targetDist), 2, 1.0)
					bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
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
				runeTxn(bot, "rune", "retarget", diagKey, string.format("dist=%.0f", retargetDist), 30, 2.0)
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
		if targetDist > 95 then
			runeTxn(bot, "rune", "commit", diagKey, string.format("dist=%.0f", targetDist), 30, 2.0)
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=commit", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			return true
		end
		bot.aib_bottleRuneGoneGraceUntil = nil
		if bot.aib_bottleRuneId ~= nil then
			runeTxn(bot, "rune", "pickup", diagKey, string.format("dist=%.0f", targetDist), 30, 1.0)
			runeResult(bot, diagKey, "pickup_attempt", string.format("dist=%.0f age=%.0f", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=pickup", targetDist, now - bot.aib_bottleRuneStarted), 1.0)
			if bot.Action_PickUpRune ~= nil then
				bot:Action_PickUpRune(bot.aib_bottleRuneId)
			else
				bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			end
			return true
		end
		runeTxn(bot, "rune", "hold", diagKey, string.format("dist=%.0f", targetDist), 30, 1.0)
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
			if bot.aib_bottleRuneStageClosedWindow == nextSpawnAt then
				Style.Blocked(bot, diagKey, "stage_done", string.format("eta=%.0f closed=1", secsToSpawn), 6.0)
				bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
				bot.aib_bottleRuneStageBlockedUntil = now + math.max(3.0, math.min(8.0, secsToSpawn + 1.0))
				return false
			end
			if bot.aib_bottleRuneStageBlockedWindow == nextSpawnAt
				and bot.aib_bottleRuneStageBlockedUntil ~= nil
				and now < bot.aib_bottleRuneStageBlockedUntil then
				if waterRuneEmergency(bot, hp, mana, stageDist, spawnKind, forceEmptyBottle) then
					bot.aib_bottleRuneStageBlockedWindow = nil
					bot.aib_bottleRuneStageBlockedUntil = nil
					Style.Intent(bot, "rune-stage-override", string.format("reason=water_emergency eta=%.0f dist=%.0f hp=%.0f mana=%.0f", secsToSpawn, stageDist, hp*100, mana*100), 2.0)
				else
					Style.Blocked(bot, diagKey, "stage_cooldown", string.format("eta=%.0f", secsToSpawn), 4.0)
					return false
				end
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
						runeTxn(bot, "rune_stage", "stage_follow", diagKey, string.format("dist=%.0f eta=%.0f", followDist, secsToSpawn), math.max(0, secsToSpawn), 1.5)
						bot:Action_MoveToLocation(bot.aib_bottleRuneStageTarget)
						return true
					end
					if followDist <= 120 then
						runeTxn(bot, "rune_stage", "stage_hold", diagKey, string.format("dist=%.0f eta=%.0f", followDist, secsToSpawn), math.max(0, secsToSpawn), 1.5)
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
						runeTxn(bot, "rune", "stage_commit", diagKey, string.format("dist=%.0f", checkDist), 30, 2.0)
						Style.Intent(bot, diagKey, string.format("dist=%.0f reason=stage_commit", checkDist), 2.0)
						bot:Action_MoveToLocation(checkLoc)
						return true
					end
				end
				Style.Blocked(bot, diagKey, "stage_done", string.format("eta=%.0f", secsToSpawn), 6.0)
				local observedStage = false
				if stageRune ~= nil then
					local stageTarget = bot.aib_bottleRuneStageTarget or stageLoc
					local observedDist = stageTarget ~= nil and GetUnitToLocationDistance(bot, stageTarget) or math.huge
					observedStage = GetRuneStatus(stageRune) ~= RUNE_STATUS_AVAILABLE or observedDist <= 850
					if observedStage then
						markRuneKnownEmpty(bot, stageRune, now)
					else
						Style.Blocked(bot, diagKey, "stage_unchecked", string.format("rune=%.0f eta=%.0f", observedDist, secsToSpawn), 6.0)
					end
				end
				bot.aib_bottleRuneStageClosedWindow = nextSpawnAt
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
				bot.aib_bottleRuneStageClosedWindow = nil
				bot.aib_bottleRuneStageBlockedWindow = nil
				bot.aib_bottleRuneStageBlockedUntil = nil
				runeTxn(bot, "rune_stage", spawnKind or "upcoming", diagKey, string.format("dist=%.0f eta=%.0f", stageDist, secsToSpawn), math.max(0, secsToSpawn), 2.0)
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
		Style.Blocked(bot, diagKey, "no_close_rune", string.format("max=%.0f water=%.0f", maxDist or 2600, Const.Rune.waterRecoveryMaxDist), 8.0)
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
		local laneBudget = Const.Rune.bottleLaneBudget
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
	runeTxn(bot, "rune", "start", diagKey, string.format("dist=%.0f hp=%.0f mana=%.0f", bestDist, hp*100, mana*100), 30, 2.0)
	Style.Intent(bot, diagKey, string.format("dist=%.0f hp=%.0f mana=%.0f reason=start", bestDist, hp*100, mana*100), 2.0)
	Style.Diag(bot, diagKey)
	bot:Action_MoveToLocation(bestLoc)
	return true
end

return M
