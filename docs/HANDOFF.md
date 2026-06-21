# HANDOFF — AIBattle × Dota 2

> CURRENT SHORT DOC: `docs/CURRENT.md` is the active quick reference for current laning order,
> diag keys, regression signals, and pre-match commands. Use it first; this HANDOFF keeps
> broader history and older context.

> Единственная точка входа. Обновлять ЕГО, новых доков не плодить.
> Последнее обновление: 2026-06-20 (Codex phase-24: small decision engine, safe deploy profiles, canonical configs).
> Полная история сессий — `docs/history/HANDOFF-full-2026-06-09.md`.
> По-русски. Доказательство = цифра из лога или stат-дампа. «На глаз» не считается.

---

## 1. Пути / окружение

- **Репо:** `C:\Users\Shadow\dota2-aibattle` · ветка `phase-2-team-dials` · git-личность: `don / don@users.noreply.github.com`
- **LIVE (что грузит Dota):** `…\dota 2 beta\game\dota\scripts\vscripts\bots\`
- **Deploy:** `tools/deploy.bat [code|playstyle|all|general|check]`; default `code`, `general.lua` только явным профилем.
- **Конфиги:** live bindings = `bots/Customize/playstyle_radiant.lua` / `playstyle_dire.lua`; канон = `bots/Customize/canonical_*.lua`; старые тесты = `archive/dota/legacy_playstyles/`
- **Логи:** `…\game\dota\console.<matchid>.log` (опция `-condebug`)
- **Анализ:** `python tools/match_stats.py <id> [id2 …]` — KDA/LH/урон/предметы/диаги по слотам
- **1v1 лобби:** Solo Mid, читы ON, хост зрителем, Local Dev Script, кикнуть слоты 1–4 и 6–9

---

## 2. Архитектура (файл → роль)

| Файл | Роль |
|---|---|
| `FunLib/aibattle_engine.lua` | Мини-движок стадий: stage возвращает handled/yield; новые top-level решения добавлять стадиями, не раздувать `Think()` |
| `FunLib/aibattle_style.lua` | Загрузчик конфига: dials/rules/item_build; ScaleDesire; HeroAbilityConfig (15 героев); M.Diag/DiagRL/Imp |
| `mode_laning_generic.lua` | Laning pipeline через `aibattle_engine`: pregame → dive → death-window → laning-core; внутри core пока сохранена старая боевая логика |
| `mode_retreat_generic.lua` | desire ×= retreat_caution; tp-fountain diag |
| `mode_rune_generic.lua` | desire ×= rune_control |
| `mode_roam_generic.lua` | gank_desire; gankGapTime=25-37s; late-hunt; AIBAntiAFK |
| `mode_push_tower_*_generic.lua` | push_desire; raw>0 guard (yield 0.15 без волны); finish-push |
| `mode_defend_tower_*_generic.lua` | defend_desire; ABSOLUTE для Ancient |
| `mode_roshan_generic.lua` | roshan_desire; roshan-kill счётчик (DiagRL 600s) |
| `mode_ward_generic.lua` | ward_desire |
| `item_purchase_generic.lua` | item_build override sBuyList; item_rules (opt-in) |
| `BotLib/hero_nevermore.lua` | SF: skill_build дефолт, item_build pos_2 (OHA) |
| `Customize/general.lua` | Состав: pos1 обе стороны; имена ChatGPT_1-4/Gemini_1-4 |
| `tools/match_stats.py` | Парсер логов: KDA/LH/items(decoded)/diags; dial-таблица R vs D; stationary spans из `AIB[...] t=... loc=...` |
| `tools/deploy.bat` | Профильный deploy dev → LIVE: default `code`, `playstyle` копирует canonical + live bindings, `general` только явно |

---

## 3. Что доказано (схема v2 + phase-3)

**Диалы:** `harass_desire` ✅ (мили 6.5×), `forwardness` ✅, `retreat_caution` ✅, `execute_threshold` ✅,
`ability_aggro` ✅ (SF 6.2×, directional), `gank_desire` ✅, `ward_desire` ✅, `push_desire` ✅ (closeout-фикс).
`rune_control` ❌ deferred (подавлен в 1v1 арбитражем laning 1.0). `farm_focus` 🟡 косвенно.

**Rules:** `respawn_behavior` ✅, `dive_policy` ✅, `smoke_usage` ✅, `buyback_policy` ✅ (`never` блокирует; `always` удалён).

**LLM-пайплайн:** промпт → ChatGPT → конфиг → измеримое поведение ✅ (8838539380: Pusher towerDmg 7926 vs Ganker 159).

**Rules (перенесены из improvements):**
- `healing_style=active` ✅ — heal-item/tango/bottle/regen работают; `heal-pullback` ✅ (8846034123). Изолировано: Radiant bottle-heal R#14 / tango-heal R#2, Dire — ничего (8848634192)
- `ability_usage=aggressive` ✅ — SF raze изолирован на Dire: ability-harass D#10, у Radiant — 0 (8848634192). AbilityHarass теперь проверяет `ability_usage == "aggressive"` как первый gate.
- `build_style` ✅ — brawler/spellcaster сборки выбираются из 3-стильного item_build (8848634192: R→brawler, D→spellcaster)
- `anti_afk`, `tower_avoid` — удалены из активного schema-пути как мёртвые флаги без потребителей

**pregame_behavior** ✅ (10.06.2026) — pg-called D#267 R#273 стабильно; pregame-aggressive_mid/safe_tower в диагах. Бот идёт к правильной позиции до крипов.

**raze1 убран из SF harass** (10.06.2026) — `ability-harass-move` снизился R#12→R#1 (8846034123→8846050605). Только raze2 (300–600) и raze3 (550–850).

**Подробности + пруфы:** `docs/history/HANDOFF-full-2026-06-09.md` §3–§21

---

## 4. Rules-система (краткая)

**Принцип именования:** `default` = OHA делает своё, мы не вмешиваемся. Если мы добавляем свою логику — даём описательное имя (например `finish_only`, `active`).

| Rule | Значения (дефолт жирным) | Счётчик | Статус |
|---|---|---|---|
| `respawn_behavior` | walk_back / tp_to_lane / **tp_to_tower** | teleports_used | ✅ |
| `dive_policy` | never / **finish_only** / always | `no-dive` | ✅ |
| `smoke_usage` | **default** / never | `smoke` | ✅ |
| `buyback_policy` | never / **default** | — | ✅ |
| `low_hp_behavior` | **tp_fountain** / run_to_tower / fight_back / regen_lane / walk_fountain | `tp-fountain` / `regen-lane` / `retreat-blocked` / `recovery-*` | ✅ |
| `aegis_policy` | **core** / any | — | ✅ |
| `healing_style` | never / **default** / active | `bottle-heal` / `tango-heal` / `heal-item` | ✅ |
| `ability_usage` | **default** / aggressive | `ability-harass` | ✅ |
| `creep_wave_priority` | **last_hit_only** / push / freeze | `cw-push` / `cw-freeze` | ✅ |
| `ability_timing` | **on_cooldown** / save_for_execute / harass_only | — | ✅ |
| `hero_priority` | always / **default** / never | `hero-prio-always` | ✅ |
| `tower_aggression` | always / **default** / never | — | 📋 PLANNED |
| `deny_policy` | always / **default** / never | `deny-act` | ✅ |
| `trading_policy` | **trade_back** / survive / all_in | — | 📋 PLANNED |
| `fountain_trip` | **never** / once_per_death / free | — | 📋 PLANNED |

**Bettability (phase-16/17, 12.06.2026):** A Duelist (harass=0.85/abil=0.90) vs B Farmer (harass=0.10/farm=0.90) — A побеждает 3:1 (8 матчей, все по убийствам, 4–10 мин). Линия существует. ✅

**Improvements** не расширять. `defensive_heal` и `ability_on_dials` перенесены в rules; backward compat оставлен только для этих двух старых имён. Неиспользуемые `anti_afk`/`tower_avoid` удалены из active schema, чтобы не плодить флаги без владельца.

---

## 5. Статус последних фаз

**phase-17 — ЗАКРЫТ ✅ (8848634192, 12.06.2026)**

Тест build_style brawler (R) vs spellcaster (D). Все проверки пройдены:

| Проверка | Результат |
|---|---|
| Radiant покупает brawler (tango/branches/bottle/bracer) | ✅ |
| Dire покупает spellcaster (slippers/null×2/faerie_fire/bottle/phase_boots) | ✅ |
| healing_style=active изолирован на Radiant | ✅ bottle-heal R#14, tango-heal R#2; Dire — 0 |
| ability_usage=aggressive изолирован на Dire | ✅ ability-harass D#10; Radiant — 0 |
| Баг: recovery-rune-bottle уходил к вражескому святилищу (7min) | 🐛 → FIXED |

**Текущий тест:** LongGame v2 (оба бота одинаково: harass=0.50 abil=0.35 fwd=0.50 exec=0.15 farm=0.80, dive=never, hero=default, pregame=safe_tower). Базовый smoke-тест движка после lane-stability фиксов.

---

**phase-18 — LANE STABILITY (16.06.2026) — закоммичено, требует LLM-тест**

Все фиксы ниже применены и закоммичены. Следующий шаг — запустить A/B матч с ChatGPT vs Gemini конфигами.

| Коммит | Фикс | Результат |
|---|---|---|
| `400b1e0` | `farm_focus` bypass когда враг в радиусе атаки | Бот бил врага стоящего рядом |
| `a02555c` | Baseline attack (в радиусе = всегда бить); dt-walk не прерывает CS (1400→1000u) | Бот фармит крипов, не гоняется |
| `c3a4be8` | Tower danger check в baseline attack | Dire перестал умирать под Radiant T1 |
| `2edaa64` | `mode_farm_generic`: DESIRE_NONE в 1v1MID | Боты не уходили фармить эншентов в ~10 мин |
| `2046ad5` | `mode_roam/defend_top/bot/roshan`: DESIRE_NONE в 1v1MID | Блок роуминга, защиты side-башен, Рошана |
| `350d836` | Pregame: 500u fixed offset вместо 15% интерполяции; `enemyHuggingTower` check | Dire no-dive: D#72→D#23; прегейм чуть симметричнее |

**Новые диаги (добавлены в lane-stability):**
- `pg-loc` — координаты ботов в прегейме каждые 3с (парсит `match_stats.py`)
- `dt-walk` — бот идёт к врагу в "dead time" (нет крипов, враг 525–1000u)
- `100cs-push` — TODO: ещё не реализован, обсуждался

**Матчи lane-stability:**

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Заметки |
|---|---|---|---|---|---|
| 8854084363 | 24.2м | **Dire** | 1/1 4.6 | 1/1 6.0 | no-dive D#72 R#1 (до enemyHuggingTower); Dire фармил эншентов (до farm fix) |
| 8854228296 | 6.3м | **Dire** | 2/2 3.2 | 2/2 3.5 | no-dive D#23 (улучшение ×3); dt-walk D#5 R#7; боты активно дерутся |

**Текущий тест:** нет. Следующая задача — §6 TOP-1.

---

**phase-19 — AFK STABILITY (17.06.2026) — закоммичено ✅**

Матчи-триггеры: 8855576439 (AFK+jitter), 8855652341 (crash), 8855694172 (crash), 8855812997 (AFK+лес), 8855867210 (AFK-фонтан 141s).

**Валидационный матч 8855965648 (17.06):** `idle D#0 R#0` — настоящего idle нет. `recovery-wait` не появился (30s cap работает). `pack-avoid D#11 R#11` — все 11 срабатываний были заблокированы botAhead → fix #12 задеплоен.

