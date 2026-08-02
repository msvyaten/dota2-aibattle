-- AIBattle survive system: defensive_heal / regen_lane / recovery.
-- Entry: AIBSurvive.Think(bot, dials, nEnemyCreeps) returns true if action was issued.
-- Extracted from mode_laning_generic.lua to keep that file manageable.

local M = {}

local J     = require(GetScriptDirectory()..'/FunLib/jmz_func')
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')
local AIBUtils = require(GetScriptDirectory()..'/FunLib/aibattle_utils')
local Const = require(GetScriptDirectory()..'/FunLib/aibattle_constants')
local AIBRunes = require(GetScriptDirectory()..'/FunLib/aibattle_runes')

local TANGO_CD = 10.0  -- shared across all tango calls; guards re-issue while CD / modifier active
local FLASK_CD = 3.0   -- laning flask (defensiveHeal); recovery uses aib_recFlaskLast at 8s (separate context)
local BOTTLE_RUNE_MAX_DIST = Const.Rune.bottleMaxDist
local BOTTLE_RUNE_STAGE_MAX_DIST = Const.Rune.bottleStageMaxDist
local RECOVERY_RUNE_MAX_DIST = Const.Rune.recoveryMaxDist
local RECOVERY_RUNE_STAGE_MAX_DIST = Const.Rune.recoveryStageMaxDist
local WATER_EMERGENCY_STAGE_WINDOW = Const.Rune.waterEmergencyStageWindow

