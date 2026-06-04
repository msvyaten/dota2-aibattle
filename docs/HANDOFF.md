# HANDOFF — AIBattle × Dota 2 (единый живой документ)

> Единственная точка входа и единственный поддерживаемый док проекта. Обновлять ЕГО, новых
> статус/план-доков не плодить. Он же — то, что отдаём другому Claude (мак/новое окно).
> Последнее обновление: 2026-06-04 (Фаза 2 DONE). Машина: Windows/Shadow PC (тут LIVE Dota). По-русски.
>
> Доказательство = ТОЛЬКО цифра из финального стат-дампа ИЛИ строка из `console.<matchid>.log`.
> «На глаз» не считается. FREEZE новых фич, пока матрица не закрыта (глубина перед шириной).

---

## 0. Проект в одном абзаце
AIBattle — «ставки на ИИ-агентов»: игрок промптом задаёт характер бота. Доказываем на Dota 2:
**промпт → конфиг → измеримое поведение бота**. База ботов — OpenHyperAI (OHA). Демо-полигон:
зеркальный 1v1 Solo Mid, Sniper vs Sniper (для harass — мили Juggernaut/Sven). Цепочка:
`промпт → LLM → JSON → playstyle_*.lua → поведение`. Сейчас: валидация Schema v2 (6 диалов +
правила) и вскрытие узких мест базовой laning-логики OHA.

## 1. Пути / окружение
- **Git-репо:** `C:\Users\Shadow\dota2-aibattle` (origin `msvyaten/dota2-aibattle`, ветка
  **`schema-v2-item-builds`**, в `main` НЕ мёржено). Git-личность: **don / don@users.noreply.github.com**.
