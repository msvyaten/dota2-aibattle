local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local AIBStyle = require( GetScriptDirectory()..'/FunLib/aibattle_style')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
	local raw = Push.GetPushDesire(bot, LANE_TOP)
	bot.PushLaneDesire[LANE_TOP] = raw
	local d = AIBStyle.ScaleDesire(raw, AIBStyle.Get().dials.push_desire)
	d = AIBStyle.FinishPush(bot, d, raw)
	if J.IsInLaningPhase() then
		AIBStyle.DiagRL(bot, "push-gd-laning", 10)
	else
		AIBStyle.DiagRL(bot, "push-gd-late", 10)
		local pushLane = AIBStyle.GetGroupPushLane()
		if pushLane == LANE_TOP then
			if raw > 0 then
				d = Clamp(d + 0.45, 0, BOT_ACTION_DESIRE_VERYHIGH)
				AIBStyle.Diag(bot, "push-lane-active")
			else
				d = 0.15
				AIBStyle.Diag(bot, "push-lane-wait")
			end
		else
			d = d * 0.15
		end
	end
	return d
end
function Think() Push.PushThink(bot, LANE_TOP) end
