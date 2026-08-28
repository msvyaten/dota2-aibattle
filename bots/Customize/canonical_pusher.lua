-- Canonical LLM playstyle: Pusher.
-- Copy into playstyle_radiant.lua or playstyle_dire.lua for a deliberate run.
-- Config tuned by Claude (2026-06-25): raised harass/rune_control to stay competitive
-- in lane, lowered push_desire/retreat_caution to fight instead of over-push.

return {
	dials = {
		harass_desire     = 0.85,
		farm_focus        = 0.35,
		forwardness       = 0.65,
		retreat_caution   = 0.38,
		rune_control      = 0.85,
		execute_threshold = 0.45,
		gank_desire       = 0.25,
		push_desire       = 0.72,
		defend_desire     = 0.60,
		ward_desire       = 0.90,
		roshan_desire     = 0.85,
	},
	item_build = {
		npc_dota_hero_nevermore = {
			"item_tango",
			"item_double_branches",
			"item_faerie_fire",
			"item_enchanted_mango",
			"item_enchanted_mango",
			"item_bottle",
			"item_magic_wand",
			"item_power_treads",
			"item_lifesteal",
			"item_dragon_lance",
			"item_lesser_crit",
			"item_black_king_bar",
			"item_orchid",
			"item_bloodthorn",
			"item_greater_crit",
			"item_hurricane_pike",
			"item_aghanims_shard",
			"item_satanic",
			"item_moon_shard",
			"item_travel_boots_2",
			"item_ultimate_scepter_2",
		},
	},
	rules = {
		respawn_behavior    = "tp_to_lane",
		pregame_behavior    = "aggressive_mid",
		dive_policy         = "finish_only",
		low_hp_behavior     = "regen_lane",
		healing_style       = "active",
		ability_usage       = "aggressive",
		creep_wave_priority = "push",
		hero_priority       = "always",
		deny_policy         = "default",
	},
}