- **LIVE (что грузит игра):** `…\dota 2 beta\game\dota\scripts\vscripts\bots\`. Структура `bots/` зеркалит LIVE.
- **Конфиги стиля:** `bots/Customize/playstyle_radiant.lua` / `playstyle_dire.lua`.
- **Логи:** `…\game\dota\console.<matchid>.log` (при `-condebug`). Метрики — финальный стат-дамп в конце.
- **Анализ матча:** `python tools/match_stats.py <id> [id2 …]` — печатает cfg + по-слотам KDA/LH/DN/
  урон/предметы/диаги. `player_slot 0=Radiant, 128=Dire`. Использовать ЕГО, не гречить логи руками.
- Python 3.12 (openai). Бэкенд `backend/generate_playstyle.py` (gpt-5.5) — НЕ используется,
  OPENAI_API_KEY отозван, конфиги пишем руками.

## 2. Архитектура (что где в коде, всё на ветке)
- **`FunLib/aibattle_style.lua`** — загрузчик: парсит `dials` (clamp 0-1), `rules` (whitelist),
  `item_build`, `item_rules`; `ScaleDesire`; `EvalItemCondition`; `Imp` (improvements, OFF по умолч.).
- **`mode_laning_generic.lua`** — главный: `GetDials/GetRules/GetImp`; `AIB_HandleRespawn` (TP после
  смерти с гардом канала); Think: last-hit/harass интерлив, shrapnel по `ability_aggro`, forwardness-
  движение; cfg-анонс в чат. + LIVE-only impruvы (defensive_heal, anti_afk, tower_avoid, ability_on_dials).
- **`mode_rune_generic.lua`** — `GetDesire = ScaleDesire(raw, rune_control)`.
- **`mode_retreat_generic.lua`** — desire ×= retreat_caution.
- **`BotLib/hero_sniper.lua`** — `ConsiderR` ветка execute_threshold. `ability_aggro` ХАРДКОД на
  `sniper_shrapnel` → на мили не сработает (помечать Sniper-only). Спеллы хардкодны по героям.
- **`item_purchase_generic.lua`** — подмена `sBuyList` на `item_build` (валидация GetItemCost);
  хук `ItemPurchaseThink` для адаптивных `item_rules` (opt-in, спит).
- **`Customize/general.lua`** — герои pos1 обе стороны, имена ChatGPT(Rad)/Gemini(Dire).

---

## 3. СТАТУС ВАЛИДАЦИИ ДИАЛОВ (МАТРИЦА ЗАКРЫТА)

| Рычаг | Статус | Пруф (match id) |
|---|---|---|
| Свап-контроль (база) | ✅ 8× | поведение И предметы за конфигом, не за стороной: 8834418344 / 8834538636 / 8834873542 / 8834920653 / 8834938959 / 8835623865 / 8835688565 |
| `respawn_behavior=tp_to_lane` | ✅ | teleports_used=1 (8834920653), =2 (8834938959) у умирающего пассива |
| `respawn_behavior=tp_to_tower` | ✅ 2× | teleports_used=2 (8835623865, Dire), =1 (8835688565, Radiant) после фикса гарда канала (Mac `89b5dc8`). Баг до фикса: =0 (8835293640) |
| `execute_threshold` (ветка) | ✅ | строка `AIB ult-finish triggered` (8834938959) — Assassinate в убегающего лоу-хп |
| `ability_aggro` (Шрапнель) | ✅ градиент ~11× (deferred: Sniper-only) | маг.урон Шрапнели 1200 (0.90) vs 110 (0.30) — зеркало 8835738321. Sniper-only |
| `harass_desire` | ❌ дальник / ✅ мили ~6.5× | Sniper: физ.урон=0 даже при 0.90 (не сходятся). Juggernaut 8835850651: физ.урон 7891 (0.90) vs 1209 (0.30), вылилось в 2/0 vs 0/2 |
| `forwardness` (бинарный @0.5) | ✅ (оговорка side) | зеркало 8836178214: пушер 0.90 = 38LH+4500 урона по вышке но умер 2×; холдер 0.10 безопасно, килл 1/0 |
| `retreat_caution` | ✅ подтв. свапом | первый прогон нечисто (8836163050, осторожный всё равно занырнул); СВАП подтвердил: 0.20 ныряет+умирает 2×+4500tower / 0.80 выживает+0 tower, осторожный выиграл обе |
| `rune_control` | ❌ deferred → 5v5 (структурно подавлен в 1v1) | КОРНЕВАЯ ПРИЧИНА (аудит): laning GetDesire в 1v1 = плоская 1.0 (mode_laning_generic ~164), руна капится 0.99 в ScaleDesire (aibattle_style ~138) → laning всегда выигрывает арбитраж. Чтобы тестить: поднять кап руны >1.0 при высоком rune_control. Отложено |
| `farm_focus` | 🟡 deferred (косвенно, на мили) | проявляется на мили (трейд vs ластхит); чистого A/B нет |

---

## 4. Ключевые находки (почему laning буксует)
1. **harass_desire = кластер laning+retreat, не диал-ордеринг.** Снайперы не сходятся на ~550
   (фармят на рейндже). Чтобы харас работал — бот должен ПОДХОДИТЬ, но это сцеплено с retreat:
   подошёл→получил→`mode_retreat` увёл = «выстрелил и отбежал».
2. **Денаи ≈ ласт-хиты** из-за асимметрии радиусов в `GetDesire`: свои крипы сканируются в **1200**,
   вражеские — в **800**. Стоя сзади, бот денаит, но не дотягивается до добивания. (Объясняет, почему
   Dire денаил больше — плюс side-bias.)
3. **Боты не знают радиус вышки.** В laning нет проверки на радиус вражеской вышки перед ударом по
   герою → бьют под вышкой и огребают. retreat-шаг триггерится на урон от КРИПОВ, не от вышки.
   `tower_avoid` импрув ❌ не работает (нужно перенести гард в боевой/retreat-слой, осознать радиус ~700).
4. **Игры тянутся 30+ мин:** киллов нет (пассивны), вышка падает поздно. Победа 1v1 = 2 килла ИЛИ
   вышка (НЕ нетворт — не путать победителя с богатым ботом).
5. **TP докупаются стоковой логикой OHA**, бесполезно в 1v1.

## 5. Аудит кода — без блокеров
- **rune_control** — см. §3 (арбитраж приоритета laning 1.0 > rune cap 0.99, не баг).
- **item_rules `dying`** [latent] — зависит от `aib_deathCount`, инкремент в `ItemPurchaseThink` на
  мёртвом фрейме; проверить, зовётся ли движком на мёртвом боте.
- **item_rules вставки** [5v5 edge] — ARDM/pos-swap ребилд сбрасывает список, но `aib_ruleDone[item]`
  остаётся true → ситуативный предмет теряется. К 1v1 не относится.
- OK: clamp/whitelist/pcall, item_build override, execute_threshold — доказаны.

---

## 6. ИСТОРИЯ ИЗМЕНЕНИЙ
**В гите (ветка `schema-v2-item-builds`):**
- `9ec61f2` (HEAD) — scorecard диалов + match id.
- `89b5dc8` — фикс tp_to_tower (гард канала ТП: `aib_tping`+`aib_tpCastTime` держат бота пока есть
  `modifier_teleporting`; раньше `aib_wasDead` сбрасывался в тик каста и Think рвал канал).
- `9fda74c` — фикс пассива (кайт от крипов, gate `retreat_caution>0.4`) + harass floor 0.05.
- `75dfa0e` — фикс «stay busy» (агро бьёт героя / фармер бьёт крипов вместо простоя).

**LIVE-only (НЕ в гите — держим до валидации):**
- Вся подсистема **improvements**: `defensive_heal`, `anti_afk`, `tower_avoid`, `ability_on_dials`,
  инфра `improvements={}` + `M.Imp`, хелпер `AIB_Diag`.
- Juggernaut в `general.lua`.

**Статус импрувов:**
- `ability_on_dials` ✅ ПОДТВЕРЖДЁН (Blade Fury по диалам: маг-урон ON ~2500-3000 vs контроль ~450-560).
- `tower_avoid` ❌ НЕ РАБОТАЕТ (towerDmg зависит от стороны не флага; дайв в боевом/пуш-режиме, гард
  только в laning + исключение «добивание<35%»). Доработать.
- `defensive_heal` — ПОЧИНЕН передёргивающий баг (heal-item 1533→69/57 за матч, чат не спамит; подтв.
  2× на обеих сторонах). Свап-пара 8836787628 (Dire=ВКЛ) / 8836810347 (Radiant=ВКЛ): Radiant выиграл
  ОБЕ → исход идёт за side-bias (Dire ныряет вышку, towerDmg 4500 + умирает), НЕ за флагом. Эффект
  импрува НЕУБЕДИТЕЛЕН — замаскирован база-багами (дайв вышки + смерть на лоу-хп). Не валидирован.
- `anti_afk` — отрабатывает (anti-afk R#441 / D#613), но эффект так же замаскирован. Не валидирован.

---

## 7. Изменения 03.06 — ЗАКОММИЧЕНЫ в ветку как dormant/unvalidated

> Затащены в гит коммитом «wip: improvements subsystem + 03.06 fixes (dormant, unvalidated)»: вся
> LIVE-only подсистема improvements + фиксы ниже. Флаги improvements OFF по умолчанию — едут как
> помеченный неготовый код (как execute_threshold), валидацию НЕ прошли. Ниже — что именно сделано.

**Контекст (матч 8836632303, Radiant=контроль / Dire=импрувы):** `heal-item` сработал **1533×** за
~12 мин (~2/сек) — defensive_heal лупил каждый тик и пожирал фарм (импрув-сторона LH 20 vs 31, lvl 8
vs 10, heroDmg 1499 vs 3144, смерть+TP, контроль победил). Старый одноразовый диаг это прятал; новые
счётчики вскрыли. Отсюда фиксы ниже. (Оговорка: 1 игра + Dire = side-bias, нужна свап-игра; но `#1533`
от стороны не зависит.)