### Фиксы

| # | Файл | Фикс | Причина |
|---|---|---|---|
| 1 | `aibattle_style.lua` | **Syntax crash**: `bot:GetAssignedLane` без `()` → `bot:GetAssignedLane()` | Lua-парсер крашил весь модуль при загрузке → OHA default (Рошан, гуляние). Матчи 8855652341, 8855694172. |
| 2 | `mode_laning_generic.lua` | **botAhead fix**: `fwd` не тянет бота назад к `target_loc` когда бот уже ВПЕРЕДИ цели | `fwd` каждый тик отменял `MoveToUnit` из AntiIdleGlobal → осцилляция на одном месте. Все AFK в 8855576439. |
| 3 | `mode_laning_generic.lua` | **GetUnitToLocationDistance arg order**: `GetUnitToLocationDistance(ownT1fwd, dest)` (было `(dest, ownT1fwd)`) | dest — Vector, не unit; VScript крашил с "invalid index". |
| 4 | `aibattle_style.lua` | **anti-idle-lane**: offset `-200` → `0` (фронт лайна), порог `300u` → `150u` | При offset=-200 и thresh=300u бот никогда не двигался (dest всегда < 300u от него). В 8855812997 AFK на 2:36-3:06 (30s), 5:34-6:04 (30s). |
| 5 | `mode_laning_generic.lua` | **kite-creep (retreat_caution)**: `J.VectorAway(bot, cen, 400)` → `GetLaneFrontLocation(GetTeam(), lane, -400)` | VectorAway уходил перпендикулярно лайну → лес. В 8855812997 бот застрял на -2683,-559 (90s, 4:40-5:00). |
| 6 | `mode_laning_generic.lua` | **pack-avoid**: `J.VectorAway(bl, cen, 350)` → `GetLaneFrontLocation(GetTeam(), lane, -500) or VectorAway` | Та же проблема перпендикулярного дрейфа в джунгли. |
| 7 | `mode_laning_generic.lua` | **kite-creep (melee-close)**: `J.VectorAway(bot, cen, 400)` → `GetLaneFrontLocation(GetTeam(), lane, -400) or VectorAway` | Второй kite-creep блок (hitByCreep/meleeClose ветка) тоже использовал VectorAway → лес. |
| 8 | `mode_laning_generic.lua` | **HandleRespawn no-TP walk**: при `tp==nil` или `tp`-кд теперь явно идёт к `AIB_ForwardSurvivingTowerLoc()`, возвращает `true` | Явный ход из фонтана при отсутствии свитка. |
| 9 | `mode_laning_generic.lua` | **tp_to_lane → таргетит T1, не фронт крипов**: `loc = t1:GetLocation()` вместо `GetLaneFrontLocation` | Фронт крипов Dire был глубоко во вражеской зоне; враг убивал их за 3с канала → TP отменялся → `aib_wasDead=false` → бот шёл пешком с TP в кармане. Матч 8855867210. |
| 12 | `mode_laning_generic.lua` | **pack-avoid bypass botAhead**: вместо изменения `dest` внутри fwd-блока — напрямую `MoveToLocation(packDest); return` | botAhead блокировал отступление (dest позади бота → `dBotT1 > dDestT1+100 = true`), бот оставался внутри пака крипов. Матч 8855965648: pack-avoid D#11 — все 11 срабатываний были заблокированы. |

