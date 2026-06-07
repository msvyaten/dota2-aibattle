# HANDOFF — AIBattle × Dota 2 (единый живой документ)

> Единственная точка входа и единственный поддерживаемый док проекта. Обновлять ЕГО, новых
> статус/план-доков не плодить. Он же — то, что отдаём другому Claude (мак/новое окно).
> Последнее обновление: 2026-06-06 (system prompt v2, anti-AFK фикс, swap run 2, AFK-наблюдения в матче — см. §15; второй матч с фиксами — §16: AFK короче но есть, осцилляция, Aegis policy).
> Машина: Windows/Shadow PC (тут LIVE Dota). По-русски.
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

**3.4 LLM-КОНФИГИ В ИГРЕ — ГЛАВНЫЙ ПРУФ ДНЯ (8838539380):**
ChatGPT_Pusher (Radiant) vs ChatGPT_Ganker (Dire) — конфиги выданы LLM из промптов (НЕ ручные экстремальные).
Pusher ВЫИГРАЛ (RadVictory, 34 мин). towerDmg **7926 vs 159** (push 0.90 vs 0.20) — контраст ×50.
→ **ЦЕПОЧКА промпт→LLM→JSON→конфиг→измеримое поведение РАБОТАЕТ на реальных LLM-значениях.** Это proof
of concept продукта. Киллы Pusher 27:10 (Ганкер при gank 0.90 слил 10:28 — пакет gank0.90+push0.20+
retreat0.25+fwd0.85 = ныряет, не закрывает; агро-архетип проигрывает 3:0 объектному = есть стабильный
фаворит = есть линия). ward 16:14 (слабо, узкий гэп 0.90/0.45), roshan диаг не сработал (raw res < 0.6).

