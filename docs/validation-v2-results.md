# Schema v2 — Validation Results

> Goal: take Schema v2 from "1/N confirmed" (only the config swap) to **N/N confirmed**,
> like Phase 1 (8/8), BEFORE merging the branch or adding any more features.
> A claim counts as confirmed ONLY with evidence: a console log line or a number from the
> end-of-match stat dump. "Looks ok" / "should work" does NOT count.

## Rules of engagement (read first)
- **FREEZE new features.** No new dials, no execute/item_rules expansion, no new heroes
  while this table has unconfirmed rows. Finish depth before adding breadth.
- One test = one claim. Change ONE dial between two runs, keep everything else equal.
- Capture evidence into the tables below and commit this file each session.
- Reproduce 1v1: lobby 1v1 Solo Mid, cheats ON, host Unassigned, load Local Dev Script bots,
  `kick 1..4` / `kick 6..9`, launch options `-condebug -console`, read `console.<matchid>.log`.

## IMPORTANT test-config note (TP)
`respawn_behavior` only matters for a bot that actually DIES. In our matchup the **passive**
bot is the one that dies (0/2). So to test TP, put the TP rule on the **passive** config,
not the aggressive one. (Current demo configs have it backwards — TP on the aggressor who
goes 2/0 and never dies, so it can never fire.)

---

## Validation matrix

| # | Claim | How to set it | Evidence to capture | Status |
|---|---|---|---|---|
| 1 | Swap holds (config drives behaviour) | aggressive vs passive, then swap sides | aggressor 2/0 + high hero dmg both orientations | ✅ confirmed (Phase 1, 8/8) |
| 2 | `ability_aggro` is a gradient | aggressor `0.3` (run A) vs `0.9` (run B), all else equal | Shrapnel magical dmg: B noticeably > A (not 0↔max) | ⬜ |
| 3 | `harass_desire` is a gradient | aggressor `0.3` vs `0.9` | hero attacks / hero dmg scales up | ❌ DEAD DIAL — see below |
| 4 | `rune_control` works (after 1v1 fix) | aggressor `0.9` vs `0.1` | bot moves to mid rune at 2:00/4:00 vs ignores (replay/positions) | ⬜ |
| 5 | `retreat_caution` works | same bot `0.2` vs `0.8` | low-HP behaviour: fights to low HP vs backs off early; deaths differ | ⬜ |
| 6 | `forwardness` (currently BINARY at 0.5) | `0.1` vs `0.9` | holds near tower vs pushes to lane front | ⬜ |
| 7 | `respawn_behavior = tp_to_tower` | put it on the **passive (dying)** bot | console `[AIB] casting TP` line, OR bot teleports (not walks) after a death | ✅ CONFIRMED — tp_to_tower teleports_used=2 (8835623865) after channel-guard fix; tp_to_lane already ✅ (2 TPs). See Test 7 |

> Note: row 6 — `forwardness` is presently a switch at 0.5, NOT a true 0–1 gradient. Confirm
> the binary effect for now; true gradation is a follow-up fix (do not implement during freeze).

---

## Evidence log (fill per run)

### Test 2 — ability_aggro gradient
| Run | ability_aggro | Shrapnel magical dmg | Hero dmg | Match log |
|---|---|---|---|---|
| A | 0.3 |  |  |  |
| B | 0.9 |  |  |  |

### Test 3 — harass_desire (FAILED, root cause found)
Match 8835349718 (R harass 0.90 / D 0.30), ~35 min. Physical hero dmg: R=109, D=0.
**109 over 35 min ≈ 2 stray autoattacks = noise, NOT proof.** Magical (Shrapnel) ~1350/1010
nearly equal because that is driven by `ability_aggro` (equal at 0.50), not harass.

**Root cause:** in `mode_laning_generic.lua` Think(), the harass branch (~line 260) sits
BELOW the last-hit (~213) and deny (~229) branches, each of which `return`s. A mid lane
almost always has a creep to last-hit/deny, so the bot returns before ever reaching harass.
→ `harass_desire` is structurally dead at any value. Fix (depth, not breadth): roll
`harass_desire` ABOVE the last-hit branch so the bot can choose to attack the hero instead
of CSing.

