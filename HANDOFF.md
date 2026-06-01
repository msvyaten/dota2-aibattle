# HANDOFF — AIBattle Dota 2 Validation (for Claude running on the Windows/Shadow PC)

You are picking up an in-progress project. Read this fully before doing anything.
The user previously worked with another Claude on a Mac; the game kept crashing on
macOS, so the whole setup was moved to this Windows machine (Shadow PC, native x86).
Communicate with the user in **Russian** — that is their language.

---

## 1. Goal

Validate the AIBattle concept in Dota 2: prove that a **natural-language prompt given
before the match measurably changes how the bot plays** in a 1v1-style mid scenario
(same hero on both sides). It's a proof-of-concept demo, not a product.

## 2. Scenario

- **Game mode:** All Pick (we switched away from 1v1 Solo Mid — see crash history).
- **Heroes:** Sniper mid (pos2 both teams), IO on other positions.
- **Base bot scripts:** OpenHyperAI (April 2026 build, 127 heroes), with our patches on top.
- **Two sides, opposite playstyles:** Radiant = aggressive, Dire = passive. The bot
  behaviour should visibly differ according to those configs.

## 3. Architecture

```
Prompt (natural language) → GPT-4o → JSON params → playstyle_*.lua
    → mode_laning_generic.lua patch → observable bot behaviour
```

- **Phase 1 (current):** hardcoded playstyle configs to prove behaviour changes.
- **Phase 2 (ready, untested):** Python backend turns real prompts into those configs.

## 4. File locations on THIS Windows machine

Our scripts live in (or must be copied to) the Dota 2 vscripts path:

```
C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots\
```

If `scripts\vscripts` doesn't exist yet, create it, then copy the `bots\` folder from
the transferred bundle (`dota2-aibattle-bundle.zip`) into it.

Key files (already patched by us — do NOT overwrite with vanilla OpenHyperAI):
- `bots\mode_laning_generic.lua` — patched with AIBattle harass logic; **Think() is now
  defined unconditionally** (this fixes a vanilla OpenHyperAI crash, see §6).
- `bots\hero_selection.lua` — patched so Sniper is picked at pos2 (mid) for both teams.
- `bots\Customize\general.lua` — IO×4 + Sniper for pos2 per team.
- `bots\mode_laning_generic.aibattle.lua` — backup of an earlier patch version.

Python backend (Phase 2):
- `backend\generate_playstyle.py` — CLI: prompt → GPT-4o → playstyle files.
- `backend\system_prompt.txt` — LLM instructions.
- `backend\test_generate.py` — pytest tests.

## 5. Playstyle parameters (5 fields)

| Param          | Radiant (aggressive) | Dire (passive)        |
|----------------|----------------------|-----------------------|
| harass_desire  | 0.85                 | 0.05                  |
| farm_priority  | false                | true                  |
| tower_safe     | false                | true                  |
| ability_aggro  | true                 | false                 |
| rune_control   | true (set, not yet hooked) | false           |

## 6. Critical history — the crash that moved us to Windows

On macOS the Dota 2 bot lobby crashed at **~28–30 seconds** every time with
`EXC_GUARD / INVALID_OPTIONS` on mach port 0 (codes `0x0000000009c00000`,
`0x8001430200000003`). We confirmed it was a **Dota 2 engine bug on macOS, NOT our
scripts** — it crashed with our code, with vanilla OpenHyperAI, AND with Valve default
bots. That's why we're now on Windows, where this is expected to be gone.

**Separately**, we found a real vanilla OpenHyperAI bug: `mode_laning_generic.lua`
defined `Think()` inside a conditional that is false for normal heroes in all-bot 1v1
games, so the engine called a nil `Think()` → crash. Our patched version defines
`Think()` unconditionally. Keep that fix.

## 7. FIRST thing to verify on this machine

The whole point of moving to Windows: confirm the lobby survives past the 28–30s mark.

1. Set Dota 2 launch option: `-condebug` (writes console output to a log file).
2. Create Lobby → **All Pick** → add Local Dev Script bots → Start.
3. Watch whether the match passes **~30 seconds without crashing**.
   - If yes → the macOS engine bug is gone, and we can finally observe bot behaviour.
   - If it still crashes → capture the console log and investigate; this would be new.
4. Console log location (with `-condebug`):
   `...\dota 2 beta\game\dota\console.log`

## 8. What "success" looks like

Once the match runs, watch the two Snipers in mid lane and confirm the configs produce
**visibly different behaviour**: Radiant Sniper should harass aggressively (uses
abilities on the enemy, trades hits, less tower-hugging); Dire Sniper should play
passively (farms, hugs tower, avoids trades). That contrast IS the validation.

## 9. Phase 2 (ready, not yet tested) — prompt → config

```
cd backend
set OPENAI_API_KEY=your_key
python generate_playstyle.py ^
  --radiant "Атакуй врага постоянно, используй шрапнель" ^
  --dire    "Фармь безопасно под башней" ^
  --output-dir "..\bots\Customize"
```
Then re-copy the `bots\` folder to the Dota 2 path and launch.

## 10. Suggested order of work

1. Confirm scripts are in the correct vscripts path (§4).
2. Run the §7 crash check first — nothing else matters until the lobby is stable.
3. If stable, observe and tune the Phase-1 hardcoded configs until the aggressive vs
   passive contrast is clearly visible (§8).
4. Only then test Phase 2 (§9).

Ask the user before making large changes. Report findings back so they can update their
project memory.
