local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local AIBStyle = require( GetScriptDirectory()..'/FunLib/aibattle_style')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
	local raw = Push.GetPushDesire(bot, LANE_BOT)
	bot.PushLaneDesire[LANE_BOT] = raw
	-- AIBattle Schema v2 (Phase 2): scale by push_desire dial, then lead-aware finish override.
	local d = AIBStyle.ScaleDesire(raw, AIBStyle.Get().dials.push_desire)
	d = AIBStyle.FinishPush(bot, d, raw)
	-- AIBattle: in late game, converge all bots on the weakest enemy lane (group push).
	-- Boost this lane's desire; suppress all other push lanes so bots rally together.
	if not J.IsInLaningPhase() then
		local pushLane = AIBStyle.GetGroupPushLane()
		if pushLane == LANE_BOT then
			d = Clamp(d + 0.3, 0, BOT_ACTION_DESIRE_VERYHIGH)
		else
			d = d * 0.15
		end
	end
	return d
end
function Think() Push.PushThink(bot, LANE_BOT) end