local function getItem(bot, name)
	local slot = bot:FindItemSlot(name)
	if slot < 0 then return nil end
	if bot:GetItemSlotType(slot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
	local it = bot:GetItemInSlot(slot)
	return (it ~= nil and it:IsFullyCastable()) and it or nil
end

local function hasItem(bot, name)
	local slot = bot:FindItemSlot(name)
	return slot >= 0 and bot:GetItemSlotType(slot) == ITEM_SLOT_TYPE_MAIN and bot:GetItemInSlot(slot) ~= nil
end

-- A consumable that is PAID FOR but has not landed in a main slot yet -- sitting in the stash,
-- riding the courier -- is sustain the bot is about to have. hasItem() only sees
-- ITEM_SLOT_TYPE_MAIN, so one tick after the purchase a just-bought salve still reads as an
-- empty bag. 8908963179 t=88 is that hole end to end: recovery-buy-critical bought salve+tango
-- at hp=29, both landed in the stash, `noSustain` was still true on the next tick, the extended
-- floor (hp<0.35) committed a fountain trip, the courier delivered the salve mid-walk, and
-- e344e49 then refused to let it be drunk (`blocked=heal-item reason=fountain_trip_committed
-- hp=38`). 200g and 40s of lane time for regen the fountain then handed out for free.
local function healInFlight(bot)
	for _, name in ipairs({ "item_flask", "item_tango", "item_tango_single" }) do
		local slot = bot:FindItemSlot(name)
		if slot >= 0 and bot:GetItemSlotType(slot) ~= ITEM_SLOT_TYPE_MAIN
			and bot:GetItemInSlot(slot) ~= nil then
			return name
		end
	end
	return nil
end

-- The TP scroll lives in the dedicated TP slot, NOT a main slot, so getItem() -- which filters
-- on ITEM_SLOT_TYPE_MAIN -- could never see it. Both TP branches in this file were therefore
-- structurally unreachable and the bot always walked home: fountain-tp-lane=0 and recovery-tp
-- absent in every match analysed (user, first report: "walked to lane on foot with a teleport").
-- Scan the full inventory the way the vendor code does (utils.GetItemFromCountedInventory, 16
-- slots), then apply the castability check that getItem() would have done.
local function getTpScroll(bot)
	local it = J.Utils.GetItemFromFullInventory(bot, "item_tpscroll")
	if it ~= nil and it:IsFullyCastable() then return it end
	return nil
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

-- Mirror of the recovery-buy guard at (a): the hp<0.22 engine floor is about to walk/TP us
-- to a fountain that heals for free, so a flask drunk now is 110g burned on the way home
-- (8906755360 t=400: hp=11% -> drank flask -> hp 11->25->47 while walking 1092,917 ->
-- 6936,6397, arrived at 100% anyway). The buy side was fixed in 543c0c1 but the CONSUME side
-- was never gated, and there are three consume sites -- hence one shared predicate.
-- Under hero fire the flask stays available: surviving the walk beats saving the gold.
local function fountainFreeHealSoon(bot, hp)
	return hp < 0.22 and not bot:WasRecentlyDamagedByAnyHero(2.0)
end

local function bottleCharges(bot)
	local bSlot = bot:FindItemSlot("item_bottle")
	if bSlot < 0 then return nil end
	if bot:GetItemSlotType(bSlot) ~= ITEM_SLOT_TYPE_MAIN then return nil end
	local bottle = bot:GetItemInSlot(bSlot)
	if bottle == nil then return nil end
	return bottle:GetCurrentCharges()
end

-- ============================ FOUNTAIN TRIP: ONE OWNER ============================
-- The latch had thirteen write sites across six functions and no owner, which is why every
-- fix to it has been a patch on one path while the same hole stayed open on the others:
-- e344e49 guarded the vendor salve, 3a93287 the floor's own decision, 4dd47d5 the bottle,
-- and each time the next match found another route in. Worse, the release logic b6d0642
-- added lived in recovery() -- FOURTH in M.Think, behind fountainRecovery() -- so from the
-- day it was written a latched trip made it unreachable: fountainRecovery returns true every
-- tick and nothing below it ever runs again. 8909768486 [D] is that in one trace:
-- `blocked=fountain-floor reason=heal_in_hand` at t=41 and t=46, then the trip latches and
-- the line never appears again while the bot walks 9245 -> 102 units with tangos in the bag,
-- regenerating 16% -> 50% on the way and arriving at 81%. Thirty-five seconds of lane and
-- the whole XP lead, for the last stretch of a bar that was filling itself.
--
-- So: every release condition lives HERE, and reviewFountainTrip runs at the top of Think
-- before any handler can claim the tick. Adding a new reason to abandon a trip means adding
-- one clause to one function, and it cannot be shadowed by ordering.

-- Above this the bot is out of every recovery band, so a trip has nothing left to fix.
-- Same number as AIBLanePolicy.Hp.softRecovery; kept local to avoid a require cycle.
local TRIP_DONE_HP = 0.55

-- Below this a held consumable is NOT a substitute for the fountain, so neither the entry guard
-- nor the abort clause may use one to keep the bot out in the lane. A tango is ~130 HP over 16
-- seconds spent standing in front of a healthy enemy; the walk home returns a full bar.
-- ONE constant for BOTH sites on purpose: the rule lived twice, with two different floors (abort
-- at 0.25 after the first fix, entry still at 0.12), and 8918941695 released the trip at hp=13
-- through the site that had not been changed. Same shape as the salve/flask/bottle chase --
-- fixing the path whose signature you happened to be looking at is not fixing the rule.
local HEAL_INSTEAD_OF_FOUNTAIN_HP = 0.25

-- "Is THIS item's own regeneration already running on me?" -- one owner, one item at a time.
-- Dota overwrites only the SAME consumable: a second salve replaces the first and throws away
-- whatever was left of it, but a salve and a tango run in parallel because they are different
-- modifiers. So the test has to be per item type. My first version of this asked one global
-- "am I healing at all", which fixed the real bug and introduced a new one -- it would have
-- refused to drink a salve while a tango ticked, which is legal and correct play. User caught
-- it before it ever reached a match.
--
-- The bug it exists for: the only guard at the consume sites was a three second cooldown, and
-- a salve heals over SIXTEEN. Three seconds in it has delivered about 75 of its 400, HP is
-- still under the 0.40 gate, the cooldown has expired -- so the bot drinks the next one over
-- the top of a channel with thirteen seconds of healing left in it. A bot holding three empties
-- all three in six seconds and buys the value of one. 8925401611 [D] around 7:00 is that, and
-- it cost 200 gold out of a 619 gold deficit on a bot that died at 7:06.
--
-- The project already knew the test -- fountainTripDoneReason and canHealHere both read these
-- modifiers to decide whether a fountain trip is still needed. It was simply never applied at
-- the sites that spend the item.
local HEAL_MODIFIER = {
	item_flask = "modifier_flask_healing",
	item_tango = "modifier_tango_heal",
	item_tango_single = "modifier_tango_heal",
	item_bottle = "modifier_bottle_regeneration",
	item_clarity = "modifier_clarity_potion",
}

local function sameHealTicking(bot, itemName)
	local mod = HEAL_MODIFIER[itemName]
	return mod ~= nil and bot:HasModifier(mod)
end

local function holdsHeal(bot, charges)
	return hasItem(bot, "item_flask")
		or hasItem(bot, "item_tango") or hasItem(bot, "item_tango_single")
		or (charges ~= nil and charges > 0)
end

-- ONE test for "a rune is worth the detour", used by both the release side and the floor.
-- 434f802 raised this from a bare hp>=0.22 to hp>=0.35 + no damage in 2s + no living enemy in
-- 1200, after a bot abandoned the walk home at a quarter of its health, headed for the river with
-- a healthy enemy still in the lane, and was finished on the way. But it only changed the copy
-- inside fountainTripDoneReason; the floor below kept its own copy and went on deferring at 22%
-- under fire. Same shape as the heal_in_hand pair (3a73f9c) -- fixing the site whose signature
-- you happen to be reading is not fixing the rule.
local function runeBeatsFountain(bot, hp)
	if hp < 0.35 or bot:WasRecentlyDamagedByAnyHero(2.0) then return nil end
	local eta, loc, dist = AIBRunes.NextSpawnEta(bot, DotaTime())
	if eta == nil or eta > 25.0 or eta <= -10.0 then return nil end
	if dist >= bot:DistanceFromFountain() then return nil end
	local foes = bot:GetNearbyHeroes(1200, true, BOT_MODE_NONE)
	if foes ~= nil and #foes > 0 and foes[1]:IsAlive() then return nil end
	return eta, loc, dist
end

-- One place to START a trip, mirroring releaseFountainTrip. Until now the latch had a release
-- owner and five commit sites, which is how the two ends came to test different things: the floor
-- committed a trip *because* an enemy was hitting the bot (a held salve cannot be drunk under
-- fire), and the release fired two seconds later *because* walking away had stopped the hitting.
-- The trip's own success destroyed the condition that started it. 8924633108 [D] ran that loop
-- five times and turned around at 6251, 6201 and 6252 units from home on three consecutive trips
-- -- the distance is not a decision, it is however far the bot gets before the 2s damage timer
-- expires. Recording what it was carrying at commit time lets the release side tell "I bought
-- sustain while walking" (new information, abort) from "I was already carrying it" (then the trip
-- should never have started, and reversing it mid-way spends the walk twice).
local function commitFountainTrip(bot, floor, heldHealNow)
	if not (bot.aib_fountainTrip or bot.aib_fountainFloorTrip) then
		bot.aib_fountainTripHeldHeal = (heldHealNow == true)
	end
	bot.aib_fountainTrip = true
	if floor then bot.aib_fountainFloorTrip = true end