**3.5 ЧУВСТВИТЕЛЬНОСТЬ — ЗАКРЫТО (Game A, 05.06):**
Тест push_desire 0.66 vs 0.34 (≈inter-LLM гэп), 2 прогона со свапом:
- Прогон 1 (8839383353): R=0.66 проиграл, D=0.34 выиграл. towerDmg R=6370 D=11187.
- Прогон 2 (8839484494, свап): R=0.34 выиграл, D=0.66 проиграл. towerDmg R=7477 D=119.
**Вывод:** towerDmg при гэпе 0.32 — негодная метрика: полностью доминирует win/loss исход (победитель всегда
больше ломает вышек). Сигнал push_desire утонул в шуме. Побочная находка: no-dive растёт с push_desire
(push=0.34 Dire → D#35; push=0.66 Dire → D#68) — направление консистентно, но метрика для ставок не годится.
ИТОГ: для ставок нужна другая метрика ИЛИ нелинейный ScaleDesire (усиливать мелкие различия промптов).
Следующий шаг — N прогонов ChatGPT_Pusher vs ChatGPT_Ganker (LLM-конфиги, §3.4), смотрим разброс исходов.

ПОРЯДОК ЖЁСТКИЙ: Фаза 0 → 1 → 2 → 3. Фаза 2 строится только если Фаза 1 показала смысл. После каждой
фазы — обновить HANDOFF статусом с пруфами, в main мёржить осознанно.

## 12. Текущая позиция (05.06.2026)
**Фаза 3 В РАБОТЕ** (ветка `phase-2-team-dials`). Фаза 2 DONE. Схема: **12 диалов + 3 rules** (buyback
упрощён до 2 значений). LLM-пайплайн доказан (§11 3.4). closeout-фикс затюнен.

**Сессия 05.06 — итоги:**

**Game A (sensitivity push 0.66/0.34) — ЗАКРЫТА:**
- 8839383353: R=0.66 проиграл (towerDmg 6370), D=0.34 выиграл (11187). Dire victory.
- 8839484494 (свап): R=0.34 выиграл (7477), D=0.66 проиграл (119). Rad victory.
- Вывод: towerDmg при узком гэпе = метрика победы, не push_desire. Сигнал ниже шума.

**Game B (rules contrast) — ЗАКРЫТА:**
- 8839679788 (без финального дампа, ПК вырубился ~34 мин): R=aggressive. Radiant вёл 28:14 +27k. no-dive: R#0 (always) D#22 (never). Визуально: D (smoke=never) не вышел под смоком.
- 8839817227 (свап): D=aggressive. Dire выиграл 28K/15D. no-dive R#25 (never) D#0 (always). smoke R#0 (never) D#1 (for_ganks). buyback=0 обе стороны.
- **dive_policy ✅** — always→0, never→22-25, свап подтверждён.
- **smoke_usage ✅** — never→0 (обе стороны), for_ganks→>0; визуальный пруф.
- **buyback=always удалён** — не срабатывал в 2 прогонах (выигрывающая сторона не умирает нужным образом). Осталось: `never` / `default`.

**Код сессии 05.06:** `buyback=always` удалён из `aibattle_style.lua` + `ability_item_usage_generic.lua`.

**⚠️ ПЕРЕД КОММИТОМ:** восстановить канон `playstyle_radiant/dire` (сейчас = Game B тест-конфиги). Канон = ChatGPT_Pusher (Rad) / ChatGPT_Ganker (Dire) — они же следующий тест.

**⏭️ СЛЕДУЮЩЕЕ ДЕЙСТВИЕ — Фаза 3 bettability:** N прогонов ChatGPT_Pusher vs ChatGPT_Ganker → разброс исходов. Уже есть 1 игра (8838539380, Pusher победил). Нужно ещё 2-3 прогона для распределения. Восстановить LLM-конфиги в LIVE из `bots/Customize/playstyle_ChatGPT55Think_*.lua`.

Дремлющие (флаги OFF): improvements (defensive_heal, anti_afk, tower_avoid, ability_on_dials) + adaptive item_rules. Не трогаем (§11 принципы).

## 13. Воспроизведение 1v1 / подводные камни
Лобби 1v1 Solo Mid, читы ON, хост зрителем (Unassigned), залить Local Dev Script ботов, кикнуть лишних
(`kick 1..4`, `kick 6..9`), launch options `-condebug -console`, читать `console.<matchid>.log`.
Имена pos1: ChatGPT (Rad) / Gemini (Dire). «Заполнить ботами» в 1v1 = 5v5 → кикать лишних.
Непоказ имени бота = клиентский рендер-квирк, не баг. «error in error handling» ×20 = фоновый шум OHA.
`print()` в console.log НЕ виден — диагностика только через `bot:ActionImmediate_Chat`.

---

## 14. RULES-СИСТЕМА + находки сессии 04.06

**ТЕРМИНОЛОГИЯ:** в общении с юзером — «счётчик», НЕ «диаг»/«diag» (в коде имена счётчиков прежние).

### 14.1 Диал vs Rule
- **Диал** = насколько сильно (плавная шкала 0–1, 0.5=нейтраль). Реализация: `ScaleDesire(GetDesire(), dial)` поверх режима OHA.
- **Rule** = какой режим / при каком условии (дискретный выбор). Критерий: плавный градиент → диал; взаимоисключающие режимы/«при условии X» → rule.
- Диапазон диалов: **0.0–1.0** включительно (0=выкл, 1=макс ×2 с потолком 0.99). Не «0.01–0.99».
- ТЕСТ-ПРОЦЕСС: брать НЕкруглые значения (0.34/0.66/0.78), ближе к реальному выводу LLM.

### 14.2 Реализованные rules (4) — все ГЕЙТЯТ существующее поведение OHA
| Rule | Значения (дефолт жирным) | Счётчик | Хук | Статус |
|---|---|---|---|---|
| respawn_behavior | walk_back / tp_to_lane / **tp_to_tower(канон)** | teleports_used | mode_laning AIB_HandleRespawn | ✅ |
| dive_policy | never / **finish_only** / when_grouped / when_ahead / always | `no-dive` | mode_laning гард (M.MayDive), ТОЛЬКО laning | ✅ 05.06 |
| smoke_usage | **for_ganks** / never | `smoke` (rate-limit 30с) | обёртка ConsiderItemDesire smoke в ability_item_usage | ✅ 05.06 |
| buyback_policy | never / **default** | — | гейт в BuybackUsageComplement (ability_item_usage) | `never` блокирует ✅; `always` удалён |

cfg-анонс печатает их: `...dive=finish_only smoke=for_ganks bb=default...`. Хелперы в aibattle_style:
`M.MayDive(bot)`, `M.Diag(bot,key)`, `M.DiagRL(bot,key,sec)` (rate-limited счётчик).

### 14.3 ГЛАВНАЯ НАХОДКА: боёвку OHA НЕ трогаем
Прощупали 3 боевые ветки по коду — **все уже реализованы в OHA**, улучшение = глубокий тюнинг базы (низкий
леверидж, бездонный колодец, против принципов §11):
- `focus_target` — уже умный взвешенный скоринг цели (mode_attack override ~283). Подкрутка тонкая/малоизмеримая.
- `teamfight_role` — позиционирование размазано по attack/retreat/roam. Дорого и рискованно.
- **ability usage** — у КАЖДОГО героя подробные Consider-функции (hero_axe 589 строк: ConsiderQ/W/R). Скиллы
  НЕ «не написаны» — написаны. «Слабый скиллинг» = тюнить чужое = НЕ наш леверидж. **НЕ берём.**

### 14.4 Что ещё можно дописать на OHA (rule = гейт) vs нельзя
Проверено по коду: smoke ✅, buyback ✅, TP-защита ✅, Рошан ✅ (mode_roshan) — ЕСТЬ в OHA → rule гейтит (легко).
**Сплит-пуш — НЕТ совсем** → писать с нуля, дорого, пропускаем.
Кандидаты-rules на будущее (есть поведение + свой счётчик): tp_defense, rosh_timing (но пересекается с
roshan_desire диалом). Цель ~15–20 rules. Принцип: добавлять варианты ЛЕНИВО (когда промпт требует), каждый = тест.
Диалы-кандидаты из реклассификации: chase_desire (возможно дублирует forwardness+retreat — проверить),
consumable_save, ability_save (=mana_conserve; сложно, hero-specific — отложено с ability usage).

**📌 ПЛАН: tower_avoid — два конкретных фикса (06.06, одобрено)**
Текущее состояние: tower_avoid ❌ (§6) — гард только в laning, нет проверки радиуса, retreat триггерится
на крипа а не на башню. Радиус башни = **700** (атака), ~900 (aggro). Боты заходят под башню и умирают.
- **Фикс 1 — dive_policy в roam-режиме:** добавить `M.MayDive(bot)` гейт в `mode_roam_generic.lua`
  перед преследованием цели. Уже работает в laning — перенести ту же логику. ~3–5 строк.
  Закрывает: бот преследует героя под башню во время ганка.
- **Фикс 3 — distance check перед advance в laning:** перед выдачей команды "двигаться вперёд к врагу"
  в `mode_laning_generic.lua` проверить: `GetNearestTower(enemyTeam) < 800` И нет дружественных крипов
  в 400 единицах → не двигаться вперёд. ~5–7 строк.
  Закрывает: бот стоит/заходит в зону башни в лейнинге без танкующих крипов (матч 06.06, ~19 мин, Radiant).
Реализовывать после завершения текущих матчей — не блокер для анализа.

### 14.5 Game B — ЗАКРЫТА (05.06, пруфы в §12)
`bots/Customize/playstyle_GameB_rules_aggressive.lua` (dive=always / smoke=for_ganks / buyback=default) vs
`..._passive.lua` (dive=never / smoke=never / buyback=never). push=0.50, диалы нейтральны → только правила.
Результат: dive_policy ✅, smoke_usage ✅, buyback=always удалён.
БАТЧ-ПРИНЦИП: несколько правил в одну игру МОЖНО, если у каждого СВОЙ независимый счётчик.

### 14.6 Продукт / долгое будущее (для документации)
- **Карточка агента:** 12 диалов + rules + item_build + драфт из curated-пула + имя + реплики в чат.
- **Драфт от LLM** возможен (general.lua Radiant_Heros/Dire_Heros — разные стороны), но из curated-пула
  (OHA формально играет всех 127, но качество разное; микро/комбо-герои — плохо). Curated определить тестами.
- **Конфиг по ролям** возможен (GetPosition уже есть; варды УЖЕ только пос4-5 нативно). Разделять общие→
  командные/ролевые — НЕ сейчас, а когда правил наберётся достаточно.
- **Потолок OHA (нужен свой бот):** командные комбо/координация, адаптация по ходу, контр-сборка, мульти-юнит.
- **Captains Mode** — проверить, как LLM играют драфт (баны/пики). Долгое будущее.
- **LLM-driven talent selection** — сейчас таланты захардкожены на героя в BotLib-файлах (`tTalentTreeList`
  с `{left_weight, right_weight}` на уровни t10/t15/t20/t25; `GetTalentBuild` в `aba_skill.lua` переводит
  в фиксированный порядок — конфиг не влияет). План: добавить опциональное поле `talent_preferences` в
  playstyle-конфиг (напр. `{ t10="right", t15="left", t20="right", t25="right" }`) и научить `GetTalentBuild`
  читать его если задано, иначе падать на дефолт из `tTalentTreeList`. LLM сможет явно выбирать сторону
  дерева — агрессивный конфиг берёт урон, защитный — выживаемость. Реализация: ~5 строк патч в
  `aba_skill.lua` + новый ключ в лоадере `aibattle_style.lua`. Ценность небольшая (таланты влияют поздно
  и редко), поэтому — долгое будущее, только когда промпт это потребует.

---

## 15. Сессия 06.06 — наблюдения и статус

### 15.1 Что сделано в коде (LIVE, не закоммичено)
- **System prompt v2** (`docs/llm_system_prompt.md`): добавлен явный win-goal («ты играешь в Dota 2, цель — ПОБЕДИТЬ»), COHERENCE RULES (4 проверки перед выводом), calibration с реальными числами, REASONING EXAMPLE со стрелочной нотацией. Удалён `buyback=always`.
- **Переименование ботов** (`Customize/general.lua`): `ChatGPT_1..5` (Radiant) / `Gemini_1..5` (Dire) — нейтральные номера вместо позиций (позиции OHA не совпадают со слотами).
- **Anti-AFK фикс** (`mode_roam_generic.lua`): (1) gank-done-retreat — при истечении gankTimeAfterArrival бот идёт к своему лейну; (2) `AIBAntiAFK()` — если бот не двигался >8 сек (порог 50 единиц), идёт к назначенному лейну. **Оценка после матча: НЕ ДОСТАТОЧНО** — проблема системнее.

### 15.2 LLM-конфиги run 2 (swap: Gemini=Radiant, ChatGPT=Dire)
Оба конфига «Ганкер», системный промпт v2, одинаковый пользовательский промпт:
- **Radiant = Gemini Gankers**: gank=0.95, push=0.40, fwd=0.85, retreat=0.40, farm=0.20, ability_aggro=0.75
- **Dire = ChatGPT Gankers**: gank=0.92, push=0.45, fwd=0.82, retreat=0.40, farm=0.20, ability_aggro=0.65
- dive=always, smoke=for_ganks, buyback=default (оба)

### 15.3 Match ID (TBD) — AFK-наблюдения в реальном времени
**Match ID: ?** — матч шёл 60+ мин, компьютер автовыключился, финальный дамп может отсутствовать.
Нужно: получить ID из истории Dota, открыть `console.<matchid>.log`, разобрать каждый эпизод.

**Хронология AFK-эпизодов (наблюдения зрителя):**
| Время | Бот | Длительность | Контекст |
|---|---|---|---|
| 19:20–19:53 | Lion Dire (Gemini) | ~33 сек | — |
| 22:14–22:24 | Warlock Dire (Gemini) | ~10 сек | — |
| 24:07–24:41 | Warlock Radiant (ChatGPT) | ~34 сек | — |
| 25:38–28:00 | **Zeus Radiant (ChatGPT)** | **~2 мин 22 сек ⚠️** | — |
| ~30:xx–?? | **Zeus Radiant (ChatGPT)** | ? | второй эпизод, позиция уточнить по логу |
| 28:54–29:13 | Lion Radiant (ChatGPT) | ~19 сек | под атакой Centaur — нет реакции ⚠️ |
| 29:44–30:21 | Lion Dire + Zeus Dire | ~37 сек | под атакой крипов — нет реакции ⚠️ |
| ~33:50–34:03+ | Axe + PA Dire | ? | **застряли в нейтральном кемпе** ⚠️ |
| ~38:00–39:00 | Axe Radiant | ~1 мин | поднял руну иллюзий, иллюзии двигались, сам стоял |
| ~38:10+–38:40+ | Axe Radiant | ~30 сек | второй эпизод через 10–15 сек после первого |
| ~50:00 | PA Radiant | ~30 сек | подобрала руну Double Damage |
| 46:54–47:14+ | **Все 5 Dire (Gemini)** | **~20 сек+ ⚠️** | массовый AFK одновременно, 2 раздуплились, 3 стояли |
| 48:52 | Warlock + PA Dire | — | прошли мимо Axe Radiant, не атаковали (ночь?) |
| 59:17–59:30 | 3 бота Radiant | ~13 сек | сразу после убийства Axe ⚠️ |
| + множество | оба конфига | — | пользователь: «застреваний было больше, не все записал» |

**Общая картина матча:**
- Матч: 60+ мин, ничья де-факто (никто не закрыл), счёт ~28-26 на 59 мин, Radiant +14k нетворс
- 44 мин: все 10 ботов в разных точках карты, никакого групп-пуша
- 41 мин: Radiant 9k преимущества, фармят джунгли по отдельности; 41:30 Dire 2 килла → 4k
- 50 мин: Рошан так и не взяли (roshan_desire=0.40-0.45 проигрывает gank_desire в арбитраже)
- Боты фармят нейтральных крипов вместо лейна (farm_focus=0.20 + поздняя стадия)
- На 59:33 ночь (подтверждено скрином) — важно для эпизода 48:52

### 15.4 Выводы по AFK — приоритеты для фикса

**Корень проблемы: `gankGapTime=3 мин` в `mode_roam_generic.lua` (OHA хардкод)**
Anti-AFK фикс (8 сек порог) НЕ решает проблему — бот выдаёт `Action_MoveToLocation` на ту же/недостижимую
точку, двигается 0 единиц, порог `moved > 50` не проходит → продолжает стоять.

**Паттерны AFK (4 типа):**
1. **gankGapTime cooldown** — 3 мин без fallback-действия. Бот видит врагов, игнорирует.
2. **Недостижимая/уже достигнутая точка** — anti-AFK шлёт на точку куда бот уже пришёл или не может дойти.
3. **Нейтральный кемп** — бот заходит в кемп и не может выйти (pathfinding / цель внутри кемпа).
4. **После убийства** — гангкилл → gankGapTime cooldown → мгновенный AFK победителей ⚠️ парадокс.

**Дополнительный баг: нет реакции на получение урона** (Lion под Centaur, Dire под крипами) — retreat/combat
не триггерится когда бот в gankGapTime кулдауне. Режим roam блокирует реакцию на входящий урон.

**Ночное зрение**: дальность 800 единиц (днём 1800). Эпизод 48:52 — вероятно Warlock/PA не видели Axe.
Проверить по логу: `DotaTime() % 600` > 300 = ночь.

**Ганкер vs Ганкер = структурная проблема**: оба конфига убивают, никто не пушит → игра не закрывается
→ матч 60+ мин → для ставок нужен хотя бы один объектный конфиг в паре.

**Правильный фикс gankGapTime (три уровня):**
1. Уменьшить кулдаун: 3 мин → 30–45 сек
2. Явный fallback в laning на время кулдауна
3. Bypass кулдауна если враг виден в радиусе X (не «не ищи цель», а «не игнорируй пришедшую»)

**✅ РЕАЛИЗОВАНО (06.06, LIVE `mode_roam_generic.lua`):**
```lua
-- 1. gankGapTime с jitter по PlayerID (десинхронизация)
local gankGapTime = 25 + (GetBot():GetPlayerID() % 5) * 3
-- итог: боты получают 25/28/31/34/37 сек (было 3 мин)

-- 2. GetDesire() = 0 во время кулдауна → OHA переключает на laning/push сам
--    Emergency (tango/fountain, res > 0.99) проходят без изменений
if (res == nil or res <= 0.99)
    and lastGankDecisionTime ~= 0
    and DotaTime() - lastGankDecisionTime < gankGapTime then
    return BOT_MODE_DESIRE_NONE
end

-- 3. Think() fallback: идти к лейну если роам-кулдаун активен (страховка)
--    Счётчик: gank-cooldown-lane
if lastGankDecisionTime ~= 0 and DotaTime() - lastGankDecisionTime < gankGapTime then
    -- move to assigned lane, return

-- 4. Stuck detection в ThinkActualGankingInLanes: если >20 сек не приблизился на <1500 ед. — бросить ганк
--    Счётчик: gank-stuck-abort
if DotaTime() - bot.aib_gankStartTime > 20 and distanceToGankLoc > 1500 then
    laneToGank = nil; bot.aib_gankStartTime = nil
```

**Метрики следующего матча:**
- idle пики < 30 сек → основной фикс работает (было 316 сек)
- `gank-cooldown-lane` > 0 → страховка нужна
- `gank-stuck-abort` > 0 → кемп-патфайндинг подтверждён
- `anti-afk` = 0 → старый механизм вытеснен

**Закрытый вопрос — нетворс как триггер:** боты не знают чужой нетворс (туман войны). Альтернативный
finish-trigger: `вражеских вышек упало больше чем своих` + `DotaTime() > 2000` → форсить push.

### 15.5 Что коммитить в конце дня (накопленные изменения)
Все LIVE, в репо не перенесены:
- `mode_roam_generic.lua` — gankGapTime фикс (5 изменений, см. §15.4) + старый anti-AFK
- `docs/llm_system_prompt.md` — v2
- `Customize/general.lua` — имена ChatGPT_1..5 / Gemini_1..5
- `bots/Customize/playstyle_radiant.lua` / `playstyle_dire.lua` — ⚠️ НЕ коммитить канон-конфиги тест-состоянием

**⏭️ СЛЕДУЮЩЕЕ ДЕЙСТВИЕ:**
1. Запустить матч с теми же конфигами (Gemini Ganker Rad / ChatGPT Ganker Dire)
2. `python tools/match_stats.py <id>` — смотреть duration + диаги
3. Проверить idle пики в логе (должны быть < 30 сек)
4. После подтверждения AFK-фикса → Pusher vs Ganker для bettability

---

## 16. Сессия 06.06 — Матч 2 (с AFK-фиксами, наблюдения в реальном времени)

### 16.1 Контекст
**Конфиги:** те же — Gemini Ganker (Radiant) vs ChatGPT Ganker (Dire).  
**Фиксы LIVE:** gankGapTime=25-37 сек (jitter по PlayerID), GetDesire=0 во время кулдауна,
Think() fallback к лейну, stuck detection (20 сек / 1500 ед).  
**Match ID: TBD** — матч ещё не завершён / ID не получен.

### 16.2 AFK-эпизоды (хронология)

| Время | Бот | Длительность | Контекст |
|---|---|---|---|
| 32:33 → 33:03-34:03 | PA Dire | ~1 мин (с паузами) | несколько коротких эпизодов подряд |
| 34:42–35:08 | Axe Radiant | ~26 сек | на фонтане (мог ресниться или хилиться — не подтверждено) |
| 35:28–36:11 | Zeus + Lion Radiant | ~43 сек | вместе, одновременно |
| 36:11–36:36 | Zeus Radiant | ~25 сек | сделал 1 шаг и снова встал |
| 44:44–45:50+ | **Zeus Radiant** | **>1 мин ⚠️** | стоял пока рядом Lion бил Warlock — нет реакции на бой союзника |
| ~44-45 мин | Zeus + Lion + PA Dire | продолжительно | **осцилляция под T2** (см. 16.3) |

**Вывод:** фикс сократил idle с 180-316 сек до 25-43 сек в большинстве случаев.
Но Zeus на 44:44 — >1 мин = новый баг-класс (не gankGapTime, а отсутствие combat-реакции).

### 16.3 Новый баг: осцилляция ("пейсинг под вышкой")
**Что:** Zeus + Lion + PA Dire ходят туда-сюда под T2 ≈ 44-45 мин. Не АФК (двигаются),
но полностью бесполезно. AntiAFK не триггерит (бот движется).

**Механика (action oscillation):**
```
Tick N:   кулдаун кончил → GetDesire > 0 → шаг вперёд (гангнуть)
Tick N+k: stuck detection / unsafe → abort → GetDesire=0 → laning
Tick N+m: GetLaneFrontLocation у T2 в поздней игре → шаг назад к T2
Tick N+p: кулдаун снова кончил → шаг вперёд
...
```
Три бота одновременно = потому что все вместе закончили одно действие (Рошан?).

**Почему хуже простого AFK:** выглядит "активно", но 0 полезных действий.

### 16.4 Роль Рошана: Dire убили, Aegis взял Lion (саппорт)
- Dire убили Рошана (~44-45 мин, с Aegis).
- **Aegis подобрал Lion** — саппорт, не кор. Текущая логика: берёт ближайший к телу.
- Aegis на саппорте = потраченный Рошан (саппорт умирает первым в файте).

**📌 ПЛАН: Aegis Policy (будущая rule)**
```lua
-- Псевдологика: пропускать Aegis если рядом есть более богатый союзник
function ShouldPickUpAegis(bot)
    local myNW = bot:GetNetWorth()
    for _, ally in ipairs(GetTeamMemberList()) do
        if ally:IsAlive() and ally ~= bot
           and ally:GetNetWorth() > myNW * 1.15 then
            return false  -- кор рядом — пусть берёт он
        end
    end
    return true
end
```
Реализация: хук в `ability_item_usage_generic.lua` (ConsiderItemPickup или аналог).
Счётчик: `aegis-skip` (саппорт пропустил) / `aegis-take` (подобрал).
Приоритет: низкий, реализовывать когда Roshan policy будет часто триггерить.

### 16.5 Match 8840957972 — данные (второй матч, с фиксами)
```
duration=4562s (76 мин, комп выключился до конца — winner_team=0)
Radiant: gank=0.95, push=0.40, fwd=0.85 (Gemini Ganker)
Dire:    gank=0.92, push=0.45, fwd=0.82 (ChatGPT Ganker)

Диаги:
  anti-afk  D#1          (старый механизм почти не триггерит)
  roshan    D#21
  rune-grab D#11 R#3
  smoke     D#1  R#1
  ward-place D#42 R#33   (очень активное вардение благодаря GetDesire=0)
  gank-cooldown-lane: 0  (объяснение ниже)
  gank-stuck-abort:   0

Idle (server-side, max/avg/cnt>60s):
  Radiant: slot0=111s, slot1=119s, slot2=202s (PA), slot3=142s (Zeus), slot4=127s (Lion)
  Dire:    slot5=173s, slot6=108s, slot7=104s, slot8=112s, slot9=113s
  → было 316s (матч без фиксов) → теперь 202s MAX (улучшение есть, но недостаточно)
```

**Почему gank-cooldown-lane=0:** Fix 2 (GetDesire=0) работал — roam Think() не вызывался во
время кулдауна → счётчик внутри Think() = 0. Это ожидаемо. Но OHA передавал laning, который
в поздней игре (76 мин, lvl 30) тоже ничего не делает → idle накапливается.

**Почему idle всё ещё 100-200s при gankGapTime=25-37s:**
Две независимые причины:
1. Во время кулдауна: GetDesire=0 → laning берёт → laning в late game иссылает
   `MoveToLocation` на ту же точку = server no-op = idle накапливается через несколько циклов
2. Вне кулдауна в late game: `IsInLaningPhase()=false` → `ThinkActualGankingInLanes` выходит
   без команды → `ThinkGeneralRoaming` тоже → roam Think() заканчивается без Action_* → idle

### 16.6 Корневой анализ: почему Zeus стоял >1 мин при бое рядом
**Ситуация:** Zeus Radiant, 44:44, Lion рядом бьёт Warlock, Zeus стоит >1 мин.

**Причина (вероятно):** GetDesire=0 (gankGapTime кулдаун) → OHA отдаёт laning.
Laning в поздней игре не видит "союзник в бою рядом" как причину двигаться.
Результат: OHA молча выбирает "ничего не делать" в laning.

**Это прямой аргумент против GetDesire=0 как финального решения.**

### 16.7 ✅ РЕАЛИЗОВАНО: "роам сам действует" (LIVE, не закоммичено)
**Реализован после анализа match 8840957972. Два изменения в `mode_roam_generic.lua`:**

**⚠️ КРИТИЧЕСКАЯ НАХОДКА (06.06, матч 3):** `lastGankDecisionTime` ВСЕГДА = 0 — `CheckLaneToGank`
никогда не вызывается (закомментировано на строке 1685 OHA). Весь наш cooldown-блок в Think()
был МЁРТВЫМ КОДОМ в матчах 1 и 2. Zeus AFK 9:37-11:37 = laning mode idle, не roam cooldown.

**Исправления (06.06, матч 3):**
1. Раскомментирован `ActualGankDesire()` в ConsiderGeneralRoamingInConditions — теперь pos3-5
   саппорты реально роамят к перетянутым лейнам в laning phase; `lastGankDecisionTime` наконец
   устанавливается → cooldown-блок в Think() становится активным.
2. GetDesire() возвращает 0.6 во время кулдауна (было 0) → Think() вызывается → P1-P4 активны.

**Изменение A — убрана GetDesire=0 супрессия:**
```lua
-- Было: return BOT_MODE_DESIRE_NONE во время кулдауна
-- Стало: всегда возвращаем ScaleDesire (роам конкурирует за арбитраж даже в кулдауне)
return AIBStyle.ScaleDesire(res, AIBStyle.Get().dials.gank_desire)
```
Трейдофф: ward-place будет меньше (раньше ward выигрывал арбитраж во время GetDesire=0).
Оправдан: активная боёвка > ≥200с idle.

**Изменение B — Think(): 4-уровневый cooldown + late-game fallback:**
```lua
if inGankCooldown then
    -- P1: враг в 1200 ед → атаковать        [cooldown-combat]
    -- P2: союзник бьётся рядом → помочь     [cooldown-assist]
    -- P3: вражеский крип в 700 → фармить    [cooldown-farm]
    -- P4: далеко от лейна (>500) → идти     [gank-cooldown-lane]
    return
end
ThinkIndividualRoaming(); ThinkGeneralRoaming(); ThinkActualGankingInLanes()
-- Поздняя игра: IsInLaningPhase()=false → ThinkActual* выходит без команды
if not IsBotThinkingMeaningfulAction() and enemyVisible then
    bot:Action_AttackUnit(enemy, true)  [roam-combat]
end
AIBAntiAFK()
```

**Метрики следующего матча (цели):**
- `cooldown-combat/assist/farm` > 0 → активное поведение работает
- `roam-combat` > 0 → late-game fallback сработал
- idle max < 40 сек (было 202с → было 316с без фиксов)
- `ward-place` меньше (ожидаемый трейдофф)

### 16.8 Наблюдения матча 3 (live, с исправленным ActualGankDesire)
- 9:37–11:37 Zeus Radiant АФК под своей T2 — laning mode idle в safe-зоне (ActualGankDesire не
  помогает: бот не находит gank-цель → desire=0 → laning берёт → laning тоже ничего не делает)
- 45 мин: Axe + Warlock + Zeus Dire одновременно лагали — late game idle (IsInLaningPhase=false
  → ActualGankDesire возвращает 0 → cooldown-блок не активен → те же проблемы что и раньше)
- Dire не защищали бараки когда их атаковали: defend_desire=0.30 → scaled ≈ 0.78 < roam 0.99
  → roam выигрывает арбитраж → бот идёт ганкать вместо защиты. OHA даёт ABSOLUTE только для
  Ancient, не для бараков → defend_desire снижает и tier3-защиту.

### 16.9 Что делать после матча (план)
1. Получить match ID, запустить `python tools/match_stats.py <id>`
2. Смотреть: cooldown-combat/assist/farm, roam-combat, idle max (цель < 40с)
3. **AIBAntiIdleGlobal (Вариант 3)** — хелпер в `aibattle_style.lua`:
   - Проверяет: союзник в бою рядом (1200) → помочь / враг виден (900) → атаковать
   - Вызывать из конца Think() в `mode_laning_generic.lua` и `mode_roam_generic.lua`
   - Счётчики: `anti-idle-assist`, `anti-idle-combat`
   - Это устраняет idle в ЛЮБОМ режиме без выигрыша арбитража
4. **Force-defend для Tier3** — аналог finish-push:
   - Когда T3 (бараки/трон) под атакой → форсировать defend desire до 0.95 независимо от диала
   - `defend_desire` остаётся "насколько активно защищаем лайн-вышки в мидгейме"
   - Реализация: в `mode_defend_tower_*_generic.lua` или через M.ForceDefend() в AIBStyle
   - Счётчик: `force-defend`
5. Dive_policy в roam (§14.4 фикс 1) — после подтверждения idle-фикса

### 16.10 Что коммитить в конце дня

### 16.11 Что коммитить в конце дня
- `mode_roam_generic.lua` — все накопленные фиксы:
  - gankGapTime=25-37s с jitter (PlayerID-based)
  - stuck detection (20s / 1500 ед)
  - активное cooldown поведение (P1-P4) + late-game roam-combat fallback
- `docs/llm_system_prompt.md` — v2
- `Customize/general.lua` — имена ChatGPT_1..5 / Gemini_1..5
- ⚠️ НЕ коммитить playstyle_radiant/dire тест-конфигами
