# Match Log — AIBattle × Dota 2

Формат матчей: Solo Mid 1v1, SF vs SF, читы ON, хост-зритель.
Данные из `python tools/match_stats.py <id>`. Слот1 = Radiant, слот129 = Dire.
История до 09.06.2026 — `docs/history/HANDOFF-full-2026-06-09.md`.

**Примечание по конфигу:** cfg-анонс (`AIB[R] harass=...`) был слишком длинным (~220 символов)
и молча дропался Dota-чатом (лимит ~160 символов). Исправлено в phase-16 (12.06.2026):
разбито на 2 сообщения. Матчи до fix имеют конфиг вручную из playstyle-файлов.
Начиная со следующего матча `match_stats.py` покажет `cfg:` и `dial:` таблицу автоматически.

---

## Сводная таблица — текущая эпоха кода (с 19.07)

Один матч = одна строка, собрано из `console.<id>.log`. Это те матчи, которые мы гоняем
и разбираем; сравнивать между собой осмысленно только их.
Пороги скоркарда: `bottle<=50%`, `empty/м<=13`, `jitter/м<=8` (`tools/scorecard.py`).
⚠️ **Сравнивать ТОЛЬКО в минуту** — сырые счётчики масштабируются длительностью.
Формат K/D lh/dn. `трипы` = recovery-walk + recovery-tp (походы на фонтан).
Матчи до 19.07 (129 штук, вся история проекта с 31.05) вынесены в
**`docs/history/match_archive.md`** — там другой код и другие метрики, напрямую в сравнение
не брать. Это настоящие матчи, не технический мусор.

