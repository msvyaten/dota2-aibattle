-- AIBattle: tiny decision-stage runner.
-- Keep policy modules small: each stage either handles the current tick or yields.

local M = {}

function M.Stage(name, run)
	return { name = name, run = run }
end

function M.Run(stages, ctx)
	for _, stage in ipairs(stages or {}) do
		if stage ~= nil and stage.run ~= nil and stage.run(ctx) then
			if ctx ~= nil then ctx.last_stage = stage.name end
			return true, stage.name
		end
	end
	return false, nil
end

return M
