-- Canonical LLM playstyle: Pusher.
-- Copy into playstyle_radiant.lua or playstyle_dire.lua for a deliberate run.

return {
	dials = {
		harass_desire     = 0.60,
		farm_focus        = 0.35,
		forwardness       = 0.55,
		retreat_caution   = 0.50,
		rune_control      = 0.75,
		execute_threshold = 0.25,
		ability_aggro     = 0.65,
		gank_desire       = 0.25,
		push_desire       = 0.90,
		defend_desire     = 0.60,
		ward_desire       = 0.90,
		roshan_desire     = 0.85,
	},
	item_build = {
		npc_dota_hero_nevermore = {
			"item_tango",
			"item_branches",
			"item_branches",
			"item_bottle",
			"item_boots",
			"item_magic_wand",
			"item_belt_of_strength",
		},
	},
	rules = {
		respawn_behavior    = "tp_to_lane",
		pregame_behavior    = "safe_tower",
		dive_policy         = "finish_only",
		low_hp_behavior     = "regen_lane",
		healing_style       = "active",
		ability_usage       = "aggressive",
		creep_wave_priority = "push",
		hero_priority       = "always",
		deny_policy         = "default",
		visual_afk_seconds  = 5,
	},
}
