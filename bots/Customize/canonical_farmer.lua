-- Canonical LLM playstyle: Farmer (distinct archetype).
-- Restored 2026-07-06 from the brawler-mirror by Claude (Opus). Contrast partner to
-- canonical_brawler: same hero/build/skill, DIALS+RULES are the only variable so a
-- match cleanly attributes archetype divergence.
--
-- WIN CONDITION (why this is not the old slow Farmer): economy -> level/item lead ->
-- CONVERSION via execute + advantaged fights, NOT tower siege. The reverted Farmer
-- (harass=0.35 / push=0.78) ground towers for 17-20 min; that failure was PUSH, not
-- farm_focus. Here push stays moderate (0.45) and hero_priority=default lets the
-- arbiter's hp_adv/execute gates pick fights only once ahead -- so a farmed lead
-- still closes the game on kills.
--
-- Identity vs brawler:
--   farm_focus 0.72 (vs 0.15): stay on the creep line, do NOT chase on sight
--   hero_priority "default" (vs "always"): fight through farm_focus/hp-adv gate, not reflex
--   harass 0.55 (vs 0.90): contest CS / deny / zone when free, do not over-commit
--   push 0.45 (vs 0.30): take tower when the wave is already shoved & safe (conversion)
--   retreat_caution 0.55 (vs 0.35): preserve economy, avoid feeding the lead back
--   ability_aggro 0.45 (vs 0.65): spend spells on securing CS / finishing, not harass
--
-- NEEDS MATCH VALIDATION: dials are a judgment call; tune if games run long or the
-- farmer never converts its lead. Reversible (config only).
-- Do NOT modify without command -- owned by Claude, not Codex.

return {
	dials = {
		harass_desire     = 0.55,
		farm_focus        = 0.72,
		forwardness       = 0.50,
		retreat_caution   = 0.55,
		rune_control      = 0.85,
		execute_threshold = 0.38,
		ability_aggro     = 0.45,
		gank_desire       = 0.50,
		push_desire       = 0.45,
		defend_desire     = 0.25,
		ward_desire       = 0.50,
		roshan_desire     = 0.50,
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
		creep_wave_priority = "last_hit_only",
		hero_priority       = "default",
		deny_policy         = "default",
	},
	skill_build = { npc_dota_hero_nevermore = {1,5,1,5,1,6,1,5,5,4,6,4,4,4,6} },
}