**Update (match 8835417950): fix applied + balanced (secure in-range last-hit → harass →
walk-to-creep), STILL FAILS.** Physical hero dmg = 0 for BOTH bots (incl. harass 0.90).
Real root cause is deeper: the two Snipers never close to autoattack range (~550) — they
farm at range, heroes sit ~1000+ apart behind creeps, so the harass branch ("attack hero
if in range") never triggers. Making harass real requires the bot to ADVANCE toward the
enemy hero, which entangles with retreat (advance → take damage → mode_retreat pulls back =
"shoot and run"). Conclusion: harass/aggression is a laning+retreat behavior cluster, not a
dial-ordering issue. Treat holistically (post-validation). Also: denies ≈ last-hits because
GetDesire scans ally creeps at 1200 but enemy creeps at 800 — bot denies from farther than
it can last-hit.

### Test 4 — rune_control
| Run | rune_control | Went to rune @2:00? @4:00? | Match log |
|---|---|---|---|
| A | 0.9 |  |  |
| B | 0.1 |  |  |

### Test 5 — retreat_caution
| Run | retreat_caution | Deaths | Lowest HP% before retreat | Match log |
|---|---|---|---|---|
| A | 0.2 |  |  |  |
| B | 0.8 |  |  |  |

### Test 7 — respawn TP (config: TP on the dying/passive bot)
| Run | respawn_behavior | TP fired? (log line / observed) | Match log |
|---|---|---|---|
| A (pre-fix) | tp_to_tower | NO — teleports_used=0 (passive Dire died 2x, did not teleport) | 8835293640 |
| **A (post-fix)** | **tp_to_tower** | **YES — teleports_used=2 (passive Dire died 2x, teleported both times)** | **8835623865** ✅ |
| **A2 (post-fix, other side)** | **tp_to_tower** | **YES — teleports_used=1 (passive Radiant died 1x, teleported)** | **8835688565** ✅ |
| ref | tp_to_lane | YES — teleports_used=2 (passive bot, prior swap test) | 8834938959 |

**Finding (RESOLVED ✅):** the respawn-TP mechanism works for BOTH behaviours now.
Original break: the TP **channel was interrupted on the next tick** — `AIB_HandleRespawn`
cleared `bot.aib_wasDead` on the same tick it issued the TP, so normal laning Think resumed
immediately and moved the bot toward the creeps (forward), cancelling the 3s channel to the
rear tower. (tp_to_lane survived only because its destination matched the bot's forward intent.)
**Fix applied** (Mac-side, commit `89b5dc8`): after casting, `AIB_HandleRespawn` sets
`aib_tping` + `aib_tpCastTime` and HOLDS the bot (returns true, issues no other action) while
`modifier_teleporting` is present (+1s grace for the cast point), clearing the flag only once
the channel resolves. **Confirmed in 8835623865**: canon config (Dire passive,
`respawn_behavior = tp_to_tower`), passive died twice and `teleports_used = 2` in the stat dump.
Row 7 of the matrix is now ✅.

---

## Code audit (2026-06-02) — unverified branch code
No blocking bugs. Code is defensive (pcall, nil-safe, 0-1 clamp, GetItemCost validation,
item_rules dormant unless configured). Findings:

1. **[root cause] `rune_control` can't express in 1v1.** The rune-fix gate is logically correct,
   but `mode_laning` GetDesire returns a flat **1.0** in 1v1 mid (mode_laning_generic.lua ~164)
   while rune desire is hard-capped at **0.99** in `ScaleDesire` (aibattle_style.lua ~138) → laning
   always outranks rune except in the narrow windows where laning itself bails. So runes are never
   taken in 1v1 due to *arbitration priority*, not short games. To test it: raise the rune cap >1.0
   for high rune_control, or drop laning desire at rune timings. Deferred (freeze).
2. **[latent] item_rules `dying`** depends on `aib_deathCount`, incremented in `ItemPurchaseThink`
   only on a dead frame — if the engine doesn't call it while the bot is dead, the count never grows.
   Verify in-game when item_rules is enabled.
3. **[5v5 edge] item_rules insertions wiped + latched:** ARDM/pos-swap rebuilds reset
   `purchaseListInReverseOrder` (item_purchase_generic.lua ~535/658/705) but `aib_ruleDone[item]`
   stays true → the situational item is dropped and never re-added. Irrelevant to 1v1.
4. **[nit] comment mismatch:** the item_rules hook comment says "to the front" but it appends to the
   END of `purchaseListInReverseOrder` = next-to-buy (the loop pops from the end). Behaviour correct.

OK: `aibattle_style` clamp/whitelist/pcall solid; item_build override proven; `Item` required
(item_purchase_generic.lua:6, no crash); `execute_threshold` proven; passive creep-fix safe.

---

## Merge gate
Merge `schema-v2-item-builds` → `main` ONLY when rows 2–7 are ✅ with evidence.
`execute_threshold` and `item_rules` stay on the branch, dormant, until the 6 dials + TP
are confirmed — then they get their own validation pass (v3).
