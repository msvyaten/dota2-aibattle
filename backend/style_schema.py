"""Model-facing AIBattle style schema used by generation and contract checks.

The runtime can retain compatibility-only values that are intentionally absent here. This
table contains only distinct choices the LLM may emit. A missing rule is omitted from the
generated Lua so the engine applies its own default.
"""

DIAL_KEYS = (
    "harass_desire", "farm_focus", "forwardness", "retreat_caution",
    "rune_control", "execute_threshold", "gank_desire",
    "push_desire", "defend_desire", "ward_desire", "roshan_desire",
)

RULE_VALUES = {
    "respawn_behavior": ("tp_to_tower", "tp_to_lane", "walk_back"),
    # Runtime-only water_rune is excluded until its 1v1 behavior is validated as a useful
    # model choice. "default" is the passive prewave option.
    "pregame_behavior": ("safe_tower", "aggressive_mid", "jungle_pressure", "default"),
    "dive_policy": ("never", "finish_only", "when_grouped", "when_ahead", "always"),
    "low_hp_behavior": ("tp_fountain", "run_to_tower", "fight_back", "regen_lane", "walk_fountain"),
    "healing_style": ("active", "default", "never"),
    # Compatibility value "basic" is normalized to default and is not a distinct choice.
    "ability_usage": ("aggressive", "default"),
    "ability_timing": ("on_cooldown", "save_for_execute", "harass_only"),
    # "freeze" is not exposed: the engine does not yet implement a real freeze policy.
    "creep_wave_priority": ("push", "last_hit_only"),
    "hero_priority": ("always", "default", "never"),
    "deny_policy": ("always", "default", "never"),
    "tower_aggression": ("always", "default", "never"),
}

# Heroes the prompt asks for a build for. The runtime keys item_build by hero name and reads
# the entry for whichever hero it was handed, so a config carrying only one of these still
# works -- it just falls back to the vendor long-game build on the other, which is wrong for
# a match that ends around fifteen minutes. Extend this when a hero joins the rotation.
ITEM_BUILD_HEROES = (
    "npc_dota_hero_juggernaut",
    "npc_dota_hero_nevermore",
)