| match | дата | мин | build | побед | R K/D lh/dn | D K/D lh/dn | урон R/D | hp<45 R/D | bottle R/D | empty/м R/D | jitter/м R/D | трипы R/D |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 8903952032 | 07/19 | 6.1 | 21d3145 | Rad | 2/0 15/2 | 0/2 14/7 | 4089/2245 | 24/46 | 61/- | 9.2/13.3 | 1.0/1.5 | 0/0 |
| 8903988046 | 07/19 | 16.5 | 140aaa5 | Rad | 2/1 53/6 | 1/2 66/10 | 8297/9721 | 48/43 | 81/88 | 7.7/10.0 | 1.0/0.5 | 0/0 |
| 8905027149 | 07/20 | 6.9 | 411d324 | Rad | 2/0 30/5 | 0/2 10/4 | 4609/2213 | 19/51 | 78/- | 5.1/8.6 | 0.6/1.9 | 0/0 |
| 8905049243 | 07/20 | 4.4 | 9f6b6cc | Dire | 0/2 11/1 | 2/0 11/2 | 2234/2578 | 18/52 | 25/95 | 7.8/9.2 | 0.9/0.7 | 0/0 |
| 8905066151 | 07/20 | 7.1 | cae1950 | Dire | 0/2 33/2 | 2/0 16/0 | 4093/2596 | 2/63 | 81/74 | 5.4/7.6 | 0.8/1.1 | 0/0 |
| 8905283635 | 07/20 | 6.0 | 0ccbb99 | Dire | 0/2 14/3 | 2/0 29/4 | 3620/3349 | 40/36 | -/49 | 7.2/6.2 | 1.5/1.2 | 0/1 |
| 8905381906 | 07/20 | 6.2 | 4e2dee2 | Dire | 0/2 11/1 | 2/0 26/4 | 2723/3503 | 23/27 | -/67 | 6.2/7.2 | 1.5/0.8 | 2/0 |
| 8905429441 | 07/20 | 8.0 | 06361e0 | Rad | 2/0 33/2 | 0/2 29/6 | 4786/3455 | 23/40 | 77/60 | 4.7/6.5 | 0.6/1.1 | 1/1 |
| 8905560371 | 07/20 | 13.0 | f77b66b | Dire | 1/1 46/4 | 1/1 46/2 | 6373/6941 | 38/33 | 69/59 | 5.4/6.1 | 2.8/2.5 | 2/1 |
| 8905657416 | 07/20 | 8.1 | f77b66b | Rad | 2/0 24/2 | 0/2 15/4 | 4791/3169 | 11/48 | 66/50 | 4.2/8.0 | 3.1/2.1 | 1/0 |
| 8905797602 | 07/20 | 7.8 | 37e83af | Rad | 2/0 25/6 | 0/2 28/3 | 4591/2861 | 39/32 | 73/71 | 6.8/7.3 | 1.8/3.1 | 0/1 |
| 8906482413 | 07/21 | 8.5 | 181b1f2 | Rad | 2/1 21/4 | 1/2 29/4 | 5022/5170 | 32/30 | 47/58 | 7.1/5.6 | 2.5/2.4 | 1/2 |
| 8906495087 | 07/21 | 10.3 | 181b1f2 | Rad | 2/0 45/7 | 0/2 18/2 | 6334/3304 | 12/31 | 77/80 | 7.4/5.6 | 2.8/1.1 | 1/4 |
| 8906520389 | 07/21 | 8.2 | 6801051 | Dire | 1/2 14/3 | 2/1 29/3 | 3230/5164 | 28/16 | 50/73 | 4.4/7.2 | 2.3/3.1 | 3/0 |
| 8906537715 | 07/21 | 11.4 | 6801051 | Dire | 1/2 42/4 | 2/1 33/1 | 6371/6115 | 24/29 | 57/58 | 6.4/4.1 | 2.7/1.8 | 2/3 |
| 8906632392 | 07/21 | 12.5 | 487293b | Dire | 1/2 48/13 | 2/1 45/6 | 6549/8573 | 25/22 | 81/68 | 8.4/5.2 | 3.8/2.8 | 2/3 |
| 8906694824 | 07/21 | 6.5 | bbfed91 | Rad | 2/1 20/2 | 1/2 21/6 | 3588/3558 | 9/34 | 78/76 | 4.9/3.4 | 6.9/0.9 | 1/1 |
| 8906755360 | 07/21 | 7.5 | cc00c9b | Rad | 2/0 29/3 | 0/2 24/4 | 5470/3136 | 9/40 | 65/50 | 2.4/4.3 | 4.9/2.5 | 1/1 |
| 8907379308 | 07/21 | 13.7 | c97c618 | Dire | 1/1 49/7 | 1/1 63/11 | 9148/9341 | 25/21 | 60/57 | 3.0/3.3 | 3.9/3.7 | 4/5 |
| 8908421422 | 07/22 | 8.0 | e06e497 | - | - | - | -/- | 20/23 | 63/55 | 3.6/3.7 | 3.5/2.7 | 2/3 |
| 8908439030 | 07/22 | 14.0 | 45db02a | Dire | 0/2 52/10 | 2/0 54/5 | 10164/9925 | 28/33 | 49/46 | 2.2/3.1 | 3.9/2.0 | 4/6 |
| 8908917919 | 07/22 | 8.9 | b6d0642 | Rad | 2/0 38/8 | 0/2 25/3 | 5275/3693 | 15/40 | 62/91 | 2.1/2.9 | 3.9/1.7 | 2/3 |
| 8908963179 | 07/22 | 6.7 | bfa60b8 | Dire | 0/2 16/6 | 2/0 25/1 | 3013/4478 | 38/17 | 88/42 | 3.9/3.6 | 4.3/3.0 | 1/2 |
| 8909533277 | 07/23 | 14.2 | 62040ea | Dire | 1/2 63/8 | 2/1 53/6 | 9384/9763 | 27/18 | 47/54 | 2.5/2.9 | 3.2/3.0 | 4/5 |

⚠️ `8909533277` — **свап сторон**: R=Grok (push/always/always), D=Gemini (last_hit_only/default/default).
Четвёртая жалоба «шёл на фонтан и лечился по дороге»: виноват НЕ салв (гард `e344e49` отработал,
`blocked=heal-item reason=fountain_trip_committed`), а **бутылка** — `low-hp-bottle` фаернул 163 раза,
hp 12→45 за 6с в 4600 юнитах от базы. Гард поставлен в `AIB_BottleIfUseful` (`4dd47d5`).
| 8909602648 | 07/23 | 4.8 | a78683e | Rad | 2/1 12/3 | 1/2 12/2 | 2041/1704 | 21/11 | 43/43 | 3.1/4.8 | 4.6/2.3 | 0/0 |

