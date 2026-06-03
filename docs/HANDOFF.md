# HANDOFF — AIBattle × Dota 2 (единый живой документ)

> Единственная точка входа и единственный поддерживаемый док проекта. Обновлять ЕГО, новых
> статус/план-доков не плодить. Он же — то, что отдаём другому Claude (мак/новое окно).
> Последнее обновление: 2026-06-03. Машина: Windows/Shadow PC (тут LIVE Dota). По-русски.
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
Турбо, зеркальная комп PA/Zeus/Axe/Lion/Warlock. Radiant=агро (harass 0.95/fwd 0.90/retreat 0.20) /
Dire=пассив (harass 0.05/fwd 0.10/retreat 0.80). item_build убран → дефолтные сборки OHA.

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
- `Customize.Force_Group_Push_Level=1` (mild) → боты не группируются для финального пуша.
  Быстрый тест: поднять до 3 (OHA-настройка, без нового кода) → увидеть, закроют ли при преимуществе.

ЗЕЛЁНЫЙ СВЕТ НА ФАЗУ 2: командная разница с цифрами есть. Смысл строить командные диалы — подтверждён.

**=== ФАЗА 2 — КОМАНДНЫЕ ДИАЛЫ (это v3) ===**
Цель: оживить то, что в 1v1 не выражалось.
1. Добавить тем же паттерном `ScaleDesire(GetDesire(), dial)` (как rune/retreat): `gank_desire`
   (mode_roam/team_roam), `push_desire` (mode_push_tower_*), `defend_desire` (mode_defend_tower_*),
   `ward_desire` (mode_ward), + `rune_control` (теперь выражается в 5v5). Добавить поля в схему dials
   + дефолты 0.5 в aibattle_style.
2. Валидировать КАЖДЫЙ командным A/B: зеркальные композиции, у одной команды варьируем ОДИН диал,
   метрика командная (участие в ганках / урон по вышкам / контроль рун / варды).

**=== ФАЗА 3 — BETTABILITY (свойство продукта) ===**
Цель: различимые агенты с НЕдетерминированным исходом — ради чего весь проект.
1. Один матчап × N прогонов → разброс исхода. Ставки нужны там, где исход неопределён, не предрешён 8/8.
2. Разные конфиги → различимость + у кого эдж (это «линия»).
3. Вывод: можно ли на матч AIBattle построить честную линию.

ПОРЯДОК ЖЁСТКИЙ: Фаза 0 → 1 → 2 → 3. Фаза 2 строится только если Фаза 1 показала смысл. После каждой
фазы — обновить HANDOFF статусом с пруфами, в main мёржить осознанно.

## 12. Текущая позиция
Фаза 0 в работе. Дремлющие на ветке (флаги OFF, валидацию не проходят, как execute_threshold):
improvements (defensive_heal, anti_afk, tower_avoid, ability_on_dials) + adaptive item_rules.
ОТЛОЖЕНО окончательно из 1v1: переделка tower_avoid, добивание вышки=победа, creep_aggro,
глубокая починка база-laning — низкий леверидж, не трогаем (см. принципы §11).

## 13. Воспроизведение 1v1 / подводные камни
Лобби 1v1 Solo Mid, читы ON, хост зрителем (Unassigned), залить Local Dev Script ботов, кикнуть лишних
(`kick 1..4`, `kick 6..9`), launch options `-condebug -console`, читать `console.<matchid>.log`.
Имена pos1: ChatGPT (Rad) / Gemini (Dire). «Заполнить ботами» в 1v1 = 5v5 → кикать лишних.
Непоказ имени бота = клиентский рендер-квирк, не баг. «error in error handling» ×20 = фоновый шум OHA.
`print()` в console.log НЕ виден — диагностика только через `bot:ActionImmediate_Chat`.
