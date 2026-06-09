# HANDOFF — AIBattle × Dota 2

> Единственная точка входа. Обновлять ЕГО, новых доков не плодить.
> Последнее обновление: 2026-06-09 (phase-12: regen_lane).
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
- `defensive_heal` — anti-thrash фикс сделан; heal-item/prev-heal работают; regen_lane в работе (phase-12)
- `ability_on_dials` ✅ (Blade Fury ON ~2500 vs OFF ~450)
- `anti_afk`, `tower_avoid` — не валидированы

**Подробности + пруфы:** `docs/history/HANDOFF-full-2026-06-09.md` §3–§21

---

## 4. Rules-система (краткая)

| Rule | Значения (дефолт жирным) | Счётчик |
|---|---|---|
| `respawn_behavior` | walk_back / tp_to_lane / **tp_to_tower** | teleports_used |
| `dive_policy` | never / **finish_only** / always | `no-dive` |
| `smoke_usage` | **for_ganks** / never | `smoke` |
| `buyback_policy` | never / **default** | — |
| `low_hp_behavior` | **tp_fountain** / run_to_tower / fight_back / regen_lane | `tp-fountain` / `regen-lane` / `retreat-blocked` |
| `aegis_policy` | **core** / any | — |

**Improvements** — opt-in булевы флаги в `improvements = { key = true }`. Off по умолчанию.

---

## 5. Текущий тест (LIVE, phase-12 — НЕ КОММИТИТЬ)

| Сторона | `low_hp_behavior` | item_build | `defensive_heal` |
|---|---|---|---|
| **Radiant** | `regen_lane` | Valve build (Eul+Blink) | true |
| **Dire** | `tp_fountain` (контроль) | OHA hero_nevermore.lua pos_2 | true |

Оба: skill_build `{1,5,1,5,1,6,1,5,5,4,6,4,4,4,6}`, все диалы нейтральны (0.50–0.80).

**Что подтверждено (09.06.2026, phase-12):**
- `regen-lane` ✅ D#18 в матче 8845558969 — Dire делал безопасные отходы
- `retreat-blocked` ✅ D#15 — враг блокировал отход, система корректно реагирует
- `kill-priority` ✅ R#15–19 стабильно по матчам
- `heal-item` / `tango-heal` / `tp-fountain` ✅ работают
- `pregame_behavior` 🔄 задеплоено 09.06, ещё не подтверждено в матче

**На тест в следующем матче:**
- `pregame-aggressive_mid D#N` и `pregame-safe_tower R#N` в первом батче диагов
- Отсутствие VScript errors при старте (pcall фикс)

---

## 6. Открытые задачи

| # | Задача | Приоритет |
|---|---|---|
| **0** | Матч → подтвердить `pregame-aggressive_mid` / `pregame-safe_tower` | **NEXT** |
| 1 | **Respawn TP** — подтвердить `respawn-no-tp`/`respawn-tp-cd` (бот шёл пешком имея свиток) | NEXT |
| 2 | **Tower damage breakdown** — hero vs creep vs auto в match_stats.py | LOW |
| 3 | **5v5 полный матч** Pusher vs Ganker | MEDIUM |
| 4 | **LLM item_build 5v5** | MEDIUM |
| 2 | **Respawn TP** — подтвердить `respawn-no-tp`/`respawn-tp-cd` (бот шёл пешком имея свиток) | NEXT |
| 3 | **Pre-game модуль** (DotaTime()<0): `safe_tower` / `aggressive_mid` / `jungle_pressure`. В 1v1 нет рун в 0:00, нейтралы не атакуют | MEDIUM |
| 4 | **5v5 полный матч** Pusher vs Ganker до конца | MEDIUM |
| 5 | **LLM item_build 5v5** | MEDIUM |
| 6 | `item_tango_single` — другое имя у разделённого танго, проверить | LOW |
| 7 | **fight_back coherence** в system prompt: fight_back → forwardness ≤ 0.65 | LOW |

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
1. У кого-то `deaths=2` → матч закончился по убийствам. `kills` в кредите может быть < 2 если последний хит взяла башня/крип — это нормально.
2. Никто не имеет `deaths=2` → смотреть `towerDmg`: у кого ~4500 — тот снёс T1 врага → победа по башне.
3. Никто не умер 2 раза, towerDmg низкий → победа по **100 last hits**.

- `towerDmg` = урон нанесённый ботом по вражеским башням (не полученный)
- `winner_team` в парсере = `Radiant` или `Dire` (было сырое 0/2, исправлено)
- В 1v1 SF `DotaTime()` в bot-скриптах **никогда не бывает < 0** — скрипты стартуют уже при DotaTime ≥ 0

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