### Корневые причины AFK в 8855812997

- **t=0-61s**: обе стороны стоят — прегейм, OHA ведёт к стартовым позициям (не баг).
- **t=81-101s, 153-183s, 334-364s**: бот на HP-aware `target_loc`, враг вне `dt-walk` (1000u), `anti-idle-lane` с порогом 300u не срабатывал. → **Fix #4**.
- **t=203-294s (4:40-5:00)**: `kite-creep` выпихнул бота в лес (-2683,-559), там `fwd` + `pack-avoid` создали равновесие вне лайна. → **Fix #5+6**.

### Новые диаги

| Ключ | Смысл |
|---|---|
| `anti-idle-lane` | AntiIdleGlobal: пошёл к фронту своего лайна (rate-limit 5s) |
| `kite-creep` | Отступил от крипов (вдоль лайна, не в джунгли) |

**Исправлено в phase-16 (12.06.2026):**
- `FunLib/aba_role.lua`: GAMEMODE_1V1MID → оба бота pos_2; диагностика через ActionImmediate_Chat
- `mode_rune_generic.lua`: guard — во время лейнинга руна только если bottle + (HP<65% или MP<40%)
- `mode_laning_generic.lua`: pre-game блок для 1v1 — движение к мид-точке через tower-lerp
- `tools/match_stats.py`: добавлены LH/мин и DN/мин в вывод

