-- TOP-0 benchmark baseline: OHA/engine defaults, zero LLM configuration.
-- Empty dials/rules mean the style loader fills every value with its engine default
-- (dials 0.5, execute_threshold 0.0, all rules "default"), and item/skill builds come
-- from the stock hero files. This is "what you get without AIBattle configs".
--
-- Owned by Claude (benchmark infrastructure). Do NOT tune values here -- the whole
-- point of this file is that there is nothing to tune.

return {
	dials = {},
	rules = {},
}
