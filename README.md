# Dota 2 AIBattle - Installation

## Copy to Dota 2

macOS:
```bash
VSCRIPTS="$HOME/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/dota/scripts/vscripts"
cp -r bots "$VSCRIPTS/"
```

Windows:
Copy the `bots/` folder to:
`C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\`

Note: BotLib/, FunLib/, and Customize/ all live inside bots/ - one copy command handles everything.

## Test it works

1. Launch Dota 2
2. Create private lobby -> Game Mode: 1v1 Solo Mid -> Fill empty slots with bots
3. Start game, open console with `~`
4. Confirm no `[Lua Error]` lines appear
