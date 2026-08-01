-- AIBattle laning tempo layer: pregame, pre-creep, dive guard, death window.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBLaneDuel = require(GetScriptDirectory()..'/FunLib/aibattle_laning_duel')

local function attackRange(ctx)
	return ctx.attackRange or ctx.bot:GetAttackRange()
end

local function hasNearbyLaneCreep(bot, list, radius)
	radius = radius or 900
	for _, creep in pairs(list or {}) do
		if J.IsValid(creep) and GetUnitToUnitDistance(bot, creep) <= radius then
			return true
		end
	end
	return false
end

local function towerLineAnchor(ctx, mode)
	local bot = ctx.bot
	local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
	local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
	if ownT1 == nil or enmT1 == nil then return nil end
	local a, b = ownT1:GetLocation(), enmT1:GetLocation()
	local totalDist = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
	if totalDist <= 1 then return nil end
	local dirX, dirY = (b.x - a.x) / totalDist, (b.y - a.y) / totalDist
	local dist
	if mode == "safe_tower" then dist = 500
	elseif mode == "aggressive_mid" then dist = totalDist * 0.45
	elseif mode == "jungle_pressure" then dist = totalDist * 0.70
	-- default (passive) pre-creep anchor: raw forwardness 0.5 put the anchor at the
	-- T1-T1 MIDPOINT = river lowground, where the bot ate uphill-advantage poke before
	-- creeps even arrived (8905027149 W1). Cap passive standoff at 0.40 = own-side
	-- highground edge; aggressive_mid keeps its 0.45 duel spot.
	else dist = totalDist * math.min((ctx.dials or {}).forwardness or 0.5, 0.40) end
	return Vector(a.x + dirX * dist, a.y + dirY * dist, a.z), totalDist, dirX, dirY
end

-- PRE-GAME PARK-AT-TOWER OVERRIDE (user, 26.07, matches 8914820239 / 8914866663).
-- Scope, corrected by the user: this is a PRE-GAME positioning override, nothing more. While
-- the match clock has not started (DotaTime < 0) BOTH bots stand next to their own T1 instead
-- of walking to the river for the pre-game staring/poke contest. The instant the timer starts
-- (DotaTime >= 0) the override releases COMPLETELY and the bots do whatever their config wants
-- -- no creep-contact handoff, no t=25 cap. (The first version capped at t<=25 and released on
-- the t=25 backstop, so the bots stood at the tower like statues until 0:25 while the creeps
-- were already fighting -- 8914866663.) Flip PRECREEP_HOLD_AT_TOWER = false to disable.
M.PRECREEP_HOLD_AT_TOWER = true

-- The pre-horn anchor, chosen ONCE and then held.
-- Nobody has levels or abilities before the horn, so there is nothing to gain by repositioning:
-- a pre-horn "duel" is bare right-clicks that decide only who enters the lane with less HP. The
-- cringe the user reported was never "the bot walked to mid" -- it was the DANCE (walk up, take
-- one poke, walk back, repeat), which came from re-deriving the position every tick. Latching the
-- point makes that dance impossible by construction, so the fix does not need to forbid anything.
--
-- Config fidelity: parking is the DEFAULT, not an override of the model's choice. An explicit
-- aggressive_mid / jungle_pressure / water_rune is a stated decision and is honored -- otherwise
-- pregame_behavior would be a dial the LLM can set and the engine ignores, which is the exact
-- failure class ("config speaks, code doesn't listen") this project keeps digging out.
-- NOTE: there are no runes at 0:00 in 1v1 mid, so "water_rune" parks the bot on an empty spawn
-- point. That is a schema/prompt question, not a code one -- the config is still obeyed here.
local function pregameAnchor(ctx)
	local bot = ctx.bot
	if bot.aib_pgAnchor ~= nil then return bot.aib_pgAnchor end
	local pgb = (ctx.rules or {}).pregame_behavior or "default"
	if pgb == "default" or pgb == "safe_tower" then pgb = "safe_tower" end
	local dest
	if pgb == "water_rune" then
		local best, minD = nil, math.huge
		for _, rid in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
			local loc = GetRuneSpawnLocation(rid)
			if loc ~= nil then
				local d = GetUnitToLocationDistance(bot, loc)
				if d < minD then minD = d; best = loc end
			end
		end
		dest = best
	else
		dest = towerLineAnchor(ctx, pgb)
	end
	if dest == nil then dest = towerLineAnchor(ctx, "safe_tower") end
	if dest ~= nil then bot.aib_pgAnchor = dest end   -- cache only a real point, never nil
	return dest
