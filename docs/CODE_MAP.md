# CODE MAP — карта проекта (что где, сколько строк, кто владелец)

> Навигационная карта для передачи проекта. Обновлено 2026-07-06 (HEAD ~fdaf108).
> Пары к этому файлу: `ARCHITECTURE.md` (философия/владение), `HANDOFF_PACKAGE.md`
> (продукт + пайплайн тика), `SPECS.md` (незакрытые работы), `CURRENT.md` (детали тика).

---

## 0. TL;DR — главное за 30 секунд

Продукт: **промпт → LLM → конфиг → измеримое поведение бота Dota 2, 1v1 mid** (герой Shadow
Fiend / nevermore). База — OpenHyperAI (OHA), форк движка бот-скриптов.

**Масштаб и что реально наше:**

| | строк | % | трогаем? |
|---|---:|---:|---|
| **Наш слой `aibattle_*`** (поведение) | **5 435** | 2.7% | ✅ ДА — здесь вся логика |
| Конфиги `Customize/` | 489 | — | ✅ ДА — пресеты архетипов |
| Гибрид entry-points (мы правили) | ~11 000 | — | ⚠️ осторожно (см. §3) |
| Вендор OHA (FunLib/BotLib/mode_*) | ~180 000 | 96% | ❌ НЕТ — база, синк сверху |
| Tools (Python) | 2 638 | — | ✅ ДА |
| Backend (LLM-генератор) | 320 | — | ✅ ДА |
| Docs | 2 607 | — | ✅ ДА |

**Вывод для новых технарей:** не пугайтесь 197k строк Lua. **Учить надо ~5.4k** — слой
`aibattle_*` + конфиги. Остальное — движок OHA, его читают по необходимости, не рефакторят.

---

## 1. Слой AIBattle — наш код (`bots/FunLib/aibattle_*.lua`, 5 435 строк, 22 файла)

Здесь живёт ВСЁ поведение. Хорошо разложено: один файл — одна ответственность.

### Ядро (движок решений и конфиг)

| Файл | строк | Роль |
|---|---:|---|
| `aibattle_style.lua` | 996 | **Центр**: загрузка конфига (rules/dials), item/skill build, ability-harass config; телеметрия `Style.Intent/Diag/TickOwner/Blocked`. Всё зовёт его. |
| `aibattle_engine.lua` | 250 | Раннер стадий и интентов: `Stage/Intent/Resolve`, `KillWindow`, `RecoveryPolicy`, `PowerRuneState`, `RuneUsePolicy`. |
| `aibattle_laning_policy.lua` | 279 | **Скоринг десиров**: `Safety/PowerRune/Fight/Recover/Siege` → score; HP-банды, пороги, no-action-капы (П4). |
| `aibattle_laning_arbiter.lua` | 103 | **Top-desire арбитр**: `Run/Candidate` — гистерезис победителя, tick-owner. Сердце выбора. |
| `aibattle_constants.lua` | 51 | Инженерные пороги (дистанции, кулдауны, HP-банды) — не LLM-facing. |
| `aibattle_motor.lua` | 47 | Владение движением `Claim/Active/Release` (v1). Retire в П1-C. |
| `aibattle_intents.lua` / `_laning_context.lua` | 73 / 37 | Хелперы интентов + билдер контекста тика. |
| `aibattle_build.lua` | 4 | Штамп sha (перезаписывается деплоем). |

### Поведенческие модули лейнинга

| Файл | строк | Роль |
|---|---:|---|
| `aibattle_survive.lua` | 657 | **Хил/реген low-HP**: `fountainRecovery`, `defensiveHeal`, `regenLane`, `recovery` (бутылка/фласка/танго/руна + fallback-цепь, buy-escape). |
| `aibattle_runes.lua` | 582 | **Руны**: `SeekBottleRune`, `FindWaterRecoveryRune`, стейджинг/пикап, bottle-fill транзакция. |
| `aibattle_laning_safety.lua` | 428 | `CreepHitReact`, `DamageUnstuck`, `RangedMeleePackSpacing`, `LastHitWatchdog`, visual-hold/AFK anti-idle. |
| `aibattle_laning_combat.lua` | 313 | `HarassAndChase`, `ContactHero`, `AbilityPressure`, `RunePowerPressure`, `UphillReposition`, `EmergencyKillPriority`, `AbilityHarass`. |
| `aibattle_laning_tempo.lua` | 286 | `Pregame`, `DivePolicy`, `DeathWindow`, `PreCreepStandoff` (стадии-гарды). |
| `aibattle_laning_recovery.lua` | 285 | **Low-HP владельцы** (цель П3): `ThinkIfAllowed`, `CriticalLock`, `ActiveLowHp`, `EmergencyRetreat`, `ForwardLowHpPullback`, `LowHpHoldState`. |
| `aibattle_laning_creeps.lua` | 210 | `GetBestLastHitCreep`, `GetBestDenyCreep`, `HandleCreepWork`. |
| `aibattle_laning_trade.lua` | 183 | `KillLock`, `HealInterrupt`, `PassingHeroTrade` (урджент-размены). |
| `aibattle_laning_siege.lua` | 173 | Осада вышки / siege-commit. |
| `aibattle_laning_duel.lua` | 135 | `Prewave`, `Pregame` дуэль. |
| `aibattle_item_policy.lua` | 129 | `ShouldUseMango`, `ShouldDelaySpareTpPurchase`. |
| `aibattle_utils.lua` | 117 | `SafeRetreatTowerLoc`, `ForwardSurvivingTowerLoc`, `EnemyTowerDanger`, `UphillMiss`, `IsTowerActuallyThreatening`. |
| `aibattle_laning_survival.lua` | 97 | `CreepAggroRelief`. |

