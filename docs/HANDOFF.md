# HANDOFF — AIBattle × Dota 2

> Единственная точка входа. Обновлять ЕГО, новых доков не плодить.
> Последнее обновление: 2026-06-11 (phase-15: 1v1 mid fixes — roam-late, rune pre-game, harass-before-kite, item_build).
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

**Improvements (все LIVE, флаги OFF по умолчанию):**
- `defensive_heal` ✅ — heal-item/tango/bottle/regen работают; `heal-pullback` ✅ отдельный CD (aib_pullbackLast, 3.0s), не блокируется wand-кулдауном (8846034123: heal-pullback R#1)
- `ability_on_dials` ✅ частично — SF raze D#62 (vs OHA D#0 при aggro=0.00). ⚠️ AbilityHarass не проверяет флаг — срабатывает для любого бота с ability_aggro>0. Нужен фикс изоляции.
- `anti_afk`, `tower_avoid` — не валидированы

**pregame_behavior** ✅ (10.06.2026) — pg-called D#267 R#273 стабильно; pregame-aggressive_mid/safe_tower в диагах. Бот идёт к правильной позиции до крипов.

**raze1 убран из SF harass** (10.06.2026) — `ability-harass-move` снизился R#12→R#1 (8846034123→8846050605). Только raze2 (300–600) и raze3 (550–850).

**Подробности + пруфы:** `docs/history/HANDOFF-full-2026-06-09.md` §3–§21

---

## 4. Rules-система (краткая)

| Rule | Значения (дефолт жирным) | Счётчик |
|---|---|---|
| `respawn_behavior` | walk_back / tp_to_lane / **tp_to_tower** | teleports_used |
| `dive_policy` | never / **finish_only** / always | `no-dive` |
| `smoke_usage` | **for_ganks** / never | `smoke` |
| `buyback_policy` | never / **default** | — |
| `low_hp_behavior` | **tp_fountain** / run_to_tower / fight_back / regen_lane / walk_fountain | `tp-fountain` / `regen-lane` / `retreat-blocked` / `recovery-*` |
| `aegis_policy` | **core** / any | — |

**Improvements** — opt-in булевы флаги в `improvements = { key = true }`. Off по умолчанию.

---

## 5. Текущий тест (LIVE, phase-15 — НЕ КОММИТИТЬ)

LLM-сгенерированные aggressive конфиги (ChatGPT vs Gemini), одинаковые диалы:

| Сторона | LLM | harass | abil | rune | execute | low_hp |
|---|---|---|---|---|---|---|
| **Radiant** | Gemini | 0.85 | 0.90 | 0.70 | 0.50 | regen_lane |
| **Dire** | ChatGPT | 0.85 | 0.90 | 0.70 | 0.45 | regen_lane |

Оба с `item_build = pos_2 SF` (bottle) и `improvements = {defensive_heal=true}`.

**Что подтверждено (11.06.2026, phase-15, матч 8847801209):**
- Оба бота с bottle ✅ — item_build fix работает
- rune-grab D#5 R#7 ✅ — рунный контроль активен
- Нет roam-late ✅ — боты остаются на мид-лейне
- Реальный бой 5 мин, Dire 2/0 ✅

**Исправлено в phase-15 (11.06.2026):**
- `aibattle_heal.lua` regenLane: stop-at-tower (был walk-to-fountain через J.VectorAway×400)
- `mode_laning_generic.lua`: harass перенесён до kite, immediate action
- `mode_retreat_generic.lua`: добавлен Think() для tp/walk_fountain
- `mode_roam_generic.lua`: roam-late отключён для GAMEMODE_1V1MID
- `mode_rune_generic.lua`: pre-game движение + ABSOLUTE-у-фонтана + bounty рун — всё отключено для 1v1
- `tools/match_stats.py`: winner mapping исправлен (0=Radiant, 1=Dire)

---

## 6. Открытые задачи

| # | Задача | Приоритет |
|---|---|---|
| **1** | **Pre-game позиционирование** — вернуть pre-game блок для 1v1 с destination = forwardness-точка между T1 (сейчас tower-lerp в лейнинге работает, но медленно) | **NEXT** |
| **2** | **[AIB-role] диаг** — проверить pos assignment ботов в следующем матче (LIVE only, в DEV нет) | **NEXT** |
| 3 | **Deny** — боты перестали денаить крипов, причина неизвестна | MEDIUM |
| 4 | **Wisdom рун в 1v1** — после 7 мин могут уводить ботов с мида (аналогично roam-late) | MEDIUM |
| 5 | **ability_on_dials изоляция** — AbilityHarass не проверяет флаг | MEDIUM |
| 6 | **5v5 полный матч** Pusher vs Ganker | MEDIUM |
| 7 | **LLM item_build — стилевые сборки** — см. §11 | LOW |

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

## 11. План: стилевые item build'ы (LLM-driven)

**Концепция:** для каждого героя — 3 готовых файла сборок. LLM выбирает файл по стилю, затем второй слой — порядок предметов внутри файла.

### Слой 1 — выбор сборки

Три файла на героя в `Customize/builds/<hero>/`:
- `aggressive.lua` — первый приоритет: мобильность + бурст (blink, echo sabre, BKB)
- `defensive.lua` — первый приоритет: выживаемость (vanguard, hood, crimson guard)
- `neutral.lua` — сбалансированный (phase boots + общий mid-game)

LLM выбирает файл целиком по диалам:
- `forwardness > 0.65` или `execute_threshold < 0.35` → aggressive
- `retreat_caution > 0.65` или `harass_desire < 0.35` → defensive
- иначе → neutral

Поле в конфиге: `item_build = "aggressive"` (строка вместо массива) — загрузчик резолвит в файл.

### Слой 2 — порядок внутри сборки

Каждый файл содержит предметы с тегами приоритета:
```lua
-- builds/axe/aggressive.lua
return {
    core    = { "item_blink", "item_echo_sabre", "item_black_king_bar" },
    luxury  = { "item_heart", "item_assault", "item_satanic" },
    situational = { "item_pipe", "item_lotus_orb" },
}
```

LLM (или правила по диалам) выставляет `item_priority = "core_first"` / `"luxury_early"` — загрузчик собирает итоговый flat-список в нужном порядке.

### Источники сборок

- **Steam Workshop** `filetype=12` — Dota 2 hero builds в JSON, парсим через `tools/parse_steam_build.py`
- **Dotabuff/Stratz API** — статистически сильные сборки по winrate/rank
- Pipeline: внешний JSON → `tools/convert_build.py` → наш `builds/<hero>/<style>.lua`

### Статус

Не начато. Предпосылки: закрыть §6 задачи 1-2 (ability_on_dials, harass-move), протестировать recovery. Первый кандидат для пилота — Axe (defensive/aggressive очевидны по роли).
