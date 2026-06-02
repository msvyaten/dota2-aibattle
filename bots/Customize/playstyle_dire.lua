-- Dire: PASSIVE Sniper (canonical). This is the DYING bot.
-- TEST 7: respawn_behavior = tp_to_tower -> after death it must TELEPORT to its tower (not walk).
return {
    dials = {
        harass_desire     = 0.05,
        farm_focus        = 1.00,
        forwardness       = 0.10,
        ability_aggro     = 0.00,
        rune_control      = 0.20,
        retreat_caution   = 0.80,
        execute_threshold = 0.00,
    },
    rules = {
        respawn_behavior = "tp_to_tower",  -- TEST 7: expect teleports_used > 0 on Dire (slot 128)
    },
    item_build = {
        "item_power_treads",
        "item_dragon_lance",
        "item_mask_of_madness",
        "item_maelstrom",
        "item_hurricane_pike",
        "item_satanic",
    },
}