### Файл `bots/mode_laning_generic.lua`

**7.1 Хелпер `AIB_Diag` + `AIB_SIDE`** — сразу после `local function GetImp(name) return Style.Imp(name) end`.
Считает срабатывания тихо, шлёт ОДНУ сводную строку макс. раз в 60 сек (чтобы не спамить чат —
`print()` в console.log не виден). Формат `AIB[R] anti-afk=15 heal-item=7`; последняя строка = итоги.
```lua
-- AIBattle diag: count each branch firing silently, then emit ONE combined summary line at most
-- once per minute (only when something fired) so a TEST GAME yields measurable numbers without
-- spamming chat. Format 'AIB[R] anti-afk=15 heal-item=7'; the LAST such line in console.<id>.log
-- carries the cumulative totals. (print() is invisible in console.log, so chat is the only
-- logging channel — keep it sparse.)
local AIB_SIDE = (bot:GetTeam() == TEAM_RADIANT) and "R" or "D"
local function AIB_Diag(key)
	bot.aib_diagCnt = bot.aib_diagCnt or {}
	bot.aib_diagCnt[key] = (bot.aib_diagCnt[key] or 0) + 1
	local now = DotaTime()
	if bot.aib_diagLast == nil or now - bot.aib_diagLast >= 60.0 then
		bot.aib_diagLast = now
		local parts = {}
		for k, v in pairs(bot.aib_diagCnt) do parts[#parts + 1] = k .. "=" .. v end
		table.sort(parts)
		bot:ActionImmediate_Chat("AIB[" .. AIB_SIDE .. "] " .. table.concat(parts, " "), true)
	end
end
```

**7.2 cfg-анонс** (в `Think`, блок `if not bot.aib_announced then`) — добавлены сторона + флаги импрувов:
```lua
		bot:ActionImmediate_Chat(string.format("AIB[%s] harass=%.2f farm=%.2f fwd=%.2f abil=%.2f rune=%.2f retreat=%.2f exec=%.2f heal=%d afk=%d tower=%d abildial=%d",
			AIB_SIDE,
			dials.harass_desire, dials.farm_focus, dials.forwardness, dials.ability_aggro,
			dials.rune_control, dials.retreat_caution, dials.execute_threshold,
			GetImp('defensive_heal') and 1 or 0, GetImp('anti_afk') and 1 or 0,
			GetImp('tower_avoid') and 1 or 0, GetImp('ability_on_dials') and 1 or 0), true)
```