end

local function releaseFountainTrip(bot, reason, detail)
	-- All three fields, always. b4b24af was caused by a release site that cleared one of
	-- three and left the others to reanimate the behaviour a tick later.
	bot.aib_fountainTrip = false
	bot.aib_fountainFloorTrip = false
	bot.aib_fountainFullSince = nil
	bot.aib_fountainTripHeldHeal = nil
	Style.DiagRL(bot, "fountain-trip-release", 3)
	Style.Blocked(bot, "fountain-floor", reason, detail or "", 5.0)
end

-- Returns a reason string when a committed trip should be abandoned, nil to keep walking.
-- Pure: reads state, issues no actions, so it is safe to call before the handler chain.
local function fountainTripDoneReason(bot, hp, charges, inFlight, flightFresh)
	local healing = bot:HasModifier("modifier_flask_healing")
		or bot:HasModifier("modifier_tango_heal")
	local hitRecently = bot:WasRecentlyDamagedByAnyHero(2.0)
	-- Below 12% the walk itself is in doubt; the fountain stays the right answer whatever
	-- else is true.
	if hp < 0.12 then return nil end

	-- 1. The cure is in the bag (b6d0642), or paid for and arriving (3a93287).
	local heldHeal = holdsHeal(bot, charges)
	-- ...but only when the cure is NEWS. A salve that was already in the bag when the trip was
	-- committed cannot be a reason to abandon it: if carrying it were sufficient, the trip would
	-- never have started. This is the user's 21.07 rollback ("a committed floor trip runs to
	-- COMPLETION") applied to the one input it did not cover -- it forbade turning around because
	-- passive regen topped the bar up, while the flask test went on turning the bot around anyway.
	local healIsNews = heldHeal and bot.aib_fountainTripHeldHeal ~= true
	-- ...and only while a consumable can still do the job. At 16-20% HP it cannot: a tango is
	-- ~130 HP over 16 seconds, spent standing in the lane in front of a healthy enemy, whereas the
	-- walk home returns a full bar. 8918007804 released the trip at hp=34, 20 and 16 and the user
	-- watched the bot leave for the fountain and come back still hurt -- "it needed to go one way
	-- or the other". Below this the fountain is simply the right answer, so the trip runs.
	if (healIsNews or flightFresh) and hp >= HEAL_INSTEAD_OF_FOUNTAIN_HP and not hitRecently and not healing then
		return healIsNews and "heal_in_hand" or "heal_in_flight",
			string.format("hp=%.0f inflight=%s", hp * 100, tostring(inFlight))
	end

	-- 2. The bar filled itself on the way. This does NOT reopen the user's 21.07 rollback:
	-- its stated reason was that a trip also restores MANA and BOTTLE CHARGES, which an HP
	-- test cannot see -- so this clause fires only when there is nothing else to collect.
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	if hp >= TRIP_DONE_HP and (charges == nil or charges >= 3) and mana >= 0.50
		and not hitRecently then
		return "recovered_en_route",
			string.format("hp=%.0f mana=%.0f bottle=%s", hp * 100, mana * 100, tostring(charges))
	end

	-- 3. A rune is nearly up and closer than home (4b). Releasing is enough -- the floor
	-- re-decides next tick and its rune branch takes over from there.
	-- The 0.22 floor was far too low and there was no threat test at all: 8918007804 turned this
	-- trip around at hp 32, 29, 26 and 22, and one of those turns is the death the user watched at
	-- ~4:00 -- the bot abandoned the walk home at a quarter of its health, headed for the river
	-- with a healthy enemy still in the lane, and was finished on the way. A rune is regen worth
	-- detouring for only if the detour is survivable, so it now needs enough health to eat a hit
	-- en route, no damage in the last two seconds, and no living enemy hero in sight.
	local runeEta, _, runeDist = runeBeatsFountain(bot, hp)
	if runeEta ~= nil then
		return "rune_due", string.format("hp=%.0f eta=%.0f rune=%.0f", hp * 100, runeEta, runeDist)
	end
	return nil
end

local function reviewFountainTrip(bot)
	if not (bot.aib_fountainTrip or bot.aib_fountainFloorTrip) then return end
	if hasFountainAura(bot) then return end          -- already there; let it top off
	if bot.aib_fountainTping then return end         -- mid-channel, do not disturb
	local hp = J.GetHP(bot)
	local inFlight = healInFlight(bot)
	if inFlight == nil then
		bot.aib_healFlightSince = nil
	elseif bot.aib_healFlightSince == nil then
		bot.aib_healFlightSince = DotaTime()
	end
	local flightFresh = inFlight ~= nil and DotaTime() - (bot.aib_healFlightSince or 0) < 25.0
	local reason, detail = fountainTripDoneReason(bot, hp, bottleCharges(bot), inFlight, flightFresh)
	if reason ~= nil then releaseFountainTrip(bot, reason, detail) end
