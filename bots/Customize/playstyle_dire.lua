-- Dire: passive mid (AIBattle Schema v2)
return {
    dials = {
        harass_desire     = 0.00,  -- 0-1: frequency of attacking enemy hero
        farm_focus        = 1.00,  -- 0-1: 0 = pure harass, 1 = pure last-hitting
        forwardness       = 0.10,  -- 0-1: 0 = glued to tower, 1 = aggressive front
        ability_aggro     = 0.00,  -- 0-1: frequency of Shrapnel on hero
        rune_control      = 0.20,  -- 0-1: 0.5 = baseline, <0.5 ignores runes
        retreat_caution   = 0.80,  -- 0-1: 0.5 = baseline, >0.5 retreats early
        execute_threshold = 0.00,  -- 0-1: 0 = never ult-finish (conservative)
    },
    rules = {
        respawn_behavior = "walk_back",  -- tp_to_tower | tp_to_lane | walk_back
    },
    -- Passive demo build: standard farming carry WITH boots (Power Treads).
    item_build = {
        "item_power_treads",
        "item_dragon_lance",
        "item_mask_of_madness",
        "item_maelstrom",
        "item_hurricane_pike",
        "item_satanic",
    },
}
