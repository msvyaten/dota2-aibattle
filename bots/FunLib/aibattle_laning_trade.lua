-- AIBattle laning hero-trade intents.

local M = {}

local J = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local Engine = require(GetScriptDirectory()..'/FunLib/aibattle_engine')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')

local function hasCancelableHealModifier(unit)
	if unit == nil then return false end
	return unit:HasModifier("modifier_flask_healing")
		or unit:HasModifier("modifier_bottle_regeneration")
		or unit:HasModifier("modifier_clarity_potion")
end

local function towerDanger(ctx)
	return AIBUtils.EnemyTowerDanger(ctx.bot)
end

local function towerThreat(ctx)
	return AIBUtils.IsTowerActuallyThreatening(ctx.bot, towerDanger(ctx))
end

local function isChanneling(unit)
	if unit == nil then return false end
	if unit:HasModifier("modifier_teleporting") then return true end
	local ok, res = pcall(function() return unit:IsChanneling() end)
	return ok and res == true
end

local function isKillable(bot, enemy, dials)
	if enemy == nil or not enemy:IsAlive() then return false end
	local exec = dials and dials.execute_threshold or 0
	if exec > 0 and J.GetHP(enemy) <= exec then return true end
	-- 3.0x (not 2.2x): GetAttackDamage ignores Raze/Requiem burst, so 2.2x under-counted SF's
	-- real kill range and the bot passed on winnable commits (15 kill windows -> 2 kills/match).
	-- That is an SF number, and it used to be spelled out here as a literal in shared code;
	-- Style.AttackDamageMult owns it now and still answers 3.0 for every hero that has not
	-- declared its own.
	return enemy:GetHealth() <= bot:GetAttackDamage() * Style.AttackDamageMult(bot, enemy)
end

-- One entry point for "is the ramp a reason to refuse", so this file cannot drift from the
-- laning context's answer. ctx.uphillMiss carries the under-fire exception; the raw geometry is
-- only the fallback for callers built without a ctx.
-- "Is my target standing in its own tower's range?" -- the question every chase has to ask and
-- only one of them did. towerThreat/enemyTowerDanger read where the bot IS, so a bot outside the
-- radius passes them and then walks in; this reads the DESTINATION. It was added to the
-- heal-interrupt chase (c370f42) and left there, which is the point-fix habit this project keeps
-- paying for: 8925476921 [R] t=325-340 walked 1900 units into Dire's half after an enemy on 41%
-- HP and ended up 200 units from the tower, HP 69% -> 26% on the way back out. hero-contact
-- refused with `unsafe tower=true` -- correctly, and far too late, because a different leg had
-- already done the walking.
local function chaseIntoTower(enemy)
	if enemy == nil then return false end
	local foeTower = GetTower(GetOpposingTeam(), TOWER_MID_1)
	return foeTower ~= nil and foeTower:IsAlive()
		and GetUnitToUnitDistance(enemy, foeTower) <= foeTower:GetAttackRange() + 150
end

local function uphillBlocks(ctx, enemy)
	if ctx ~= nil and ctx.uphillMiss ~= nil then return ctx.uphillMiss(enemy) end
	return AIBUtils.UphillMiss(ctx and ctx.bot or nil, enemy)
end

