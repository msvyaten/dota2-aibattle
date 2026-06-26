-- AIBattle tiny intent runner. Keeps laning step order explicit and inspectable.

local M = {}
local Style = require(GetScriptDirectory()..'/FunLib/aibattle_style')

function M.Run(stages, bot)
	for _, stage in ipairs(stages or {}) do
		local ok = stage.fn()
		if ok then
			if bot ~= nil then Style.TickOwner(bot, stage.name, "", 2.0) end
			return true, stage.name
		end
	end
	return false, nil
end

return M
