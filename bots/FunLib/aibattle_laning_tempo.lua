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

function M.PreCreepStandoff(ctx)
	local bot = ctx.bot
	local now = DotaTime()
	if now > 25 then return false end
	if now >= 0 and not bot.aib_postHornRecoveryReset then
		bot.aib_postHornRecoveryReset = true
		ctx.clearRecovery()
		ctx.state("post-horn-reset", "reason=precreep", 2.0)
	end
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
	if preMode == "aggressive_mid" and enemy ~= nil and dist <= range + 20
		and not ctx.uphillMiss(enemy) and J.GetHP(bot) >= 0.70 then
		bot:Action_AttackUnit(enemy, false)
		ctx.diag("precreep-trade")
		return true
	end
	-- Forward trades (contact = hit an enemy in range+120; close = walk to the attack edge)
	-- are for aggressive_mid ONLY. Once the standoff actually runs (anchor fix 4e2dee2), these
	-- mode-agnostic branches marched the passive FARMER to the river center to trade and it
	-- took poke 64->35% before creeps (8905381906: precreep-contact x6, precreep-close x6,
	-- loc -325,-193 -> -15,37). A passive preset holds its own-highground anchor and only ever
	-- spaces BACK; it never advances to contest pre-creep.
	local aggressive = preMode == "aggressive_mid"
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

function M.DivePolicy(ctx)
	local bot = ctx.bot
	local twr = ctx.enemyTowerDanger()
	if twr == nil then return false end
	local twrDist = GetUnitToUnitDistance(bot, twr)
	local healingSafeHit = ctx.healingChannelActive()
		and J.GetHP(bot) >= 0.45
		and not ctx.towerThreatening(twr)
		and ctx.alliedCreepsAtTower(twr, twr:GetAttackRange() + 120) >= 1
		and twrDist <= attackRange(ctx) + 80
	if ctx.healingChannelActive() and not healingSafeHit and twrDist <= twr:GetAttackRange() + 420 then
		ctx.diag("heal-no-dive")
		bot:Action_MoveToLocation(J.VectorAway(bot:GetLocation(), twr:GetLocation(), 420))
		return true
	end
	if not Style.MayDive(bot) and ctx.towerThreatening(twr) then
		ctx.diag("no-dive")
		bot:Action_MoveToLocation(J.VectorAway(bot:GetLocation(), twr:GetLocation(), 350))
		return true
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