function M.KillLock(ctx)
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local win = Engine.KillWindow(ctx)
	if win == nil then return nil end
	local enemy = win.enemy
	if enemy == nil or not enemy:IsAlive() then return nil end
	if win.hp < 0.30 and win.dist > range + 60 and not win.mutualLow then
		return Engine.Blocked("kill-lock", 120, "self_critical", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	-- Attacking a hero in tower range draws the tower onto the bot, so a tower
	-- currently on creeps is NOT safe for a committed kill-lock (this is how the bot
	-- kept walking into a tower switch and dying). Use the aggro-aware range check.
	if AIBUtils.IsTowerActuallyThreatening(bot, towerDanger(ctx), true) then
		return Engine.Blocked("kill-lock", 90, "tower", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	-- Through the ctx owner, not the raw geometry: kill-lock is the leg that closes 800 units
	-- down to attack range, so it is precisely the one that must not refuse while we are being
	-- shot from up the ramp. 8925432161 [R] blocked it five times in that state.
	if uphillBlocks(ctx, enemy) then
		return Engine.Blocked("kill-lock", 90, "uphill", string.format("dist=%.0f hp=%.0f", win.dist, win.hp*100))
	end
	-- A kill worth walking under a tower for is a kill we can land from outside it. Finishing
	-- from where we already stand keeps its own leg below (win.dist <= range + 80).
	if win.dist > (ctx.attackRange or bot:GetAttackRange()) + 80 and chaseIntoTower(enemy) then
		return Engine.Blocked("kill-lock", 90, "chase_into_tower", string.format("dist=%.0f ehp=%.0f", win.dist, win.ehp*100))
	end
	if not win.inCommitRange then
		return Engine.Blocked("kill-lock", 90, "far", string.format("dist=%.0f max=%.0f hp=%.0f", win.dist, win.maxDist, win.hp*100))
	end

	local reason = win.mutualLow and "mutual_low_finish" or "killable_enemy"
	local priority = win.mutualLow and 145 or (win.inRange and 135 or 125)
	return Engine.Intent("kill-lock", priority, reason, function()
		-- Was AbilityExecute only, which is why a bot locked onto a killable enemy never
		-- razed. See Style.FightAbilities.
		if Style.FightAbilities(bot, enemy) then return end
		if win.dist <= range + 80 then
			bot:Action_AttackUnit(enemy, true)
			Style.Diag(bot, win.mutualLow and "mutual-low-finish-atk" or "kill-lock-atk")
		else
			if ctx.moveToAttackEdge == nil or not ctx.moveToAttackEdge(enemy, nil, 0) then return false end
			Style.Diag(bot, win.mutualLow and "mutual-low-finish-chase" or "kill-lock-chase")
		end
	end, string.format("dist=%.0f ehp=%.0f hp=%.0f exec=%s atk=%s mutual=%s",
		win.dist, win.ehp*100, win.hp*100, tostring(win.execute), tostring(win.attackKill), tostring(win.mutualLow)))
end

function M.HealInterrupt(ctx)
	local bot = ctx.bot
	local range = ctx.attackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(math.max(1100, range + 520), true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0) then return nil end
	local hp = J.GetHP(bot)
	for _, enemy in ipairs(enemies) do
		local isHeal = enemy:IsAlive() and hasCancelableHealModifier(enemy)
		if enemy:IsAlive() and (isHeal or isChanneling(enemy)) then
			local channelKey = isHeal and "heal" or (enemy:HasModifier("modifier_teleporting") and "tp" or "channel")
			local dist = GetUnitToUnitDistance(bot, enemy)
			if hp < 0.18 and dist > range + 80 and not isKillable(bot, enemy, ctx.dials or {}) then
				return Engine.Blocked("channel-interrupt", 85, "low_hp", string.format("hp=%.0f kind=%s", hp*100, channelKey))
			end
			local towerIsThreat = towerThreat(ctx)
			-- The bypass below is licensed for hitting from where we already stand -- that is
			-- the healingSafeHit case DivePolicy itself permits. But the branch reached to
			-- range+120, and those last 120 units the bot walks itself, unexamined, because
			-- towerThreat reads the CURRENT position. Codex's audit: the comment promised a
			-- standing hit and the code did not guarantee one. Inside attack range nothing
			-- moves; past it this is a small chase, and it owes the same destination question
			-- the real chase below already asks.
			local wouldStep = dist > range
			if dist <= range + 120 and (not towerIsThreat or (isHeal and hp >= 0.45))
				and not (wouldStep and chaseIntoTower(enemy)) then
				return Engine.Intent("channel-interrupt", isHeal and 150 or 132, "enemy_" .. channelKey, function()
					bot:Action_AttackUnit(enemy, true)
					Style.Diag(bot, "channel-interrupt-atk")
				end, string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
			end
			local chaseMinHp = isHeal and 0.32 or 0.45
			-- A CHASE has to ask about the destination, not about where we stand. towerThreat
			-- reads the current position, so a bot outside the radius always passed it and then
			-- walked in -- and `isHeal and hp >= 0.45` waived even that. 8924703835 [R] t~340:
			-- the enemy was healing at 26% HP, channel-interrupt won the urgent arbiter at 138,
			-- the chase carried the bot to 796 units from the enemy tower, DivePolicy logged
			-- `blocked=tower-range reason=no_licence` a tick later and tried to walk it back out
			-- -- two owners pulling opposite ways -- and HP went 91% -> 52% for one denied salve.
			-- The bypass stays on the in-range branch above on purpose: interrupting from where
			-- we already stand is exactly the healingSafeHit case DivePolicy itself permits
			-- (laning_tempo.lua:341). Walking in to do it is not the same transaction.
			if dist <= math.max(isHeal and 1050 or 900, range + (isHeal and 560 or 300))
				and not uphillBlocks(ctx, enemy)
				and hp >= chaseMinHp
				and not towerIsThreat and not chaseIntoTower(enemy) then
				return Engine.Intent("channel-interrupt", isHeal and 138 or 118, "enemy_" .. channelKey, function()
					if ctx.moveToAttackEdge == nil or not ctx.moveToAttackEdge(enemy, nil, 0) then return false end
					Style.Diag(bot, "channel-interrupt-chase")
				end, string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
			end
			return Engine.Blocked("channel-interrupt", 80, "unsafe", string.format("dist=%.0f hp=%.0f kind=%s", dist, hp*100, channelKey))
		end
	end
	return nil
end

function M.PassingHeroTrade(ctx)
	local bot = ctx.bot
	local rules = ctx.rules or {}
	local dials = ctx.dials or {}
	if (rules.hero_priority or "default") == "never" then return nil end

	local range = ctx.attackRange or bot:GetAttackRange()
	local enemies = bot:GetNearbyHeroes(range + 220, true, BOT_MODE_NONE)
	if not (enemies and #enemies > 0 and enemies[1]:IsAlive()) then return nil end

	local hp = J.GetHP(bot)
	if hp < 0.45 then
		return Engine.Blocked("hero-pass", 60, "low_hp", string.format("hp=%.0f", hp*100))
	end
	if towerThreat(ctx) then
		return Engine.Blocked("hero-pass", 60, "tower", string.format("hp=%.0f", hp*100))
	end

	local enemy = enemies[1]
	if chaseIntoTower(enemy) and GetUnitToUnitDistance(bot, enemy) > range + 80 then
		return Engine.Blocked("hero-pass", 60, "chase_into_tower", string.format("hp=%.0f", hp*100))
	end
	if uphillBlocks(ctx, enemy) then
		return Engine.Blocked("hero-pass", 60, "uphill", string.format("hp=%.0f", hp*100))
	end

	local now = DotaTime()
	local heroPrio = rules.hero_priority or "default"
	local cd = (heroPrio == "always") and 0.6 or (1.8 - 0.8 * (dials.harass_desire or 0.5))
	if bot.aib_passHeroLast ~= nil and now - bot.aib_passHeroLast < cd then return nil end

	local dist = GetUnitToUnitDistance(bot, enemy)
	if dist <= range + 50 then
		return Engine.Intent("hero-pass", 105, "nearby_enemy", function()
			bot.aib_passHeroLast = DotaTime()
			bot.aib_harassLast = DotaTime()
			bot:Action_AttackUnit(enemy, false)
			Style.Diag(bot, "hero-pass-atk")
		end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
	end

	return Engine.Intent("hero-pass", 90, "nearby_enemy", function()
		if ctx.moveToAttackEdge == nil or not ctx.moveToAttackEdge(enemy, nil, 0) then return false end
		bot.aib_passHeroLast = DotaTime()
		Style.Diag(bot, "hero-pass-chase")
	end, string.format("dist=%.0f hp=%.0f", dist, hp*100))
end

return M