**7.3 Блок `defensive_heal` — ГЛАВНЫЙ ФИКС (анти-передёргивание).** Кулдаун 2.5с + не лечиться при
добиваемом крипе в радиусе + `hitCreep/moveToCreep` считаются один раз тут и переиспользуются
интерливом ниже (поэтому из начала интерлива убрана повторная `local hitCreep, moveToCreep = …`).
Полный финальный блок (на месте старого defensive_heal, ПЕРЕД комментом «Last-hit / harass interleave»):
```lua
	-- AIBattle improvement (opt-in defensive_heal, HERO-AGNOSTIC): at low HP recover IN LANE via
	-- inventory items + pull back to safety, instead of plodding to fountain (which bleeds farm).
	-- Threshold scales with retreat_caution (cautious heals earlier). No hero spells — items only.
	-- Anti-thrash (fix for heal-item firing ~2x/s and starving farm): at most one heal attempt per
	-- HEAL_CD seconds, and NEVER skip a securable in-range last-hit to heal (free CS > a wand tick).
	-- Diag: 'heal-item' / 'heal-pullback'. NOTE: hitCreep/moveToCreep are computed once here and
	-- reused by the last-hit/harass interleave below.
	local HEAL_CD = 2.5
	local hitCreep, moveToCreep = GetBestLastHitCreep(nEnemyCreeps)
	local lhSecurable = J.IsValid(hitCreep) and not moveToCreep
		and GetUnitToUnitDistance(bot, hitCreep) <= botAttackRange
	if GetImp('defensive_heal') and not lhSecurable
		and J.GetHP(bot) < (0.30 + 0.20 * (dials.retreat_caution or 0.5))
		and (bot.aib_healLast == nil or DotaTime() - bot.aib_healLast >= HEAL_CD) then
		-- instant items: safe to pop any time
		for _, nm in ipairs({ "item_magic_wand", "item_magic_stick", "item_faerie_fire", "item_satanic" }) do
			local it = bot:GetItemInSlot(bot:FindItemSlot(nm))
			if it ~= nil and it:IsFullyCastable() then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbility(it); return
			end
		end
		local safe = not (bot:WasRecentlyDamagedByAnyHero(1.0) or bot:WasRecentlyDamagedByCreep(1.0))
		if safe then
			-- channel items (break on damage): only when not being hit
			local salve = bot:GetItemInSlot(bot:FindItemSlot("item_flask"))
			if salve ~= nil and salve:IsFullyCastable() then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-item")
				bot:Action_UseAbilityOnEntity(salve, bot); return
			end
			local bottle = bot:GetItemInSlot(bot:FindItemSlot("item_bottle"))
			if bottle ~= nil and bottle:IsFullyCastable() then
				bot.aib_healLast = DotaTime()
				bot:Action_UseAbility(bottle); return
			end
		else
			-- being hit, no instant heal -> pull back toward own tower to regen, don't keep fighting
			local back = AIB_ForwardSurvivingTowerLoc()
			if back then
				bot.aib_healLast = DotaTime(); AIB_Diag("heal-pullback")
				bot:Action_MoveToLocation(back); return
			end
		end
	end
```
И сразу после него интерлив, первая строка теперь СРАЗУ `local csAllowed = …` (без повторного hitCreep):
```lua
	-- Last-hit / harass interleave (AIBattle): secure an IN-RANGE last-hit first (free CS,
	-- no repositioning), THEN harass with probability harass_desire, and only WALK to a
	-- creep when not harassing. Lets the bot farm AND harass instead of one killing the other.
	local csAllowed = J.IsValid(hitCreep) and (J.GetPosition(bot) <= 2 or not J.IsThereNonSelfCoreNearby(700))
	local needMove = csAllowed and (GetUnitToUnitDistance(bot, hitCreep) > botAttackRange
		or (moveToCreep and GetUnitToUnitDistance(bot, hitCreep) > botAttackRange * 0.8))
```

**7.4 anti-afk диаг** (в блоке `anti_afk`, ветка «walk to nearest creep»):
было `if not bot.aib_afkDiag then bot.aib_afkDiag = true; bot:ActionImmediate_Chat("AIB anti-afk", true) end`
стало:
```lua
				AIB_Diag("anti-afk")
```
(Прежние одноразовые `AIB heal-item` ×2 и `AIB heal-pullback` уже заменены на `AIB_Diag(...)` внутри 7.3.)

### Файл `tools/match_stats.py` (в репо — можно пушить отдельно)
**7.5 cfg-детект + diag-парсинг** под новый формат `AIB[R] …` и сводный `key=count` (+ легаси).
Было:
```python
    cfg = [l.split("localize: ", 1)[1] for l in lines if "AIB harass" in l]
    diag = sorted(set(re.findall(r"'(AIB (?:heal|anti|ult|respawn|fwd)[^']*)'", "\n".join(lines))))
```
Стало:
```python
    text = "\n".join(lines)
    cfg = [l.split("localize: ", 1)[1] for l in lines if "harass=" in l]
    # Diag: 'AIB[R] anti-afk=15 heal-item=7'. Aggregate per key -> {side: count}; combined lines
    # carry 'key=N' (cumulative, keep max), legacy '<key> #N' / bare '<key>' handled too.
    diag = {}
    for side, body in re.findall(r"'AIB(\[[RD]\])?\s+([^']*)'", text):
        if "harass=" in body:  # that's the cfg announce, not a diag
            continue
        s = side.strip("[]") or "?"
        pairs = re.findall(r"([\w-]+)=(\d+)", body)  # combined format 'anti-afk=15 heal-item=7'
        if pairs:
            for key, val in pairs:
                d = diag.setdefault(key, {})
                d[s] = max(d.get(s, 0), int(val))
        else:  # legacy: '<key> #N' (cumulative) or bare '<key>' (one occurrence)
            m = re.search(r"#(\d+)$", body)
            key = (body[:m.start()] if m else body).strip()
            if key:
                d = diag.setdefault(key, {})
                d[s] = max(d.get(s, 0), int(m.group(1))) if m else d.get(s, 0) + 1
```
И печать diag в `main` (было `for d in diag: print("  diag:", d)`):
```python
        for key in sorted(diag):
            sides = " ".join(f"{s}#{n}" for s, n in sorted(diag[key].items()))
            print("  diag:", key, sides)
```
Проверено: парсит новый и старые логи, не падает.

