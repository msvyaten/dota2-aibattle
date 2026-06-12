# HANDOFF — AIBattle × Dota 2

> Единственная точка входа. Обновлять ЕГО, новых доков не плодить.
> Последнее обновление: 2026-06-12 (phase-17: improvements→rules refactor (healing_style/ability_usage), build_style 3-стиля, вода-руна distance cap).
> Полная история сессий — `docs/history/HANDOFF-full-2026-06-09.md`.
> По-русски. Доказательство = цифра из лога или stат-дампа. «На глаз» не считается.

---

## 1. Пути / окружение

- **Репо:** `C:\Users\Shadow\dota2-aibattle` · ветка `phase-2-team-dials` · git-личность: `don / don@users.noreply.github.com`
- **LIVE (что грузит Dota):** `…\dota 2 beta\game\dota\scripts\vscripts\bots\`
- **Deploy:** `tools/deploy.bat` — xcopy 7 файлов из репо → LIVE (запускать перед каждым тестом)
- **Конфиги:** `bots/Customize/playstyle_radiant.lua` / `playstyle_dire.lua`
- **Логи:** `…\game\dota\console.<matchid>.log` (опция `-condebug`)
- **Анализ:** `python tools/match_stats.py <id> [id2 …]` — KDA/LH/урон/предметы/диаги по слотам
- **1v1 лобби:** Solo Mid, читы ON, хост зрителем, Local Dev Script, кикнуть слоты 1–4 и 6–9

---

## 2. Архитектура (файл → роль)

| Файл | Роль |
|---|---|
| `FunLib/aibattle_style.lua` | Загрузчик конфига: dials/rules/improvements/item_build; ScaleDesire; HeroAbilityConfig (15 героев); M.Diag/DiagRL/Imp |
| `mode_laning_generic.lua` | Главный: last-hit/harass интерлив; defensive_heal; regen_lane; HandleRespawn; ability harass/execute |
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
| `tools/match_stats.py` | Парсер логов: KDA/LH/items(decoded)/diags; dial-таблица R vs D |
| `tools/deploy.bat` | xcopy dev → LIVE |

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
- `anti_afk`, `tower_avoid` — не валидированы

**pregame_behavior** ✅ (10.06.2026) — pg-called D#267 R#273 стабильно; pregame-aggressive_mid/safe_tower в диагах. Бот идёт к правильной позиции до крипов.

**raze1 убран из SF harass** (10.06.2026) — `ability-harass-move` снизился R#12→R#1 (8846034123→8846050605). Только raze2 (300–600) и raze3 (550–850).

**Подробности + пруфы:** `docs/history/HANDOFF-full-2026-06-09.md` §3–§21

---

## 4. Rules-система (краткая)

| Rule | Значения (дефолт жирным) | Счётчик | Статус |
|---|---|---|---|
| `respawn_behavior` | walk_back / tp_to_lane / **tp_to_tower** | teleports_used | ✅ |
| `dive_policy` | never / **finish_only** / always | `no-dive` | ✅ |
| `smoke_usage` | **for_ganks** / never | `smoke` | ✅ |
| `buyback_policy` | never / **default** | — | ✅ |
| `low_hp_behavior` | **tp_fountain** / run_to_tower / fight_back / regen_lane / walk_fountain | `tp-fountain` / `regen-lane` / `retreat-blocked` / `recovery-*` | ✅ |
| `aegis_policy` | **core** / any | — | ✅ |
| `healing_style` | **passive** / active | `bottle-heal` / `tango-heal` / `heal-item` | ✅ (был `improvements.defensive_heal`) |
| `ability_usage` | **basic** / aggressive | `ability-harass` | ✅ (был `improvements.ability_on_dials`; теперь правильно изолирует AbilityHarass) |
| `creep_wave_priority` | **last_hit_only** / push / freeze | — | 📋 PLANNED |
| `ability_timing` | **on_cooldown** / save_for_execute / harass_only | — | 📋 PLANNED |
| `trading_policy` | **trade_back** / survive / all_in | — | 📋 PLANNED |
| `fountain_trip` | **never** / once_per_death / free | — | 📋 PLANNED |

**Improvements** — только технические флаги (не LLM-стиль): `anti_afk`, `tower_avoid`. Off по умолчанию.
`defensive_heal` и `ability_on_dials` → перенесены в rules. Старые конфиги с `improvements = {}` работают через backward compat в buildStyle().

---

## 5. Текущий тест (LIVE, phase-17 — НЕ КОММИТИТЬ)

Тест build_style: brawler (Radiant) vs spellcaster (Dire). Оба SF, execute=0.45, pregame=safe_tower.

| Сторона | build_style | healing_style | ability_usage |
|---|---|---|---|
| **Radiant** | brawler | active | basic |
| **Dire** | spellcaster | passive | aggressive |

**Валидация phase-17 (8848634192, 12.06.2026):**

| Проверка | Результат |
|---|---|
| Radiant покупает brawler (tango/branches/bottle/bracer) | ✅ |
| Dire покупает spellcaster (slippers/null×2/faerie_fire/bottle/phase_boots) | ✅ |
| healing_style=active изолирован на Radiant | ✅ bottle-heal R#14, tango-heal R#2; Dire — 0 |
| ability_usage=aggressive изолирован на Dire | ✅ ability-harass D#10; Radiant — 0 |
| Баг: recovery-rune-bottle уходил к вражескому святилищу (7min) | 🐛 → FIXED: 2000 unit cap |

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

## 6. Открытые задачи

| # | Задача | Приоритет |
|---|---|---|
| **1** | **Новые правила (пара)** — реализовать `creep_wave_priority` + `ability_timing` первыми (простые, измеримые) | **TOP-1** |
| **2** | **Item build вариативность** — Layer 1 (build_style) ✅ DONE; Layer 2 — ситуативный порядок (§12) | **TOP-2** |
| 3 | **5v5 полный матч** Pusher vs Ganker | MEDIUM |
| 4 | **Больше героев** — пилот на Axe (defensive/aggressive очевидны по роли) | LOW |

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

- **НЕ КОММИТИТЬ** `playstyle_radiant/dire` тест-конфигами. Канон = ChatGPT_Pusher / ChatGPT_Ganker.
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

# Deploy в LIVE перед игрой
tools\deploy.bat

# Коммит (только когда явно попросили)
git add <files>
git commit -m "описание
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
git push origin phase-2-team-dials   # только по команде
```