end

function M.PreCreepHold(ctx)
	if not M.PRECREEP_HOLD_AT_TOWER then return false end
	if DotaTime() >= 0 then return false end   -- timer started: full release, config owns
	local bot = ctx.bot
	-- Survival still overrides everything (parity with M.Pregame): a bot being bursted retreats.
	if ctx.surviveThink ~= nil and ctx.surviveThink(bot, ctx.dials, nil) then return true end
	local anchor = pregameAnchor(ctx)
	if anchor == nil then return false end
	if GetUnitToLocationDistance(bot, anchor) > 120 then
		bot:Action_MoveToLocation(anchor)
		ctx.diag("precreep-park")
		return true
	end
	-- Standing on the anchor. A swing at an enemy already inside attack range issues NO movement,
	-- so it cannot restart the dance -- and refusing it would silently mute hero_priority="always"
	-- / aggressive_mid, which is the licence PreEngageAllowed exists to express.
	local range = ctx.attackRange or bot:GetAttackRange()
	local enemy, dist = ctx.nearestEnemyHero(range + 150)
	if enemy ~= nil and AIBLaneDuel.PreEngageAllowed(ctx.rules)
		and AIBLaneDuel.PreHeroFreeHit(ctx, enemy, dist, range, "pregame-free-hit") then
		return true
	end
	Style.DiagRL(bot, "precreep-park-hold", 5)
	return true
end