**Исправлено в phase-17 (12.06.2026):**
- `FunLib/aibattle_style.lua`: `improvements.defensive_heal` → `rules.healing_style`; `improvements.ability_on_dials` → `rules.ability_usage`; backward compat; `M.Imp()` shim; `build_style` 3-стиля; AbilityHarass gate на `ability_usage == "aggressive"`
- `FunLib/aibattle_heal.lua`: прямая проверка `rules.healing_style`; water rune distance cap 2000 (fix святилища)
- `mode_laning_generic.lua`: MSG2 анонс `heal=` + `abil=`

---

---

**phase-24 — CODEX LONG-TERM INFRA SKELETON (20.06.2026) — не продуктовый backlog**

Цель: не реализовывать новые зрительские метрики/KDA/score — это закрывается стримом. В коде оставить маленький долгоживущий скелет, чтобы следующие фиксы добавлялись как понятные стадии, а не как ещё один fallback внутри огромного `Think()`.

| # | Файл | Изменение | Почему |
|---|---|---|---|
| 29 | `FunLib/aibattle_engine.lua` | Добавлен tiny stage runner: `Stage(name, fn)` + `Run(stages, ctx)` | Единая форма для top-level решений; новый функционал должен входить отдельной стадией |
| 30 | `mode_laning_generic.lua` | `Think()` стал диспетчером `pregame → dive → death-window → laning-core`; старая боевая логика сохранена в `ThinkLaningCore` | Меньше риска сломать поведение сейчас, но дальше можно дробить core без очередной лестницы fallback'ов |
| 31 | `tools/deploy.bat` | Профили `code`, `playstyle`, `all`, `general`, `check`; default = `code`; `general.lua` не копируется без явного `general` | Случайный repo→LIVE overwrite лобби/состава больше не происходит |
| 32 | `Customize/canonical_*.lua` + `CANONICAL.md` | Канон-конфиги отделены от live bindings `playstyle_radiant/dire` | Эксперименты не портят источник правды |
| 33 | `.gitignore` | `archive/dota/local_automation/` исключён как локальная одноразовая автоматизация | Python-agent и UI-скрипты запуска не являются долгосрочной инфраструктурой Dota-проекта |
| 34 | `FunLib/aibattle_style.lua` | Удалён active `improvements`-контейнер с мёртвыми `anti_afk`/`tower_avoid`; `low_hp_hold` стал нормальным clamped rule | Флаги без потребителя больше не выглядят как поддерживаемая функциональность |
| 35 | `FunLib/aibattle_style.lua` | `buildStyle()` разгружен: dials/items/skills/item_rules вынесены в маленькие parse-функции | Парсер конфига проще расширять без разрастания одной функции |
| 36 | `FunLib/aibattle_style.lua` | `AntiIdleGlobal()` разбит на локальные шаги `combat/assist/creep/lane/push` без изменения порядка | Последний fallback читается как pipeline, а не как простыня условий |
| 37 | `archive/dota/legacy_playstyles/` | Старые неканонические playstyle-пресеты и observe-тесты вынесены из `Customize` | Активная папка конфигов больше не смешивает runtime, канон и одноразовые эксперименты |
| 38 | `mode_laning_generic.lua` + `canonical_*.lua` | Pregame больше не атакует врага до крипов; канон явно задаёт pregame/regen/heal/dive rules | Матч 8858957849: на `t=0` HP уже R=53% / D=46%, после чего первая волна становилась смертельной |
| 39 | `aibattle_style.lua` + `mode_retreat_generic.lua` + `match_stats.py` | Добавлена rate-limited intent telemetry (`intent=retreat_desire`, `intent=retreat_tp`, `intent=retreat_walk`) | Отличаем желание/попытку от шумного per-tick счётчика; `retreat-tp=170` больше не маскирует реальные эпизоды |

Правило на будущее: если новая логика top-level решает "кто ходит сейчас", добавлять её как stage в движок. Если логика является внутренней механикой уже выбранной стадии, держать её внутри соответствующего модуля и не расширять общий fallback-слой.

**phase-23 — CODEX VISUAL-AFK WATCHDOG (19.06.2026) — закоммичено Codex ✅**

Триггер-матч: 8858472901. Матч был неполный (`game=534s`, shutdown/abandon, финального stat dump нет), но telemetry доказала именно визуальный AFK: Radiant стоял `0-322s`, Dire стоял `81-393s`. При этом `cs-inrange R#441/D#149`, `deny-act R#77/D#12` показывают, что это не "код ничего не делает", а "герой стоит на месте и фармит/денает". Для зрителя это всё равно AFK.

