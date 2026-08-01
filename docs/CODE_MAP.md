# CODE MAP — карта проекта (что где, сколько строк, кто владелец)

> Навигационная карта для передачи проекта. Структура обновлена 2026-08-01.
> Числа ниже являются снимком, а не источником текущего состояния. Актуальные размеры,
> прямые action-сайты, shared-state writers и мёртвые локальные функции выдаёт
> `python tools/project_inventory.py`.
> Пары к этому файлу: `ARCHITECTURE.md` (философия/владение), `HANDOFF_PACKAGE.md`
> (продукт + пайплайн тика), `SPECS.md` (незакрытые работы).

---

## 0. TL;DR — главное за 30 секунд

Продукт: **промпт → LLM → конфиг → измеримое поведение бота Dota 2, 1v1 mid** (герой Shadow
Fiend / nevermore). База — OpenHyperAI (OHA), форк движка бот-скриптов.

**Масштаб и что реально наше:**

| | строк | % | трогаем? |
|---|---:|---:|---|
| **Наш слой `aibattle_*`** (поведение) | **7171** | — | ✅ ДА — здесь вся логика |
| Конфиги `Customize/` | 684 | — | ✅ ДА — пресеты архетипов |
| **Наши патчи ВНУТРИ вендорных файлов** | **217** | — | ⚠️ 21 файл, см. §3 |
| Вендор OHA (всё остальное в `bots/`) | ~191484 | 96% | ❌ НЕТ — база, синк сверху |
| Tools (Python) | 4391 | — | ✅ ДА |
| Docs | измерять утилитой | — | ✅ ДА |

**Итого Lua в `bots/`: 199031 строк.** Наших из них — 7764 (3.9%), считая патчи в вендоре.

**Вывод для новых технарей:** не пугайтесь 197k строк Lua. **Учить надо ~6.9k** — слой
`aibattle_*` + конфиги. Остальное — движок OHA, его читают по необходимости, не рефакторят.

---

## 1. Слой AIBattle — наш код (`bots/FunLib/aibattle_*.lua`, 7171 строк, 22 файла)

Здесь живёт ВСЁ поведение. Хорошо разложено: один файл — одна ответственность.

### Ядро (движок решений и конфиг)

| Файл | строк | Роль |
|---|---:|---|
| `aibattle_style.lua` | 1208 | **Центр**: загрузка конфига (rules/dials), item/skill build, ability-harass config; телеметрия `Style.Intent/Diag/TickOwner/Blocked`. Всё зовёт его. |
| `aibattle_engine.lua` | 254 | Раннер стадий и интентов: `Stage/Intent/Resolve`, `KillWindow`, `RecoveryPolicy`, `PowerRuneState`, `RuneUsePolicy`. |
| `aibattle_laning_policy.lua` | 345 | **Скоринг десиров**: `Safety/PowerRune/Fight/Recover/Siege` → score; HP-банды, пороги, no-action-капы (П4). |
| `aibattle_laning_arbiter.lua` | 132 | **Top-desire арбитр**: `Run/Candidate` — гистерезис победителя, tick-owner. Сердце выбора. |
| `aibattle_constants.lua` | 51 | Инженерные пороги (дистанции, кулдауны, HP-банды) — не LLM-facing. |
| `aibattle_motor.lua` | 45 | Владение движением `Claim/Active/Release` (v1). Retire в П1-C. |
| `aibattle_intents.lua` / `_laning_context.lua` | 73 / 37 | Хелперы интентов + билдер контекста тика. |
| `aibattle_build.lua` | 4 | Штамп sha (перезаписывается деплоем). |

### Поведенческие модули лейнинга

