-- Radiant: aggressive mid (AIBattle Schema v2)
return {
    dials = {
        harass_desire     = 0.95,  -- 0-1: frequency of attacking enemy hero
        farm_focus        = 0.10,  -- 0-1: 0 = pure harass, 1 = pure last-hitting
        forwardness       = 0.90,  -- 0-1: 0 = glued to tower, 1 = aggressive front
        ability_aggro     = 0.85,  -- 0-1: frequency of Shrapnel on hero
        rune_control      = 0.80,  -- 0-1: 0.5 = baseline, >0.5 contests runes more
        retreat_caution   = 0.20,  -- 0-1: 0.5 = baseline, <0.5 fights longer
        execute_threshold = 0.45,  -- 0-1: ult-finish a fleeing enemy below this HP fraction
        -- Phase 2 team dials (0.5 = baseline x1). Canon leaves them neutral; A/B configs vary one.
        gank_desire       = 0.50,  -- 0-1: roaming/ganking pressure (mode_roam + mode_team_roam)
        push_desire       = 0.50,  -- 0-1: tower siege pressure (mode_push_tower_*)
        defend_desire     = 0.50,  -- 0-1: defending own towers (mode_defend_tower_*)
        ward_desire       = 0.50,  -- 0-1: vision investment (mode_ward)
        roshan_desire     = 0.50,  -- 0-1: Roshan priority (mode_roshan)
    },
    rules = {
        respawn_behavior = "tp_to_tower",  -- tp_to_tower | tp_to_lane | walk_back
    },
    -- Aggressive demo build: greedy damage rush, NO boots -- everything into damage.
    item_build = {
        "item_wraith_band",
        "item_wraith_band",
        "item_dragon_lance",
        "item_maelstrom",
        "item_greater_crit",
        "item_satanic",
    },
}