| # | Файл | Фикс | Причина |
|---|---|---|---|
| 23 | `mode_laning_generic.lua` | **Visual AFK watchdog** перед last-hit: если герой почти не меняет координаты `visual_afk_seconds` (default/current 6s, clamp 3-12s), выдать видимый move/chase/strafe/wave/lane step | Старые fallback'и считали in-range last-hit полезным действием, но на экране бот стоял 5+ минут |
| 24 | `mode_laning_generic.lua` | Location report 10s → 5s; cfg-анонс печатает `vafk=<seconds>` | Старый 10s лог пропускал короткие AFK-окна; в следующем матче сразу видно, что порог загружен |
| 25 | `aibattle_style.lua` | Добавлены rules `visual_afk_seconds`, `visual_afk_distance`; `AntiIdleGlobal()` теперь пишет `anti-idle-enter` и возвращает true/false | Раньше `pre-aig` был, но не было видно, чем закончился AntiIdleGlobal |
| 26 | `tools/match_stats.py` | Telemetry (`t/hp/gold/loc/enemy-dist`) отделена от action-diag; выводит `stationary[R/D]` интервалы | Больше не надо руками читать координаты; AFK по картинке стал числом |
| 27 | `tools/deploy.bat` | Deploy копирует `aibattle_survive.lua` и `aibattle_utils.lua` вместо удалённого `aibattle_heal.lua` | Phase-22 удалил heal-модуль, а deploy всё ещё мог оставлять LIVE без новых shared модулей |
| 28 | `Customize/playstyle_*.lua` | Текущий тестовый конфиг: `debug_skeleton_laning` выключен, `visual_afk_seconds = 6` | Следующий матч проверяет нормальный режим + новый watchdog, а не диагностический skeleton |

Новые diag-ключи: `anti-afk-back`, `anti-afk-safe`, `anti-afk-chase`, `anti-afk-strafe`, `anti-afk-wave`, `anti-afk-lane`, `anti-idle-enter`.

Проверка перед коммитом: `match_stats.py 8858472901` показывает старые stationary spans; Python AST OK; `git diff --check` по изменённым файлам OK; Lua/luac в окружении нет. Изменения задеплоены в LIVE Dota folder, SHA256 локальных/live файлов совпал для `aibattle_style.lua`, `mode_laning_generic.lua`, `playstyle_radiant.lua`, `playstyle_dire.lua`.

Следующий тест: свежий матч должен иметь cfg `vafk=6`, должны появиться `anti-afk-*`, а `stationary[...]` не должен показывать длинные интервалы >10-15s.

---

**phase-20 — AFK STANDOFF (18.06.2026) — закоммичено ✅**

Матчи-триггеры: 8856304426, 8856343351, 8856358551, 8856380112.

| # | Файл | Фикс | Причина |
|---|---|---|---|
| 13 | `mode_laning_generic.lua` | **HandleRespawn pregame guard**: `DotaTime() < 0` → clear wasDead, return false | Бот TP-ил до крипов в прегейме; `respawn-tp-cd R#2` при втором реснере — потраченный свиток |
| 14 | `mode_laning_generic.lua` | **Death-window block** (dw-heal/dw-farm/dw-fwd): когда враг мёртв — лечиться, фармить, двигаться вперёд | Бот стоял столбом 40-60s пока враг на ресне (8856304426, 8856343351) |
| 15 | `mode_laning_generic.lua` | **dt-walk range**: 1000→1400u | Standoff на ~1288u; враг был вне старого dt-walk, ни один бот не сближался |
| 16 | `aibattle_style.lua` | **AntiIdleGlobal P1 range**: 1200→1600u | Та же причина — враг за порогом |
| 17 | `mode_laning_generic.lua` | **fwd-fallback (tower-lerp)**: когда `botAhead=true` — бот идёт к `fwd`% точке между T1-башнями вместо стояния | `botAhead` блокировал fwd когда волна крипов ещё за ботом; бот не двигался 40s+ (8856343351) |
| 18 | `mode_laning_generic.lua` | **fwd-fallback вынесен ЗА `if dest ~= nil`** | fwd-fallback не срабатывал когда dest было nil или < 150u от бота (внутри `if dest` — никогда не доходило) |
| 19 | `mode_laning_generic.lua` | **Прегейм анонс конфига** — перемещён в pregame-блок | `bot.aib_announced` в Think() мог не дойти до прегейма; теперь гарантированно печатает до старта |
| 20 | `mode_laning_generic.lua` | **pack-avoid offset**: -500→-150; VectorAway 350→200 | Бот откатывался слишком далеко от фронта, оставаясь за волной без врагов → 0 LH (8856358551) |
| 21 | `mode_laning_generic.lua` | **idle-creep-atk**: если ничего не сработало и враг-крипы в ренже — бить их | `last_hit_only` → бот стоял рядом с крипами на 100% HP без единого удара (8856358551) |
| 22 | `mode_laning_generic.lua` | **kite-creep HP-gate**: кайтить только при hp < 0.70; offset -400→-200 (оба блока) | При 65-70% HP бот кайтил и потом стоял 20s пока регенится (3:37-3:47 в 8856380112) |

### Новые диаги

| Ключ | Смысл |
|---|---|
| `dw-heal` | Death window: использовал tango/flask пока враг на ресне |
| `dw-farm` | Death window: атаковал вражеского крипа |
| `dw-fwd` | Death window: двинулся к фронту (нет крипов в ренже) |
| `fwd-fallback` | Продвижение через tower-lerp когда botAhead или dest nil |
| `idle-creep-atk` | Fallback атака вражеского крипа (последний шанс перед AntiIdleGlobal) |
| `pre-aig` | Достиг AntiIdleGlobal (счётчик частоты) |

---

## 6. Открытые задачи