function M.PreCreepStandoff(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now > 25 then return false end
	local range = attackRange(ctx)
	-- Yield to laning-core only once an ENEMY creep is actually last-hittable-close, not the
	-- instant any creep is within 900. Root of "Dire drifts to river lowground and tanks poke
	-- to half HP before creeps" (8905283635 W1): allied creeps spawn BEHIND the bot and march
	-- THROUGH the anchor, so the 900 ally check was true from horn -> the standoff yielded every
	-- tick and never pulled the bot to its own-highground anchor; it sat at its spawn drift
	-- point on lowground eating uphill harass until recover finally fired at 55%. Hold the
	-- anchor through the creep march; switch to CS when enemy creeps arrive in range.
	if hasNearbyLaneCreep(bot, ctx.enemyCreeps, range + 150) then return false end
	local enemy, dist = ctx.nearestEnemyHero(math.max(900, range + 320))
	local preMode = (ctx.rules or {}).pregame_behavior or "default"
	local mayEngage = AIBLaneDuel.PreEngageAllowed(ctx.rules)
	if mayEngage and enemy ~= nil and dist <= range + 20
		and not ctx.uphillMiss(enemy) and J.GetHP(bot) >= 0.70 then
		bot:Action_AttackUnit(enemy, false)
		ctx.diag("precreep-trade")
		return true
	end
	-- Forward trades (contact = hit an enemy in range+120; close = walk to the attack edge)
	-- require an explicit licence to engage pre-creep. Fully mode-agnostic they marched the
	-- passive FARMER to the river center and it took poke 64->35% before creeps (8905381906:
	-- precreep-contact x6, precreep-close x6, loc -325,-193 -> -15,37) -- a config that asked
	-- for none of that must still hold its own-highground anchor and only ever space BACK.
	-- The licence is no longer pregame_behavior alone: hero_priority="always" is an explicit
	-- "attack the enemy hero whenever you can" and grants it too. See PreEngageAllowed.
	local aggressive = mayEngage
	if aggressive and enemy ~= nil and dist <= range + 120
		and not ctx.uphillMiss(enemy) and J.GetHP(bot) >= 0.55 then
		bot:Action_AttackUnit(enemy, false)
		ctx.diag("precreep-contact")
		return true
	end
	if enemy ~= nil and dist <= math.max(820, range + 280)
		and not ctx.uphillMiss(enemy) and J.GetHP(bot) >= 0.48 then
		if dist < range * 0.62 and J.GetHP(bot) < 0.65 then
			local back = ctx.towardFountain(bot:GetLocation(), 220)
			if back ~= nil then
				bot:Action_MoveToLocation(back)
				ctx.diag("precreep-space")
				return true
			end
		end
		if aggressive and ctx.moveToAttackEdge(enemy, "precreep-close", 0) then return true end
	end

	-- Placed AFTER the space-back above so a weakened bot still gives ground first; this only
	-- covers the case where the enemy is already inside attack range and the bot would
	-- otherwise just stand there. Shared with the two duel stages -- one implementation, not a
	-- third fork of the same idea. See AIBLaneDuel.PreHeroFreeHit for why it exists.
	if AIBLaneDuel.PreHeroFreeHit(ctx, enemy, dist, range, "precreep-free-hit") then return true end

	local anchor, totalDist, dirX, dirY = towerLineAnchor(ctx, preMode)
	if anchor ~= nil then
		local ownT1 = GetTower(GetTeam(), TOWER_MID_1)
		if preMode == "aggressive_mid" then
			local a = ownT1:GetLocation()
			local anchorDist = math.min(totalDist * 0.46, totalDist - range - 250)
			anchor = Vector(a.x + dirX * anchorDist, a.y + dirY * anchorDist, a.z)
		end
		local anchorGap = GetUnitToLocationDistance(bot, anchor)
		if anchorGap <= 160 then
			-- Poke-react: the owning hold must not TANK range-edge poke. The counter-attack
			-- branches above are hp-gated (0.55/0.48) and the old space-back only fired at
			-- dist<0.62*range, so a 350-500u poke war left the bot standing while its HP
			-- melted 41->27 pre-creeps (8905049243 W1). Trade while strong (branches above);
			-- once weakened and still being hit, give ground toward the tower instead.
			local pokeReact = bot:WasRecentlyDamagedByAnyHero(1.5)
				and J.GetHP(bot) < 0.55 and enemy ~= nil
			if pokeReact or (enemy ~= nil and dist < range * 0.70) then
				local back = ctx.towardFountain(bot:GetLocation(), pokeReact and 320 or 260)
				if back ~= nil then
					bot:Action_MoveToLocation(back)
					ctx.diag("precreep-space")
					return true
				end
			end
			-- OWN the at-anchor hold. Returning false here released the tick to the rest
			-- of the pipeline; pre-creeps nothing above anti-idle can act, and anti-idle
			-- MOVES ("walk to a visible enemy") -- so the bot oscillated anchor<->enemy
			-- poke range every tick eating harass (8905027149 W1: precreep-anchor x14 vs
			-- winner=anti-idle x13). Committed-owner invariant: a positioner that placed
			-- the bot holds the tick for the episode. Standing still is the correct
			-- pre-creep behavior.
			Style.DiagRL(bot, "precreep-hold", 5)
			return true
		end
		-- Do not walk back INTO the poke we just gave ground from: while weakened and
		-- recently hit, hold the safer spot instead of re-approaching the anchor
		-- (otherwise space-back <-> anchor-return oscillates through the enemy's range).
		if J.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(2.5) then
			Style.DiagRL(bot, "precreep-hold", 5)
			return true
		end
		bot:Action_MoveToLocation(anchor)
		ctx.diag("precreep-anchor")
		return true
	end
	return false
end

function M.Pregame(ctx)
	local bot = ctx.bot
	if DotaTime() >= 0 or GetGameMode() ~= GAMEMODE_1V1MID then return false end
	-- Park-at-tower override owns the whole pre-horn window when on (single owner).
	if M.PreCreepHold(ctx) then return true end
	if ctx.surviveThink(bot, ctx.dials, nil) then return true end
	-- Two uphill retreats mean the river duel can't be taken from our side of the
	-- ramp; park at the safe pregame spot until creeps spawn instead of feeding the
	-- retreat/advance dance for the whole pregame.
	if bot.aib_pgDisengaged then
		local target = towerLineAnchor(ctx, "safe_tower")
		if target ~= nil and GetUnitToLocationDistance(bot, target) > 120 then
			bot:Action_MoveToLocation(target)
		end
		Style.DiagRL(bot, "pg-disengage", 5)
		return true
	end
	if ctx.pregameDuel ~= nil and ctx.pregameDuel() then return true end
	-- Hold the uphill-retreat anchor while the enemy is still around. Without this the
	-- tower-line anchor below pulls the bot straight back into the duel scan and the
	-- uphill-retreat cycle restarts every ~2s for the whole pregame.
	local frozen = bot.aib_pgUphillBackAnchor
	if frozen ~= nil then
		local frzRange = ctx.attackRange or bot:GetAttackRange()
		local frzEnemy = ctx.nearestEnemyHero(frzRange + 700)
		if frzEnemy ~= nil then
			if GetUnitToLocationDistance(bot, frozen) > 100 then
				bot:Action_MoveToLocation(frozen)
			end
			Style.DiagRL(bot, "pg-uphill-freeze", 5)
			return true
		end
		bot.aib_pgUphillBackAnchor = nil
	end
	Style.DiagRL(bot, "pg-pos", 5)
	local pgb = (ctx.rules or {}).pregame_behavior
	if pgb == "water_rune" then
		local runeLoc, minD = nil, math.huge
		for _, rid in ipairs({ RUNE_POWERUP_1, RUNE_POWERUP_2 }) do
			local loc = GetRuneSpawnLocation(rid)
			if loc then
				local d = GetUnitToLocationDistance(bot, loc)
				if d < minD then minD = d; runeLoc = loc end
			end
		end
		if runeLoc and GetUnitToLocationDistance(bot, runeLoc) > 100 then
			bot:Action_MoveToLocation(runeLoc)
		end
	else
		local target = towerLineAnchor(ctx, pgb)
		if target ~= nil and GetUnitToLocationDistance(bot, target) > 100 then
			bot:Action_MoveToLocation(target)
		end
	end
	return true
end

-- Exit point measured FROM THE TOWER, latched once.
-- Two separate defects lived in the old retreat legs, both fixed here:
--   1. The destination was J.VectorAway(bot:GetLocation(), ...) -- recomputed from the CURRENT
--      position on every tick, so it receded as the bot walked and Action_MoveToLocation was
--      re-issued forever. That is the exact bug class this codebase has already paid for four
--      times (f26c645, b4b24af, 39e3e6b, nearly f2d543a) and which the siege module warns about
--      sixty lines away. Visible symptom: the bot stutters near towers instead of leaving.
--   2. A fixed 350/420 offset from the BOT does not guarantee leaving the radius: standing 100
--      units from a 700-range tower and stepping 350 further out is still inside it. Anchoring
--      the point to the tower makes "outside" mean outside.
local function towerExitPoint(bot, twr, extra)
	local a, b = twr:GetLocation(), bot:GetLocation()
	local dx, dy = b.x - a.x, b.y - a.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d <= 1 then return nil end                       -- degenerate: standing on the tower
	local want = twr:GetAttackRange() + (extra or 300)
	return Vector(a.x + dx / d * want, a.y + dy / d * want, b.z)
end

local function towerExit(ctx, twr, key, extra)
	local bot = ctx.bot
	local now = DotaTime()
	if bot.aib_towerExitDest == nil or bot.aib_towerExitUntil == nil or now >= bot.aib_towerExitUntil then
		local dest = towerExitPoint(bot, twr, extra)
		if dest == nil then return false end
		bot.aib_towerExitDest = dest
		bot.aib_towerExitUntil = now + 3.0
	end
	if GetUnitToLocationDistance(bot, bot.aib_towerExitDest) > 90 then
		bot:Action_MoveToLocation(bot.aib_towerExitDest)
	end
	ctx.diag(key)
	return true
end

-- Why are we allowed to stand inside an enemy tower's radius at all?
-- Nothing used to ask. enemyTowerDanger() is evaluated at the bot's CURRENT position, so it can
-- only turn non-nil once the bot is ALREADY inside range+120, and towerThreatening() returns
-- false while the tower is shooting an allied creep. Net effect: the bot strolls in under creep
-- cover, the creep dies, the tower retargets, the poke lands -- and only then does anything
-- react. 69 movement sites issue Action_MoveToLocation and not one of them asks whether the
-- destination sits under a tower, so this is the single owner of that question.
-- The licences below are exactly the preconditions the siege module already acts on, so a
-- legitimate siege is never interrupted: wave cover == siege's own `alliedTank`, and
-- tower_aggression="always" keeps buying the right to stand and eat it.
local function towerLicence(ctx, twr)
	local rules = ctx.rules or {}
	if (rules.tower_aggression or "default") == "always" then return "tower_aggression" end
	if ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 120) >= 1 then return "wave_cover" end
	if Style.MayDive(ctx.bot) then return "dive" end
	if ctx.enemyDeadRecently() then return "enemy_dead" end   -- free window: tower dmg is a win con
	return nil
end

function M.DivePolicy(ctx)
	local bot = ctx.bot
	local twr = ctx.enemyTowerDanger()
	if twr == nil then
		bot.aib_towerExitDest = nil                      -- out of range: never reuse a stale point
		bot.aib_towerExitUntil = nil
		return false
	end
	local twrDist = GetUnitToUnitDistance(bot, twr)
	local healingSafeHit = ctx.healingChannelActive()
		and J.GetHP(bot) >= 0.45
		and not ctx.towerThreatening(twr)
		and ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 120) >= 1
		and twrDist <= attackRange(ctx) + 80
	if ctx.healingChannelActive() and not healingSafeHit and twrDist <= twr:GetAttackRange() + 420 then
		return towerExit(ctx, twr, "heal-no-dive", 420)
	end
	if not Style.MayDive(bot) and ctx.towerThreatening(twr) then
		return towerExit(ctx, twr, "no-dive", 300)
	end
	-- Standing in the radius for no reason at all: leave BEFORE the tower gets to pick us.
	local licence = towerLicence(ctx, twr)
	if licence == nil then
		ctx.blocked("tower-range", "no_licence", string.format("tower=%.0f hp=%.0f", twrDist, J.GetHP(bot) * 100), 4.0)
		return towerExit(ctx, twr, "tower-range-exit", 300)
	end
	if ctx.towerAggroDrop ~= nil and ctx.towerAggroDrop(twr) then return true end
	return false
