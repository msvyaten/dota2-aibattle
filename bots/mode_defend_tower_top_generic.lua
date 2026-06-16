local Defend = require( GetScriptDirectory()..'/FunLib/aba_defend')
local AIBStyle = require( GetScriptDirectory()..'/FunLib/aibattle_style')

local bot = GetBot()
local botName = bot:GetUnitName()

if bot:IsInvulnerable() or not bot:IsHero() or not string.find(botName, "hero") or bot:IsIllusion() then
	return
end

-- AIBattle Schema v2 (Phase 2): scale defend desire by the defend_desire team dial.
-- Emergency defense (ancient/base at ABSOLUTE) passes through ScaleDesire untouched.
function GetDesire()
	if GetGameMode() == GAMEMODE_1V1MID then return BOT_MODE_DESIRE_NONE end
	return AIBStyle.ScaleDesire(Defend.GetDefendDesire(bot, LANE_TOP), AIBStyle.Get().dials.defend_desire)
end
function Think() Defend.DefendThink(bot, LANE_TOP) end