end
-- =================================================================================

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
	bot.aib_fountainFloorTrip = false
	bot.aib_fountainTping = false
	bot.aib_fountainTpCast = nil
	bot.aib_fountainWaitLast = nil
	bot.aib_fountainFullSince = nil
	bot.aib_fountainBottleLast = nil
	bot.aib_recWaitStart = nil
	bot.aib_recWaitDest = nil
	bot.aib_recWaitKind = nil
	bot.aib_recMoveLast = nil
	bot.aib_recBottleLast = nil
	bot.aib_recFlaskLast = nil
	AIBRunes.Reset(bot)
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
		if bot:HasModifier("modifier_teleporting") then
			Style.DiagRL(bot, "fountain-tp-hold", 3); return true
		end
		if DotaTime() - (bot.aib_fountainTpCast or 0) < 1.0 then
			Style.DiagRL(bot, "fountain-tp-hold", 3); return true
		end
		bot.aib_fountainTping = false
	end
	local hp = J.GetHP(bot)
	local maxMana = bot:GetMaxMana()
	local mana = maxMana > 0 and (bot:GetMana() / maxMana) or 1.0
	local charges = bottleCharges(bot)
	local bottleNotFull = charges ~= nil and charges < 3
	local nearBase = bot:DistanceFromFountain() < 2600
	local inFountain = hasFountainAura(bot)
	-- fountainRecovery must NOT initiate or SUSTAIN a trip from lane.
	-- obs 8905797602 t~300 killed the nearBase self-init. obs 8906495087 t=154-179 showed the
	-- rest of the class: aib_fountainTrip is set by this function itself (below), and it only
	-- clears once hp>=0.98 AND mana>=0.90 -- but a raze-spamming SF is never at 90% mana, so the
	-- latch never opened and the bot kept walking home. Trace: hp 28%->100% (flask landed) while
	-- loc marched 1730,1499 -> 6928,6372, fountain-wait=37 with trip_init=0.
	-- Fix: only a floor/config-initiated trip (aib_fountainFloorTrip) survives away from base.
	-- A self-issued top-off is confined to the fountain aura or the base area, and the latch is
	-- dropped the moment the bot is out in the lane.
	local floorTrip = bot.aib_fountainFloorTrip == true
	if not (inFountain or floorTrip or (bot.aib_fountainTrip and nearBase)) then
		if bot.aib_fountainTrip then
			bot.aib_fountainTrip = false
			bot.aib_fountainFullSince = nil
			Style.DiagRL(bot, "fountain-latch-drop", 5)
		end
		if nearBase and (hp < 0.98 or mana < 0.90 or bottleNotFull) then
			Style.DiagRL(bot, "fountain-init-skip", 5)
		end
		return false
	end
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
	-- bottleNotFull no longer forces a fountain wait: the bottle refills instantly in the
	-- fountain aura and via rune/courier in lane, and gating the wait on it kept the bot looping
	-- here so it never reached the TP-back below -> it walked home on foot.
	-- Mana alone must NEVER drive the walk: SF sits at 40-80% mana permanently, so `mana<0.90`
	-- as a trip reason meant "always go home" (8906495087). Mana tops off only while already
	-- standing in the aura; out on a floor trip only HP keeps the walk alive.
	-- ROLLBACK (user, 21.07): a committed floor trip runs to COMPLETION. Turning the bot around
	-- mid-way because a flask or passive regen topped its HP back up is wrong -- the engine
	-- already decided it needed to go home, and the trip also restores mana and bottle charges,
	-- which the HP test does not see. Only a self-issued top-off stays subject to the hp/mana
	-- test (and that one is already confined to the fountain/base area by the entry gate).
	if hp < 0.98 or (mana < 0.90 and inFountain) or (floorTrip and not inFountain) then
		bot.aib_fountainFullSince = nil
		if bot.aib_fountainWaitLast == nil or DotaTime() - bot.aib_fountainWaitLast >= 1.0 then
			bot.aib_fountainWaitLast = DotaTime()
			commitFountainTrip(bot, false, holdsHeal(bot, charges))
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
	bot.aib_fountainFloorTrip = false
	bot.aib_fountainFullSince = nil

	local tp = getTpScroll(bot)
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

