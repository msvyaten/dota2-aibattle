-- AIBattle tiny intent runner. Keeps laning step order explicit and inspectable.

local M = {}

function M.Run(stages)
	for _, stage in ipairs(stages or {}) do
		local ok = stage.fn()
		if ok then return true, stage.name end
	end
	return false, nil
end

return M