⚠️ `8909602648` — **пробный матч серии 1, В ЗАЧЁТ НЕ ИДЁТ** (R=Grok/D=Gemini, билд `a78683e`).
Скоркард ACCEPTED, но юзер увидел 4 регресса. Корни: (1) **uphill-гард перебивал явный
`hero_priority="always"`** — 32 отказа и 33 отхода у Radiant против 1 у Dire, т.е. агрессия
той модели, что стоит на Radiant, глушится рельефом; (2) **латч осады не перепроверял волну** —
`wave=1` → `wave=0` за 3с, Dire съел 319 урона от вышки (18% всего) и проиграл на этом.
Починено `bee3dd8`. Ещё два (пустой тик у `creep-work`, стойка впереди ренджевика) — в BACKLOG.

**Конфиги матчей серии Gemini vs Grok** (из cfg-анонса в логе):

- `8908421422` R: cw:last_hit_only pgb:default har0.65/fwd0.55/ret0.55
             D: cw:push pgb:default har0.75/fwd0.65/ret0.45
- `8908439030` R: cw:last_hit_only pgb:default har0.65/fwd0.55/ret0.55
             D: cw:push pgb:default har0.75/fwd0.65/ret0.45
- `8908917919` R: cw:last_hit_only pgb:default har0.65/fwd0.55/ret0.55
             D: cw:push pgb:default har0.75/fwd0.65/ret0.45
- `8908963179` R: cw:last_hit_only pgb:default har0.65/fwd0.55/ret0.55
             D: cw:push pgb:default har0.75/fwd0.65/ret0.45

---

## 2026-06-19 — Codex phase-23, visual-AFK watchdog

**Триггер:** пользовательский критерий AFK = герой стоит на месте, даже если кодово он фармит/денает.

| MatchID | Dur | Победитель | Заметки |
|---|---|---|---|
| 8858472901 | game=534s | ? | неполный матч, shutdown/abandon без финального stat dump; skeleton был активен (`dbg-skeleton R#52 D#53`, `dbg-skip-fwd R#64 D#21`), но stationary остался: R `0-322s`, D `81-393s`; при этом `cs-inrange R#441 D#149`, `deny-act R#77 D#12` |

**Вывод:** forwardness/fallback не единственный root cause. Бот может быть "полезно занят" внутри Dota API и всё равно выглядеть AFK для зрителя. Поэтому добавлен visual-AFK watchdog перед last-hit: после `vafk=6s` почти без смещения бот обязан сделать видимое движение (`anti-afk-*`).

**Что проверять в следующем матче:** cfg должен показать `vafk=6`; в diag должны появиться `anti-afk-back/safe/chase/strafe/wave/lane`; `stationary[...]` не должен показывать длинные интервалы >10-15s.

---

## 2026-06-19 — phase-22, диагностика skeleton-режима (jitter/AFK изоляция)

**Цель:** проверить гипотезу что forwardness/fwd-fallback/fwd-push перехватывают тики и вызывают jitter/AFK.
**⚠️ ВАЖНО: debug_skeleton_laning НЕ задеплоен в LIVE** — матч прошёл с обычным phase-22 кодом (fwd-блок активен).
**Конфиг Radiant:** assassin — harass=0.80 ability=0.80 fwd=0.60 retreat=0.45 exec=0.60 farm=0.35 / healing=active ability=aggressive pregame=aggressive_mid dive=never
**Конфиг Dire:** farmer — harass=0.25 ability=0.25 fwd=0.60 retreat=0.75 exec=0.15 farm=0.90 / healing=default pregame=safe_tower dive=never

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Заметки |
|---|---|---|---|---|---|
| 8857897714 | 6.9м | **Dire** | 0/2 2.2/м DN 3 lvl6 | 2/0 4.1/м DN 5 lvl7 | skeleton НЕ активен (не задеплоен); fwd-fallback D#101 R#198 + fwd-push D#162 R#100 = jitter подтверждён; Dire: low-hp-hold D#327 (~108s); fb-skip D#396 (Dire почти не атаковал героя); Радиант АФК ~6:45 → смерть |

