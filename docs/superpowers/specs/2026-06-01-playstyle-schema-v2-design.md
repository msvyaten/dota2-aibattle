# Playstyle Schema v2 — Design

> Date: 2026-06-01. Project: AIBattle × Dota 2 validation.
> Status: design approved by user, pending spec review → implementation plan.
> Builds on validated Phase 1 + Phase 2 (prompt → LLM → JSON → playstyle_*.lua → behaviour).

## Goal

Increase the **expressiveness** of the playstyle control surface in two ways:
1. Convert the existing boolean fields to continuous **0–1 dials** (a "dimmer", not a switch),
   so the same fields produce many more distinct styles and naturally cover intermediate values.
2. Introduce a second control type — **rules** (discrete event→action behaviours) — starting with
   `respawn_behavior` (teleport-to-tower-after-death).

Scope of v2 = **duel-observable controls only** (validatable in 1v1 Sniper mid). Team-oriented
dials (gank/push/defend/roshan/ward) are explicitly deferred to **schema v3** (validated at 5v5).

## Non-goals (v2)

- No team-oriented dials (deferred to v3).
- No LLM code generation. The LLM only emits numbers (0–1) and enum values from a whitelist.
- No new heroes / no 5v5 (those are later roadmap phases).

## File format — `playstyle_<team>.lua`

The config moves from a flat table to two named sections, `dials` and `rules`:

```lua
return {
    dials = {
        harass_desire   = 0.85,  -- 0–1: frequency of attacking enemy hero
        farm_focus      = 0.10,  -- 0–1: 0 = pure harass, 1 = pure last-hitting
        forwardness     = 0.90,  -- 0–1: 0 = glued to tower, 1 = aggressive front
        ability_aggro   = 0.80,  -- 0–1: frequency of Shrapnel on hero
        rune_control    = 1.00,  -- 0–1: pull toward contesting runes
        retreat_caution = 0.20,  -- 0–1: 0 = fights to the end, 1 = retreats early
    },
    rules = {
        respawn_behavior = "tp_to_tower",  -- tp_to_tower | tp_to_lane | walk_back
    },
}
```

## Section `dials` — 0–1 tendencies (all duel-observable)

| Field | Range | Hook (file) | Mapping to behaviour | Replaces |
|---|---|---|---|---|
| `harass_desire` | 0–1 | mode_laning | `random() < dial` → attack enemy hero | (existing dial) |
| `farm_focus` | 0–1 | mode_laning | balance last-hit ↔ harass | bool `farm_priority` |
| `forwardness` | 0–1 | mode_laning | how far forward of own tower the bot stands | bool `tower_safe` (inverted) |
| `ability_aggro` | 0–1 | mode_laning | frequency of casting Shrapnel on hero | bool `ability_aggro` |
| `rune_control` | 0–1 | **mode_rune** | `Desire *= dial` (NEW hook — currently declared but unused) | bool `rune_control` |
| `retreat_caution` | 0–1 | **mode_retreat** | `Desire *= dial` → retreats earlier/later | (NEW dial) |

Notes:
- `forwardness` is the inverse of the old `tower_safe` (1.0 = most aggressive front).
- `farm_focus` and `harass_desire` are related but distinct: `farm_focus` governs CS-vs-harass
  balance; `harass_desire` governs how often the bot actually swings at the hero when in range.
- **Dial→behaviour mapping (3 kinds), so 0.5 always means "baseline":**
  - **Frequency dials** (`harass_desire`, `ability_aggro`): dial is used directly as a probability —
    `math.random() < dial`. (0 = never, 1 = always.)
  - **Desire-multiplier dials** (`rune_control`, `retreat_caution`): map dial∈[0,1] to a multiplier
    `m = 2 * dial`, then `GetDesire() * m`, clamped to the engine's valid desire range.
    So **0.5 = baseline (×1), 0 = suppressed (×0), 1.0 = amplified (×2)**. This lets a dial both
    damp AND amplify a behaviour relative to the bot's natural tendency.
  - **Balance/position dials** (`farm_focus`, `forwardness`): scale thresholds / target positions
    inside `Think()` (e.g., `forwardness` interpolates the standing position from own-tower to
    lane-front; `farm_focus` shifts the last-hit-vs-harass decision threshold).

## Section `rules` — discrete event→action behaviours

| Rule | Values | Behaviour |
|---|---|---|
| `respawn_behavior` | `tp_to_tower` / `tp_to_lane` / `walk_back` *(default)* | On death→alive transition: act per value |

`respawn_behavior = "tp_to_tower"` semantics (per user decision):
- TP to the friendly tower **nearest to the fight / lane front**, NOT the one nearest the fountain.
- Concretely: if the **most-forward surviving** friendly tower on the active lane is T1 (tier-1),
  TP to T1; if T1 is dead, fall back to the next surviving tower toward the front (T2, …).
- In 1v1 mid this resolves to: mid T1 if alive, else mid T2.
- Implementation: detect respawn, use `item_tpscroll` on the chosen tower's location.
  (OHA already handles TP scrolls in `mode_roam_generic.lua` — reuse that machinery.)
- `tp_to_lane` = TP to lane front (current OHA default-ish). `walk_back` = no TP, walk.

The `rules` section is designed to be **extensible**: each rule is an independent named handler
that does not affect the others. `respawn_behavior` is the first; more rules join in later schemas.

## Layer changes (for the implementation plan)

1. **`backend/system_prompt.txt`** — rewrite for the nested schema: describe every dial as a 0–1
   float, describe `rules` enum values, give a valid nested-JSON example, demand JSON-only output.
2. **`backend/generate_playstyle.py`** — validate the nested structure; **guardrails**: clamp dials
   into 0–1; validate each rule value against a whitelist (unknown → safe default `walk_back`);
   unknown keys ignored. Update `write_playstyle_lua` to emit the nested `dials`/`rules` tables.
3. **`bots/mode_laning_generic.lua`** — `GetPlayStyle()` returns `{dials=…, rules=…}`; `Think()`
   reads `style.dials.*`; add the `respawn_behavior` handler (death→alive detection + TP).
4. **`bots/mode_rune_generic.lua`, `bots/mode_retreat_generic.lua`** — multiply `GetDesire()`
   return by the corresponding dial (with clamp).

## Guardrails (important for the betting product)

- Dials outside 0–1 → clamped. Unknown dial key → ignored.
- Rule with unknown value → fall back to safe default (`walk_back`).
- LLM emits ONLY numbers and whitelisted enums — no code. Keeps agents predictable and explainable,
  which is required for a fair, bettable match.

## Validation plan (1v1)

For each new/changed control, run a 1v1 match and confirm the observable effect:
- `rune_control` high vs low → bot moves to rune spawns vs ignores them.
- `retreat_caution` high vs low → bot backs off early vs fights to low HP.
- `ability_aggro` graded (e.g., 0.3 vs 0.9) → Shrapnel-on-hero frequency scales (not just on/off).
- `forwardness` graded → standing distance from own tower scales.
- `respawn_behavior = tp_to_tower` → after a death, bot TPs to the forward surviving tower, not walks.

Reproduce via the existing 1v1 launch procedure (lobby 1v1 Solo Mid, load Local Dev Script bots,
kick extras), with `-condebug`; read metrics from `console.<matchid>.log`.

## Deferred to schema v3

- Team-oriented dials: `gank_desire`, `push_desire`, `defend_desire`, `roshan_desire`, `ward_desire`
  (code may be stubbed earlier, but validation requires 5v5).
- Additional rules beyond `respawn_behavior`.
