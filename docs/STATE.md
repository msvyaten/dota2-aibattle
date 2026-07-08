# AIBattle State

Last updated: 2026-07-08.

This is the short source of truth before starting a match. Long design notes live in
`docs/SPECS.md`, `docs/HANDOFF_PACKAGE.md`, and `docs/BACKLOG.md`.

## Current Snapshot

- Branch: `phase-2-team-dials`
- Exact repo HEAD: run `python tools\pre_match_state.py`.
- Pre-P3 baseline commit before this prep package: `c1cd4e4`.
- GitHub status before this prep package: `origin/phase-2-team-dials` was at the same commit.
- Live marker observed before this update: `SWAP+lhsecure2+rangedspace+p3a2+hpbehind-inrange+concede`
- Live/HEAD status: not identical by marker. Before a match, either deploy `HEAD` or explicitly record the custom live marker.

## Dirty Configs

Claude-owned local config/playstyle changes are present:

- `bots/Customize/canonical_brawler.lua`: `retreat_caution` changed from `0.35` to `0.50`.
- `bots/Customize/canonical_farmer.lua`: comment documents the `0.65 -> 0.55` retreat-caution experiment.
- `bots/Customize/playstyle_radiant.lua`: binds Radiant to `canonical_farmer`.
- `bots/Customize/playstyle_dire.lua`: binds Dire to `canonical_brawler`.

Do not commit these config/playstyle files unless the user explicitly asks.

## Current Stage

Completed:

- Gate 0: technical runtime gate passed.
- Gate 1: new architecture beat phase-22 comparison.
- Stage 0.5: watchability package accepted.
- P3-A slice 1: `Recovery.Owner` skeleton.
- P3-A slice 2: `EmergencyRetreat` and `ForwardLowHpPullback` register on `Recovery.Owner`.

Next structural task:

- P3-B: dissolve `ActiveLowHp` / regen-lane / heal-pullback / step-back into `Recovery.Owner` episode actions, and update `postmatch.py` / `scorecard.py` in the same commit so low-HP jitter is counted by episodes.

Do not start P1 arbiter migration before P3 unless explicitly redirected.

## P3 Baseline

Reference matches already available:

| Match | Result | Runtime | Empty Action | Jitter/Min | Bottle Empty |
| --- | --- | --- | --- | --- | --- |
| `8885447129` | Dire won, R=farmer D=brawler | R=0/D=0 errors | R=53 D=37 | R=24.9 D=22.9 | R=28% D=68% |
| `8886710243` | Radiant won, R=farmer D=brawler | R=0/D=0 errors | R=57 D=47 | R=25.8 D=21.6 | R=80% D=61% |

P3 should improve low-HP jitter without regressing runtime errors, LH, or empty_action.
The dominant baseline jitter keys are `low-hp-back` and `lane-line-fallback`.

## Pre-Match Command

Run this before any new test match:

```powershell
python tools\pre_match_state.py
```

If `live_matches_head=false`, deploy or explicitly label the match as a custom live-marker run.
