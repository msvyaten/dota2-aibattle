# AIBattle State

Last updated: 2026-07-08.

Static source of truth before starting a match: stage, next allowed task, what not to
touch, and P3 baselines. Long design notes live in `docs/SPECS.md`,
`docs/HANDOFF_PACKAGE.md`, and `docs/BACKLOG.md`.

**Volatile state is not duplicated here** (it drifts). For the live snapshot — HEAD,
upstream, live marker, live/HEAD match, resolved Radiant/Dire presets, dirty tree —
run the tool:

```powershell
python tools\pre_match_state.py
```

If `live_matches_head=false`, deploy `HEAD` or explicitly record that the match uses a
custom live marker. If the tree is dirty, commit configs **only on explicit user
request** (playstyle/canonical are a living matchup) or record them as a local
experiment.

## Current Stage

Completed:

- Gate 0: technical runtime gate passed.
- Gate 1: new architecture beat phase-22 comparison.
- Stage 0.5: watchability package accepted.
- P3-A slice 1: `Recovery.Owner` skeleton.
- P3-A slice 2: `EmergencyRetreat` and `ForwardLowHpPullback` register on `Recovery.Owner`.

Next structural task:

- P3-B: dissolve `ActiveLowHp` / regen-lane / heal-pullback / step-back into
  `Recovery.Owner` episode actions, and update `postmatch.py` / `scorecard.py` in the
  same commit so low-HP jitter is counted by episodes.

Do not start P1 arbiter migration before P3 unless explicitly redirected.

## Cycle Plan — Roles (agreed 2026-07-08)

One tact = one code owner. Do not edit the same Lua files in parallel.

**Opus (Claude) — owns P3-B implementation.** Strictly per SPECS §2.6 (11 cutover
points, soft-through-desire, `safetyCanAct` trap). 2–3 slices, max ~6 changes per
match: first the per-move-diag → episode cutover **plus `postmatch.py`/`scorecard.py`
in the same commit**, then cut ActiveLowHp's safety leg. One slice — one log
signature — one match between slices. `pre_match_state.py` before every match.

**Codex — review + tooling (in parallel, not the same Lua files):**

1. Checklist-review of Opus's P3-B diffs against the SPECS §2 mandate: all 11
   cutover points covered, fight↔safety loop dead, episode diag not re-issued
   per tick.
2. **DONE by Codex:** `postmatch.py` watch section now reports `creep-hit-react-lh`
   (secure-LH v2, still unvalidated) and `recovery-owner` episode signatures for
   P3-B acceptance.
3. Do NOT fix bottle/rune-seek point-wise — systemic chain, P3+P1 cure it.

**Fable high — acceptance only, one pass after the first P3-B match:** re-run the
updated postmatch on baseline logs `8886935149`/`8886970304` (old jitter proxy vs
episodes on the same data — honesty check); accept by low-hp-back episodes ↓ without
regressing errors/LH/empty_action/bottle; watchability judged by eye. Arbitration if
a cutover spot isn't covered by §2.6.

**After P3-B acceptance:** P3-C (windup gate + safe-CS + rune-seek), then P1-A —
Fable reviews the §3.6–3.7 candidate registry for the eager-diag trap *before*
implementation starts.

**Routine (Opus fast / Sonnet):** swaps, deploy (cp + sha stamp), git batches on
command, per-match postmatch runs. Watchlist items (P4 empty_action, mutual gambles)
stay parked unless explicitly ordered.

## P3 Baseline

Baselines are static snapshots — pinned on the **current fix stack** (code `c1cd4e4`) so
P3's delta is attributable and not conflated with intervening fixes. Both are short,
P3-dominant matches (jitter driven by `low-hp-back`), which is exactly the signal P3
targets.

| Match | Len | Matchup / Result | Runtime | Empty Action | Jitter/Min | Bottle Empty |
| --- | --- | --- | --- | --- | --- | --- |
| `8886935149` | 5.9m | R=brawler D=farmer · Dire won | R=0/D=0 | R=63 D=63 | R=26.8 D=19.7 | R=80% D=80% |
| `8886970304` | 6.6m | R=farmer D=brawler · Dire won | R=0/D=0 | R=79 D=55 | R=27.4 D=13.1 | R=76% D=52% |

Dominant jitter key both matches: `low-hp-back` (123/69 in 8886970304; 76/64 in
8886935149), `lane-line-fallback` secondary. Watch item: `critical-recover-hold`
spiked to R=14 D=35 in 8886970304 — legit safe-regen (D won, nobody died standing),
but judge watchability by eye.

P3 should cut low-HP jitter (`low-hp-back` episodes) without regressing runtime errors,
LH, empty_action, or bottle.
