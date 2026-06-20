-- Canonical LLM playstyle: Ganker.
-- Copy into playstyle_radiant.lua or playstyle_dire.lua for a deliberate run.

return {
	dials = {
		harass_desire     = 0.85,
		farm_focus        = 0.20,
		forwardness       = 0.85,
		retreat_caution   = 0.25,
		rune_control      = 0.70,
		execute_threshold = 0.40,
		ability_aggro     = 0.65,
		gank_desire       = 0.90,
		push_desire       = 0.20,
		defend_desire     = 0.30,
		ward_desire       = 0.45,
		roshan_desire     = 0.35,
	},
	rules = {
		respawn_behavior = "tp_to_lane",
	},
}