-- Rune transaction logic lives in FunLib/aibattle_runes.lua.

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
		and not sameHealTicking(bot, "item_flask")
		and not fountainFreeHealSoon(bot, hp)
		and not (bot:WasRecentlyDamagedByAnyHero(0.5) or bot:WasRecentlyDamagedByCreep(0.5)) then
		local flask = getItem(bot, "item_flask")
		if flask then
			bot.aib_flaskLast = DotaTime()
			Style.Diag(bot, "heal-item")
			bot:Action_UseAbilityOnEntity(flask, bot)
			return true
		end
	end

	if AIBRunes.SeekBottleRune(bot, hp, mana, "bottle-rune", BOTTLE_RUNE_MAX_DIST, {
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
		if safe and not sameHealTicking(bot, "item_clarity") then
			local clarity = getItem(bot, "item_clarity")
			if clarity then
				bot.aib_manaLast = DotaTime(); Style.Diag(bot, "mana-clarity")
				bot:Action_UseAbilityOnEntity(clarity, bot); return true
			end
		end
	end

	-- 9. Flask at lower threshold -- not gated by healReady so tango/wand use doesn't block it.
	-- At critical HP (< 0.30) bypass recent-damage check (channel gets cancelled but worth trying).
	if hp < 0.40 and not sameHealTicking(bot, "item_flask")
		and (bot.aib_flaskLast == nil or DotaTime() - bot.aib_flaskLast >= FLASK_CD) then
		local flask = getItem(bot, "item_flask")
		if flask and fountainFreeHealSoon(bot, hp) then
			Style.Blocked(bot, "heal-item", "fountain_floor_free_heal", string.format("hp=%.0f", hp*100), 8.0)
			flask = nil
		end
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
	local holdThresh = Style.LowHpHoldThreshold()
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
		if bSlot >= 0 and bot:GetItemSlotType(bSlot) == ITEM_SLOT_TYPE_MAIN then
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
					if AIBRunes.SeekBottleRune(bot, hp, mana, "recovery-rune-bottle", RECOVERY_RUNE_MAX_DIST, {
						lane_aware = false,
						force_empty_bottle = true,
						stage_upcoming = true,
						stage_window = WATER_EMERGENCY_STAGE_WINDOW,
						stage_max_dist = RECOVERY_RUNE_STAGE_MAX_DIST,
					}) then return true end
					if hp < 0.65 or mana < 0.45 then
						recoveryPlan(bot, "lane", "empty_bottle_no_rune", string.format("hp=%.0f mana=%.0f", hp*100, mana*100), 8.0)
					else
						Style.DiagRL(bot, "empty-bottle-ok", 8)
					end
					-- Release the recovery wait so laning resumes -- but only once the bot has
					-- ARRIVED. This used to clear aib_recWaitStart every tick, and "empty
					-- bottle above 24% HP" is the chronic state (bottle_empty runs 50-80% in
					-- every match), so it fired continuously. Path (e) re-arms the latch
					-- whenever start is nil and re-derives aib_recWaitDest from the MOVING
					-- enemy creep centroid, so the bot re-issued a move to a slightly
					-- different point every 1.5s: 8906755360 t=379-390 (D, user window
					-- "twitched under its own tower"), hp 29-39%, state-recover-xp dist=411
					-- then 930, arbiter winner cycling visual-hold:20 / anti-idle:2 /
					-- idle-heal:46 / creep-work:38, and recovery-timeout never fired once in
					-- the entire match -- the 10s latch it guards was being reset under it.
					-- Every other release site clears all three fields; this one cleared one,
					-- which is what let the destination drift while the episode "continued".
					if hp >= 0.24 and (bot.aib_recWaitDest == nil
						or GetUnitToLocationDistance(bot, bot.aib_recWaitDest) <= 220) then
						bot.aib_recWaitStart = nil
						bot.aib_recWaitDest = nil
						bot.aib_recWaitKind = nil
					end
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
		if flask and fountainFreeHealSoon(bot, hp) then
			Style.Blocked(bot, "recovery-flask", "fountain_floor_free_heal", string.format("hp=%.0f", hp*100), 8.0)
			flask = nil
		end
		if flask and sameHealTicking(bot, "item_flask") then
			Style.Blocked(bot, "recovery-flask", "already_healing", string.format("hp=%.0f", hp*100), 4.0)
			flask = nil
		end
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
		local enemyDeadWindow = bot.aib_eDeadSince ~= nil and DotaTime() - bot.aib_eDeadSince < 24.0
		if hp < postFightBack
			and bot:WasRecentlyDamagedByAnyHero(8.0)
			and not (enemyDeadWindow and hp >= Const.Recovery.earlyLowHp)
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
	if hp >= threshold then
		bot.aib_recWaitStart = nil
		bot.aib_recWaitDest = nil
		bot.aib_recWaitKind = nil
		return false
	end

	local behavior = Style.Get().rules.low_hp_behavior or "tp_fountain"
	local gold     = bot:GetGold()

	-- a. Buy flask + courier (rate-limited 15s)
	-- Don't buy sustain the fountain is about to give away for free (user rule, 21.07): the
	-- buy at (a) runs BEFORE the hp<0.22 fountain floor at (d2), so a bot that is already
	-- going home was spending 110g per flask on the way -- 3 flasks per side in 8906537715
	-- while bottle_empty FAILed at 57/58 (the flask-loop that starves the bottle). If the
	-- floor is going to fire anyway and nobody is hitting us, walk home and heal for free.
	-- Under hero fire the buy stays available: surviving the walk beats saving the gold.
	-- NOTE: must NOT return here -- the floor lives further down in this same function, so an
	-- early return would stop the trip as well as the buy. Skip only the purchase block.
	-- ...but only while that is still a prediction and not a wish. The guard defers to a floor
	-- that has not run yet, and 8925573332 [D] is what happens when the floor never gets there:
	-- low_hp_behavior=regen_lane sends the tick into the water-rune branch, which returned
	-- `blocked` every tick because no rune was up, so the walk home never started. The bot stood
	-- at (912,998) from t=975 to t=995 between 1% and 12% HP with 1478 gold in the bag, refusing
	-- to buy a 110 gold salve because something else was supposedly about to save it. The buy
	-- waits on the floor, the floor waits on the rune, and the rune has nothing.
	-- So the deferral is now time-boxed: it holds while the floor plausibly just has not had its
	-- tick yet, and expires once the bot has been in the band long enough that the prediction is
	-- simply false. Two seconds is a floor that fires every tick when it fires at all.
	if hp < 0.22 then
		if bot.aib_floorDeferSince == nil then bot.aib_floorDeferSince = DotaTime() end
	else
		bot.aib_floorDeferSince = nil
	end
	local floorDeferFresh = bot.aib_floorDeferSince == nil
		or DotaTime() - bot.aib_floorDeferSince < 2.0
	local floorWillSendHome = hp < 0.22 and not bot:WasRecentlyDamagedByAnyHero(2.0)
		and floorDeferFresh
	if floorWillSendHome and not hasItem(bot, "item_flask") then
		Style.Blocked(bot, "recovery-buy", "fountain_floor_free_heal", string.format("hp=%.0f gold=%d", hp*100, gold), 8.0)
		Style.DiagRL(bot, "buy-skip-fountain-floor", 5)
	end
	if gold >= 55 and not floorWillSendHome
		and (bot.aib_recBuyLast == nil or DotaTime() - bot.aib_recBuyLast >= 15.0) then
		if hasItem(bot, "item_flask") then
			Style.Blocked(bot, "recovery-buy", "flask_in_inventory", string.format("hp=%.0f", hp*100), 8.0)
			return false
		end
		-- Critical-stuck escape (8884639175 t=410-436): the bot froze at its anchor for
		-- ~26s at 26-29% HP while its tower was sieged, with 136 idle gold, because
		-- budget_cap AND bottle-gold-protect both blocked the one buy that would un-stick
		-- it (no bottle charge, no reachable rune, no second TP). When in-lane sustain is
		-- genuinely exhausted, survival > saving: allow ONE flask past both caps. Cannot
		-- runaway -- each buy spends gold and the 15s rate limit above still holds.
		local charges = bottleCharges(bot)
		local criticalStuck = hp < 0.30
			and (charges == nil or charges <= 0)
			and gold >= itemCost("item_flask")
			and not bot:HasModifier("modifier_flask_healing")
		if not criticalStuck then
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
		end
		bot.aib_recBuyLast = DotaTime()
		bot.aib_recBuyCount = (bot.aib_recBuyCount or 0) + 1
		bot.aib_recBuySpent = (bot.aib_recBuySpent or 0) + itemCost("item_flask")
		recoveryPlan(bot, "buy_flask", criticalStuck and "critical_stuck" or "critical", string.format("hp=%.0f gold=%d count=%d", hp*100, gold, bot.aib_recBuyCount or 0), 2.0)
		bot:ActionImmediate_PurchaseItem("item_flask")
		Style.Diag(bot, criticalStuck and "recovery-buy-critical" or "recovery-buy")
		return true
	end

	-- b. TP to fountain -- tp_fountain ONLY.
	-- walk_fountain is defined as "no TP escape; walk to own fountain on foot" (style.lua:86):
	-- a fountain trip pre-chosen by the rule must stay a walk. It used to be lumped in here,
	-- which was latent only because the TP branch was unreachable (getItem filtered on
	-- ITEM_SLOT_TYPE_MAIN while the scroll lives in the TP slot); edd7a44 made that branch live,
	-- so walk_fountain would have started teleporting. mode_retreat_generic.lua:839 already
	-- walks correctly -- this was the single divergent site. Falls through to (c) below.
	local tp = getTpScroll(bot)
	if tp and behavior == "tp_fountain" then
		commitFountainTrip(bot, true, holdsHeal(bot, bottleCharges(bot)))
		-- Same channel claim as the floor branch below: without it fountainRecovery cancels
		-- this TP with its own move order on the next tick.
		bot.aib_fountainTping = true
		bot.aib_fountainTpCast = DotaTime()
		recoveryPlan(bot, "tp_fountain", "critical", string.format("hp=%.0f", hp*100), 2.0)
		Style.Diag(bot, "recovery-tp"); bot:Action_UseAbility(tp); return true
	end

	-- c. Walk to fountain (walk_fountain, or tp_fountain with no scroll)
	if behavior == "walk_fountain" or (behavior == "tp_fountain" and not tp) then
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			commitFountainTrip(bot, true, holdsHeal(bot, bottleCharges(bot)))
			recoveryPlan(bot, "walk_fountain", "no_tp", string.format("hp=%.0f", hp*100), 2.0)
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- d. Water rune (regen_lane only)
	if behavior == "regen_lane" then
		local now = DotaTime()
		local bestRune, bestLoc, bestDist = AIBRunes.FindWaterRecoveryRune(bot, hp, mana, now)
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

	-- d2. Engine survival floor (beats the regen_lane config -- same principle as
	-- MayDive/concede): regen_lane has NO fountain leg, so a bot with zero sustain at
	-- 5-22% HP bought a flask and stood under its tower waiting for the courier for 30s
	-- (8905066151 t=252-285, user: "he could just TP to base and heal"). When in-lane
	-- sustain is exhausted and HP is critical, go to the fountain regardless of style:
	-- TP if the scroll is up and we are not being hit (channel would break), else walk
	-- (walking toward the fountain is also the flee direction).
	-- Extended floor (obs 8905797602 t=446, user "back-and-forth under the tower"): 22-35% HP with an
	-- empty bottle, no active flask/tango heal, and its per-life flask budget already spent has
	-- NO in-lane way to recover -- path (e) below just paces it back-and-forth under the tower.
	-- Commit to the fountain instead of pacing (same engine-over-config principle as the hp<0.22
	-- floor). Tightly gated: a bot with a bottle charge, mid-heal, or an affordable flask never
	-- reaches here (paths a/d handle it first), so farm is not regressed.
	-- `recBuyCount >= 2` was a proxy for "cannot buy sustain any more", and it is a LAGGING
	-- one: the counter is per-life (reset at :181), so after a death the bot has to spend two
	-- flasks before the extended floor can fire -- by which point it has already fallen through
	-- hp<0.22 and the plain floor owns the tick. That is why no_sustain_floor read 0 for five
	-- matches straight: not "the window never opened" but "the gate always arrives late".
	-- 8906755360 life 2 is the proof: recBuyCount hit 2 at t~388 and hp was under 0.22 by t=395.
	-- Ask the real question instead -- is there ANY sustain, held or purchasable, right now.
	-- All three added clauses are pure reads (no Style.Blocked side effects), so this cannot
	-- double-log against the buy block above.
	local fcharges  = bottleCharges(bot)
	local cannotBuyFlask = (bot.aib_recBuyCount or 0) >= 2
		or gold < itemCost("item_flask")
		or (wantsBottleFromStyle(bot) and hp >= 0.22)   -- gold is reserved for the bottle
	-- "Is there a cure in the bag" is holdsHeal, and this test has to use it. It used to check the
	-- tango MODIFIER (already drinking) but not the tango ITEM, so a bot carrying two tangos
	-- counted as having no sustain at all. That is the other half of the turn-around loop: the
	-- extended floor committed the trip at hp<0.35 as "no sustain", and the release side -- which
	-- does count tangos -- cancelled the same trip as "heal_in_hand" a few seconds later. Two
	-- tests for one question, disagreeing, on the two ends of one latch.
	local noSustain = not holdsHeal(bot, fcharges)
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_tango_heal")
		and cannotBuyFlask
	-- A trip is a ~60 second round trip. It is only worth it when the bot genuinely cannot heal
	-- where it stands. Holding a flask while walking home is the worst of both -- and that is
	-- exactly what 8908439030 produced twice (user: "he did not need to go, he has two flasks
	-- and the wave is under his own tower"): the extended floor fired at hp~26 with an empty
	-- bag, the trip latched, recovery-buy then bought a flask at hp=31 (its own guard only
	-- covers hp<0.22, so it does not know the floor reaches 0.35), and e344e49 then refused to
	-- let that flask be drunk because a trip was committed. Net result: 110g spent, flask
	-- carried home unused, 60 seconds of lane time gone.
	-- So: if the bot can heal itself right here and nothing is hitting it, it must not walk.
	-- This is narrow on purpose and does NOT reopen the 21.07 rollback, which was about
	-- aborting a trip because passive regen happened to top the bar back up. Here the bot is
	-- holding the cure and being told to walk past it.
	local heldHeal = hasItem(bot, "item_flask")
		or hasItem(bot, "item_tango") or hasItem(bot, "item_tango_single")
		or (fcharges ~= nil and fcharges > 0)
	-- Sustain in transit counts as sustain: the bot paid for it, so the answer to "can I heal
	-- where I stand" is yes, in a few seconds. Bounded on purpose -- an item nobody is
	-- delivering (no courier, courier dead) must not suppress the floor forever, so the
	-- suppression expires and the bot goes home the moment delivery stops being plausible.
	local inFlight = healInFlight(bot)
	if inFlight == nil then
		bot.aib_healFlightSince = nil
	elseif bot.aib_healFlightSince == nil then
		bot.aib_healFlightSince = DotaTime()
	end
	local flightFresh = inFlight ~= nil and DotaTime() - (bot.aib_healFlightSince or 0) < 25.0
	local canHealHere = (heldHeal or flightFresh)
		and not bot:WasRecentlyDamagedByAnyHero(2.0)
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_tango_heal")
	if canHealHere and hp >= HEAL_INSTEAD_OF_FOUNTAIN_HP then
		-- Entry guard only: this decides whether to START a trip. Abandoning one already
		-- running belongs to reviewFountainTrip, which runs before the chain and therefore
		-- cannot be shadowed by an owner above it.
		releaseFountainTrip(bot, heldHeal and "heal_in_hand" or "heal_in_flight",
			string.format("hp=%.0f flask=%s inflight=%s", hp*100,
				tostring(hasItem(bot, "item_flask")), tostring(inFlight)))
	end

	-- The bot is holding the cure and the ONLY thing between it and drinking is that something is
	-- hitting it right now. Walking home does fix that -- which is exactly the trap: contact
	-- breaks after a few hundred units, canHealHere flips true, and the trip is released four
	-- thousand units from where the fight was. 8924633108 [D] paid ~30 seconds of lane per cycle
	-- for a salve it could have drunk one step behind its own creeps, and finished with 13 last
	-- hits to Radiant's 44. The short version has to be written down, or the fountain keeps
	-- getting used as a way to break contact.
	-- Narrow on purpose: only reached with a heal actually in the bag and above the band where a
	-- consumable can still do the job, so a bot with nothing to drink falls through to the floor
	-- below unchanged, and one that is already mid-heal is not interrupted.
	if not canHealHere and (heldHeal or flightFresh) and hp >= HEAL_INSTEAD_OF_FOUNTAIN_HP
		and not bot:HasModifier("modifier_flask_healing")
		and not bot:HasModifier("modifier_tango_heal")
		and not (bot.aib_fountainTrip or bot.aib_fountainFloorTrip) then
		local away = xpRecoveryLoc(bot, nEnemyCreeps, hp)
		if away ~= nil then
			if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 1.5 then
				bot.aib_recMoveLast = DotaTime()
				Style.Diag(bot, "heal-break-contact")
				recoveryPlan(bot, "break_contact", "heal_in_hand",
					string.format("hp=%.0f", hp * 100), 2.0)
				bot:Action_MoveToLocation(away)
			end
			return true
		end
	end

	-- The trip is off because the cure is on its way -- and then nobody decided what to do for
	-- the forty seconds until it lands. 8925401611 [D] spent 5:50 to 6:46 at 19-36% HP in the
	-- contested half of the lane: not fighting, not farming (last hits frozen at 26), not
	-- leaving. idle=60 against 22 for the other side. The level gap opens exactly in that window
	-- and both deaths follow it. Waiting for the courier is the right call; waiting for it in
	-- front of a healthy enemy is not -- it reaches us just as fast behind our own line.
	-- Deliberately does NOT claim the tick once we are there: the point is to wait somewhere
	-- safe, not to stop playing. Standing at the spot yields, so last-hit and lane work own the
	-- wait, which is the difference between this and the idling it replaces.
	if flightFresh and not heldHeal and hp < 0.55
		and not (bot.aib_fountainTrip or bot.aib_fountainFloorTrip) then
		local back = xpRecoveryLoc(bot, nEnemyCreeps, hp)
		if back ~= nil and GetUnitToLocationDistance(bot, back) > 220 then
			if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 1.5 then
				bot.aib_recMoveLast = DotaTime()
				Style.Diag(bot, "heal-inflight-back")
				recoveryPlan(bot, "back", "heal_in_flight", string.format("hp=%.0f", hp * 100), 2.0)
				bot:Action_MoveToLocation(back)
			end
			return true
		end
		Style.DiagRL(bot, "heal-inflight-hold", 5)
	end

	-- 4b (user's deferred call, 21.07 -> chosen 23.07): before spending 60 seconds walking
	-- home, look at the rune clock. A rune that is nearly up and closer than the fountain
	-- gives the same full bar plus bottle charges plus map presence, for a few seconds of
	-- walking. Three of the nine trips in 8907379308 fired at 30-34% HP and the user marked
	-- all three "almost full / no idea why it went"; the fix he picked was this, not
	-- narrowing the floor band, because the timer is the actual reason those trips were wrong.
	--
	-- The band and the threat test now come from runeBeatsFountain, shared with the release side.
	-- This site used to carry its own copy at hp>=0.22 with no threat test at all, so 434f802's
	-- narrowing never reached it. It only DEFERS -- the floor still owns the decision on the next
	-- tick once the window passes, so this cannot strand a bot in lane.
	local runeEta, runeLoc, runeDist = runeBeatsFountain(bot, hp)
	if runeEta ~= nil then
		releaseFountainTrip(bot, "rune_due",
			string.format("hp=%.0f eta=%.0f rune=%.0f home=%.0f",
				hp * 100, runeEta, runeDist, bot:DistanceFromFountain()))
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 2.0 then
			bot.aib_recMoveLast = DotaTime()
			recoveryPlan(bot, "rune_stage", "floor_deferred",
				string.format("hp=%.0f eta=%.0f", hp * 100, runeEta), 2.0)
			Style.Diag(bot, "floor-rune-defer")
			bot:Action_MoveToLocation(runeLoc)
		end
		return true
	end

	local floorReason = hp < 0.22 and "regen_lane_floor" or "no_sustain_floor"
	if not canHealHere and (hp < 0.22 or (hp < 0.35 and noSustain)) then
		local tpFloor = getTpScroll(bot)
		if tpFloor ~= nil and not bot:WasRecentlyDamagedByAnyHero(1.5) then
			commitFountainTrip(bot, true, heldHeal)
			-- Claim the channel. fountainRecovery() runs BEFORE recovery() (:832 vs :835) and,
			-- once the trip is latched, re-issues Action_MoveToLocation(fountain) every second
			-- -- which cancels this very TP one tick after it is cast. That is why 8908963179
			-- shows recovery-tp=1, recovery-walk=0, fountain-wait=10 and a 30s march home on
			-- foot: the floor teleported, and the trip-walker immediately un-teleported it.
			-- The channel guard at the top of fountainRecovery already handles this; it was
			-- simply never armed from here (only the TP-back-to-lane branch :278 armed it).
			bot.aib_fountainTping = true
			bot.aib_fountainTpCast = DotaTime()
			recoveryPlan(bot, "tp_fountain", floorReason, string.format("hp=%.0f", hp*100), 2.0)
			Style.Diag(bot, "recovery-tp")
			bot:Action_UseAbility(tpFloor)
			return true
		end
		if bot.aib_recMoveLast == nil or DotaTime() - bot.aib_recMoveLast >= 5.0 then
			commitFountainTrip(bot, true, heldHeal)
			recoveryPlan(bot, "walk_fountain", floorReason, string.format("hp=%.0f", hp*100), 2.0)
			bot.aib_recMoveLast = DotaTime(); Style.Diag(bot, "recovery-walk")
			bot:Action_MoveToLocation(J.GetTeamFountain())
		end
		return true
	end

	-- e. No-resource recovery: move toward XP/safety once, then yield back to laning.
	-- Passive regen is context, not a terminal action; standing still here looks like AFK.
	local back, backKind = xpRecoveryLoc(bot, nEnemyCreeps, hp)
	if back then
		if bot.aib_recWaitStart == nil then
			bot.aib_recWaitStart = DotaTime()
			bot.aib_recWaitDest = back
			bot.aib_recWaitKind = backKind
		end
		back = bot.aib_recWaitDest or back
		backKind = bot.aib_recWaitKind or backKind
		if DotaTime() - bot.aib_recWaitStart < 10.0 then
			local backDist = GetUnitToLocationDistance(bot, back)
			if backDist <= 220 then
				Style.DiagRL(bot, "recovery-yield", 5)
				recoveryPlan(bot, "wait_safe", "hold_position", string.format("hp=%.0f", hp*100), 4.0)
				return true
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
		bot.aib_recWaitDest = nil
		bot.aib_recWaitKind = nil
		Style.DiagRL(bot, "recovery-timeout", 10)
	end

	return false
end

--

function M.Think(bot, dials, nEnemyCreeps)
	-- BEFORE the chain, not inside it. Any release condition placed after fountainRecovery is
	-- unreachable the moment a trip latches, which is exactly how b6d0642's guard spent its
	-- whole life dead. See the FOUNTAIN TRIP: ONE OWNER block at the top of this file.
	reviewFountainTrip(bot)
	if fountainRecovery(bot)              then return true end
	if defensiveHeal(bot, dials)           then return true end
	if regenLane(bot, dials, nEnemyCreeps) then return true end
	if recovery(bot, dials, nEnemyCreeps)  then return true end
	return false
end

return M