end

local function updateEnemyDeathState(ctx)
	local bot = ctx.bot
	if bot.aib_ePID == nil then
		local allNear = bot:GetNearbyHeroes(2000, true, BOT_MODE_NONE)
		if allNear then
			for _, h in ipairs(allNear) do
				if h:IsHero() and not h:IsIllusion() then
					for pid = 0, 9 do
						if GetTeamMember(pid) == h then
							bot.aib_ePID = pid
							bot.aib_eDeathCount = GetHeroDeaths(pid)
							break
						end
					end
					if bot.aib_ePID then break end
				end
			end
		end
	end
	local eIsDead = false
	if bot.aib_ePID ~= nil then
		local deaths = GetHeroDeaths(bot.aib_ePID)
		if deaths > (bot.aib_eDeathCount or 0) then
			bot.aib_eDeathCount = deaths
			bot.aib_eDeadSince = DotaTime()
		end
		local respawnWindow = 8 + 4 * (GetHeroLevel and GetHeroLevel(bot.aib_ePID) or 1)
		eIsDead = bot.aib_eDeadSince ~= nil and DotaTime() - bot.aib_eDeadSince < respawnWindow
	end
	if GetHeroKills ~= nil then
		local ok, kills = pcall(GetHeroKills, bot:GetPlayerID())
		if ok and type(kills) == "number" then
			if bot.aib_myKillCount == nil then
				bot.aib_myKillCount = kills
			elseif kills > bot.aib_myKillCount then
				bot.aib_myKillCount = kills
				bot.aib_eDeadSince = DotaTime()
				eIsDead = true
			end
		end
	end
	return eIsDead
