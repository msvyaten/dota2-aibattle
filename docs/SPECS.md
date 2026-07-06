# Спеки незакрытых работ (дизайн готов, имплементация ждёт)

> Все — поведенческие, требуют своих матчей и чистой атрибуции.
> **Порядок (пересмотрен 06.07, Fable-high): П1-A → П3 → П1-B → П1-C. Motor v2 (§1) ОТМЕНЁН — поглощён П1-A (см. §3.6).**
> rune_control — match-free сетап. Контекст: HANDOFF_PACKAGE §4. Составил Claude (Opus high), 06.07; §3 доведён до мандата Fable-high 06.07.
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

## 3. П1 — арбитр как единственный владелец тика (МАНДАТ, Fable-high 06.07)

**Статус: мандат.** Эскиз доведён по коду HEAD c8bd23c: `mode_laning_generic.lua` (1263),
`aibattle_laning_arbiter.lua`, `aibattle_laning_policy.lua`, `aibattle_engine.lua`,
`aibattle_motor.lua` прочитаны целиком, все якоря сверены.

### 3.1 Проблема — один корень, четыре класса симптомов

Top-desire арбитр владеет только СЕРЕДИНОЙ тика (`mode_laning_generic.lua:967`).
До него — 7 guard-блоков (953-966), после — ~16 блоков «кто первый вернул true»
(968-1173). Из этой архитектуры СЛЕДУЮТ все хронические классы:

1. **Осц-пары через границу арбитра**: `uphill-reposition`(1033) ↔ `lane-line-fallback`(1171),
   `critical-lock` ↔ `low-hp-back`. Хэндлеры не видят друг друга — дерутся на чередующихся тиках.
2. **Suppress-спагетти**: fwd-position несёт 12 suppress-условий (1097-1111),
   lane-line-fallback — 9 гардов (692-727). Каждый гард — ручное знание «кто ещё может
   хотеть тик»; связи растут как O(N²) от числа хэндлеров.
3. **Windup-cancel** (soft-полоса, 8884555745 t=218): мувер одной стадии отменяет замах
   атаки другой — понятием «идёт свинг» не владеет никто.
4. **Четыре реализации commit-паттерна**: winner-hysteresis +18/1.5s (arbiter.lua:48-61),
   `Motor.Claim`, `aib_siegeCommitUntil`, rune-commit окно — плюс ~15 per-handler
   кулдаунов `aib_*Last`. Один и тот же «committed owner», написанный четырежды.

Motor/П3 лечат конкретные пары; П1 убирает класс целиком и усушает оркестратор.

### 3.2 Модель: election + commitment

Один проход на тик:

```
Candidate = { name, band, score(), canAct(), class, action() }
  band  ∈ {urgent, recovery, desire, lanework, position, idle} — фикс-полосы
  class ∈ {attack, move, hold, cast} — для windup-гейта (3.5)
Факты тика (расширенный policyArgs из AIB_RunTopDesireArbiter:785-836) собираются
ОДИН раз; все score/canAct читают их — кандидаты не дублируют сканы.
Сортировка по score → первый, чей action() == true, владеет тиком.
action() == false → blocked=empty_action → следующий (контракт П4, уже работает).
```

**Полосы (константы в policy.lua, существующие desire-скоры НЕ трогаем):**

| Полоса | Диапазон | Кто |
|---|---|---|
| urgent | 150-200 | survive, emergency-low, kill-lock, heal-interrupt, critical-lock, prewave |
| lh-urgent | 140 | last-hit-urgent (существует, mode_laning:853) |
| desire | 60-135 | safety/power-rune/fight/recover/siege — скоры policy.lua как есть |
| lanework | 35-58 | safe-cs, hero-over-creep, cs-inrange, idle-heal, harass, creep-work, ability-harass |
| position | 15-30 | uphill-reposition, fwd-position, lane-line-fallback |
| idle | 1-10 | visual-hold, visual-afk, anti-idle |