Merge в `main` — осознанно, когда фаза с пруфами закрыта.

---

## 11. План: новые rules (TOP-1)

### Что реализовывать первым

**Пара:** `creep_wave_priority` + `ability_timing` — оба без зависимостей, легко верифицируются диагами.

### `creep_wave_priority`

Управляет тем, как бот работает с волной крипов.

| Значение | Поведение |
|---|---|
| `last_hit_only` (дефолт) | Атаковать крипа только когда HP ≤ dmgDelta. Минимальный пуш. |
| `push` | Атаковать крипов свободно, форсировать пуш волны. |
| `freeze` | Не атаковать крипов вообще если волна под своей башней — держать морозку. |

Реализация: в `mode_laning_generic.lua` в разделе last-hit/harass — перед атакой крипа проверяем rule. Диага: `cw-push` / `cw-freeze-skip`.

### `ability_timing`

Управляет когда использовать способности в бою.

| Значение | Поведение |
|---|---|
| `on_cooldown` (дефолт) | Кастовать при первой возможности (текущее поведение) |
| `save_for_execute` | Не харасить способностями — копить для добива (HP < execute_threshold) |
| `harass_only` | Кастовать только для харасса, никогда в execute-фазе |

Реализация: в `AbilityHarass` (aibattle_style.lua:563) добавить проверку rule перед кастом; аналогично в execute-блоке laning.

### Остальные planned rules (после тестирования первых двух)

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
