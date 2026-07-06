# Спеки незакрытых работ (дизайн готов, имплементация ждёт)

> Все — поведенческие, требуют своих матчей и чистой атрибуции. Порядок: Motor v2 → П3 → П1.
> rune_control — match-free сетап. Контекст: HANDOFF_PACKAGE §4. Составил Claude (Opus high), 06.07.
> Процесс: один фикс — одна лог-сигнатура; приёмка только по scorecard.py; вышел за критерий — СТОП.

---

## 1. Motor — корректированный план (v2 recovery-claims = NO-OP)

**⚠️ ПОПРАВКА 06.07 (эмпирика 6 матчей + чтение гейтов):** миграция recovery-движителей под
Claim (v2) — **NO-OP для jitter**. Позиционеры глушат себя на лоу-хп СВОИМИ гейтами ДО
motor-чека: `lane-line-fallback` (mode_laning_generic:692 `suppressed-lowhp`) и `UphillReposition`
(combat.lua:188 `lowHpHold`) бэйлятся раньше, чем проверяют `Motor.Active`. А recovery-клеймы
существуют только на лоу-хп → регимы НЕ пересекаются, yield не триггерится (`lane-line-suppressed-motor=0`
все матчи). Реальная осц-пара — `uphill-reposition ↔ lane-line-fallback`, ОБЕ healthy-регим,
и НИ ОДНА не Claim'ит (только yield) → нечему уступать.

**РЕАЛЬНЫЙ ФИКС (одной задачей, после матча 7):**
1. Дать Claim САМОЙ паре: `UphillReposition` и `lane-line-fallback` при движении делают
   `Motor.Claim(..., prio 15-20, ttl ~1.2)` — тогда уступают ДРУГ ДРУГУ (committed-destination
   для настоящей пары).
