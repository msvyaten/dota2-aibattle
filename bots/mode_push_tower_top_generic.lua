local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local AIBStyle = require( GetScriptDirectory()..'/FunLib/aibattle_style')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
    local raw = Push.GetPushDesire(bot, LANE_TOP)
    bot.PushLaneDesire[LANE_TOP] = raw
    -- AIBattle Schema v2 (Phase 2): scale by push_desire dial, then lead-aware finish override.
    local d = AIBStyle.ScaleDesire(raw, AIBStyle.Get().dials.push_desire)
    return AIBStyle.FinishPush(bot, d, raw)
end
function Think() Push.PushThink(bot, LANE_TOP) end
