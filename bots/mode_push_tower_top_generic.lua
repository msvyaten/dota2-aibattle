local Push = require( GetScriptDirectory()..'/FunLib/aba_push')
local AIBStyle = require( GetScriptDirectory()..'/FunLib/aibattle_style')
local J = require( GetScriptDirectory()..'/FunLib/jmz_func')
local bot = GetBot()
local botName = bot:GetUnitName()
if bot == nil or bot:IsInvulnerable() or not bot:IsHero() or not bot:IsAlive() or not string.find(botName, "hero") or bot:IsIllusion() then return end
if bot.PushLaneDesire == nil then bot.PushLaneDesire = {0, 0, 0} end

function GetDesire()
	AIBStyle.DiagRL(bot, "push-gd", 10)
	local raw = Push.GetPushDesire(bot, LANE_TOP)
	bot.PushLaneDesire[LANE_TOP] = raw
	-- AIBattle Schema v2 (Phase 2): scale by push_desire dial, then lead-aware finish override.
	local d = AIBStyle.ScaleDesire(raw, AIBStyle.Get().dials.push_desire)
	d = AIBStyle.FinishPush(bot, d, raw)
	-- AIBattle: in late game, converge all bots on the weakest enemy lane (group push).
	-- Boost this lane's desire; suppress all other push lanes so bots rally together.
	-- IMPORTANT: only boost when raw>0 (wave present). When raw=0, yield to roam so
	-- group-push-rally can navigate bots to the lane front and wait for the next wave.
	if not J.IsInLaningPhase() then
		AIBStyle.DiagRL(bot, "push-late", 10)
		local pushLane = AIBStyle.GetGroupPushLane()
		if pushLane == LANE_TOP then
			if raw > 0 then
				-- Wave present: win arbitration so PushThink() actually pushes
				d = Clamp(d + 0.45, 0, BOT_ACTION_DESIRE_VERYHIGH)
				AIBStyle.Diag(bot, "push-lane-active")
			else
				-- No wave: yield to roam so group-push-rally navigates bot to lane front
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