| # | Задача | Приоритет |
|---|---|---|
| **0** | **⭐ Бенчмарк** — дефолтный OHA vs наш лучший конфиг (реальный прирост) | **NEXT** |
| **1** | **Кластер лейн-контроля** — `hero_priority` + `tower_aggression` + `deny_policy` + `creep_wave_priority` + `ability_timing` (дизайн готов, §11) | **TOP-1** |
| **2** | **Item build вариативность** — Layer 1 ✅; Layer 2 — ситуативный порядок (§12) | **TOP-2** |
| 3 | **5v5 полный матч** Pusher vs Ganker | MEDIUM |
| 4 | **Ult "в молоко"** — SF Requiem вхолостую: враг уходит. Наблюдать, возможно max_range в HeroAbilityConfig | LOW |
| 5 | **Больше героев** — пилот на Axe | LOW |

---

## 7. Диаги / счётчики (актуальные)

| Ключ | Файл | Смысл |
|---|---|---|
| `regen-lane` | laning | шаг назад для регена (сработал безопасно) |
| `retreat-blocked` | laning | хотел regen, враг мешает (rate-limit 3s) |
| `heal-pullback` | laning | отход к башне (НЕ regen_lane билд) |
| `tango-heal` | laning | тангу съел (HP < 65%, буффа нет, дерево в 700) |
| `bottle-heal` | laning | бутылку выпил (HP < 70% или мана < 40%, нет hero dmg 1.5s) |
| `mana-mango` | laning | манго съел (мана < 20%, instant) |
| `heal-item` | laning | instant-предмет: wand (>10 ch) / stick (>8 ch) / ff / satanic |
| `mana-clarity` | laning | кларитку выпил (мана < 40%, безопасно) |
| `prev-heal` | laning | превентивный хил (75% HP, полностью безопасно, кулдаун 30s) |
| `tp-fountain` | retreat | tp_fountain режим активирован (rate-limit 5s) |
| `recovery-tango` | laning | recovery: тангу без TANGO_CD (2000 radius, нет врага) |
| `recovery-bottle` | laning | recovery: bottle без safety gate |
| `recovery-flask` | laning | recovery: flask без safety gate |
| `recovery-buy` | laning | recovery: купил flask + вызвал курьера |
| `recovery-tp` | laning | recovery: TP на фонтан (нет золота на flask) |
| `recovery-walk` | laning | recovery: пешком на фонтан (walk_fountain или нет TP) |
| `recovery-rune` | laning | recovery: пошёл за водяной руной (regen_lane) |
| `recovery-wait` | laning | recovery: стоит у башни (нет предметов/золота/руны) |
| `respawn-no-tp` | laning | умер без TP scroll |
| `respawn-tp-cd` | laning | TP scroll на КД при реснере |
| `ability-harass` | laning | способность по врагу (ability_aggro) |
| `execute` | laning | execute сработал (HP% < execute_threshold) |
| `late-hunt` | roam | преследование в 2500 (post-laning, gank≥0.7 or pos≥3) |
| `push-lane-active` | push | волна есть → boost +0.45 |
| `push-lane-wait` | push | волны нет → yield 0.15 |
| `finish-push` | push | finish-state override → push 0.90+ |
| `ward-place` | ward | поставлен observer ward |
| `roshan-kill` | roshan | Рошан убит (DiagRL 600s) |
| `anti-idle-lane` | laning | AntiIdleGlobal: пошёл к фронту своего лайна (rate-limit 5s) |
| `kite-creep` | laning | отступил вдоль лайна от вражеских крипов (lane-aware, не VectorAway) |

---

## 8. Интерпретация match_stats.py

**Win condition — порядок проверки:**
1. Счёт 2-0 / 2-1 / 1-2 / 0-2 (`deaths=2` у кого-то) → **победа по убийствам**. Убийства могут быть от башни/крипа, не обязательно от вражеского бота.
2. Счёт 0-0 / 0-1 / 1-0 / 1-1 И высокий `towerDmg` → **победа по башне** (T1 снесена).
3. Счёт 0-0 / 0-1 / 1-0 / 1-1 И низкий `towerDmg` → **победа по 100 last hits**.

**towerDmg при победе по убийствам:** если счёт 2-x / x-2 И towerDmg ≈ 4500 — игра автоматически убила башню чтобы завершить матч. Этот урон не реальный — **игнорировать** при определении причины победы.

- `towerDmg` = урон нанесённый ботом по вражеским башням (не полученный)
- `winner_team` в парсере = `Radiant` или `Dire` (было сырое 0/2, исправлено)
- В 1v1 SF `DotaTime()` **бывает < 0** во время обратного отсчёта (~-90s). Боты активны у фонтана, invulnerable → rune mode возвращал ABSOLUTE (пофикшено в phase-15)

---

## 9. Ключевые правила

- **НЕ КОММИТИТЬ** `playstyle_radiant/dire` тест-конфигами. Канон = `Customize/canonical_pusher.lua` / `canonical_ganker.lua`.
- Python/UI-автоматизация запуска Dota лежит в `archive/dota/local_automation/` и не является частью долгосрочной инфраструктуры.
- **Пушим пачкой по команде.** Перед пушем спросить.
- `general.lua` — синк только LIVE→репо; repo→LIVE не копировать.
- Метод A/B: 1 переменная = 1 матч + свап-подтверждение. Брать НЕкруглые значения (0.34/0.66).
- Side-bias реален (Dire структурно ныряет вышку) → свап обязателен для чистого сигнала.
- `print()` в console.log НЕ виден. Диагностика только через `bot:ActionImmediate_Chat`.