end

function M.DeathWindow(ctx)
	local bot = ctx.bot
	if not updateEnemyDeathState(ctx) then return false end
	Style.DiagRL(bot, "dw-active", 3)
	ctx.clearRecovery()
	if J.GetHP(bot) < 0.38 or (J.GetHP(bot) < 0.55 and bot:WasRecentlyDamagedByAnyHero(4.0)) then
		for s = 0, 5 do
			local it = bot:GetItemInSlot(s)
			if it ~= nil and it:IsFullyCastable() then
				local nm = it:GetName()
				if nm == "item_flask" then
					bot:Action_UseAbilityOnEntity(it, bot)
					ctx.diag("dw-heal")
					return true
				elseif nm == "item_tango" then
					local trees = bot:GetNearbyTrees(400)
					if trees and trees[1] then
						bot:Action_UseAbilityOnTree(it, trees[1])
						ctx.diag("dw-heal")
						return true
					end
				end
			end
		end
	end
	local range = attackRange(ctx)
	local ec = bot:GetNearbyCreeps(range + 50, true)
	if ec and #ec > 0 then
		for _, c in ipairs(ec) do
			if c:IsAlive() and J.CanBeAttacked(c) then
				bot:Action_AttackUnit(c, true)
				ctx.diag("dw-farm")
				return true
			end
		end
	end
	local twr = ctx.enemyTowerDanger()
	if twr ~= nil and J.GetHP(bot) >= 0.25 and not ctx.towerThreatening(twr) then
		if GetUnitToUnitDistance(bot, twr) <= range + 60 then
			bot:Action_AttackUnit(twr, true)
			ctx.diag("dw-tower")
			return true
		end
		if ctx.moveToAttackEdge(twr, "dw-tower-step", 30) then return true end
	end
	local dwDest = GetLaneFrontLocation(GetTeam(), ctx.assignedLane or LANE_MID, 0)
	if dwDest == nil then
		local enmT1 = GetTower(GetOpposingTeam(), TOWER_MID_1)
		if enmT1 ~= nil then dwDest = enmT1:GetLocation() end
	end
	if dwDest ~= nil and GetUnitToLocationDistance(bot, dwDest) > 150 then
		bot:Action_MoveToLocation(dwDest + RandomVector(50))
		Style.DiagRL(bot, "dw-fwd", 5)
		return true
	end
	return false
end

return M
