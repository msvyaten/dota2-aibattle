-- Radiant: aggressive mid (AIBattle Schema v2)
return {
    dials = {
        harass_desire   = 0.95,  -- 0-1: frequency of attacking enemy hero
        farm_focus      = 0.10,  -- 0-1: 0 = pure harass, 1 = pure last-hitting
        forwardness     = 0.90,  -- 0-1: 0 = glued to tower, 1 = aggressive front
        ability_aggro   = 0.85,  -- 0-1: frequency of Shrapnel on hero
        rune_control    = 0.80,  -- 0-1: 0.5 = baseline, >0.5 contests runes more
        retreat_caution = 0.20,  -- 0-1: 0.5 = baseline, <0.5 fights longer
    },
    rules = {
        respawn_behavior = "tp_to_tower",  -- tp_to_tower | tp_to_lane | walk_back
    },
}
