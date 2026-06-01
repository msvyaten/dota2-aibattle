-- Radiant: SWAPPED -> now the PASSIVE config (control test; was on Dire).
-- respawn_behavior set to tp_to_lane to finally validate TP-after-death:
-- this is the bot that reliably dies, so it must teleport to mid on respawn.
return {
    dials = {
        harass_desire   = 0.00,  -- 0-1: frequency of attacking enemy hero
        farm_focus      = 1.00,  -- 0-1: 0 = pure harass, 1 = pure last-hitting
        forwardness     = 0.10,  -- 0-1: 0 = glued to tower, 1 = aggressive front
        ability_aggro   = 0.00,  -- 0-1: frequency of Shrapnel on hero
        rune_control    = 0.20,  -- 0-1: 0.5 = baseline, <0.5 ignores runes
        retreat_caution = 0.80,  -- 0-1: 0.5 = baseline, >0.5 retreats early
    },
    rules = {
        respawn_behavior = "tp_to_lane",  -- TEST: was "walk_back"; expect teleports_used>0 after a death
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