**Намеренное пересечение** (единственное): no-action-капы desire
(`safetyNoAction=44`, `fightNoAction=40`, policy.lua:49,63) лежат НИЖЕ lanework —
симптомный desire без действия больше не крадёт тик у живого ласт-хита.
Это закрывает остаток «0-CS при агро-конфигах» ПО ПОСТРОЕНИЮ.

### 3.3 Commitment — замена четырёх дублей

- **Внутриполосный гистерезис** (есть): +18/1.5s победителю, БАНД-КАППЕД — бонус не
  поднимает score выше потолка полосы. Преемпция между полосами всегда чистая.
- **Commit TTL** (фаза C): победитель может объявить `commit=ttl` — арбитр переизбирает
  его автоматически до истечения ttl или появления кандидата ВЫШЕ ПОЛОСОЙ (не скором).
  Заменяет Motor.Claim / siegeCommitUntil / rune-commit / committed-hold.
- **Attack-авто-commit**: победитель class=attack коммитится до конца свинга.

### 3.4 Band-refractory — замена временнЫх suppress-гардов (фаза C)

Часть suppress-условий — не «кто-то хочет тик сейчас», а «кто-то владел недавно»
(recentRecovery 2.5s, recentCreepRelief 1.8s, recentTopEmpty 3.0s, recentVisualHold,
recentWatchdog). Их заменяет ОДНО правило арбитра: position/idle-кандидаты не участвуют
в выборах N секунд после владения recovery/safety-полосы:
`Refractory = { position_after_recovery=2.5, position_after_damage=1.8, position_after_empty_desire=3.0 }`.
Тайм-стемпы `aib_recMoveLast`/`aib_creepReliefLast`/`aib_topArbiterEmptyLast` перестают
читаться хэндлерами — их читает только арбитр.

### 3.5 Windup-гейт (фаза C) — закрывает soft-банд windup-cancel

Победитель class=move НИЖЕ urgent-полосы не исполняется, пока идёт активный замах:
`DotaTime() - bot:GetLastAttackTime() < attackPoint` (и цель жива) → тик отдаётся
предыдущему владельцу (hold). Recover/safety при 38-40% HP больше не отменяют
добивающий свинг ретрит-мувом — «замахнулся-не ударил-ушёл» умирает архитектурно.

### 3.6 Реестр миграции (все якоря — mode_laning_generic.lua, HEAD c8bd23c)

**Голова тика (фаза B) → urgent-кандидаты:**

| Блок | Якорь | score | Примечание |
|---|---|---|---|
| AIBSurvive true-emergency | :953 | 195 | canAct: hp<trueEmergencyHp |
| emergency-low recovery | :954 | 190 | через Recovery.Owner после П3 |
| kill-lock (urgent) | :957 | 170 | intent из Trade.KillLock |
| heal-interrupt | :959 | 165 | |
| early-low (Hp.danger) | :963 | 130 (recovery-полоса) | П3 |
| critical-lock | :964 | 160 | П3 |
| prewave-duel / standoff | :965-966 | 152/151 | canAct: пред-крипово окно |

Вне арбитра ОСТАЮТСЯ: `AIB_HandleRespawn` (:1190 — защита TP-канала, абсолют),
pregame/dive/death-window стадии (:1177-1179 — редкие tempo-гарды, с lane-хэндлерами
не осциллируют; втягивать = perfectionism trap).

**Desire-арбитр (:967)** — без изменений: last-hit 140, safety, power-rune, fight,
recover, siege. Скоринг policy.lua не трогаем.

**Хвост тика (фаза A) → lanework/position/idle-кандидаты (скоры кодируют ТЕКУЩИЙ порядок):**