---

## 8. НЕ КОММИТИТЬ (LIVE-only тест-состояние)
- `bots/Customize/playstyle_radiant.lua` / `playstyle_dire.lua` в LIVE = ТЕСТ (свапнутая пара импрувов).
  В РЕПО держится КАНОН (radiant=агро, dire=пассив). **НЕ перезаписывай канон тест-конфигами.**
- `general.lua` — синк только LIVE→репо; repo→LIVE НЕ копировать (репо старее).

## 9. GIT (ветка `schema-v2-item-builds`, личность don)
```bash
cd <репо>
git status
git log --oneline origin/schema-v2-item-builds..HEAD   # проверь незапушенное

git add tools/match_stats.py            # + bots/mode_laning_generic.lua если вариант (А)
git commit -m "diag: per-side cumulative counters (sparse summary) + defensive_heal anti-thrash

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push origin schema-v2-item-builds
```
Пуш — ПОСЛЕ подтверждения пользователя (пуш пачкой раз в день). Merge в `main` — только когда матрица
+ impruвы валидированы с пруфами. `rune_control` и ability_aggro-на-мили — пометить deferred/hero-specific.

## 10. Рабочий процесс (durable)
- Конфиги пишем РУКАМИ в `playstyle_*.lua`; живую LLM-генерацию не юзаем (бережём лимиты).
- Цикл: ставлю конфиг → юзер играет → шлёт ПАЧКУ match id → читаю за заход через `match_stats.py`.
  Игры доигрывать ДО КОНЦА (нужен стат-дамп).
- Метод A/B: зеркало — оба бота идентичны кроме ОДНОГО диала = 1 игра/тест. Baseline `forwardness 0.70`
  (иначе не сходятся). item_build симметричный. Стороны свапать между прогонами (side-bias РЕАЛЕН:
  slot128/Dire чаще ныряет вышку).
- Беречь токены: правки кода через Grep+якорь, не чтением целиком; не плодить доки — обновлять ЭТОТ.

## 11. РОАДМАП AIBattle v2 → продукт

**ПРИНЦИПЫ**
- Матрица v2 закрыта (6 диалов + respawn доказаны). Цель сместилась: забрать выигрыш и двигать
  продукт, а НЕ полировать пассивный 1v1.
- ПОСЛЕ мёржа v2 базу `mode_laning` не чурнить «на ходу» — иначе рискуем обнулить доказанные цифры
  (ability 11×, harass 6.5× и т.д.).
- Не уходить в починку база-багов ради валидации improvements — бездонный колодец, низкий леверидж.
  improvements остаются дремлющими (флаги OFF).

**=== ФАЗА 0 — ЗАФИКСИРОВАТЬ v2 (сейчас) ===**
1. Однострочный фикс §11а: гейт анти-крип-кайта `retreat_caution > 0.4` → `>= 0.4` (baseline ровно
   0.40 → сейчас ветка всегда ВЫКЛ). Больше базу не трогать.
2. В §3 пометить deferred/hero-specific: `rune_control` (структурно 5v5), `farm_focus` (косвенно),
   `ability_aggro` (Sniper-only).
3. Проверить, что все флаги improvements = OFF по умолчанию (defensive_heal/anti_afk/tower_avoid/
   ability_on_dials) — едут как dormant-код, как execute_threshold.
4. Мёрж ветки в main: `git checkout main && git merge schema-v2-item-builds && git push origin main`
   (конфликтов быть не должно — main отстал на Phase-1-коммите). Вернуться на ветку.
5. improvements ЗАПАРКОВАТЬ: defensive_heal/anti_afk/tower_avoid не валидировать через починку базы.
   Вернёмся, только если конкретное демо потребует.

**=== ФАЗА 1 — 5v5 SMOKE-ТЕСТ ✅ DONE (8836936748) ===**
Турбо, зеркальная комп PA/Zeus/Axe/Lion/Warlock. 2 игры.
Игра 1 (8836936748): Radiant=агро / Dire=пассив / Force_Group_Push_Level=1.
Игра 2 (8837002740): SWAP Radiant=пассив / Dire=агро / Force_Group_Push_Level=3.

