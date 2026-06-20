-- Canonical LLM playstyle: Pusher.
-- Copy into playstyle_radiant.lua or playstyle_dire.lua for a deliberate run.

return {
	dials = {
		harass_desire     = 0.40,
		farm_focus        = 0.45,
		forwardness       = 0.65,
		retreat_caution   = 0.70,
		rune_control      = 0.60,
		execute_threshold = 0.20,
		ability_aggro     = 0.55,
		gank_desire       = 0.25,
		push_desire       = 0.90,
		defend_desire     = 0.60,
		ward_desire       = 0.90,
		roshan_desire     = 0.85,
	},
	rules = {
		respawn_behavior    = "tp_to_lane",
		pregame_behavior    = "safe_tower",
		dive_policy         = "never",
		low_hp_behavior     = "regen_lane",
		healing_style       = "active",
		ability_usage       = "aggressive",
		creep_wave_priority = "last_hit_only",
		hero_priority       = "default",
		deny_policy         = "default",
		visual_afk_seconds  = 6,
	},
}
