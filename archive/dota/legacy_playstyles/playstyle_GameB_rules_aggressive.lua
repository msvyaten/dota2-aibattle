-- PREP: Game B — RULES CONTRAST BATCH (aggressive side).
-- Dials neutral/identical to the passive side (push EQUAL 0.50) so only RULES differ.
-- Three rules contrasted at once; each has its own independent counter:
--   dive_policy=always   -> counter 'no-dive' should be ~0 here (bots DO dive)
--   smoke_usage=default  -> counter 'smoke'   should be >0 here
--   buyback_policy=default (always removed — never fired in testing)
-- Copy to playstyle_radiant.lua (or dire) for the batch game; swap sides for run 2.
return {
    dials = {
        harass_desire     = 0.50,
        farm_focus        = 0.50,
        forwardness       = 0.70,
        retreat_caution   = 0.50,
        rune_control      = 0.50,
        execute_threshold = 0.00,
        ability_aggro     = 0.00,
        gank_desire       = 0.50,
        push_desire       = 0.50,
        defend_desire     = 0.50,
        ward_desire       = 0.50,
        roshan_desire     = 0.50,
    },
    rules = {
        respawn_behavior = "tp_to_lane",
        dive_policy      = "always",
        smoke_usage      = "default",
        buyback_policy   = "default",
    },
}