РЕЗУЛЬТАТ:
- **Стабильность ✅** — 10 ботов, без крашей, матч доигрался до стат-дампа (winner_team=0, 33 мин).
- **Командный A/B-сигнал ✅** — агро vs пассив выражается командно: Radiant 20 килов / 8 смертей /
  ~60 500 hero dmg vs Dire 6 / 21 / ~28 300. Урон ×2.1. Диалы масштабируются на команду.
- **Смотрибельность ⚠️** — игра затянулась на 33 мин (Turbo!): агро-команда имела 20к gold advantage
  на 19 мин но не закрыла — боты не собирались командой, не осаждали бараки/вышки, стояли в лейте.
  В итоге крипы сами запушили. Это вскрыло ровно мандат Фазы 2.

НАХОДКИ:
- Диалы — индивидуальное поведение, **командной цели нет**: push/gank/defend — за Фазой 2.
- item_build не по роли (всем одинаковые настройки) + OHA скиллит без учёта позиции — OHA-база.
- `Customize.Force_Group_Push_Level=1` → боты не группируются для пуша → ПОДНЯТО ДО 3.
  Результат (8837002740, SWAP R=пассив/D=агро): агро tower dmg ~3700 (vs ~400 при level=1),
  игра закрылась за 29 мин. **Level=3 оставляем как бейзлайн для 5v5.**

СВАП-ВАЛИДАЦИЯ 5v5 ✅ (8837002740): Dire=агро 28 килов / ~66k dmg, Radiant=пассив 7 / ~40k.
Поведение следует за конфигом, не за стороной — в 5v5 тоже работает.

ЗЕЛЁНЫЙ СВЕТ НА ФАЗУ 2: командная разница с цифрами есть. Смысл строить командные диалы — подтверждён.

**=== ФАЗА 2 — КОМАНДНЫЕ ДИАЛЫ (это v3) — КОД ГОТОВ, ВАЛИДАЦИЯ ВПЕРЕДИ ===**
Ветка **`phase-2-team-dials`** (от `schema-v2-item-builds`, т.к. main отстал на 2 коммита Фазы 1;
влитие всего в main — одним осознанным шагом, когда Фаза 2 с пруфами). Цель: оживить командное, что
в 1v1 не выражалось. Дальше — двигать к продукту (Фаза 3), а НЕ в полировку 5v5 (см. принципы).

**2.1 РЕАЛИЗАЦИЯ (DONE, dormant при дефолте 0.5 = ×1):** тот же паттерн `ScaleDesire(GetDesire(), dial)`,
что rune/retreat. 4 новых поля в `DEFAULT_DIALS` (aibattle_style ~11) + в канон-конфигах (явно 0.50):
- `push_desire`   → `mode_push_tower_{mid,top,bot}_generic.lua` (обёртка вокруг `Push.GetPushDesire`).
- `defend_desire` → `mode_defend_tower_{mid,top,bot}_generic.lua` (эмердженси-защита базы = ABSOLUTE
  проходит сквозь ScaleDesire нетронутой — низкий диал НЕ бросает базу).
- `gank_desire`   → `mode_roam_generic.lua` (индив-роам) + `mode_team_roam_generic.lua` (после CapForLanePush).
- `ward_desire`   → `mode_ward_generic.lua` (numeric-ветка; early `return false` для pos<=3 не трогаем).
- `rune_control`  → УЖЕ был в `mode_rune_generic.lua` (теперь должен выразиться в 5v5).
Инфра: `M.Diag(bot,key)` промоутнут из mode_laning в lib (общий счётчик на хэндле бота) — laning-диаги
делегируют через тонкую локальную обёртку, доказанные счётчики целы. Новые диаги: `ward-place`
(посадка обзёрвера, mode_ward ~121), `rune-grab` (подбор руны, mode_rune ~407). match_stats.py их парсит
из коробки (generic `key=count`). ScaleDesire безопасен к nil-диалу; лоадер подставляет дефолты.

**2.2 ВАЛИДАЦИЯ (план, ~5 игр вместо 10 — пруф+продукт за один заход):**
Паттерн ScaleDesire доказан 6× → риск что обёртка сломается мал; режем человеко-время на игры и сразу
щупаем Фазу 3. Метрика командная (К/D, hero/towerDmg, диаги `ward-place`/`rune-grab`). Стороны свапать.
1. **Изолированный A/B ×2** — для диалов, умеющих ТИХО не работать (нужен чистый контраст):
   - `rune_control`: команда A 0.90 vs B 0.10 → `rune-grab` R# vs D#. (Был структурно задавлен в 1v1.)
   - `defend_desire`: A 0.90 vs B 0.10 → отзыв на пуш вышек / время жизни вышек. (Реактивный → легко даёт
     нулевой сигнал не по причине диала.)