| Файл | строк | Роль |
|---|---:|---|
| `aibattle_survive.lua` | 1028 | **Хил/реген low-HP**: `fountainRecovery`, `defensiveHeal`, `regenLane`, `recovery` (бутылка/фласка/танго/руна + fallback-цепь, buy-escape). |
| `aibattle_runes.lua` | 697 | **Руны**: `SeekBottleRune`, `FindWaterRecoveryRune`, стейджинг/пикап, bottle-fill транзакция. |
| `aibattle_laning_safety.lua` | 583 | `CreepHitReact`, `DamageUnstuck`, `RangedMeleePackSpacing`, `LastHitWatchdog`, visual-hold/AFK anti-idle. |
| `aibattle_laning_combat.lua` | 451 | `HarassAndChase`, `ContactHero`, `AbilityPressure`, `RunePowerPressure`, `UphillReposition`, `EmergencyKillPriority`, `AbilityHarass`. |
| `aibattle_laning_tempo.lua` | 464 | `Pregame`, `DivePolicy`, `DeathWindow`, `PreCreepStandoff` (стадии-гарды). |
| `aibattle_laning_recovery.lua` | 405 | **Low-HP владельцы** (цель П3): `ThinkIfAllowed`, `CriticalLock`, `ActiveLowHp`, `EmergencyRetreat`, `ForwardLowHpPullback`, `LowHpHoldState`. |
| `aibattle_laning_creeps.lua` | 236 | `GetBestLastHitCreep`, `GetBestDenyCreep`, `HandleCreepWork`. |
| `aibattle_laning_trade.lua` | 163 | `KillLock`, `HealInterrupt`, `PassingHeroTrade` (урджент-размены). |
| `aibattle_laning_siege.lua` | 315 | Осада вышки / siege-commit и API владельца latch. |
| `aibattle_laning_duel.lua` | 237 | `Prewave`, `Pregame` дуэль. |
| `aibattle_item_policy.lua` | 173 | `ShouldUseMango`, `ShouldDelaySpareTpPurchase`. |
| `aibattle_utils.lua` | 171 | `SafeRetreatTowerLoc`, `ForwardSurvivingTowerLoc`, `EnemyTowerDanger`, `UphillMiss`, `IsTowerActuallyThreatening`. |
| `aibattle_laning_survival.lua` | 94 | `CreepAggroRelief`. |

---

## 2. Как течёт решение (тик)

Оркестратор: `bots/mode_laning_generic.lua`. `GetDesire()` заявляет желание играть лейнинг,
`Think()` → `ThinkLaningCore()` прогоняет пайплайн. После P1-A прежний хвост участвует в
одной election; до неё всё ещё остаётся urgent-голова.

```
1. tempo-гарды: respawn / pregame / dive / death-window                                      [tempo]
2. hard recovery floor + urgent kill/channel interrupt                                       [recovery, trade]
3. Recovery.Owner + prewave duel / pre-creep standoff                                        [recovery, duel, tempo]
4. ★ MERGED ELECTION: top desires + lane work + positioning + watchdog/anti-idle candidates  [policy→arbiter]
5. winner executes lazily; an incapable candidate must report no-action and release the tick
```

Каждое решение логируется: `intent=<key>`, `blocked=<key> reason=<why>`, `tick-owner`,
`top-arbiter winner/losers` → анализируется инструментами (§5).

**Открытый структурный долг (см. SPECS):** P1-A объединил середину и хвост, но urgent-голова
ещё short-circuit'ит election (P1-B), а suppress/commit/anti-idle механика всё ещё дублируется
(P1-C). П3 сводит оставшиеся low-HP движения в один owner. `mode_laning_generic.lua` сейчас
около 1.6k строк и должен уменьшаться по мере этих ownership-катоверов.

---

## 3. Entry-points и патчи в вендоре (Dota вызывает; мы правили частично)

**Это самая важная таблица карты.** Каждая строка — место, где наш код живёт внутри чужого.
При обновлении базы OHA конфликты будут ровно здесь и больше нигде. Считано по `AIB`-маркерам,
поэтому вставка БЕЗ маркера этому аудиту невидима — маркер это не стиль, а способ мерить границу.

| Файл | всего строк | наших | доля |
|---|---:|---:|---:|
| `bots/mode_laning_generic.lua` | 1580 | 61 | 3% |
| `bots/mode_roam_generic.lua` | 2210 | 38 | 1% |
| `bots/ability_item_usage_generic.lua` | 8483 | 19 | 0% |
| `bots/mode_retreat_generic.lua` | 857 | 15 | 1% |
| `bots/item_purchase_generic.lua` | 1404 | 12 | 0% |
| `bots/mode_push_tower_bot_generic.lua` | 39 | 9 | 23% |
| `bots/mode_push_tower_mid_generic.lua` | 35 | 8 | 22% |
| `bots/mode_push_tower_top_generic.lua` | 35 | 8 | 22% |
| `bots/mode_roshan_generic.lua` | 190 | 6 | 3% |
| `bots/mode_rune_generic.lua` | 864 | 6 | 0% |
| `bots/FretBots/SettingsDefault.lua` | 443 | 6 | 1% |
| `bots/mode_team_roam_generic.lua` | 1719 | 5 | 0% |
| `bots/mode_ward_generic.lua` | 212 | 4 | 1% |
| `bots/FunLib/jmz_func.lua` | 6758 | 4 | 0% |
| `bots/mode_defend_tower_bot_generic.lua` | 18 | 3 | 16% |
| `bots/mode_defend_tower_mid_generic.lua` | 16 | 3 | 18% |
| `bots/mode_defend_tower_top_generic.lua` | 18 | 3 | 16% |
| `bots/BotLib/hero_sniper.lua` | 708 | 3 | 0% |
| `bots/hero_selection.lua` | 1128 | 2 | 0% |
| `bots/FunLib/aba_defend.lua` | 1410 | 1 | 0% |
| `bots/FunLib/aba_role.lua` | 437 | 1 | 0% |