| Блок | Якорь | band/score | Судьба |
|---|---|---|---|
| safe low-hp CS | :968-979 | lanework 56 | позже сольётся с П3 soft-полосой (hold+CS) |
| HeroOverCreep | :993 | lanework 52 | |
| cs-inrange | :996-1001 | lanework 50 | |
| AIBSurvive idle-heal | :1003 | lanework 45 | |
| EmergencyRetreat | :1007 | — | умирает как отдельная точка → П3 Recovery.Owner |
| ForwardLowHpPullback | :1013 | — | → П3 |
| EmergencyKillPriority | :1023 | desire 122 | кандидат «execute»; в фазе C свести с KillLock |
| LowHpHold/ActiveLowHp | :1027-1029 | — | → П3 |
| UphillReposition | :1033 | position 28 | ★ пара с lane-line умирает здесь |
| HarassAndChase | :1042 | lanework 42 | |
| HandleCreepWork | :1044-1062 | lanework 40 | ОДИН кандидат, внутренности не трогать |
| AbilityHarass | :1081 | lanework 38 | |
| fwd-position | :1086-1165 | position 22 | 12 suppress-условий → фаза C (refractory) |
| VisualHold / VisualAFK | :1169-1170 | idle 8/6 | |
| LaneLineFallback | :689-783, вызов :1171 | position 18 | 9 гардов → canAct (фаза A), снос в C |
| AntiIdleGlobal | :1173 | idle 2 | |

**⚠️ Скрытые меж-стадийные зависимости** (главный риск фазы A): ранние блоки пишут в
runtimeCtx то, что читают поздние — `csAllowed/needMove` (:1040-1041, пишутся перед
HarassAndChase), `lowHpHold` (:1028), `deathSurvive` (:1018). При обёртке в кандидатов
эти значения ОБЯЗАНЫ переехать в билдер фактов тика (вычисляются до выборов), иначе
поведение зависит от порядка score() и молча ломается.

### 3.7 Фазы миграции (каждая = один коммит, матч между, git-revert как откат)

**Фаза A — хвост тика (механическая, средняя).** Блоки :968-1173 → кандидаты; гарды
остаются ВНУТРИ canAct/action (поведение эквивалентно, порядок = скоры). Единственное
намеренное изменение — no-action-капы vs lanework (3.2). Меж-стадийные данные → факты
тика. Сигнатура: `tick-owner` получает `band=` в detail. Критерий фазы: ≥95% тиков
один владелец; LH/jitter/empty_action не хуже базлайна (scorecard, 1 матч).

**Фаза B — голова тика (малая).** :953-966 → urgent-кандидаты по таблице 3.6.
Критерий: осц-пара `critical-lock↔low-hp-back` отсутствует; выживаемость без регресса.

**Фаза C — снос дублей (выигрыш).** (1) 12+9 suppress-условий → band-refractory (3.4);
(2) commit-унификация (3.3), Motor v1 retire — владение тиком = владение мотором;
(3) windup-гейт (3.5); (4) свести EmergencyKillPriority с KillLock.
Критерий: оркестратор ужимается ощутимо (цель ~-300 строк); windup-cancel сигнатуры нет.

### 3.8 Связи с другими спеками

- **Motor v2 (§1) — НЕ ДЕЛАТЬ.** Пара uphill↔lane-line решается фазой A по построению
  (оба — position-кандидаты, один победитель + гистерезис). Motor v1 живёт до фазы C,
  потом retire. Чистку мёртвых v2-claim'ов (§1 п.2) — прицепом к фазе C.
- **П3 (§2) — совместим, упрощается.** Фаза A его НЕ ждёт (оборачивает recovery-вызовы
  как есть). После П3 Recovery.Owner становится единственным recovery-кандидатом
  (полоса 100-130), а строки EmergencyRetreat/ForwardLowHpPullback/ActiveLowHp из
  таблицы 3.6 схлопываются в него.
- **П4 canAct** — уже в policy (safetyNoAction/fightNoAction); контракт распространяется
  на все полосы без изменений.

### 3.9 Критерий выхода П1 целиком

≥95% тиков ровно один tick-owner; осц-пар в tick-owner-сэмплах нет 2 матча подряд;
jitter ≤60 обе стороны; empty_action ≤80; errors=0; LH и bottle без регресса (scorecard).

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