2. **Композит «Агрессор vs Черепаха» ×3 прогона** (закрывает push/gank/ward + 1-й замер Фазы 3):
   - Агрессор: push/gank 0.90, defend/ward 0.10. Черепаха: наоборот. Зеркальная комп, один матчап ×3.
   - Читаем: towerDmg/`ward-place`/К участие подтверждают, что диалы КОЛЛЕКТИВНО дают видимо разные
     команды; разброс исхода по 3 прогонам = вход в Фазу 3.
(Альтернатива — классическая матрица 10 игр по диалу — консервативнее, но возвращает в полировку 5v5.)

**2.3 CLOSEOUT-ФИКС (lead-aware finish-push) — НОВЫЙ КОД, валидирован 1 игрой.**
Проблема (найдена на 1-м композите): при огромном перевесе команды НЕ закрывают (towerDmg 549 за 39
мин, игра не кончалась). Причина: gank/push конкурируют за арбитраж, **gank выигрывает** → «Агрессор»
становится «ганкером» (31 килл), а push-режим почти не активен. push_desire масштабирует желание, но
сырое push-desire структурно низкое → даже ×1.8 проигрывает fight/farm (тот же класс, что rune_control
в 1v1). Решение: `M.IsFinishState(bot)` + `M.FinishPush(bot, d, raw)` в aibattle_style — когда мертвы
≥`FINISH_DEAD`(=2) вражеских героев, форсим push-desire к 0.90-0.99 (ранг по raw-lane → боты сходятся
на ОДНУ линию, group-push), перебивая арбитраж. **Диал-независимо** (добивать выигранную игру = база,
не стиль; push_desire формирует мид-гейм при живых врагах). Edge-triggered диаг `finish-push`. Врезан в
3 `mode_push_tower_*`. (API: `GetTeamPlayers`+`IsHeroAlive` — глобальные, надёжны.)

**2.4 РЕЗУЛЬТАТЫ (пруфы):**
- **8838026385** (комп вырубился ~39 мин, БЕЗ финального дампа, ДО closeout-фикса; снапшот): лейн-диалы
  идентичны (0.5/0.5/0.70) → разница = чисто командные диалы. Радиант=Агрессор vs Дайр=Черепаха:
  киллы **31:13**, `ward-place` **1:16**, towerDmg **549:0**. → gank_desire ✅ сильно, ward_desire ✅
  чисто (не side-bias), push_desire 🟡 направление есть но абсолют ничтожный (→ выявил closeout-баг).
- **8838137361** (ПОЛНЫЙ дамп, `k_EMatchOutcome_RadVictory`, **27 мин**, ПОСЛЕ closeout-фикса): тот же
  композит Радиант=Агрессор. towerDmg **3621:95** (было 549 → ×6.6), `finish-push` **R#9 D#3** (override
  сработал), `ward-place` **5:11** (Черепаха больше), киллы **18:11**. Агрессор ВЫИГРАЛ за 27 мин.
  → **closeout-фикс работает** (549→3621 towerDmg, игра закрылась); Фаза-2-механика подтверждена реальным
  дампом; cfg-анонс теперь печатает gank/push/defend/ward.
- **8838192223** (СВАП, прервался ~30 мин, без финального дампа): Радиант=Черепаха / Дайр=Агрессор.
  `ward-place` **R#30 D#6** — полностью инвертировалось vs игры 1 (5:11) → **ward_desire ✅ чисто при свапе**.
  `finish-push` **R#6 D#2** — Черепаха (Radiant) имела больше finish-окон чем Агрессор (Dire): Дайр-боты
  структурно суицидальнее (§4 side-bias), Агрессор-конфиг (gank 0.90, retreat 0.50) усиливает ныряние →
  Агрессор умирает сам, Черепаха получает override. Результат: качель, явного доминирования нет, игра
  затянулась. → Поведение идёт за конфигом, не за стороной. Side-bias реален но не отменяет диал-эффект.
  ЗАМЕТКА: finish-push порог `FINISH_DEAD=2` работает на Радианте, туговат на Дайре (Дайр умирает сам до
  набора 2 вражеских смертей). Тюнинг (снизить до 1 или добавить gold-advantage триггер) — не блокер
  для Фазы 3.
- **ИТОГ Фазы 2:** механика доказана достаточно. gank ✅, ward ✅ (инвертируется при свапе), push ✅
  (closeout-фикс), defend/rune — deferred на A/B в рамках Фазы 3. Затупы на линии (ждут просадки хп
  крипа) — laning-косметика, низкий приоритет, после.

**=== ФАЗА 3 — BETTABILITY (свойство продукта) ===**
Цель: различимые агенты с НЕдетерминированным исходом — ради чего весь проект.
1. Один матчап × N прогонов → разброс исхода. Ставки нужны там, где исход неопределён, не предрешён 8/8.
2. Разные конфиги → различимость + у кого эдж (это «линия»).
3. Вывод: можно ли на матч AIBattle построить честную линию.