Всего **21 вендорных файлов** несут **217 наших строк**.

⚠️ **Правило:** в вендорные файлы лезть только точечно и по нужде (риск слияния сверху).

---

## 4. Конфиги (`bots/Customize/`, 684 строк) — зона Claude

| Файл | строк | Роль |
|---|---:|---|
| `canonical_brawler.lua` | 63 | Архетип «драчун» (fight-on-sight, harass 0.90). Radiant/Dire primary. |
| `canonical_farmer.lua` | 77 | Архетип «фармер» (econ, farm_focus 0.72, hero_priority=default). |
| `canonical_pusher.lua` | 57 | Архетип «пушер». |
| `canonical_ganker.lua` | 57 | Архетип «ганкер». |
| `canonical_oha_default.lua` | 12 | Голый OHA-дефолт (базлайн TOP-0). |
| `playstyle_radiant.lua` / `_dire.lua` | 1 / 2 | **Байндинг**: какой canonical бежит на стороне. Живой матчап. ⚠️ НЕ коммитить без команды. |
| `general.lua` | 220 | Общие оверрайды/настройки. Синк только LIVE→репо. |

Пресет = таблица `{ dials, rules, item_build, skill_build }`. Схема — в HANDOFF_PACKAGE §2.
- **dials** — LLM-facing числа 0..1 (harass_desire, farm_focus, forwardness, push_desire…).
- **rules** — LLM-facing выборы (hero_priority, low_hp_behavior, tower_aggression…).
- **constants** — инженерные (в `aibattle_constants.lua`), НЕ в конфиге.

---

## 5. Tools (`tools/`, Python, 3 052 строки)

| Файл | строк | Роль |
|---|---:|---|
| `postmatch.py` | 70 | ⭐ **Главный разбор матча**: scorecard + сигнатуры фиксов + jitter-breakdown, ~20 строк. |
| `scorecard.py` | 74 | Голый вердикт PASS/FAIL (jitter/empty_action/bottle/errors). |
| `match_stats.py` | 1211 | Глубокий анализ (KDA/LH, семейства интентов, арбитр, stationary, fix_candidate). |
| `betting.py` | 414 | 💰 **Рыночный слой**: кривая преимущества R−D, рыночные линии, in-play база. См. ниже. |
| `check_all.py` | 396 | Контроль дрейфа: lua-syntax, deploy-манифест, live≠repo, sha. Гонять после деплоя. |
| `parse_demo.py` / `parse_itembuilds.py` | 336 / 161 | Парсинг демок / билдов. |
| `check_text_encoding.py` / `test_match_stats.py` | 66 / 324 | Кодировка / тесты. |

### `betting.py` — зачем он отдельно от `match_stats.py`

Два инструмента отвечают на **разные вопросы** и намеренно не пересекаются:

| | `match_stats.py` | `betting.py` |
|---|---|---|
| Вопрос | Работал ли бот? (инженерное QA) | Есть ли здесь рынок и как его прайсить? |
| Смотрит на | каждую сторону по отдельности | **разницу R−D во времени** |
| Читатель | разработчик движка | продукт / букмекер |

Единственное, чего нет в `match_stats.py`, — **кривая преимущества** (R минус D по времени).
Все метрики `betting.py` — её производные. Оба инструмента работают офлайн по
готовому `console.<matchid>.log`: ни Lua, ни движок, ни деплой не затрагиваются.

**По одному матчу** — форма матча во времени:
- `first_event` — когда матч завёлся (первая кровь либо размен с просадкой HP >20%)
- `decided_at` / `dead_tail%` — когда исход перестал быть спорным и какая доля матча
  прошла уже решённой. Прямой замер «интрига держится»