---

## 2. Как течёт решение (тик) — 13 стадий

Оркестратор: `bots/mode_laning_generic.lua`. `GetDesire()` заявляет желание играть лейнинг,
`Think()` → `ThinkLaningCore()` прогоняет пайплайн. Побеждает первый вернувший `true`.

```
1-2.  tempo-гарды (respawn / pregame / dive / death-window) + urgent (kill-lock, heal-interrupt)   [tempo, trade]
3-4.  recovery-гейты + critical-recovery lock                                                       [recovery]
5.    prewave-дуэль / pre-creep standoff                                                            [duel, tempo]
6-7.  ★ TOP-DESIRE АРБИТР: last-hit / safety / power-rune / fight / recover / siege                 [policy→arbiter]
       (скоринг в policy.lua, прогон в arbiter.lua; победитель исполняет; empty → следующий)
8-10. last-hit, harass, CS-walk, push/deny/siege, uphill, spacing, fwd-position                     [creeps, combat, safety]
11-13. visual-hold, lane-line-fallback, anti-idle                                                   [safety]
```

Каждое решение логируется: `intent=<key>`, `blocked=<key> reason=<why>`, `tick-owner`,
`top-arbiter winner/losers` → анализируется инструментами (§5).

**Открытый структурный долг (см. SPECS):** арбитр владеет только СЕРЕДИНОЙ тика (стадия 6).
Осцилляции = пары хэндлеров по разные стороны его границы. **П1** делает арбитр единственным
владельцем тика; **П3** сводит low-HP в один owner. Это и есть архитектурные улучшения — файл
`mode_laning_generic` (1262) укоротится за счёт П1.

---

## 3. Entry-points — гибрид (Dota вызывает; мы правили частично)

| Файл | строк | Наше / OHA |
|---|---:|---|
| `bots/mode_laning_generic.lua` | 1262 | **НАШ оркестратор** — главный владелец лейнинг-тика. |
| `bots/item_purchase_generic.lua` | 1395 | OHA + наш override билда (`Style.GetItemBuild`) + AIB recovery-покупки. |
| `bots/ability_item_usage_generic.lua` | 8473 | **В основном OHA** (способности/предметы/курьер). Мы трогали курьер/глиф. Курьер-гейт база-трипа живёт тут (:720). |
| `bots/hero_selection.lua` | 1127 | OHA, пик героя. |
| `bots/mode_*.lua` (прочие режимы) | 9642 | OHA-режимы (retreat/roam/farm/rune/push…). В 1v1 mid активен почти только laning. |

⚠️ **Правило:** в вендорные файлы лезть только точечно и по нужде (риск слияния сверху).

---

## 4. Конфиги (`bots/Customize/`, 489 строк) — зона Claude

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

## 5. Tools (`tools/`, Python, 2 638 строк)

| Файл | строк | Роль |
|---|---:|---|
| `postmatch.py` | 70 | ⭐ **Главный разбор матча**: scorecard + сигнатуры фиксов + jitter-breakdown, ~20 строк. |
| `scorecard.py` | 74 | Голый вердикт PASS/FAIL (jitter/empty_action/bottle/errors). |
| `match_stats.py` | 1211 | Глубокий анализ (KDA/LH, семейства интентов, арбитр, stationary, fix_candidate). |
| `check_all.py` | 396 | Контроль дрейфа: lua-syntax, deploy-манифест, live≠repo, sha. Гонять после деплоя. |
| `parse_demo.py` / `parse_itembuilds.py` | 336 / 161 | Парсинг демок / билдов. |
| `check_text_encoding.py` / `test_match_stats.py` | 66 / 324 | Кодировка / тесты. |

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
| `test_generate.py` | 83 | Тесты (10/10). E2E упирается в OPENAI_API_KEY. |

---

## 7. Docs (`docs/`, 2 607 строк) — что читать

| Файл | Когда открывать |
|---|---|
| **`CODE_MAP.md`** (этот) | Первый вход: где что лежит. |
| **`HANDOFF_PACKAGE.md`** | Продукт, схема конфига, пайплайн тика, 4 структурные проблемы (П1-П4), скоркард. |
| **`SPECS.md`** | Незакрытые работы с дизайном (П1-мандат, П3, ловушки). Что делать дальше. |
| `ARCHITECTURE.md` | Философия, владение, слои rules/dials/constants. |
| `CURRENT.md` | Детали 13 стадий тика. |
| `HANDOFF.md` | История сессий/решений. |
| `PM_REVIEW.md` | Этапы продукта (Gate 0/1), уроки процесса. |
| `CODEX_MEMORY.md` / `llm_system_prompt.md` / `match_log.md` | Память Codex / промпт / журнал матчей. |

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
| Разбор матча | `python tools/postmatch.py <id>` |
| Что делать дальше | `docs/SPECS.md` |
