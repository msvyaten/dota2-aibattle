-- Series 1 config: Grok.
-- Written by Grok from the shared strategy text (docs/llm_system_prompt.md), 23.07.2026.
-- One prompt -> three models -> three readings; the spread between them IS the product.
--
-- Do NOT edit to "improve" it. This file is a model's answer, not our design: tuning it
-- destroys the only thing the series measures. Fixes go in bot code, never here.
-- Reads the text as pressure: push the wave, always prefer the hero, always deny.
-- Its pre-creep engage licence comes from hero_priority="always" (bfa60b8).

return {
	dials = {
		harass_desire     = 0.75,
		farm_focus        = 0.65,
		forwardness       = 0.65,
		retreat_caution   = 0.45,
		rune_control      = 0.60,
		execute_threshold = 0.55,
		ability_aggro     = 0.70,
		gank_desire       = 0.30,
		push_desire       = 0.60,
		defend_desire     = 0.60,
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
		creep_wave_priority = "push",
		hero_priority       = "always",
		deny_policy         = "always",
		tower_aggression    = "default",
	},
}
