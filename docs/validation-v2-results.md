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
| 3 | `harass_desire` is a gradient | aggressor `0.3` vs `0.9` | hero attacks / hero dmg scales up | ⬜ |
| 4 | `rune_control` works (after 1v1 fix) | aggressor `0.9` vs `0.1` | bot moves to mid rune at 2:00/4:00 vs ignores (replay/positions) | ⬜ |
| 5 | `retreat_caution` works | same bot `0.2` vs `0.8` | low-HP behaviour: fights to low HP vs backs off early; deaths differ | ⬜ |
| 6 | `forwardness` (currently BINARY at 0.5) | `0.1` vs `0.9` | holds near tower vs pushes to lane front | ⬜ |
| 7 | `respawn_behavior = tp_to_tower` | put it on the **passive (dying)** bot | console `[AIB] casting TP` line, OR bot teleports (not walks) after a death | ⚠️ tp_to_lane WORKS (2 TPs), tp_to_tower FAILS (0 TPs) — channel interrupted; see Test 7 |

> Note: row 6 — `forwardness` is presently a switch at 0.5, NOT a true 0–1 gradient. Confirm
> the binary effect for now; true gradation is a follow-up fix (do not implement during freeze).

---

## Evidence log (fill per run)

### Test 2 — ability_aggro gradient
| Run | ability_aggro | Shrapnel magical dmg | Hero dmg | Match log |
|---|---|---|---|---|
| A | 0.3 |  |  |  |
| B | 0.9 |  |  |  |

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
| A | tp_to_tower | NO — teleports_used=0 (passive Dire died 2x, did not teleport) | 8835293640 |
| ref | tp_to_lane | YES — teleports_used=2 (passive bot, prior swap test) | 8834938959 |

**Finding:** the respawn-TP mechanism works (tp_to_lane proven, 2 teleports). `tp_to_tower`
specifically fails. Tower lookup is NOT the cause (this game the lane was pushed into the
enemy, so the passive bot's own towers were intact → `loc` valid). Suspected break: the TP
**channel is interrupted on the next tick** — `AIB_HandleRespawn` clears `bot.aib_wasDead`
on the same tick it issues the TP (mode_laning_generic.lua line ~70), so normal laning Think
resumes immediately and moves the bot toward the creeps (forward), cancelling the 3s channel
to the rear tower. With tp_to_lane the destination matches the bot's intent (forward), so the
channel completes. Likely fix: keep guarding (don't clear `aib_wasDead`) until the TP is
consumed / the bot is no longer channelling, so Think can't move it mid-channel. NOT yet
applied — awaiting confirmation.

---

## Merge gate
Merge `schema-v2-item-builds` → `main` ONLY when rows 2–7 are ✅ with evidence.
`execute_threshold` and `item_rules` stay on the branch, dormant, until the 6 dials + TP
are confirmed — then they get their own validation pass (v3).