---

## 10. Git / deploy

```bash
# Проверить незапушенное
git log --oneline origin/phase-2-team-dials..HEAD

# Проверить deploy-план без записи
tools\deploy.bat check

# Deploy кода в LIVE перед игрой (default)
tools\deploy.bat code

# Только если нужно развернуть live playstyle-файлы
tools\deploy.bat playstyle

# general.lua копировать только явной командой
tools\deploy.bat general

# Коммит (только когда явно попросили)
git add <files>
git commit -m "описание
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin phase-2-team-dials   # только по команде
```

Merge в `main` — осознанно, когда фаза с пруфами закрыта.

---

## 11. План: новые rules (TOP-1)

### Приоритетная очередь действий в лейне

Бот на каждом тике проходит очередь сверху вниз и делает первое разрешённое действие. Rules — гейты на каждом уровне, не конкурируют между собой.

```
1. Безопасность     low_hp_behavior
2. Добив            execute_threshold dial
3. Атака героя      hero_priority rule
4. Атака башни      tower_aggression rule
5. Денай            deny_policy rule
6. Ласт-хит / волна creep_wave_priority rule
7. Позиция          forwardness dial
```

### Кластер лейн-контроля (новые rules)

**`hero_priority`** — кого атаковать первым: героя или крипа

| Значение | Поведение |
|---|---|
| `always` | Враг в радиусе → всегда атаковать героя, даже если есть крип для ласт-хита |
| `default` | Атаковать героя только если прямо сейчас нет крипа в окне ласт-хита |
| `never` | Игнорировать героя — только крипы |

**`tower_aggression`** — когда атаковать вражескую башню

| Значение | Поведение |
|---|---|
| `always` | Башня в радиусе → атаковать её, даже жертвуя ласт-хитами |
| `default` | Бить башню когда волна зачищена и нечего делать (OHA поведение) |
| `never` | Не атаковать башню во время лейнинга |

**`deny_policy`** — как агрессивно денать своих крипов

| Значение | Поведение |
|---|---|
| `always` | Приоритет дению: прерывает харасс ради дения |
| `default` | Денать когда удобно, не жертвуя ласт-хитами и харассом |
| `never` | Не денать вообще |

**`creep_wave_priority`** — как бот работает с вражескими крипами

| Значение | Поведение |
|---|---|
| `push` | Атаковать крипов свободно — волна едет к башне врага |
| `last_hit_only` (дефолт) | Атаковать только в окне ласт-хита — волна стоит в равновесии |
| `freeze` | Не атаковать крипов — волна тянется к своей башне; враг вынужден идти за фармом далеко от своей базы |

### `ability_timing` (отдельная пара к `ability_usage`)

| Значение | Поведение |
|---|---|
| `on_cooldown` (дефолт) | Кастовать при первой возможности (харасс + добив) |
| `save_for_execute` | Не харасить способностями — копить ману для добива |
| `harass_only` | Кастовать только для харасса, Requiem в добиве не использовать |

Реализация: gate в `AbilityHarass` + `AbilityExecute` (aibattle_style.lua).

### Остальные planned rules (после кластера)

- `trading_policy`: `trade_back` / `survive` / `all_in` — ответ на получаемый урон
- `fountain_trip`: `never` / `once_per_death` / `free` — разрешить ли ходить на фонтан

---

## 12. План: стилевые item build'ы (TOP-2)

**Концепция:** для каждого героя — 3 готовых файла сборок. LLM выбирает файл по стилю, затем второй слой — ситуативный порядок внутри файла.

### Слой 1 — выбор сборки

Три файла на героя в `Customize/builds/<hero>/`:
- `aggressive.lua` — мобильность + бурст (blink, echo sabre, BKB)
- `defensive.lua` — выживаемость (vanguard, hood, crimson guard)
- `neutral.lua` — сбалансированный (phase boots + общий mid-game)

LLM выбирает строкой: `item_build = "aggressive"` — загрузчик резолвит в файл.
Или авто-выбор по диалам: `forwardness > 0.65` → aggressive; `retreat_caution > 0.65` → defensive.

### Слой 2 — порядок внутри сборки

```lua
-- builds/nevermore/aggressive.lua
return {
    core       = { "item_bottle", "item_power_treads", "item_black_king_bar" },
    luxury     = { "item_bloodthorn", "item_greater_crit" },
    situational = { "item_orchid", "item_hurricane_pike" },
}
```

Порядок покупки: core → luxury. Situational — подключается по runtime-условиям:
- если проигрываем (deaths > kills + 1) → defensive situational вперёд
- если enemy имеет magic burst → BKB ускоряется

### Источники сборок

- **Steam Workshop** `filetype=12` — Dota 2 hero builds в JSON, `tools/parse_steam_build.py`
- Pipeline: внешний JSON → `tools/convert_build.py` → `builds/<hero>/<style>.lua`

### Статус

Не начато. Первый кандидат для пилота — SF (3 стиля уже имеет смысл: aggressive/neutral/defensive).

---

## Codex audit: 8858984642 / 8859758837

