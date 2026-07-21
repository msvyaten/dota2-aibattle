# AIBattle State

Last updated: 2026-07-21 (after match 8907379308).

## ▶ NEXT SESSION START HERE (fresh context)

**Bot code in LIVE = HEAD = `90e7ebf`. Matchup R=brawler / D=farmer. Origin in sync.**
Only `bots/Customize/playstyle_*.lua` are dirty -- that IS the live matchup, do not commit
them without an explicit order. Never `git add -A` in this repo; name files explicitly.

**Given a match id, run `python tools/postmatch.py <id>` once** and read `watch: pending batch`
FIRST (one row per unvalidated commit, ordered by blast radius), then `empty_action by winner`,
then `farm drivers`. Then `python tools/pathology.py <id>` for the watchability shapes.
The scorecard passing does NOT mean healthy: empty/min read 8.4 against a limit of 13 while
~45% of those ticks were structural no-ops.

**Compare counters PER MINUTE, never raw.** 8907379308 ran 13.7 min against the previous 7.5;
read raw, `anti-idle-lane` 24 -> 28 looks like a regression when per minute it fell 3.2 -> 2.0.

**Evidence hierarchy (this cost three wrong diagnoses on 21.07):** positions+hp over time
(`t=..s hp=..% loc=..`) > plain `Style.Diag` counters > `Style.Intent` reason strings, which
are rate-limited and must be read as a LOWER BOUND only. Mark every claim as proven or
hypothesis; do not commit a fix on an unverified theory.

**Validation debt** = `git log <build-sha-from-the-match-log>..HEAD`. Do not carry a total
forward by hand -- a played match clears everything up to its own build.

### Awaiting validation (debt from `c97c618`)
- `e344e49` -- no salve during a committed fountain trip. The salve is eaten by the VENDOR
  rule in `ability_item_usage_generic`, not by our sites: `f942b46` guarded ours and read
  consume-blocked=0 for a whole match. Signature `blocked=heal-item reason=fountain_trip_committed`.
- `39e3e6b` -- the twitch pair. `fwd-position` bypassed its cooldown entirely past 1600 units
  (17 -> 109 in 63s) and `hero-prio-chase` had no throttle at all (88 in the first 93s). Both
  now throttled and wired into Motor; `fwd-position` was the one positioner never in it.
  Baselines to beat: fwd-position 10.0/min, hero-prio-chase 12.1/min.
- `90e7ebf` -- tools only.

### Open, needs a decision before any fix
1. **Fountain trips at 30-34% HP.** Four of nine trips in 8907379308 were at 15-25% (correct);
   three were at 30-34%, all from the extended `no_sustain_floor` that `183a5f7` made reachable
   after five silent matches. User called those out as "why did it go at all". Two candidate
   fixes, DEFERRED by the user: raise the floor's band, or teach it the rune timer (a bot with
   an empty bottle 20s before a rune spawn should take the rune, not walk home).
   ⚠️ Do NOT re-add a mid-trip abort: the user rolled that back on 21.07 -- a committed floor
   trip runs to completion because it also restores mana and bottle charges.
2. **"Started drinking a salve -> do not enter a trade"** (user rule, any trade cancels it).
   Not implemented.
3. **Rune spawn inference** -- confirmed in the log (8907379308 t=351-361: staged to dist=0,
   then `stage_dead_window nearest=inf`, ~15s wasted, rune had spawned at the other side).
   User parked it as a future item.
4. **Damage-by-source probe v2 FAILED** -- `death=0` and `other` still 16-24%: the sampler does
   not run while the bot is dead, so the death bucket never fills. Until this is fixed, any
   "who is chewing on me" claim is unsupported.

### Diagnosed, ready, no match needed
- **`trade.lua` forks `moveToAttackEdge`** (`:41`), and its copy is NOT melee-pack aware. Used
  by the three URGENT-stage handlers (KillLock, HealInterrupt, PassingHeroTrade), which run
  before the arbiter -- so it undercuts `3e64ecb` on that path. Highest-value dedup left.
- **`HandleCreepWork` is the only handler built a hand-rolled ctx** (18 keys) instead of
  `runtimeCtx`, which is why it has no `ctx.blocked` / `ctx.meleeCreepCentroid` and why cs-walk
  and deny were awkward to instrument.