- `lead_changes` — сколько раз лидерство переходило
- `amplitude` — размах разрыва. Ловит то, чего не видят смены лидера: разрыв может
  гулять на 1400 золота ни разу не пересекая ноль — знак не меняется, а коэффициенты
  ходить должны
- `deficit_overcome` — какой дефицит отыграл победитель. **Ноль по всей серии = live-рынок
  умирает после первого отрыва**, ставить после 3-й минуты не на что

**По серии** (`--series`) — готовые рыночные линии:
- **тотал** (распределение длительности → больше/меньше N минут)
- **фора** (распределение финального разрыва)
- **раскладка по способу победы** (киллы / вышка+LH) → рынок метода
- **replay-check** — разброс по 4 осям. Один и тот же победитель это нормально
  (тяжёлые фавориты есть везде); провал — когда матчи прожиты **одинаково**
- **in-play база** — эмпирическая P(победа | разрыв на минуте N). На 6 матчах не
  прайсится, нужно ~25–30; копится с первого дня, чтобы потом не переигрывать серию

**НЕ дублирует** `match_stats.py`: победитель/KDA/LH/DN/урон/предметы, экономика бутылки,
stationary-спаны, доля контакта, диаг- и intent-профили — всё это берётся оттуда.

```bash
python tools\betting.py <matchid>                    # один матч
python tools\betting.py --series <id1> <id2> <id3>   # серия + рыночные линии
```


**Деплой:** `tools/deploy.bat` (из cmd) ИЛИ вручную `cp` файлов в LIVE + штамп sha в
`LIVE/FunLib/aibattle_build.lua`. LIVE:
`C:\Program Files (x86)\Steam\...\dota 2 beta\game\dota\scripts\vscripts\bots\`.
Лог матча: `game\dota\console.<matchid>.log` (лобби Solo Mid, читы ON, `-condebug`).

---

## 6. Backend — LLM-генератор (`backend/`, 320 строк)

| Файл | строк | Роль |
|---|---:|---|
| `generate_playstyle.py` | 145 | Пайплайн: стратегия-текст → LLM → валидный конфиг (12 диалов + 10 rules). |
| `system_prompt.txt` | 84 | Промпт генератора (под SF). |
| `test_generate.py` | 96 | Тесты (11/11). Прогон идёт офлайн через `--radiant-json/--dire-json`, ключ не нужен. |

---

## 7. Docs (`docs/`, 2 607 строк) — что читать

| Файл | Когда открывать |
|---|---|
| **`CODE_MAP.md`** (этот) | Первый вход: где что лежит. |
| **`HANDOFF_PACKAGE.md`** | Продукт, схема конфига, пайплайн тика, 4 структурные проблемы (П1-П4), скоркард. |
| **`SPECS.md`** | Незакрытые работы с дизайном (П1-мандат, П3, ловушки). Что делать дальше. |
| `ARCHITECTURE.md` | Философия, владение, слои rules/dials/constants. |
| `HANDOFF.md` | История сессий/решений. |
| `llm_system_prompt.md` / `match_log.md` | Промпт генератора / журнал матчей. |

---

## 8. «Где менять X?» — быстрый справочник

| Хочу… | Иду в… |
|---|---|
| Поменять стиль игры бота | `bots/Customize/canonical_*.lua` (диалы/rules) |
| Сменить матчап (кто против кого) | `bots/Customize/playstyle_radiant/dire.lua` |
| Как бот скорит desire (safety/fight/…) | `aibattle_laning_policy.lua` |
| Порядок/арбитраж тика | `aibattle_laning_arbiter.lua` + `mode_laning_generic.lua` |
| Поведение на низком HP / реген | `aibattle_laning_recovery.lua` + `aibattle_survive.lua` |
| Ласт-хит / деней / крип-волна | `aibattle_laning_creeps.lua` |
| Харасс / чейз / способности | `aibattle_laning_combat.lua` |
| Руны / бутылка | `aibattle_runes.lua` |
| Осада вышки | `aibattle_laning_siege.lua` |
| Пороги-числа (дистанции, кулдауны) | `aibattle_constants.lua` |
| Телеметрия / диаг-сигнатуры | `aibattle_style.lua` (`Intent/Diag/Blocked/TickOwner`) |
| Разбор матча (работал ли бот) | `python tools/postmatch.py <id>` |
| Ставочность матча (есть ли рынок) | `python tools/betting.py <id>` |
| Что делать дальше | `docs/SPECS.md` |