2. Заодно убрать мёртвые v2 recovery-claim'ы (`emerg-retreat`/`fwd-lowhp-pull` в recovery.lua,
   `prewave-duel` require+claims в duel.lua) и вернуть prio critical 110→100, low-hp 90→80 —
   это чистка no-op, делать В ТОМ ЖЕ коммите (не отдельным revert-churn'ом на проверенном файле).
Критерий выхода: `lane-line-suppressed-motor > 0` + healthy-регим jitter вниз, 2 матча.

**Ниже — устаревший план v2 (для истории, НЕ реализовывать):**

**Проблема.** ~55 вызовов `Action_MoveToLocation`, каждый со своим кулдауном → N регуляторов
на одном актуаторе → jitter (хронический FAIL scorecard, порог ≤60). Motor v1
(`aibattle_motor.lua`: `Claim/Active/Release`) покрыл `critical-recover` (prio 100) и
`ActiveLowHp` (80); позиционеры (`UphillReposition` combat.lua:191, `lane-line-fallback`
mode_laning_generic:700) уступают.

**Корень остатка.** Инвариант «claim ttl ≥ свой move-кулдаун» держит покрытых, но **три
движителя двигают БЕЗ claim** → между их кулдаунами мотор «ничей», позиционер вклинивается:

| Хэндлер | Файл:строка | кулдаун | вставить `Claim` |
|---|---|---|---|
| `EmergencyRetreat` | recovery.lua:215 | 1.5s | `("emerg-retreat", 110, 1.6)` |
| `ForwardLowHpPullback` | recovery.lua:235 | 1.2s | `("fwd-lowhp-pull", 90, 1.3)` |
| `prewave-duel-back` | duel.lua:41,82 | ~2s | `("prewave-duel", 70, 1.5)` |

Плюс поднять существующие prio в полосы: critical 100→110, low-hp 80→90. Preemption уже
в `Motor.Claim`. Полосы: recovery-critical 110 / recovery-soft 90 / duel 70 / position 10-30.

**Границы.** НЕ мигрировать остальные ~40 точек. НЕ трогать логику recovery. Отдельный
коммит от конфигов.
**Критерий выхода.** `jitter_sum` ≤60 обе стороны 2 матча подряд; `pg-duel-uphill-back`
падает с 172-179 до ≤~40; регресса (empty_action≤80, errors=0, LH>0) нет.
**Объём.** ~6 строк в 2 файлах + 2 правки prio. Обратимо git-revert'ом.

---

## 2. П3 — единый владелец low-HP (ПОСЛЕ Motor v2)

**Проблема.** Low-HP размазан по 7 функциям (`ThinkIfAllowed`:32, `CriticalLock`:63,
`ActiveLowHp`:119, `EmergencyRetreat`:199, `ForwardLowHpPullback`:219, `LowHpHoldState`:240
в recovery.lua + хил в survive.lua). И safety-, и recover-кандидаты зовут один
`ActiveLowHp(retreatOnly=true)` → косметический выбор арбитра → петли `fight→safety→fight`.
Пороги-россыпь: 0.45 / 0.34 / 0.30 / 0.25 / 0.32-0.35 / softRecovery / 0.40+0.15*rc.

**Дизайн.** Один вход `Recovery.Owner(ctx)`, детерминированный по HP-полосе:
- critical <0.25 → committed retreat через `Motor.Claim("recover",110)`, единый путь;
- soft 0.25-0.45 → hold за якорем (Claim 90) + безопасный CS если крип рядом;
- caution 0.45-0.55 → lane work осторожно, не committed, уступает desire.
`EmergencyRetreat`/`ForwardLowHpPullback` роутить через него. Safety-кандидат делегирует
`Recovery.Owner`, не дублирует recover → петля исчезает. Пороги — единые константы.

**Границы.** НЕ переписывать survive.lua-хил. НЕ до приёмки Motor v2.
**Критерий выхода.** stationary >10s при живом враге ≤2/матч (2 матча); jitter из П2 держится;
петли fight↔safety исчезают.

---

## 3. П1 — арбитр как единственный владелец тика (хендофф техкоманде)

**Проблема.** Top-desire арбитр — стадия 6 из 13. Осцилляции = пары хэндлеров по разные
стороны его границы (`uphill-reposition↔lane-line-fallback`, `critical-lock↔low-hp-back`).
Motor/П3 лечат конкретные пары; П1 убирает класс.

**Дизайн.** Втянуть стадии 1-5 и 8-13 в арбитр как кандидатов с фикс-полосами (та же
band-модель, что Motor): urgent 150+ / recovery 100-130 (через Recovery.Owner) / desire
60-120 (как сейчас) / position 10-30 / idle 0-10. Один проход: собрать кандидатов с prio +
`canAct()` (контракт П4 уже есть), исполнить одного. Границы «до/после арбитра» исчезают.

**Предусловия.** Motor v2 + П3 приняты (band-модель обкатана, recovery уже один вход);
П4 canAct на месте (есть).
**Критерий выхода.** ≥95% тиков ровно один tick-owner; осцилляционных пар нет 2 матча.
**Размер.** Средний: инфра (arbiter/policy/Motor/tick-owner телеметрия) есть — работа в
перерегистрации стадий как кандидатов. Мигрировать полосами, матч между, не всё разом.

---

## 4. rune_control — изоляция диала (match-free сетап, не код)

**Проблема.** Единственный диал без изолированного матч-подтверждения: в 1v1 laning-desire
≈1.0 давит rune-staging. Прошлый прокси «покинул линию» неверен.
**Предусловие.** Только после того как фикс `9e424ba` даст `result=filled>0` (сейчас 0 все
матчи — мерить нечего). Если filled всё ещё 0 → копать pickup-путь, не rune_control.
**Сетап.** Свап-контроль по ОДНОМУ диалу: A `rune_control=0.9` vs B `0.1`, идентичны в
остальном; 2 матча со свапом сторон. Прокси — staging-claim'ы и `filled` count, не позиция.
**Успех.** Сигнатура следует за диалом, не стороной (как ability_timing). Закрывает 12/12.
**Если не разделяется.** Честный вывод: валиден по механике, но не изолируем в 1v1 —
пометить «только 5v5/полная карта», не гнаться (perfectionism trap).

---

## 5. Мёртвые значения схемы — РЕШЕНО (внести прицепом к первому заходу в backend)

ТОЛЬКО `healing_style="passive"` — no-op (движок ветвится лишь на `=="active"` [survive.lua]
и `=="never"` [item usage]; passive == default). **Решение (06.07):**

- **`healing_style="passive"` → УБРАТЬ** ✅ СДЕЛАНО из `RULE_VALUES` (generate_playstyle.py) и
  `HEALING_STYLE_VALUES` (aibattle_style.lua). Третьего режима хила нет — дубль `default`.

**⚠️ ПОПРАВКА 06.07 (прошлый аудит был НЕВЕРЕН):** `ability_usage` — **НЕ no-op, НЕ депрецировать**.
`aibattle_style.lua:882` (`M.AbilityHarass`): `if rules.ability_usage ~= "aggressive" then return false`
— правило гейтит ВСЮ раз-харасс-систему. `basic` уже маппится в `default` (style.lua:342), поэтому
промпт (`aggressive|default`) корректен. Диал `ability_aggro` — это ИНТЕНСИВНОСТЬ внутри
aggressive, не замена правила. Оставить как есть.