- **Three shipped fixes have never shown their signature.** `recovery_commit` was unobservable
  by construction and is fixed (`604de19`); `fountain-init-skip` has a real but very thin
  window (base area, outside the aura, no latch -- usually skipped by TP'ing out) and must NOT
  be treated as an acceptance gate; `power-rune-candidate/no_action_capped` needs the bot to be
  HOLDING an action rune, which SF rarely is.

### Refuted -- do not retry
- **cs-walk is NOT the root of low farm.** 133 side-matches (`tools/farm_drivers.py`):
  cs-walk/min correlates **+0.35** with lh/min, i.e. it marks CS activity, not cost. It is
  SIDE-determined (Radiant 11.7-13.4/min vs Dire 6.3-7.2/min, archetype effect ~0) -- the old
  "the farmer walks in for every last hit" reading came from matches where the farmer happened
  to be Radiant. The real predictor is time below 45% HP (**-0.40**).
- `deny-act` is not an 8% conversion story either -- the probe split it and 75-80% are real
  swings; the enemy contests the same creep. Same trap cs-walk fell into; do not re-open
  either without splitting the counter first.
- "The farmer is not in lane" (87% in lane) and "wave-watch parks it out of range" (13% of
  holds lead to a cs-walk vs 16% for the brawler).

### LLM experiment
Schema now matches the engine (`docs/PROMPT_DRIFT.md`, sections A/B/C/E + corrections
appendix). No API key is involved: the user runs the prompt in an LLM UI and hands the JSON
back, which goes in via `--radiant-json` / `--dire-json` through the same sanitiser.
`water_rune` is reachable in the engine but
deliberately kept out of the generator whitelist until a match tests it.
⚠️ The schema describes the ENGINE, which also runs 5v5 -- do not delete a dial because it is
inert in 1v1 mid. ward_desire/roshan_desire were removed on that reasoning and restored.

---

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
2. **DONE:** `postmatch.py` watch section reports `recovery-owner` episode
   signatures for P3-B acceptance (plus recover-cap/dive-floor triage signatures;
   secure-LH v2 retired 19.07 -- structurally shadowed by last-hit-urgent 140).
3. Do NOT fix bottle/rune-seek point-wise — systemic chain, P3+P1 cure it.

**Fable high — acceptance only, one pass after the first P3-B match:** re-run the
updated postmatch on baseline logs `8886935149`/`8886970304` (old jitter proxy vs
episodes on the same data — honesty check); accept by low-hp-back episodes ↓ without
regressing errors/LH/empty_action/bottle; watchability judged by eye. Arbitration if
a cutover spot isn't covered by §2.6.

**After P3-B acceptance:** P3-C (windup gate + safe-CS + rune-seek), then P1-A —
Fable reviews the §3.6–3.7 candidate registry for the eager-diag trap *before*
implementation starts.

## Findings 2026-07-09 (Fable) — P3-B.1 accepted, order revised

- **P3-B.1 (`e0bc99f`) ACCEPTED.** Two matches (8888053119, 8888664145): old retreat
  diags = 0, episodes ≤14/side, empty_action safe, LH ≈ baseline. Honesty check: the
  old proxy counted 76–123 `low-hp-back` re-issues where the episode counter records
  ≤14 decisions — ~9× inflation removed by construction.
- **Rune diagnosis CORRECTION (do NOT patch runes.lua):** in 8888664145 D's bottle-rune
  window, staging→pickup worked (`pickup_attempt` logged). The rune was lost because
  `ActiveLowHp mode=back` (SOFT band, threat=false) overrode the committed pickup move
  on alternating ticks (dist stuck at 91, rune aged out → `gone`). This is a committed-
  transaction violation in the recovery layer, not a rune-engine bug.
- **Next fix (Opus): rune-commit yield guard** in `ActiveLowHp` — while a bottle-rune
  commit window is active (`aib_bottleRuneStarted`, same signal as fwd-suppress) and
  band is soft/caution and not threatened, positional branches yield so the persisting
  pickup move completes. Signature: `blocked=recovery-owner reason=rune_commit`.
  CRITICAL/threatened never yield. This is the §2.2 "rune-seek if reachable" point —
  a P3-C down-payment, not an ad-hoc patch.
- **Revised order:** rune guard → P1-A (lane-line-fallback 84/89 is now the dominant
  jitter key; gated on Fable's §3.6–3.7 registry re-pin — anchors are stale) →
  P3-B.2 (architecture completion, metric already banked) → P3-C rest. Prewave
  Farmer/Brawler stays parked (config-level, on explicit order only).
- **09.07 late (Fable):** registry re-pin DONE (SPECS §3.6.1). Rune guard deployed+pushed
  (`3957992`). Match 8888743934 forensics: siege desire has NO canAct cap (P4 hole) —
  siege empty-wins pace at the tower; the cap is folded INTO P1-A phase A as part of its
  intended change (SPECS §3.6.1 addendum) — do NOT ship it as a separate fix. Prewave
  verdict: `canonical_farmer` runs `pregame_behavior="aggressive_mid"` — config bug, the
  farmer must decline early duels; engine already gates duel by config + hpFloor.
  Creep-aggro disengage in the duel module = small backlog guard after P1-A.
  Pipeline: farmer config edit → match on 3957992 (validates rune-guard + config, captures
  phase-A baseline greps) → Opus implements phase A per §3.6.1 → match → Fable acceptance.

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