**Наблюдения (визуально из игры):**
- 0:46–0:56: Radiant стоял рядом со своими мили-крипами без движения (до прихода вражеских крипов — AntiIdleGlobal P3/P4 не находят цель)
- Оба бота: jitter туда-сюда пока крипы шли к линии
- 3:05–3:20: Radiant ходил без цели, к крипам не подходил
- 4:53–5:05: оба стояли под вышкой и хилились, никто не пошёл к руне за bottle-heal
- Dire отступал глубоко к своей вышке (low-hp-hold D#327 + packSafeDest — выглядело как "фонтан")
- ~6:45: Radiant встал в АФК → Dire убил с рейзов + ульт

**Ключевые диаги:**
- `pre-aig D#24` — AntiIdleGlobal только 24 раза за 6.9м (fwd-слой перехватывал большинство тиков)
- `fwd-ahead D#581 R#237` — бот уже впереди цели forwardness, fwd-fallback берёт управление
- `fb-skip D#396 R#31` — Dire ultra-passive на execute (396 пропусков!); победил через фарм и АФК врага

**Вывод:** fwd-fallback/fwd-push активны и мешают. АФК до прихода крипов = AntiIdleGlobal P3 ищет вражеские крипы, их ещё нет → idle. **Следующий шаг:** задеплоить skeleton-режим и повторить.

---

## 2026-06-18 — phase-21, survivability (закоммичено, матчи-триггеры)

**Коммит:** `3268631`. Фиксы: aib_deathSurvive gate, aib_lowHpHold→flag, packSafeDest, death-window v2 (GetHeroDeaths), tango/flask пороги.

| MatchID | Заметки |
|---|---|
| 8856793181 | триггер-матч phase-21 |
| 8857025900 | триггер-матч phase-21 |
| 8857092260 | триггер-матч phase-21 |
| 8857127028 | триггер-матч phase-21 |
| 8857712302 | дебаг анонса позиции (R vs D позиция в прегейме); фикс GetGameMode()~=0 |
| 8857785564 | 1.7м / Dire 2/0 / короткий матч; tango-heal D#3 ✅; low-hp-hold D#18 ✅ |

---

## 2026-06-17/18 — phase-19/20, lane stability (закоммичено, матчи-триггеры)

**phase-19** (`e95a2a5`–`2843fbe`): botAhead, VectorAway→lane-aware, anti-idle-lane, HandleRespawn walk, pack-avoid bypass.
**phase-20** (`40edbd4`): idle-creep-atk fallback, kite-creep HP gate, fwd-fallback tower-lerp, dt-walk 1000→1400u.

| MatchID | Фаза | Заметки |
|---|---|---|
| 8855576439 | phase-19 | триггер-матч |
| 8855652341 | phase-19 | триггер-матч |
| 8855694172 | phase-19 | триггер-матч |
| 8855812997 | phase-19 | триггер-матч |
| 8855867210 | phase-19 | триггер-матч |
| 8855965648 | phase-19 | триггер-матч |
| 8856304426 | phase-20 | триггер-матч (AFK standoff) |
| 8856343351 | phase-20 | триггер-матч (0 LH) |
| 8856358551 | phase-20 | триггер-матч (kite oscillation) |
| 8856380112 | phase-20 | триггер-матч |

---

## 2026-06-16 — phase-18, lane stability (baseline attack + off-lane блокировки)

**Конфиг оба (LongGame v2 smoke):** harass=0.50 farm=0.80 fwd=0.50 abil=0.35 exec=0.15 dive=never hero=default pregame=safe_tower healing=active
**Цель:** smoke-тест движка после phase-18 heal-фиксов. Конфиги не в репо.
**Применены 6 фиксов:** farm_focus bypass, dt-walk creep guard, baseline-attack, tower-danger guard, enemyHuggingTower guard, jungle block (mode_farm), off-lane guards (roam/defend_top/bot/roshan), pregame symmetry.

| MatchID | Dur | Победитель | Конфиг R / D | Заметки |
|---|---|---|---|---|
| 8854084363 | 24.2м | **Dire** | LongGame v2 / LongGame v2 | До полного набора фиксов: бот уходил на эншенты ~10м; нет dive под вышку; Dire первый фраг. Диагностика: `dt-walk` не уступал крипам, farm_focus=0.80 блокировал харасс 80% тиков. |
| 8854228296 | 6.3м | **Dire** | LongGame v2 / LongGame v2 | После частичных фиксов. «Повеселее на линии, не стояли в АФК». no-dive уменьшился D#72→D#23 ✅. Движок стабилен. |

**Итог:** инфраструктура и heal-движок стабильны. 6 фиксов lane stability закоммичены (commits 400b1e0–350d836). Требует валидации в A/B матче.

**Коммиты сессии:**
- `400b1e0` — farm_focus bypass: атака в радиусе не зависит от farm_focus
- `a02555c` — baseline attack + dt-walk уступает крипам
- `c3a4be8` — tower-danger guard в baseline; out-of-range разделён
- `2edaa64` — jungle farming заблокирован в GAMEMODE_1V1MID
- `2046ad5` — mode_roam/defend_top/bot/roshan → DESIRE_NONE в 1v1
- `350d836` — pregame safe_tower: фиксированный 500u от своей T1 (не % от расстояния)

---

## 2026-06-14 — phase-17, новые правила + 1v1 блокировки

**Новые правила:** `pregame_behavior`, `hero_priority`, `deny_policy`, `cw=freeze/push` + guard
**1v1 блокировки:** `mode_ward`, `mode_outpost`, `mode_farm` (jungle path)
**Переменная по сессии:** freeze (save_for_execute + hero=always + deny=always) vs push (on_cooldown + hero=default + deny=never)

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Конфиг R / D | Заметки |
|---|---|---|---|---|---|---|
| 8851932909 | 3.0м | **Dire** | 0/2 2.3 | 2/0 1.0 | freeze+defaults / OHA defaults | 1v1 rule (2 deaths); cw-freeze D#19 ✅; ph=0 R (нет авто-атак) |
| 8851955017 | 6.9м | **Radiant** | 2/0 1.6 | 0/2 2.7 | freeze / push | push огребал от крипов: recovery-flask D#146, kite-creep D#24; guard ещё не был применён |
| 8851989182 | 8.9м | **Radiant** | 2/0 2.9 DN 25 | 0/2 2.0 DN 1 | freeze+always+deny=always / push+default+deny=never | deny-act R#626→25 денаев ✅; hero-prio-always R#58 ✅; lvl 9 vs 6 |
| 8852008347 | 9.2м | **Dire** | 0/2 1.4 DN 1 | 2/0 3.6 DN 16 | push+default+deny=never / freeze+always+deny=always | своп сторон — результат не зависит от стороны ✅ |
| 8852048126 | 5.0м | **Dire** | 0/2 0.8 | 2/0 3.4 DN 14 | push+default+deny=never / freeze+always+deny=always | ward/outpost блоки ✅ (нет ward-place); farm блок ❌ не провалидирован (lvl 4/6) |
| 8852077804 | 5.0м | **Radiant** | 2/0 2.8 DN 4 | 0/2 2.8 DN 4 | freeze+default / push+default | LH равный (14/14); push ph=0 → бот никогда не бьёт героя без hero=always |

**Итог:** freeze побеждает push 4:0 независимо от стороны. Корень: `cw=push`+`hero=default` → ph_dmg=0 (бот игнорирует героя). Следующий тест: push + hero_priority=always.
**⚠️ farm/jungle блок** — не провалидирован: боты не доходят до lvl 8 в 5-мин матчах.

---

## 2026-06-14 — phase-17, hero_priority=always изоляция (оба бота)

**Конфиг оба:** spellcaster, execute=0.45, deny_policy=default, ability_timing=on_cooldown, hero_priority=**always**
**Переменная:** cw=push vs cw=freeze, оба направления

### До фиксов (shrine-issue + freeze-bug)
**Проблемы:** боты уходили на шрайны (water rune DESIRE_HIGH 3200), freeze блокировал ВСЕ ласт-хиты

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Конфиг R / D | Заметки |
|---|---|---|---|---|---|---|
| 8852107561 | 10.9м | **Dire** | 1/2 2.4 DN 9 | 2/1 4.0 DN 3 | freeze+always / push+always | уходили на шрайны; результат смазан — у freeze 26 LH только через sticky auto-attack |
| 8852131228 | 7.2м | **Radiant** | 2/1 3.6 DN 4 | 1/2 **0.0 LH** DN 4 | push+always / freeze+always | Dire freeze = 0 LH 🐛; hero-prio-always D#180 — бот атаковал героя вместо крипов |

**Фикс:** `csAllowed` больше не исключает freeze → ласт-хиты разрешены. `hero_priority=always` уступает движению к ласт-хиту.

### После фиксов ✅
| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Конфиг R / D | Заметки |
|---|---|---|---|---|---|---|
| 8852179010 | 4.2м | **Radiant** | 2/1 1.2 DN 1 | 1/2 2.2 DN 2 | freeze+always / push+always | freeze LH=5 (не 0) ✅; нет shrine-диагов ✅; heroDmg 1264 vs 762 |
| 8852194852 | 3.8м | **Dire** | 0/2 2.4 DN 1 | 2/0 3.4 DN 2 | push+always / freeze+always | freeze LH=13 > push LH=9; heroDmg freeze 1297 vs push 968; ability-harass D#42 vs R#2 |

**Итог:** freeze+hero=always побеждает push+hero=always **2:0 после фиксов**, обе стороны. Freeze бот фармит лучше (свободен от атаки всех крипов) и больше харассит героя.
**⚠️ farm/jungle блок** — не провалидирован: боты не доходят до lvl 8 в коротких матчах.

---

## 2026-06-12 — phase-17, build_style валидация

**Конфиг Radiant:** build_style=brawler, healing_style=active, ability_usage=basic, execute=0.45, pregame=safe_tower
**Конфиг Dire:** build_style=spellcaster, healing_style=passive, ability_usage=aggressive, execute=0.45, pregame=safe_tower
**cfg в логах:** нет MSG1/MSG2 (матч до deploy phase-17 анонса; конфиг вручную)

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Заметки |
|---|---|---|---|---|---|
| 8848634192 | 9.2м | **Dire** | 0/2 1.3 | 2/0 2.8 | brawler/spellcaster ✅; heal R-only ✅; ability-harass D#10 ✅; баг: recovery-rune-bottle→святилище (FIXED) |

**Итог:** item build система работает. Радиант покупал brawler (tango, branches, bottle, bracer), Dire — spellcaster (slippers, null×2, faerie_fire, bottle, phase_boots). Healing и ability isolation подтверждены.

---

## 2026-06-12 — phase-16, A/B execute_threshold

**Общий конфиг (оба бота):** harass=0.85 farm=0.20 fwd=0.80 abil=0.90 rune=0.70 retreat=0.35
gank=0.50 push=0.50 defend=0.50 ward=0.50 roshan=0.50 · rules: dive=finish_only bb=default · improvements={defensive_heal}
**Переменная:** execute_threshold — ChatGPT=**0.45** vs Gemini=**0.50**
**cfg в логах:** нет (cfg-announce сломан до 12.06 — слишком длинное сообщение)

| MatchID | Dur | Победитель | R (LLM, exec) | D (LLM, exec) | R K/D LH/м | D K/D LH/м | Заметки |
|---|---|---|---|---|---|---|---|
| 8848473484 | 6.5м | **Dire** | Gemini 0.50 | ChatGPT 0.45 | 0/2 0.8 | 2/0 3.2 | rune-grab D#1; role-pos R#1(!) D#2 ✓ |
| 8848499114 | 8.9м | **Dire** | Gemini 0.50 | ChatGPT 0.45 | 0/2 2.7 | 2/0 2.0 | execute-approach R#2; rune-grab D#1 |
| 8848509609 | 8.1м | **Radiant** | ChatGPT 0.45 | Gemini 0.50 | 2/0 3.0 | 0/2 3.1 | recovery-flask D#21 |
| 8848526118 | 4.5м | **Radiant** | ChatGPT 0.45 | Gemini 0.50 | 2/0 2.4 | 0/2 3.1 | быстрый фраг |

**Итог: ChatGPT (execute=0.45) побеждает 4:0.** Коммитит убийство при HP<45% → первый фраг → сноубол.

---

## 2026-06-11, вечер — phase-15 валидация

**Конфиг:** harass=0.85 farm=0.20 fwd=0.80 abil=0.90 rune=0.70 retreat=0.35 · R=exec0.50(Gemini) D=exec0.45(ChatGPT)
rules: dive=finish_only low_hp=regen_lane · improvements={defensive_heal}
**cfg в логах:** нет (cfg-announce сломан)

| MatchID | Время | Dur | Победитель | R K/D LH/м | D K/D LH/м | Заметки |
|---|---|---|---|---|---|---|
| 8847716072 | 17:42 | 6.9м | **Radiant** | 2/1 2.5 | 1/2 2.9 | первый матч с defensive_heal + rune-grab; bottle-heal D#3 |
| 8847756115 | 18:12 | **21.7м** | **Radiant** | 1/1 2.7 | 1/1 3.0 | roam-late D#1337 R#1251 — баг роуминга ещё не пофикшен; rune-grab D#5 R#7 |
| 8847801209 | 18:39 | 4.9м | **Dire** | 0/2 1.8 | 2/0 2.7 | ✅ **phase-15 валидация** — roam-late убран, bottle у обоих, rune-grab D#5 R#7 |

---

## 2026-06-11, утро–день — отладка (role, pre-game, rune guard)

**Конфиги:** менялись в течение сессии. Из HANDOFF — base: harass=0.85 abil=0.90 fwd=0.80 rune=0.70 farm=0.20
Точные exec и retreat варьировались; bottle у обоих (phase-15 item_build) присутствует в items.
**cfg в логах:** нет (cfg-announce сломан)
Матчи без duration (8847216639, 8847241097, 8847292950, 8847303687, 8847467079) — аборты/краши, пропущены.

| MatchID | Время | Dur | Победитель | R K/D LH/м | D K/D LH/м | Что отлаживали |
|---|---|---|---|---|---|---|
| 8847222624 | 09:33 | 11.2м | **Dire** | 1/2 3.7† | 2/1 4.2† | pg-called D#798 R#798; формат 5v5(!) — см. ниже |
| 8847285564 | 10:58 | 5.8м | **Dire** | 0/2 3.5 | 2/0 3.3 | pre-game движение, до role fix |
| 8847326984 | 12:20 | 6.7м | **Radiant** | 2/0 3.3 | 0/2 2.4 | kill-priority R#54 (execute тест) |
| 8847358477 | 12:39 | 4.3м | **Radiant** | 2/1 1.6 | 1/2 2.1 | быстрый матч |
| 8847375816 | 12:50 | 5.0м | **Dire** | 1/2 1.8 | 2/1 0.8 | kill-priority D#19 R#96 |
| 8847385506 | 13:08 | 10.6м | **Radiant** | 2/1 3.1 | 0/2 2.5 | tp-fountain D#15; execute D#1 |
| 8847402555 | 13:23 | 9.4м | **Radiant** | 1/1 2.9 | 1/2 3.7 | execute D#10 execute-approach D#18 (execute тест) |
| 8847434228 | 13:56 | 10.5м | **Radiant** | 2/1 2.7 | 0/2 3.2 | execute-approach R#11; regen-lane R#40 |
| 8847451410 | 14:09 | 9.0м | **Dire** | 1/2 3.1 | 2/1 2.9 | execute D#6; tp-fountain R#30 |
| 8847467510 | 14:26 | 10.1м | **Dire** | 1/2 1.9 | 2/1 2.4 | execute D#11; regen-lane D#34 |
| 8847486118 | 14:38 | 9.2м | **Dire** | 1/2 2.8 | 0/1 2.6 | execute R#5; regen-lane R#24 |

† 8847222624 — 10 слотов в логе (5v5 загрузка), реально сыграли только slot0 и slot128. LH из слотов 0/128.

---

## Сводка по фиксам (что валидировалось)

| Фикс | Матч | Результат |
|---|---|---|
| roam-late отключён для 1v1 | 8847801209 | ✅ нет roam-late в диагах |
| item_build SF pos_2 (bottle) | 8847801209 | ✅ bottle-heal D#3, recovery-bottle у обоих |
| pre-game движение (pg-called) | 8847222624 | ✅ pg-called D#798 R#798 |
| defensive_heal | 8847716072 | ✅ bottle-heal, heal-item активны |
| role pos_2 для 1v1 | 8848473484 | ✅ role-pos R#1 D#2 (pos_2 у обоих) |
| rune laning guard | 8848473484+ | ✅ боты не ходят за руной без нужды |
| execute_threshold=0.45 > 0.50 | 8848473484–8848526118 | ✅ 4:0 |
| healing_style изолирован (active vs passive) | 8848634192 | ✅ bottle-heal/tango-heal только R; D — ничего |
| ability_usage изолирован (aggressive vs basic) | 8848634192 | ✅ ability-harass D#10; R — 0 |
| build_style (brawler vs spellcaster item_build) | 8848634192 | ✅ оба купили правильные сборки |
| water rune distance cap (fix: бот к святилищу) | 8848634192 | 🐛 FIXED: ≤2000 units в aibattle_heal.lua |
