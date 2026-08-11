# AIBattle Handoff

Короткий операционный справочник. Текущий план: `docs/STATE.md` и `docs/BACKLOG.md`.
Архитектура: `docs/ARCHITECTURE.md`; карта файлов: `docs/CODE_MAP.md`; крупные мандаты:
`docs/SPECS.md`. Полная старая версия — в истории git:
`git show ae2604d:docs/HANDOFF.md`.

## Cold Start

```powershell
python tools\pre_match_state.py
python tools\check_all.py --skip-live
```

Не копировать HEAD/LIVE из документации. `pre_match_state.py` показывает ветку, upstream,
live marker, bindings и грязные файлы на текущей машине.

## Пути

- Repo: `C:\Users\Shadow\dota2-aibattle`
- Dota root: `...\dota 2 beta\game\dota`
- LIVE bots: `...\dota\scripts\vscripts\bots`
- Logs: `console.<matchid>.log`
- Replay: `<matchid>.dem`

Перенос установки без правки исходников:

- `DOTA_LOG_DIR`
- `DOTA_BOTS_DIR`
- `DOTA_REPLAY_DIR`
- `DOTA_ITEMBUILDS_DIR`

## Владение

- Runtime, tooling, telemetry, deploy: Codex.
- Canonical/generated strategies и live matchup: обычно Claude.
- `playstyle_radiant.lua`, `playstyle_dire.lua`, `general.lua` являются состоянием эксперимента,
  а не обычным source-кодом. Не коммитить без прямой команды.
- При параллельной работе перед редактированием и коммитом перечитать `git status` и diff.
  Не откатывать незнакомые изменения.

## Проверки

Локальный gate:

```powershell
python tools\check_all.py --skip-live
```

Он проверяет encoding, Lua/Python syntax, deploy manifest, runtime modules, schema contract,
51+ тест и project inventory. Полная проверка после deploy:

```powershell
python tools\check_all.py
```

Она дополнительно требует `HEAD == LIVE`, отсутствие drift и stale runtime-файлов.

Перед любым утверждением «эта функция мертва / недостижима / никогда не срабатывает»:

```powershell
python tools\check_all.py --twins <ИмяФункции>
```

Печатает все определения с похожим именем и file:line. Греп находит код, но не доказывает
о нём ничего — тело надо прочитать целиком, и у всех однофамильцев тоже.

## Deploy

```powershell
tools\deploy.bat check
tools\deploy.bat code
tools\deploy.bat playstyle
tools\deploy.bat all
tools\deploy.bat general
```

- `code` — runtime, безопасный default.
- `playstyle` — canonical presets и live bindings.
- `all` — code + playstyle, без `general.lua`.
- `general` — только явный lobby/general sync.
- `check` — dry run.

После code deploy перезапустить lobby и подтвердить полный `check_all.py`.

## Матч

Основной анализ:

```powershell
python tools\postmatch.py <matchid>
python tools\pathology.py <matchid>
python tools\betting.py <matchid>
```

Дополнительно:

- `match_stats.py` — полная телеметрия, counters, timeline, items и farm trace;
- `scorecard.py` — критерии watchability;
- `binding.py` — доказательство связи config knob -> behavior;
- `series.py` — серия на frozen build/config;
- `project_inventory.py` — размер и ownership debt.

## Чтение Данных

Доказательства по убыванию силы:

1. позиция, HP, цель и действие во времени;
2. tick owner и transaction/episode telemetry;
3. cumulative diag counters;
4. rate-limited intent/blocked строки как нижняя граница;
5. визуальное наблюдение с точным timestamp.

Raw counters между матчами разной длины не сравнивать: использовать rate/min. Build матча
берётся из его лога. Validation debt вычисляется как `git log <match-build>..HEAD`.

## Config Pipeline

Живой model-facing schema находится в `backend/style_schema.py` и автоматически сверяется с
`bots/FunLib/aibattle_style.lua`, `backend/system_prompt.txt` и canonical configs.

Основной путь без API:

```powershell
python backend\generate_playstyle.py --radiant-json <file-or-json> --dire-json <file-or-json> --output-dir bots\Customize
```

Опциональный API path использует `OPENAI_API_KEY` и `AIBATTLE_OPENAI_MODEL`.

## Git

Индексировать только названные файлы. Не использовать `git add -A` при грязных bindings.
Force-push и destructive reset запрещены. После push проверить:

```powershell
git rev-list --left-right --count origin/phase-2-team-dials...HEAD
```

Ожидаемый результат синхронизации: `0 0`.
