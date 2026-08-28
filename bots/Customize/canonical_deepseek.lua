-- Series 1 config: Deepseek.
-- Written by Deepseek from the shared strategy text (docs/llm_system_prompt.md), 23.07.2026.
-- One prompt -> three models -> three readings; the spread between them IS the product.
--
-- Do NOT edit to "improve" it. This file is a model's answer, not our design: tuning it
-- destroys the only thing the series measures. Fixes go in bot code, never here.
-- Reads it as early tempo: the ONLY config using pregame_behavior="aggressive_mid",
-- and the lowest farm_focus (0.55). Denies like Grok, farms and pushes less than both.
-- Its pre-creep engage licence comes from aggressive_mid, i.e. a different knob than
-- Grok's -- same visible behaviour reached two ways, which is worth watching.

return {
	dials = {
		harass_desire     = 0.65,
		farm_focus        = 0.55,
		forwardness       = 0.60,
		retreat_caution   = 0.45,
		rune_control      = 0.55,
		execute_threshold = 0.55,
		gank_desire       = 0.25,
		push_desire       = 0.50,
		defend_desire     = 0.50,
		ward_desire       = 0.50,
		roshan_desire     = 0.50,
	},
	rules = {
		respawn_behavior    = "tp_to_lane",
		pregame_behavior    = "aggressive_mid",
		dive_policy         = "finish_only",
		low_hp_behavior     = "regen_lane",
		healing_style       = "active",
		ability_usage       = "aggressive",
		ability_timing      = "on_cooldown",
		creep_wave_priority = "last_hit_only",
		hero_priority       = "default",
		deny_policy         = "always",
		tower_aggression    = "default",
	},
}
