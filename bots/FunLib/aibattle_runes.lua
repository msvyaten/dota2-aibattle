-- AIBattle rune transaction engine: bottle rune commit/staging/pickup memory.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	if bot:GetItemSlotType(bSlot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
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

local function killableEnemyNearby(bot, hp)
	if bot == nil or hp == nil or hp < 0.34 then return nil, nil end
	local range = bot:GetAttackRange()
	-- hero-agnostic: this is a one-hit kill guard for rune departure, not an attack band.
	-- It needs to see a nearby dying hero before the rune owner takes the bot out of lane.
	local enemies = bot:GetNearbyHeroes(math.max(900, range + 520), true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0) then return nil, nil end
	for _, enemy in ipairs(enemies) do
		if J.IsValidHero(enemy) and enemy:IsAlive() and enemy:GetHealth() > 0 then
			local dist = GetUnitToUnitDistance(bot, enemy)
			if dist <= range + 520
				and enemy:GetHealth() <= bot:GetAttackDamage() * Style.AttackDamageMult(bot, enemy) then
				return enemy, dist
			end
		end
	end
	return nil, nil
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

-- 1v1 MID RUNE SCHEDULE (authoritative, user 28.07). This mode is NOT 5v5:
--   0:00 and 2:00 -- NO runes at all (unlike 5v5, which has bounty/water there).
--   4:00          -- WATER runes at BOTH river spots.
--   every 2 min after (6:00, 8:00, ...) -- ONE power rune at one of the two spots.
-- The old model started the grid at 2:00 and called both 2:00 and 4:00 "water". That first window
-- is fiction, and staging is built to ARRIVE EARLY, so the bot walked onto an empty spot at
-- 1:55-1:58 in 8917945764 and paid farm time for a spawn that cannot happen. (The 3:48 trip in the
-- same match was staging for the 4:00 water spawn -- that one is correct play and stays.)
-- "Both spots" at 4:00 is also what makes the avoid-contested pick sound: at a water window the
-- uncontested spot is a guaranteed fill, whereas at a power window only one spot has anything.
local FIRST_RUNE_SPAWN = 240

local function bottleSpawnKindAt(t)
	if t == FIRST_RUNE_SPAWN then return "water" end
	return "power"
end

local function nextBottleRuneSpawn(now)
	if now == nil or now < 0 then return nil end
	-- Keep the just-passed window "current" for 12s. Without this the window id
	-- flips to the NEXT spawn on the very tick the rune appears, sameStageWindow
	-- goes false and the at-spawn both-spots commit scan (secsToSpawn <= 0 >= -12)
	-- is unreachable: the bot staged perfectly, then "forgot" why it was standing
	-- there and walked off with no_close_rune - filled=0 in every match.
	local prev = math.floor(now / 120) * 120
	if prev >= FIRST_RUNE_SPAWN and now - prev <= 12.0 then
		return prev, bottleSpawnKindAt(prev)
	end
	local nxt = prev + 120
	if nxt < FIRST_RUNE_SPAWN then nxt = FIRST_RUNE_SPAWN end
	return nxt, bottleSpawnKindAt(nxt)
end

-- True when a visible alive enemy hero is within radius of loc. Used to avoid
-- staging at the contested river spot: at water windows BOTH spots spawn a rune,
-- so walking to the uncontested one converts staging into a guaranteed fill
-- instead of a pickup race the bot loses (result=gone age=2-3 at dist=42-96,
-- filled=0 across matches while the enemy bottle filled).
local function nearestEnemyToLoc(loc)
	if loc == nil then return nil end
	local best = nil
	for _, h in pairs(GetUnitList(UNIT_LIST_ENEMY_HEROES) or {}) do
		if h ~= nil and h:CanBeSeen() and h:IsAlive() then
			local hl = h:GetLocation()
			if hl ~= nil then
				local dx, dy = hl.x - loc.x, hl.y - loc.y
				local d = math.sqrt(dx * dx + dy * dy)
				if best == nil or d < best then best = d end
			end
		end
	end
	return best
end

local function enemyNearLoc(loc, radius)
	local d = nearestEnemyToLoc(loc)
	return d ~= nil and d <= radius
end

-- One survival question, asked wherever a rune trip BEGINS or CONTINUES.
--
-- These three tests used to live only at the direct-commit departure. The staging path
-- asked one of them at departure (hero_damage) and NOTHING afterwards, so a staged trip
-- was a promise the bot could not take back. 8974058954 t=468-484: R left the lane at 35%
-- hp for a rune 2161u away, the enemy came into view at 1118u four seconds later, and
-- stage_follow/stage_hold kept re-issuing the walk until R died standing AT the spot
-- (23% -> 2%, killed by a 100% enemy). A rune is sustain, not a hill to die on.
--
-- `dist == nil` means "already away": the trip-length short-circuit does not apply,
-- because a bot standing at the spot is not made safe by having a short walk left.
-- It prints as `rune=-1` in the refusal line, which is how a reader tells the two apart.
local function tripUnsafe(bot, hp, dist)
	if dist ~= nil and dist <= 700 then return nil end
	local visibleEnemies = bot:GetNearbyHeroes(1150, true, BOT_MODE_NONE)
	local routeEnemy = (visibleEnemies and #visibleEnemies > 0 and visibleEnemies[1]:IsAlive()) and visibleEnemies[1] or nil
	if routeEnemy ~= nil and hp < 0.55
		and (AIBUtils.UphillMiss(bot, routeEnemy) or bot:WasRecentlyDamagedByAnyHero(2.0)) then
		return "route_unsafe", string.format("enemy=%.0f rune=%.0f hp=%.0f",
			GetUnitToUnitDistance(bot, routeEnemy), dist or -1, hp * 100)
	end
	local near = bot:GetNearbyHeroes(650, true, BOT_MODE_NONE)
	local enemyTooClose = near and #near > 0 and near[1]:IsAlive()
		and GetUnitToUnitDistance(bot, near[1]) <= bot:GetAttackRange() + 120
	if enemyTooClose and (hp < 0.55 or bot:WasRecentlyDamagedByAnyHero(1.0)) then
		return "enemy_near", string.format("enemy=%.0f rune=%.0f hp=%.0f",
			GetUnitToUnitDistance(bot, near[1]), dist or -1, hp * 100)
	end
	if bot:WasRecentlyDamagedByAnyHero(1.0) and hp < 0.45 then
		return "hero_damage", string.format("hp=%.0f rune=%.0f", hp * 100, dist or -1)
	end
	return nil
end

-- The race the bot is standing in. While staging it holds still at a landmark the enemy
-- wants too, so "is an enemy near ME" is the wrong question: what decides the trip is
-- whether the enemy reaches the SPOT no later than the rune appears there. Answering it
-- with the same 300u/s travel model the departure window already uses (stageDist/300+2)
-- keeps one movement model in this file instead of two.
--
-- In 8974058954 this is the tick that was missing: at t=471-476 the enemy was 1877u then
-- 929u from the spot with eta 8s then 3s -- it beat the rune both times -- while R held
-- at 38-40% hp and picked the rune up straight into a fight it could not win.
local function spotRaceLost(bot, hp, spot, secsToSpawn)
	if spot == nil or hp >= 0.55 then return nil end
	-- No known spawn time means no race to judge. Without this, `secsToSpawn = math.huge`
	-- (what nextBottleRuneSpawn returns when the clock is unreadable) makes every enemy on
	-- the map "arrive first" and the gate refuses everything.
	if secsToSpawn == nil or secsToSpawn == math.huge then return nil end
	local enemyDist = nearestEnemyToLoc(spot)
	if enemyDist == nil then return nil end
	local eta = math.max(0, secsToSpawn or 0)
	if enemyDist / 300.0 > eta + 1.5 then return nil end
	return string.format("enemy=%.0f eta=%.0f hp=%.0f", enemyDist, eta, hp * 100)
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

local function nearestRuneSpot(bot, now, avoidContested)
	local bestRune, bestLoc, bestDist, bestScore = nil, nil, math.huge, math.huge
	for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		local loc = GetRuneSpawnLocation(runeId)
		-- An actually-available rune on the ground is free value. Never skip it because
		-- of a stale known-empty mark -- that mark is why runes sat uncollected for
		-- minutes while the bot ignored them.
		local available = loc ~= nil and GetRuneStatus(runeId) == RUNE_STATUS_AVAILABLE
		if loc ~= nil and (available or not isRuneKnownEmpty(bot, runeId, now)) then
			local dist = GetUnitToLocationDistance(bot, loc)
			-- Water windows spawn a rune at BOTH spots; prefer the uncontested one.
			-- Small tie-break toward a rune that is actually present, but let distance
			-- dominate so the bot does not abandon farm to chase a far rune.
			-- hero-agnostic: rune contest radius is map/vision spacing, not attack reach.
			local score = dist + ((avoidContested and enemyNearLoc(loc, 700)) and 1400 or 0)
				- (available and 300 or 0)
			if score < bestScore then
				bestRune, bestLoc, bestDist, bestScore = runeId, loc, dist, score
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

local function rememberNoCloseRefusal(bot, now)
	if bot == nil then return end
	bot.aib_noCloseRuneUntil = (now or DotaTime()) + 8.0
end

function M.RecentNoCloseRefusal(bot, now)
	return bot ~= nil and bot.aib_noCloseRuneUntil ~= nil
		and (now or DotaTime()) <= bot.aib_noCloseRuneUntil
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
	bot.aib_noCloseRuneUntil = nil
end

-- Rune clock for callers OUTSIDE the rune machinery. Returns seconds until the next bottle
-- rune spawns, plus the nearest spot and its distance -- nil when there is no spot to speak of.
--
-- It exists for the fountain floor. A floor trip is a ~60 second round trip that ends in a
-- full bar; a rune is a few seconds of walking that ends in a full bar AND bottle charges
-- AND map presence. When the rune is nearly up and closer than home, walking home is simply
-- the worse of two available answers -- the user flagged three such trips at 30-34% HP in
-- 8907379308 as "almost full / no idea why it went", and deferred the fix to the rune timer
-- rather than to narrowing the floor band, precisely because the timer is the real reason.
-- ================== GROUND TRUTH: WHEN DO RUNES ACTUALLY APPEAR? ==================
-- The machinery in this file only ever looked at the rune spots when it already wanted a bottle
-- (empty bottle AND low hp/mana). So "no rune seen in the log" proves only that the bot did not
-- LOOK -- not that no rune spawned. Two matches of that non-evidence nearly convinced me to delete
-- staging outright; it is not evidence and must not be used as such.
--
-- What IS established: nextBottleRuneSpawn puts the first window at 2:00, and 1v1 mid has no rune
-- at 0:00 or 2:00 (user, 28.07). Staging is built to ARRIVE EARLY, so a fictional window becomes a
-- real walk onto an empty spot -- 1:55-1:58 and 3:48 in 8917945764, paid for in farm time.
--
-- Staging itself is worth KEEPING: arriving a few seconds before the spawn is how the spot is
-- actually contested, and it reads as the bot understanding the game. The defect is the CLOCK.
-- So: sample the truth every tick (unconditionally, unlike everything above), and let the bot
-- correct itself inside the match -- if the first modelled window comes and goes with no rune ever
-- observed, the clock is fiction in this mode and staging stops for the rest of the match. One
-- match now also prints the real schedule, so the model can be fixed from data instead of guesses.
function M.Observe(bot, now)
	if bot == nil or now == nil or now < -30.0 then return end
	bot.aib_runeSeenStatus = bot.aib_runeSeenStatus or {}
	local anyUp = false
	for _, id in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		local st = GetRuneStatus(id)
		if st == RUNE_STATUS_AVAILABLE then anyUp = true end
		if bot.aib_runeSeenStatus[id] ~= st then
			bot.aib_runeSeenStatus[id] = st
			Style.Intent(bot, "rune-ground-truth",
				string.format("id=%s status=%s t=%.0f", tostring(id), tostring(st), now), 0)
		end
	end
	if anyUp then
		bot.aib_runeEverSeenUp = true
		bot.aib_runeClockDead = nil            -- a real rune re-validates the clock
		return
	end
	-- Judge a modelled window a few seconds AFTER it should have produced something.
	-- Must start at FIRST_RUNE_SPAWN, not at 120: 2:00 legitimately has no rune in this mode, so
	-- judging it would declare the clock dead at ~2:06 and switch off staging for the real 4:00
	-- water window -- the safety net would have destroyed the behaviour it exists to protect.
	local w = math.floor(now / 120) * 120
	if w >= FIRST_RUNE_SPAWN and now - w >= 6.0 and now - w <= 8.0
		and not bot.aib_runeEverSeenUp and not bot.aib_runeClockDead then
		bot.aib_runeClockDead = true
		Style.Intent(bot, "rune-clock-dead", string.format("window=%.0f", w), 0)
	end
end

-- True once a modelled window has passed with no rune ever observed: the schedule this file
-- models is not this mode's schedule, so stop travelling on it. Travel toward a rune that is
-- actually on the ground is unaffected -- that path never consults the clock.
function M.ClockDead(bot)
	return bot ~= nil and bot.aib_runeClockDead == true
end

function M.NextSpawnEta(bot, now)
	if bot == nil or now == nil then return nil end
	if M.ClockDead(bot) then return nil end   -- do not let callers defer on a fictional spawn
	local nextSpawnAt, spawnKind = nextBottleRuneSpawn(now)
	if nextSpawnAt == nil then return nil end
	local _, loc, dist = nearestRuneSpot(bot, now, spawnKind == "water")
	if loc == nil then return nil end
	return nextSpawnAt - now, loc, dist
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
	if bot:GetItemSlotType(bSlot) ~= ITEM_SLOT_TYPE_MAIN then return false end
	local bottle = bot:GetItemInSlot(bSlot)
	local now = DotaTime()
	if bottle == nil then return false end
	if bottle:GetCurrentCharges() ~= 0 then
		bot.aib_emptyBottleSince = nil
		return false
	end
	bot.aib_emptyBottleSince = bot.aib_emptyBottleSince or now
	local killEnemy, killDist = killableEnemyNearby(bot, hp)
	if killEnemy ~= nil and bot.aib_bottleRuneTarget == nil then
		Style.Blocked(bot, diagKey, "kill_window",
			string.format("dist=%.0f ehp=%.0f hp=%.0f", killDist, J.GetHP(killEnemy) * 100, hp * 100), 3.0)
		return false
	end
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
		-- Threat abort. The old gate (hp<0.22 AND damage within 1.2s) missed the rune
		-- death-march: 8905049243 R committed at ~50%, kept re-issuing the walk through
		-- the enemy wave INTO the enemy hero at hp 31->19->8 (spell pokes >1.2s apart
		-- never coincided with the check) and died -- second death, game over. A bottle
		-- rune is sustain, not a hill to die on: abort the commit when low and either
		-- recently damaged or a living enemy hero is near the rune spot.
		local threatAbort = (hp < 0.30
				and (bot:WasRecentlyDamagedByAnyHero(3.0) or enemyNearLoc(bot.aib_bottleRuneTarget, 800)))
			or (hp < 0.22 and bot:WasRecentlyDamagedByAnyHero(1.2))
		if threatAbort then
			Style.Blocked(bot, diagKey, "threat_abort", string.format("hp=%.0f", hp*100), 4.0)
			runeResult(bot, diagKey, "abort", string.format("reason=threat hp=%.0f", hp*100), 8.0)
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
			-- hero-agnostic: gone grace is rune pickup/spot tolerance, not combat spacing.
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
			local pickedRune = bot.aib_bottleRuneId
			runeTxn(bot, "rune", "pickup", diagKey, string.format("dist=%.0f", targetDist), 30, 1.0)
			runeResult(bot, diagKey, "pickup_attempt", string.format("dist=%.0f age=%.0f", targetDist, now - bot.aib_bottleRuneStarted), 2.0)
			Style.Intent(bot, diagKey, string.format("dist=%.0f age=%.0f reason=pickup", targetDist, now - bot.aib_bottleRuneStarted), 1.0)
			if bot.Action_PickUpRune ~= nil then
				bot:Action_PickUpRune(pickedRune)
			else
				bot:Action_MoveToLocation(bot.aib_bottleRuneTarget)
			end
			clearRuneAttempt(bot)
			bot.aib_bottleRuneCooldownUntil = now + 1.5
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
	local nearestDist, nearestWaterDist = math.huge, math.huge
	-- What this scan actually read, for the refusal line at the bottom. `nearest=inf` alone
	-- cannot say whether there was no rune or whether we looked at the wrong instant, and in
	-- 8972598364 it was inf on all 62 observations across both sides while M.Observe recorded
	-- the same rune id changing status twice inside one second. Observe only logs on change, so
	-- it cannot answer for the ticks the scan ran on; this can. Two characters per rune, in a
	-- line that is already rate limited to once per 8s.
	local seenStatus = ""
	for _, runeId in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
		local status = GetRuneStatus(runeId)
		seenStatus = seenStatus .. tostring(status) .. (isRuneKnownEmpty(bot, runeId, now) and "e" or "-")
		if status == RUNE_STATUS_AVAILABLE and not isRuneKnownEmpty(bot, runeId, now) then
			local loc = GetRuneSpawnLocation(runeId)
			if loc ~= nil then
				local dist = GetUnitToLocationDistance(bot, loc)
				local runeType = GetRuneType(runeId)
				if dist < nearestDist then nearestDist = dist end
				if runeType == RUNE_WATER and dist < nearestWaterDist then nearestWaterDist = dist end
				local score = dist + ((runeType == RUNE_WATER) and 0 or 350)
				-- Critical relax: a LIVE rune just beyond the policy cap is still the best
				-- sustain a dying bot has. 8905066151 t=375+: a regen rune sat top (~3800u)
				-- while D stood at 10-16% hp -- the 2600/3600 cap hid it and the staging
				-- machinery churned cooldowns instead. At sub-25% HP with no enemy at the
				-- spot, a long walk that fully heals beats standing still.
				local allowedDist = dist <= (maxDist or 2600)
					or (runeType == RUNE_WATER and waterRecoveryAllowed(bot, hp, mana, dist, forceEmptyBottle))
					-- hero-agnostic: emergency rune trip is bounded by map travel and spot danger.
					or (hp < 0.25 and dist <= 4500 and not enemyNearLoc(loc, 900))
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
			local stageRune, stageLoc, stageDist = nearestRuneSpot(bot, now, spawnKind == "water")
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
				if waterRuneEmergency(bot, hp, mana, stageDist, spawnKind, forceEmptyBottle)
					and secsToSpawn <= Const.Rune.waterEmergencyStageWindow then
					bot.aib_bottleRuneStageBlockedWindow = nil
					bot.aib_bottleRuneStageBlockedUntil = nil
					Style.Intent(bot, "rune-stage-override", string.format("reason=water_emergency eta=%.0f dist=%.0f hp=%.0f mana=%.0f", secsToSpawn, stageDist, hp*100, mana*100), 2.0)
				else
					local reason = waterRuneEmergency(bot, hp, mana, stageDist, spawnKind, forceEmptyBottle) and "stage_too_early" or "stage_cooldown"
					Style.Blocked(bot, diagKey, reason, string.format("eta=%.0f", secsToSpawn), 4.0)
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
				-- Dead-window abort: the spawn time has already passed and NO rune is available
				-- (enemy took it / known empty -> nearestDist stays inf), yet the stage hold below
				-- keeps the bot dancing at the empty spot until aib_bottleRuneStageUntil
				-- (nextSpawnAt+7). 8903907295 W1 t=6:01-6:07: stage_hold eta=-4->-6, nearest=inf.
				-- Release the stage and block re-staging this window so lane/recovery takes the tick.
				if secsToSpawn < -1.5 and nearestDist == math.huge then
					Style.Blocked(bot, diagKey, "stage_dead_window", string.format("eta=%.0f nearest=inf", secsToSpawn), 4.0)
					bot.aib_bottleRuneStageWindow = nil
					bot.aib_bottleRuneStageUntil = nil
					bot.aib_bottleRuneStageTarget = nil
					bot.aib_bottleRuneStageClosedWindow = nextSpawnAt
					bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
					bot.aib_bottleRuneStageBlockedUntil = now + 3.0
					return false
				end
				if bot.aib_bottleRuneStageUntil ~= nil and now <= bot.aib_bottleRuneStageUntil
					and bot.aib_bottleRuneStageTarget ~= nil then
					local followDist = GetUnitToLocationDistance(bot, bot.aib_bottleRuneStageTarget)
					-- The tick that was missing in 8974058954. Everything below this point
					-- re-issues the walk unconditionally until the stage window expires, so
					-- once the trip started nothing could call it off. Ask the same two
					-- questions the departure asks; on a yes, release the stage (and block
					-- re-staging this window) so lane/recovery takes the tick instead.
					local holdUnsafe, holdDetail = tripUnsafe(bot, hp, nil)
					local holdRace = holdUnsafe == nil
						and spotRaceLost(bot, hp, bot.aib_bottleRuneStageTarget, secsToSpawn) or nil
					if holdUnsafe ~= nil or holdRace ~= nil then
						local reason = holdUnsafe or "spot_race_lost"
						bot.aib_bottleRuneStageWindow = nil
						bot.aib_bottleRuneStageUntil = nil
						bot.aib_bottleRuneStageTarget = nil
						bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
						bot.aib_bottleRuneStageBlockedUntil = now + 4.0
						Style.Blocked(bot, diagKey, reason,
							string.format("stage=hold %s", holdDetail or holdRace), 4.0)
						runeResult(bot, diagKey, "abort",
							string.format("reason=%s hp=%.0f stage=1", reason, hp * 100), 6.0)
						return false
					end
					if followDist > 120 then
						if bot.aib_bottleRuneStageFollowLast == nil or now - bot.aib_bottleRuneStageFollowLast >= 1.0 then
							bot.aib_bottleRuneStageFollowLast = now
							runeTxn(bot, "rune_stage", "stage_follow", diagKey, string.format("dist=%.0f eta=%.0f", followDist, secsToSpawn), math.max(0, secsToSpawn), 1.5)
						end
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
								-- Both water spots are up: don't race the enemy for the
								-- contested one when the other is free.
								if runeType == RUNE_WATER and enemyNearLoc(loc, 700) then
									score = score + 1400
								end
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
				if observedStage then
					bot.aib_bottleRuneStageClosedWindow = nextSpawnAt
					bot.aib_bottleRuneStageBlockedWindow = nextSpawnAt
					bot.aib_bottleRuneStageBlockedUntil = now + math.max(3.0, math.min(8.0, secsToSpawn + 1.0))
				end
				return false
			end
			if waterRuneEmergency(bot, hp, mana, stageDist, spawnKind, forceEmptyBottle) then
				stageWindow = math.min(stageWindow, Const.Rune.waterEmergencyStageWindow)
			end
			-- Travel-aware departure: leaving a 20s window for a 6s walk parks the bot
			-- at the spot for 10+ idle seconds (8882969763: left at eta=17, dist=1708,
			-- hp=99 - lost farm for nothing). Depart when travel time + buffer says so.
			-- Buffer trimmed 5->2s (user 19.07: bots leave lane ~3s too early to check the
			-- rune); still arrives ~2s before spawn, enough to stage.
			stageWindow = math.min(stageWindow, stageDist / 300.0 + 2.0)
			if stageRune ~= nil and stageLoc ~= nil and secsToSpawn >= 0 and secsToSpawn <= stageWindow and stageDist <= stageMaxDist then
				if laneAware and stageDist > 700 and hp > 0.62 and hasLastHitWindow(bot) and secsToSpawn > 5 then
					Style.Blocked(bot, diagKey, "last_hit_window", string.format("stage=1 rune=%.0f hp=%.0f eta=%.0f", stageDist, hp*100, secsToSpawn), 6.0)
					return false
				end
				local stageUnsafe, stageDetail = tripUnsafe(bot, hp, stageDist)
				if stageUnsafe ~= nil then
					Style.Blocked(bot, diagKey, stageUnsafe, string.format("stage=1 %s eta=%.0f", stageDetail, secsToSpawn), 6.0)
					return false
				end
				local stageRace = spotRaceLost(bot, hp, stageLoc, secsToSpawn)
				if stageRace ~= nil then
					Style.Blocked(bot, diagKey, "spot_race_lost", "stage=1 " .. stageRace, 6.0)
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
		-- Keep this call within three lines of the `return false` below: check_all's silent-refusal
		-- detector looks that far back for a logger and nothing further, so a fourth line of
		-- wrapping turns a named refusal into a reported silent one.
		rememberNoCloseRefusal(bot, DotaTime())
		Style.Blocked(bot, diagKey, "no_close_rune", string.format(
			"max=%.0f waterMax=%.0f nearest=%.0f water=%.0f mid=%.0f status=%s", maxDist or 2600,
			Const.Rune.waterRecoveryMaxDist, nearestDist, nearestWaterDist, midContextDistance(bot), seenStatus), 8.0)
		return false
	end

	local commitUnsafe, commitDetail = tripUnsafe(bot, hp, bestDist)
	if commitUnsafe ~= nil then
		Style.Blocked(bot, diagKey, commitUnsafe, commitDetail, 6.0)
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
