-- AIBattle public intent taxonomy.
-- Keep this list small: match analysis and LLM summaries should reason at this level.

local M = {}

local families = {
	fight = {
		"ability", "channel", "execute", "harass", "hero", "kill", "mutual", "rune-pressure",
	},
	chase = {
		"chase",
	},
	farm = {
		"cs", "deny", "farm", "last-hit",
	},
	push = {
		"cw-push", "dw-farm", "fwd", "push",
	},
	siege = {
		"dw-tower", "siege", "tower-opportunity", "visual-hold-tower",
	},
	rune = {
		"bottle-rune", "recovery-rune", "rune-", "state-rune",
	},
	recover = {
		"critical-recovery", "damage-unstuck", "fountain", "heal", "low-hp", "recovery", "regen",
	},
	retreat = {
		"emerg", "retreat", "tp",
	},
	safety = {
		"anti-afk", "anti-idle", "creep-aggro", "creep-hit", "melee-pack", "precreep", "prewave",
		"visual-hold", "uphill",
	},
	state = {
		"state-", "arbiter",
	},
	blocked = {
		"blocked",
	},
}

local order = {
	"fight", "chase", "farm", "push", "siege", "rune", "recover", "retreat", "safety", "state", "blocked",
}

function M.PublicFamilies()
	local out = {}
	for i, family in ipairs(order) do out[i] = family end
	return out
end

function M.Family(name)
	name = tostring(name or "")
	for _, family in ipairs(order) do
		for _, prefix in ipairs(families[family]) do
			if string.sub(name, 1, #prefix) == prefix or string.find(name, prefix, 1, true) ~= nil then
				return family
			end
		end
	end
	return "other"
end

function M.WithFamily(name, detail)
	local family = M.Family(name)
	local d = detail or ""
	if string.find(d, "family=", 1, true) ~= nil then return d end
	if d ~= "" then return "family=" .. family .. " " .. d end
	return "family=" .. family
end

return M
