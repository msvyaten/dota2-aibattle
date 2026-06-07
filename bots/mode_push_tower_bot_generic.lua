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
	local d = AIBStyle.ScaleDesire(raw, AIBStyle.Get().dials.push_desire)
	d = AIBStyle.FinishPush(bot, d, raw)
	-- AIBattle: split diagnostic to confirm whether OHA calls push GetDesire post-laning.
	-- Hypothesis (match 10): push-gd=204 ≈ 8min×5bots → OHA may skip push GetDesire after laning.
	-- push-gd-laning: calls in laning phase | push-gd-late: calls after laning phase (0 = confirmed skip)
	if J.IsInLaningPhase() then
		AIBStyle.DiagRL(bot, "push-gd-laning", 10)
	else
		AIBStyle.DiagRL(bot, "push-gd-late", 10)
		-- Late-game group push: boost when wave present; yield to roam when no wave.
		local pushLane = AIBStyle.GetGroupPushLane()
		if pushLane == LANE_BOT then
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
function Think() Push.PushThink(bot, LANE_BOT) end
