-- Series 1 config: Gemini.
-- Written by Gemini from the shared strategy text (docs/llm_system_prompt.md), 23.07.2026.
-- One prompt -> three models -> three readings; the spread between them IS the product.
--
-- Do NOT edit to "improve" it. This file is a model's answer, not our design: tuning it
-- destroys the only thing the series measures. Fixes go in bot code, never here.
-- Reads the same text as control: hold last hits, no forced hero priority, highest
-- farm_focus of the three. The only config with NO pre-creep engage licence --
-- neither aggressive_mid nor hero_priority=always -- so it should stand at the horn.

return {
	dials = {
		harass_desire     = 0.65,
		farm_focus        = 0.70,
		forwardness       = 0.55,
		retreat_caution   = 0.55,
		rune_control      = 0.60,
		execute_threshold = 0.60,
		gank_desire       = 0.20,
		push_desire       = 0.60,
		defend_desire     = 0.55,
		ward_desire       = 0.50,
		roshan_desire     = 0.50,
	},
	rules = {
		respawn_behavior    = "tp_to_lane",
		pregame_behavior    = "default",
		dive_policy         = "finish_only",
		low_hp_behavior     = "regen_lane",
		healing_style       = "active",
		ability_usage       = "aggressive",
		ability_timing      = "on_cooldown",
		creep_wave_priority = "last_hit_only",
		hero_priority       = "default",
		deny_policy         = "default",
		tower_aggression    = "default",
	},
}
