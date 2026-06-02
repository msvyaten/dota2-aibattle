# AIBattle × Dota 2 — HANDOFF (полный контекст для нового окна)

> Дата: 02.06.2026. Машина: Windows / Shadow PC (виртуалка на Mac). **Общаться с пользователем по-русски.**
> Это единая точка входа. Прочитать целиком перед действиями. Связанные доки:
> `docs/report-schema-v2.md` (сводка по диалам), `docs/validation-v2-results.md` (детальный лог тестов),
> `docs/windows-plan-finish-1v1.md` (план добивания валидации). Авто-память: `~/.claude/.../memory/aibattle-dota-validation.md`.

---

## 0. Что за проект (в одном абзаце)
AIBattle — продукт «ставки на ИИ-агентов»: игрок задаёт **промптом** характер бота, боты дерутся, на это ставят.
Доказываем на Dota 2: **промпт → конфиг → измеримое поведение бота**. База ботов — OpenHyperAI (OHA).
Демо-полигон — зеркальный 1v1 Solo Mid, Sniper vs Sniper. Ядро (Phase 1/2) ДОКАЗАНО. Сейчас — валидация
вглубь Schema v2 (6 диалов + правила) и вскрытие узких мест базовой laning-логики OHA.

## 1. Где что лежит
- **Git-репо:** `C:\Users\Shadow\dota2-aibattle` (origin: github **msvyaten/dota2-aibattle**, ветка **`schema-v2-item-builds`**, в `main` НЕ мёржено). Git-личность: **don / don@users.noreply.github.com** (личность юзера, уже в локальном конфиге репо).
- **LIVE-код (что грузит игра):** `C:\Program Files (x86)\Steam\steamapps\common\dota 2 beta\game\dota\scripts\vscripts\bots\`
- **Конфиги стиля:** `bots/Customize/playstyle_radiant.lua` и `playstyle_dire.lua`.
- **Логи матчей:** `...\dota 2 beta\game\dota\console.<matchid>.log` (при `-condebug`). Метрики — в финальном стат-дампе в конце лога.
- **Бэкенд (генерация конфига из промпта):** `backend/` (нужен свежий OPENAI_API_KEY — старый отозван; юзер бережёт лимиты, генерит промпты сам).

## 2. Что ДОКАЗАНО (с пруфами)
- **Свап-контроль 6×:** поведение И предметы следуют за конфигом, не за стороной. Матчи 8834418344 / 8834538636 / 8834873542 / 8834920653 / 8834938959.
- **`respawn_behavior = tp_to_lane`:** бот телепортится после смерти. `teleports_used`=1 (8834920653), =2 (8834938959).
- **`execute_threshold` (ветка, добивание ультом):** строка `AIB ult-finish triggered` (8834938959) — агро-бот скастовал Assassinate в убегающего лоу-хп.
- **`item_build`** (билд из конфига заменяет хардкод героя): подтверждено по item-дампу (у агро нет ботинок, у пассива Power Treads).

## 3. Статус диалов Schema v2 (матрица валидации)
6 диалов: `harass_desire`, `farm_focus`, `forwardness`, `ability_aggro`, `rune_control`, `retreat_caution`.
Правила: `respawn_behavior` (tp_to_tower | tp_to_lane | walk_back). На ветке спят: `execute_threshold`, адаптивные `item_rules`.

| Диал/правило | Статус | Пруф/заметка |
|---|---|---|
| свап-контроль | ✅ 6× | см. §2 |
| `tp_to_lane` | ✅ | teleports_used 1→2 |
| `tp_to_tower` | ⏳ ТЕСТИТСЯ СЕЙЧАС | был ❌ (канал TP рвался), ПОЧИНЕН (см. §5), идёт проверочный матч |
| `execute_threshold` (ветка) | ✅ | `AIB ult-finish` |
| `ability_aggro` (Шрапнель) | 🟡 работает, градиент не измерен | оба шрапнелят 975–1350 маг.; чистый A/B 0.3 vs 0.9 не снят |
| `harass_desire` | ❌ мёртв на Снайпере | физ-урон по герою = 0 даже при 0.90. Снайперы не сходятся на ~550, фарм на рейндже. Оживёт на МИЛИ |
| `rune_control` | 🟡 фикс есть, не подтв. | в 1v1 руну не берёт никто (standoff) |
| `retreat_caution` | ⬜ не прогнан | — |
| `forwardness` (бинарный @0.5) | ⬜ не прогнан чисто | — |
| `farm_focus` | ⬜ косвенно | проверится на мили |

## 4. Ключевые находки (почему буксует)
1. **harass_desire — кластер laning+retreat, не ордеринг.** Снайперы (рейндж) не подходят на дистанцию автоатаки → ветка «бить героя если в радиусе» не триггерится. Чинить позиционно (подход к герою), но это сцеплено с retreat: подошёл→получил→`mode_retreat` увёл = «выстрелил и отбежал».
2. **Денаи ≈ ласт-хиты** из-за асимметрии радиусов в `GetDesire` (`mode_laning_generic.lua`): свои крипы сканируются в **1200**, вражеские — в **800**. Стоя сзади, бот денаит, но не дотягивается до добивания.
3. **Игры тянутся 30+ мин:** киллов нет (пассивны), вышка падает от крипов поздно. Победа 1v1 = **2 килла ИЛИ вышка** (нетворт ни при чём — НЕ путать победителя с богатым ботом!). Мили-герой даст киллы → короче.
4. **TP докупаются стоковой логикой OHA** (не наша настройка), бесполезно в 1v1.
5. **Вышки (задача на будущее):** бот не доламывает вражескую вышку, чтобы победить (пример 8835417950 ~29 мин: вышке 1 тычка, крипы под ней, бот проигнорировал). Не в текущих фиксах.

## 5. Что мы накодили (по файлам, всё на ветке)
- **`FunLib/aibattle_style.lua`** — загрузчик: парсит `dials` (clamp 0-1), `rules` (whitelist), `item_build`, `item_rules`; `ScaleDesire`; `EvalItemCondition` (behind/ahead/dying/low_hp/enemy_magical/enemy_physical). Добавлен диал `execute_threshold` (дефолт 0).
- **`mode_laning_generic.lua`** — главный: `GetDials/GetRules` через aibattle_style; `AIB_HandleRespawn` (TP после смерти, теперь с **гардом канала**: после каста держит бота пока `modifier_teleporting`+1с грейс, не даёт Think отменить TP — это фикс tp_to_tower); `aib_wasDead` ставится в death-guard `GetDesire`; Think: **last-hit/harass интерлив** (добить в радиусе → харас по `harass_desire` → подойти к крипу), shrapnel по `ability_aggro`, forwardness-движение; чат-конфиг `AIB harass=.. farm=.. fwd=.. abil=.. rune=.. retreat=.. exec=..` (виден в console.log как CLocalize::FindSafe).
- **`mode_rune_generic.lua`** — `GetDesire = ScaleDesire(raw, rune_control)`; ослаблен «outnumbered»-гард при rune_control>0.6 (контест в 1v1).
- **`mode_retreat_generic.lua`** — desire домножается на retreat_caution.
- **`BotLib/hero_sniper.lua`** — в `ConsiderR` ветка execute_threshold (добив ультом убегающего лоу-хп). ВАЖНО: `ability_aggro` захардкожен на `sniper_shrapnel` → на мили НЕ сработает (это норм, помечать Sniper-only).
- **`item_purchase_generic.lua`** — подмена `sBuyList` на `item_build` из конфига (валидация через GetItemCost); хук `ItemPurchaseThink` для адаптивных `item_rules` (opt-in, спит без правил).
- **`Customize/general.lua`** — Sniper pos1 обе стороны, имена ChatGPT(Rad)/Gemini(Dire).

## 6. LIVE vs РЕПО (важно!)
- **РЕПО** держит КАНОН: `playstyle_radiant` = агро, `playstyle_dire` = пассив.
- **LIVE** сейчас = ТЕСТ-СОСТОЯНИЕ (идёт A/B-батч Снайпера, см. §7). После валидации вернуть канон из гита.
- Код (mode_*, aibattle_style, hero_sniper, item_purchase, general) — LIVE синкнут с репо.
- Имя бота Radiant не отображается в игре — клиентский рендер-квирк, НЕ кодовый баг (на сервере имя верное).

## 7. АКТИВНЫЙ ПЛАН (что прямо сейчас)
Идёт снайперский A/B-батч (юзер играет, потом разбираем ОДНИМ заходом):
- **Игра 1 — tp_to_tower:** Radiant=агро, Dire=пассив+`tp_to_tower`. Пруф: `teleports_used>0` у slot 128 (Dire) + наблюдение «телепортнулся к вышке».
- **Игры 2–4 — дуэльный A/B (симметрия):** оба бота = baseline (все диалы 0.50, forwardness 0.70, respawn walk_back, одинаковый item_build), меняется ОДИН диал (Radiant LOW / Dire HIGH): Т2 `ability_aggro` 0.3/0.9 (маг.урон), Т5 `retreat_caution` 0.2/0.8 (смерти/мин-HP), Т6 `forwardness` 0.1/0.9 (позиция, на глаз).
- **Потом (после лимитов) — МИЛИ-герой** (sven/juggernaut, зеркало, правка `general.lua`): оживить **harass_desire** (физ-урон по герою — метрика, что была 0 на Снайпере) + `farm_focus` + проверка `item_build`-override на мили.
- **Merge-gate:** мёрж в `main` только когда дуэльные диалы + tp_to_tower + мили-harass ✅ с пруфами. `rune_control` и ability_aggro-на-мили честно пометить deferred/hero-specific.

## 8. Правила работы (соблюдать)
- **FREEZE фич:** новые диалы / расширения execute_threshold/item_rules / новые герои — НЕ добавляем, пока матрица не закрыта. Глубина перед шириной.
- **Доказательство — только цифра из стат-дампа ИЛИ строка из `console.<id>.log`.** «На глаз»/«вроде работает» не принимается.
- **Один тест = один диал** между двумя прогонами (или зеркальный A/B в одной игре: оба бота равны кроме одного диала).
- **Игры — до конца** (нужен финальный стат-дамп). Прерванный лог = нет данных.
- **Гит:** коммит локально, **пуш пачкой** по команде юзера «заливай». Перед работой — `git status` + `git log origin/<branch>..HEAD` (нет ли незапушенного). Sync LIVE→репо безопасен; робокопи репо→LIVE тоже ок (general.lua в репо актуален).
- **Не переписывать вслепую:** если что-то не работает — сообщить НА КАКОМ ШАГЕ рвётся (с пруфом), предложить точечный фикс.
- **Эффективность токенов:** один точный grep на лог (kills/deaths/last_hits/denies/teleports_used/hero_damage + физ/маг + runes + items), без больших чтений; батчить анализ нескольких игр в один заход.

## 9. Как читать лог (шпаргалка grep)
```
# в LIVE-папке dota:
L=$(ls -t console.8*.log | head -1)
grep -n "player_slot:\|kills:\|deaths:\|last_hits:\|denies:\|teleports_used:\|hero_damage:\|net_worth:\|level:\|power_runes:\|water_runes:" "$L" | grep -v claimed
grep -A3 "hero_damage_dealt {" "$L" | grep "pre_reduction\|damage_type"   # физ vs маг по герою
grep "AIB " "$L"   # чат-диагностики (config announce и т.п.)
```
player_slot 0 = Radiant, 128 = Dire. Нет `player_slot:` в логе → игра прервана (дампа нет).

## 10. Стратегия на будущее (после валидации v2)
По убыванию влияния на продукт:
1. **5v5-пивот** — командные/руны/позиционные диалы оживают сами, матчи НЕДЕТЕРМИНИРОВАНЫ (основа ставок). Главный продуктовый рычаг.
2. **Холистический laning/combat-фикс** — «подход-харас-добивание-отступление-пуш» как связный кластер (иначе боты пассивны и в 5v5).
3. **Win-condition/вышки** — бот хочет победить, а не тянуть.
4. **Разнообразие героев** — разные «личности» = интереснее ставки.
5. **Prompt-UX** — готовая инструкция для ChatGPT (схема dials/rules/item_build/item_rules), чтобы юзер писал промпты. Юзер просил собрать такой текст, когда дойдём до промптов.

## 11. Подводные камни
- 1v1 Solo Mid + «заполнить ботами» спавнит 5v5 → кикать лишних (`kick 1..4`, `kick 6..9`), остаются ChatGPT vs Gemini.
- `print()` НЕ виден в console.log — диагностика только через `bot:ActionImmediate_Chat`.
- «error in error handling» ×20 в логе — фоновый шум OHA, НЕ наш баг (столько же в рабочих логах).
- Файлы LIVE — LF, репо — CRLF; git варнит, Lua ест оба.
- Не путать победителя 1v1 с богатым ботом: победа = 2 килла / вышка.