Что показали матчи:
- `creep-dmg` был почти только телеметрией в лейнинге: он писался после решений по ластхиту/харассу и не давал отдельного действия. Поэтому бот мог продолжать добивать крипов, пока его били крипы.
- Empty bottle логика была слишком узкой: только water rune, только recovery-сценарий, враг рядом полностью блокировал желание, а оба матча закончились с `water_runes=0` и `power_runes=0`.
- Явного желания "сбить хил врагу" не было. Обычный харасс мог попасть случайно, но salve/bottle/clarity не становились приоритетной целью.

Что добавлено:
- `creep-aggro-back`: раннее survival-действие до ластхита. Если бот недавно получил урон от крипов и HP ниже `creep_aggro_relief_hp` (дефолт `0.55`), он отходит к безопасной стороне/своей башне.
- `heal-interrupt-atk` / `heal-interrupt-chase`: враг с cancellable-heal модификаторами (`flask`, `bottle`, `clarity`) становится срочной целью, если бот не в критическом HP.
- `hero-pass-atk` / `hero-pass-chase`: враг, проходящий рядом во время лейнинга, больше не проходит через случайный `farm_focus`-ролл; бот обязан дать удар или шагнуть к удару, если он не в опасном HP, не под вражеской башней и не атакует с низины.
- `bottle-rune` / `recovery-rune-bottle`: пустая bottle теперь ищет ближайшую доступную water или power rune и может сработать из обычного defensive-heal, а не только из recovery.
- `bottle-rune` теперь lane-aware: в лейнинге действует строгий `bottle_rune_max_dist` (дефолт `1900`) и `bottle_rune_lane_budget` (дефолт `1500`), не уходит в rune-trip во время last-hit окна и пишет `blocked=bottle-rune reason=...`.
- `recovery-rune-bottle` остаётся шире (`2600`, без lane-budget), потому что это уже post-fight восстановление, а не бросание мида ради далёкой воды.

Что смотреть в следующем матче:
- Вместо одного `creep-dmg` должны появляться `creep-aggro-back`.
- Когда герои расходятся рядом/за спину друг другу, должны появляться `hero-pass-*`, а не только редкие `harass-atk`.
- При salve/bottle/clarity у врага должны появляться `heal-interrupt-*`.
- При пустой bottle и низком HP/mana должны появляться `bottle-rune` или `recovery-rune-bottle`; в итоговой статистике не должно оставаться `water_runes=0 power_runes=0`, если безопасная руна была доступна.
- Если бот не идёт к руне, смотреть `blocked=bottle-rune reason=no_close_rune/enemy_near/last_hit_window/lane_budget/hero_damage`.

---

## Codex infra pass: intents, blocked reasons, live build

Что изменено в инфраструктуре:
- `FunLib/aibattle_engine.lua` теперь умеет не только запускать стадии, но и арбитрировать intent-кандидаты с `priority`, `reason`, `detail` и `action`.
- `FunLib/aibattle_style.lua` получил `Blocked(...)` telemetry: теперь можно видеть не только "что сделал бот", но и "чего хотел, но не сделал" (`blocked=hero-pass reason=low_hp`, `blocked=creep-aggro reason=hp_ok`).
- Лейнинг-логика trade/survival вынесена из `mode_laning_generic.lua` в маленькие модули:
  - `FunLib/aibattle_laning_survival.lua`
  - `FunLib/aibattle_laning_trade.lua`
- `tools/deploy.bat` генерирует live `FunLib/aibattle_build.lua` с текущим git sha; `ThinkAnnounce` пишет `AIB[R] build=<sha>` / `AIB[D] build=<sha>` в начале матча.
- `tools/match_stats.py` теперь парсит `build=...`, `intent=...`, `blocked=...` и печатает `alert:` симптомы:
  - `ignored-nearby-hero`
  - `stationary-while-damaged`
  - `creep-dmg-without-relief`
  - `enemy-healed-without-interrupt`
  - `bottle-no-rune-intent`

Правило на будущее:
- Новая логика, которая выбирает действие текущего тика, должна возвращать intent через `AIBEngine.Intent(...)` или `AIBEngine.Blocked(...)`.
- Низкоуровневую механику держать в модуле своей области (`laning_trade`, `laning_survival`, `survive`, `utils`), а не расширять `mode_laning_generic.lua`.

### Regression audit: 8860283516

Матч шёл на `build=4a1377d`, то есть без lane-aware bottle rune фикса `9a81295`.

Что подтвердилось:
- Визуальная тупость была реальной: `alert ignored-nearby-hero`, `stationary-while-damaged`.
- `creep-aggro` был слишком сильным: мог уводить бота даже на высоком HP (`79-98%`) только из-за факта recent creep damage.
- Самый неприятный баг: `creep-aggro cooldown_hold` возвращал handled intent с пустым action, то есть тик считался обработанным, но бот ничего не делал.
- `hero-pass` проигрывал `creep-aggro` по priority, поэтому герои могли проходить рядом без атаки.
- Low HP survival мог не получить тик, потому что early intents стояли до `AIBSurvive.Think`.

Фиксы после аудита:
- `creep-aggro` теперь не срабатывает выше `creep_aggro_relief_hp`, даже если рядом много крипов.
- `creep-aggro cooldown_hold` больше не пустой no-op: либо продолжает движение к последней safe-точке, либо yield.
- `hero-pass` и `heal-interrupt` подняты по priority выше обычного creep-aggro.
- При HP `<55%` early `AIBSurvive.Think` вызывается до visual-afk / trade / creep intents.
- `match_stats.py` больше не считает `build=...` обычным diag.