**3.1 ПРОДУКТОВОЕ ВИДЕНИЕ (уточнено 04.06):**
Личность агента = промпт пользователя → LLM → JSON → конфиг. Два варианта продукта:
- Один промпт → разные LLM-модели интерпретируют по-своему → разные конфиги → ставка «какая модель умнее»
- Пользователь пишет свой промпт → LLM интерпретирует → конфиг → бот → ставка на свою стратегию
Вариативность интерпретации между моделями = источник недетерминизма для ставок.

**3.2 LLM-ПАЙПЛАЙН (протестирован 04.06):**
Системный промпт: `docs/llm_system_prompt.md` (v1, 12 диалов + rules + few-shot пример + scale calibration).
Модель: ChatGPT 5.5 Thinking. Конфиги сохранены в `bots/Customize/playstyle_ChatGPT55Think_*.lua`.

Стратегия «Пушер» → `playstyle_ChatGPT55Think_Pusher.lua`:
  push=0.90, ward=0.90, roshan=0.85, gank=0.25, retreat=0.70 — модель корректно прочла «don't chase kills»,
  «ward every spot», «secure Roshan», «fall back when outnumbered».

Стратегия «Ганкер» → `playstyle_ChatGPT55Think_Ganker.lua`:
  gank=0.90, harass=0.85, fwd=0.85, farm=0.20, push=0.20, retreat=0.25 — корректно прочла «roam constantly»,
  «don't waste time farming or sieging», «keep them scared».

Контраст между конфигами по ключевым диалам: push 0.90 vs 0.20, gank 0.25 vs 0.90, ward 0.90 vs 0.45,
roshan 0.85 vs 0.35. Значения НЕ экстремальные (не 0.10/0.90 везде) — реальная LLM-интерпретация более
взвешенная. Вопрос к проверке в игре: виден ли сигнал при таком разбросе (0.20–0.90) в статистике?

**3.3 ТЕСТ ПАЙПЛАЙНА (ручные прогоны, Phase 3 персонажи):**
finish-push тюнинг: FINISH_DEAD снижен 2→1, добавлен гейт по времени >600s (10 мин).
roshan диаг: кулдаун 30с (теперь считает окна, не тики).

Игра 1 (8838334930, Берсерк vs Осадник — РУЧНЫЕ конфиги): Осадник (Dire) победил, 63 мин. Берсерк слабый
  (retreat=0.15 → 45 смертей, 17 килов). roshan диаг = 219 тиков (баг — теперь пофикшен).
Игра 2 (8838437446, СВАП + Берсерк retreat 0.15→0.30): Осадник (Radiant) победил, **44 мин** (−19 мин).
  finish-push фикс сработал. Берсерк живучее (35 смертей), но Осадник всё равно доминирует 2:0.
  → Осадник имеет стабильный эдж над Берсерком на этом пуле героев. Для bettability: «коэффициент
  на Осадника 1.4, на Берсерка 2.1» — это и есть честная линия (3 вариант по §11).

СЛЕДУЮЩИЙ ШАГ: протестировать ChatGPT55Think_Pusher vs ChatGPT55Think_Ganker — проверить виден ли
сигнал при реальных LLM-значениях (не экстремальных), и измерить разброс исхода по N прогонам.

ПОРЯДОК ЖЁСТКИЙ: Фаза 0 → 1 → 2 → 3. Фаза 2 строится только если Фаза 1 показала смысл. После каждой
фазы — обновить HANDOFF статусом с пруфами, в main мёржить осознанно.

## 12. Текущая позиция
**Фаза 2: DONE** (ветка `phase-2-team-dials`, закоммичена, §11 2.4). gank/ward/push доказаны,
closeout-фикс работает (27 мин, towerDmg ×6.6), свап подтверждён (ward инвертируется). defend/rune —
deferred. **СЛЕДУЮЩЕЕ — Фаза 3:** bettability (различимые агенты + недетерминированный исход, §11 Фаза 3).
LIVE сейчас = свап-конфиг (Radiant=Черепаха/Dire=Агрессор) — перед Фазой 3 вернуть канон.
Дремлющие на ветке (флаги OFF, валидацию не проходят, как execute_threshold):
improvements (defensive_heal, anti_afk, tower_avoid, ability_on_dials) + adaptive item_rules.
ОТЛОЖЕНО окончательно из 1v1: переделка tower_avoid, добивание вышки=победа, creep_aggro,
глубокая починка база-laning — низкий леверидж, не трогаем (см. принципы §11).

## 13. Воспроизведение 1v1 / подводные камни
Лобби 1v1 Solo Mid, читы ON, хост зрителем (Unassigned), залить Local Dev Script ботов, кикнуть лишних
(`kick 1..4`, `kick 6..9`), launch options `-condebug -console`, читать `console.<matchid>.log`.
Имена pos1: ChatGPT (Rad) / Gemini (Dire). «Заполнить ботами» в 1v1 = 5v5 → кикать лишних.
Непоказ имени бота = клиентский рендер-квирк, не баг. «error in error handling» ×20 = фоновый шум OHA.
`print()` в console.log НЕ виден — диагностика только через `bot:ActionImmediate_Chat`.
