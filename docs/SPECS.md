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

**СТАТУС 07.07:**
1. ✅ **СДЕЛАНО (07bf053) и ВАЛИДИРОВАНО (8885447129):** пара Claim'ит — `UphillReposition`
   = `Motor.Claim("uphill-repo", 20, 1.5)`, `lane-line-fallback` = `Claim("lane-line", 20, 1.5)`,
   каждый уступает при чужом активном клейме. Результат: `lane-line-fallback` 195→88,
   `lane-line-suppressed-motor` фаерит, jitter_sum −40%. Остаточная медленная осц (6с-каденция
   uphill) — policy-конфликт «где стоять», добивают П3/П1-A.
2. ⏳ Чистка мёртвых v2 recovery-claim'ов + возврат prio (110→100, 90→80) — прицепом к П1-C
   (см. §3.8), НЕ отдельным коммитом.

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

## 2. П3 — единый владелец low-HP (МАНДАТ, Fable-high 07.07)

**Статус: мандат.** Эскиз доведён по коду HEAD 07bf053: recovery.lua, survive.lua (целиком),
constants, все вызовы в mode_laning_generic сверены. Валид-данные: 8884639175 (freeze),
8885365845 (flee-фикс контекст), 8885447129 (flee/poscommit валидированы, low-hp-back = остаток).

### 2.1 Проблема — инвентарь фрагментации (11 движущих точек, ~15 порогов)

**Движение на low-HP исполняют 11 НЕЗАВИСИМЫХ владельцев** (якоря = HEAD 07bf053):

| # | Владелец | Якорь | Движение | CD |
|---|---|---|---|---|
| 1 | `ThinkIfAllowed` (роутер ×3 порога) | recovery.lua:32 | → surviveThink/ActiveLowHp | — |
| 2 | `CriticalLock` (+flee 67ae609) | recovery.lua:63 | committed dest 4s, hold, flee | 0.8-1.0 |
| 3 | `ActiveLowHp` | recovery.lua:119 | safe-step / **back** / watch-step / committed-hold | 0.8-3.0 |
| 4 | `EmergencyRetreat` | recovery.lua:219 | back + parting AbilityHarass | 1.5 |
| 5 | `ForwardLowHpPullback` | recovery.lua:240 | back с вражеской половины | 1.2 |
| 6 | `LowHpHoldState` | recovery.lua:262 | probe (⚠️ diag-сайд-эффект `low-hp-limit`) | — |
| 7 | `fountainRecovery` | survive.lua:173 | фонтан-трип state machine | 1.0 |
| 8 | heal-pullback (`defensiveHeal`) | survive.lua:386 | back при dmg (не-regen_lane) | 3.0 |
| 9 | `regenLane` | survive.lua:403 | → xpRecoveryLoc при враге <900 | 1.5 |
| 10 | post-fight step-back (`recovery`) | survive.lua:495 | → xpRecoveryLoc после боя | 5.0 |
| 11 | fallback-цепь (`recovery`) | survive.lua:520 | buy(+escape 9bb91a2)/TP/walk/руна/xp-hold | 15/5/1.5 |

Плюс **оба десира сходятся в одну точку**: safety-кандидат (mode_laning:871) и
recover-кандидат (:911) оба кончаются `ActiveLowHp(softRecovery, retreatOnly)` → выбор
арбитра косметический → петли `fight→safety→fight`.

**Пороги-россыпь (все НЕ именованы единообразно):** 0.55(softRecovery/laneLowHp) ·
0.45(activeRecovery/low_hp_hold/FwdPull) · 0.45+0.20rc(postFightBack) · 0.40(damageLockout/
heal-pullback/flask) · 0.35(danger/earlyLowHp/low-hp-creep) · 0.34(criticalLockClear) ·
0.32(low-hp-fight) · 0.30(critical/buy-escape/runeYield) · 0.28(safeLastHitMin/xpRecovery-switch) ·
0.25(EmergencyRetreat) · 0.22(emergencyHp) · 0.20+0.20rc+0.08d(fallback) · 0.14(trueEmergency).

**Следствия (все валидированы матчами):** freeze «стоял и умер» (8884639175/8885365845 —
полечен flee-фиксом ТОЧЕЧНО, семантика осталась размазанной); `low-hp-back=47-51` = главный
остаток jitter (8885447129); windup-cancel «замахнулся-не ударил-ушёл» (8884555745 t=218);
«не ищет руну/не тратит золото, стоя на 20%» (жалоба юзера, смотрибельность).

### 2.2 Дизайн: Recovery.Owner — полоса × угроза × эпизод

Один вход `Recovery.Owner(ctx)` в recovery.lua. Решение = функция ДВУХ осей + эпизод-стейт:

**Ось 1 — HP-полоса** (единые константы `Bands`, гистерезис на границах ±0.03):

| Полоса | HP | Поведение |
|---|---|---|
| CRITICAL | <0.25 (выход ≥0.32) | committed retreat, НИКАКОЙ lane work. `Motor.Claim("recover",110)` |
| SOFT | 0.25-0.45 | hold за якорем + разрешённые действия (см. ниже). Claim 90 только на репозиции |
| CAUTION | 0.45-0.55 | lane work с оглядкой; Owner НЕ двигает, отдаёт advisory-флаг (экс-lowHpHold) |

**Ось 2 — угроза** (урок flee-фикса: полоса без угрозы ≠ полоса под дайвом):
`threatened = WasRecentlyDamagedByAnyHero(2.5) OR живой враг ≤900`.
- CRITICAL×threatened → **прогрессивный flee** к фонтану (генерализация 67ae609: шаги 700,
  переоценка на достижении); CRITICAL×safe → hold+реген у якоря / фонтан-трип если ресурсы
  исчерпаны (порядок эскалации: items → buy(+escape) → руна если достижима → TP/walk фонтан).
- SOFT×threatened → отход за якорь (ОДНА committed-точка); SOFT×safe → hold + safe-CS +
  реген + rune-seek если достижима (закрывает «руна лежала, он стоял»).

**Эпизод-модель (ключ к честному jitter):** вместо 6 per-handler кулдаунов — ОДИН эпизод:
`{band, dest, until, mode}`. Правила:
1. **Один якорь на эпизод** (инвариант under-tower фикса): все под-движения эпизода целят
   ОДНУ точку; смена dest только по (a) ttl 4s, (b) смене полосы/угрозы (edge, не уровень).
2. Re-issue move к ТОЙ ЖЕ точке — тихий (без diag), ≤1/с.
3. **Diag пишется на СМЕНУ эпизода, не на каждый move**: `intent=recovery-owner band=X
   mode=flee|hold|walk|cs|item reason=... dest=...`. → счётчик меряет ЭПИЗОДЫ (реальные
   решения), а не спам команд — jitter-прокси становится честным по построению (сейчас
   low-hp-back=47 это 47 re-issue ОДНОГО отступления, метрика завышает; см. анализ порогов).

**Windup-гейт (закрывает 8884555745):** Owner НЕ выдаёт move, пока идёт замах атаки
(добивающий свинг в SOFT: `DotaTime()-GetLastAttackTime() < attackPoint` и цель жива) —
свинг завершается, потом отход. Локальная версия П1 §3.5 для recovery-движений.

**SOFT safe-CS** = поглощение блока mode_laning:968-979 (те же гейты: крип умирает с удара,
в рендже, hp≥safeLastHitMin, не под активной вышкой, без damageLockout) — становится
действием Owner'а, а не отдельной стадией.

### 2.3 Кто куда девается

**Поглощаются (функции удаляются):** EmergencyRetreat→CRITICAL (parting-shot сохраняется),
ForwardLowHpPullback→SOFT×threatened (вражеская половина = автоугроза), ActiveLowHp→
растворяется (fight/creep-ветки→SOFT-действия; back/safe-step/watch-step/committed-hold→
эпизод-ядро), CriticalLock→CRITICAL-ядро (flee-логика сохраняется КАК ЕСТЬ), regenLane→
SOFT×threatened, heal-pullback→SOFT, post-fight step-back→SOFT/CAUTION×safe, fallback-цепь→
CRITICAL-эскалация (порядок и buy-escape сохраняются).

**Остаются:** survive.lua item-хил (`defensiveHeal` пп.1-9, `recovery` items) — граница
«items отдельно от движения» держится; `fountainRecovery` — терминальная машина, но вход
в неё ТОЛЬКО по решению Owner (CRITICAL×safe, ресурсы исчерпаны); `CreepHitReact`/
`DamageUnstuck` — остаются в safety (damage-react, не low-HP).

**Кандидаты арбитра:** recover-action = `Recovery.Owner(ctx)` напрямую; safety-action
теряет `ActiveLowHp`-ногу (только CreepHitReact/DamageUnstuck) → петля fight↔safety
умирает по построению (retreat производит ТОЛЬКО Owner).

**Вызовы в mode_laning:** :963 (early-low) + :964 (CriticalLock) → один `Owner.Urgent(ctx)`
(CRITICAL-полоса) до арбитра; :1007/:1013/:1027-1029 — УДАЛЯЮТСЯ; :968-979 → SOFT-действие.
:953-954 (trueEmergency 0.14/emergencyHp 0.22) — внутрь CRITICAL как под-градация.

**Стейт-вары под снос:** `aib_lowHpActiveLast`, `aib_lowHpHoldLast`, `aib_emergLast`,
`aib_fwdPullLast`, `aib_regenMoveLast`, `aib_pullbackLast`, `aib_criticalRecover*` →
один `aib_recoveryEpisode = {band, dest, until, mode, at}`.

### 2.4 Жёсткие инварианты (в кластере живут РЕШЁННЫЕ баги — не регрессировать)

1. **Единая точка отступления** (under-tower твитч, решён): не возвращать «разные точки
   к фонтану»; watch-step/nudge НЕ воскрешать.
2. **Committed-hold через арбитр-гистерезис** (не через Motor) за якорем — сохранить.
3. **flee-dived** (67ae609, валидирован freeze 67→1): threatened-ветка CRITICAL обязана
   вести себя идентично текущей.
4. **buy-escape** (9bb91a2, валидирован): порядок «items → buy сверх кэпов при critical-stuck»
   сохраняется в CRITICAL-эскалации.
5. **Probe без сайд-эффектов** (ловушка §3.6): band/threat-классификатор НЕ пишет diag;
   `low-hp-limit` диаг умирает вместе с LowHpHoldState (его advisory-роль → CAUTION-флаг).
6. **regen_lane семантика** (оба live-конфига): SOFT держит бота В ЛИНИИ (xpRecoveryLoc),
   эскалация на фонтан только из CRITICAL. `low_hp_behavior` = стратегия Owner'а:
   tp/walk_fountain понижают порог фонтан-эскалации, regen_lane повышает.

### 2.5 Миграция (фаза = коммит + матч, по образцу П1)

**П3-A — скелет (behavior-preserving):** Owner как классификатор полоса×угроза + эпизод-стейт;
CriticalLock/EmergencyRetreat/FwdLowHpPullback роутятся через него (семантика 1:1, dual-emit
старых диагов рядом с новыми `recovery-owner`). Выход: freeze=0 держится, flee фаерит,
stationary ≤2, старые/новые диаги согласуются.

**П3-B — растворение дублей:** safety-нога ActiveLowHp отрезается; ActiveLowHp/regenLane/
heal-pullback/step-back → эпизод-ядро; per-move диаги умирают (счёт = эпизоды). В ТОМ ЖЕ
коммите обновить `tools/postmatch.py`+`scorecard.py`: JITTER_KEYS дополняются
`recovery-owner-episodes` (старые ключи уходят в 0 — оставить для старых логов). Выход:
`low-hp-back/safe-step/watch-step` = 0; `recovery-owner` эпизодов ≤ ~15/матч; петля
fight↔safety отсутствует (нет чередования `state-desire-fight/safety` на соседних тиках);
jitter_sum падает скачком (прокси честный).

**П3-C — семантика:** windup-гейт + SOFT safe-CS поглощает :968 + rune-seek в SOFT×safe +
фонтан-эскалация из CRITICAL×safe по исчерпанию ресурсов. Выход: windup-cancel сигнатуры
нет; глазная приёмка юзера: на low-HP бот ЛИБО дерётся/добивает, ЛИБО идёт в одну сторону,
ЛИБО стоит с целью (реген/руна) — никаких «стоит и грустит».

### 2.6 П3-B — line-by-line план катовера (Fable-high 07.07, по HEAD 6da86e5)

**Статус пред-условий:** срез 1 (Owner+эпизоды, 543e2a0) и срез 2 (emerg/fwd-pull регистрируются,
6da86e5) в LIVE. Это план ЕДИНСТВЕННОГО опасного коммита П3. Один коммит + git-revert откат.

**Архитектурное решение (где исполняется soft):** Owner-движение НЕ бежит пре-арбитром —
пре-арбитр (`Owner.Urgent`, :963-972) обрабатывает ТОЛЬКО critical-полосу; soft-действия
исполняются ЧЕРЕЗ desire-кандидатов recover/safety (иначе soft-отступление крадёт тик у
lane work — ровно то, от чего П4-капы). Пост-арбитрные low-HP вызовы умирают.

**Катовер по точкам:**
1. **safety-кандидат** (mode_laning :898-901): убрать ActiveLowHp-ногу → остаются
   CreepHitReact/DamageUnstuck. ⚠️ ОБЯЗАТЕЛЬНО одновременно убрать `lowHpRetreatReady`
   из `safetyCanAct` (:811) — иначе safety-десир выигрывает тики, на которых не может
   действовать → empty_action спайк.
2. **recover-кандидат** (:939): action = `Recovery.Owner(ctx)` напрямую (вместо ThinkIfAllowed).
3. **EmergencyRetreat** (recovery.lua:296): УДАЛИТЬ + вызов :1036. Покрытие: hp<0.25 =
   critical-полоса пре-арбитра; parting-shot (AbilityHarass по врагу ≤800) переносится
   внутрь critical-входа Owner.
4. **ForwardLowHpPullback** (recovery.lua:317): УДАЛИТЬ + вызов :1042. Покрытие: вражеская
   половина ⇒ threatened=true форсирован; hp<0.45=activeRecovery ⇒ recover-десир активен.
5. **ActiveLowHp** (recovery.lua:~190-290): растворить в Owner.softAction():
   - bottle-ветка — УДАЛИТЬ (дубль survive item-слоя, bottleIfUseful);
   - low-hp-fight (враг в рендже, hp≥0.32) и low-hp-creep (hp≥0.35 / 0.28+creep-dmg) —
     перенести КАК ЕСТЬ (семантика safe-CS уточняется в П3-C, не тут);
   - safe-step / back / watch-step / committed-hold → эпизод-ядро: ОДНА committed-точка
     (SafeRetreatTowerLoc), hold за якорем с danger-чеком (логика :158-180 сохраняется
     1:1 — инвариант under-tower), re-issue к той же точке тихий ≤1/с.
6. **regenLane** (survive.lua:403): УДАЛИТЬ. Условие (regen_lane & hp<0.45 & враг≤900) ≡
   SOFT×threatened → recover-десир → Owner.
7. **heal-pullback** (survive.lua:386): УДАЛИТЬ (то же покрытие).
8. **LowHpHoldState** (recovery.lua:~340): заменить чистым `Owner.Context(ctx)` →
   (band, threatened, lowHpHold) БЕЗ диагов (`low-hp-limit` умирает). ⚠️ Потребители
   `aib_lowHpHold`/`ctx.lowHpHold`: fwd-suppress (mode_laning) и UphillReposition
   (combat:188) — формула lowHpHold (hp<rules.low_hp_hold=0.45 & свой T1<900) сохраняется
   ВНУТРИ Context 1:1.
9. **Стейт-чистка:** aib_lowHpActiveLast/aib_lowHpHoldLast/aib_emergLast/aib_fwdPullLast/
   aib_regenMoveLast/aib_pullbackLast → один `aib_recoveryEpisode`.
10. **НЕ трогать в П3-B** (scope): post-fight step-back (survive:495, enemy-gone реген —
    в П3-C), fountainRecovery, fallback-цепь (buy/TP/walk/rune/xp-hold — уже внутри
    surviveThink), item-слой целиком.
11. **Tools В ТОМ ЖЕ КОММИТЕ:** postmatch.py — добавить счёт `recovery-owner` эпизодов;
    scorecard.py — старые JITTER_KEYS оставить (старые логи), добавить информационную
    метрику эпизодов БЕЗ порога (порог ставим после 2 матчей данных).

**Приёмка П3-B (1 матч):** `low-hp-back/safe-step/watch-step` = 0; эпизодов ≤~15;
чередования `state-desire-fight/safety` на соседних тиках нет; freeze=0; stationary≤2;
LH не хуже; empty_action ≤80 (следить — п.1 меняет safetyCanAct).

### 2.6.1 Ре-пин П3-B.2 после merged-election (Fable 19.07, код HEAD 140aaa5)

План §2.6 писан по последовательному хвосту (6da86e5). После П3-B.1 (e0bc99f) и П1-A
фазы A (a2bc9a9) точки катовера сменили форму. Сверено по живому коду:

**Уже СДЕЛАНО, из плана вычеркнуть:** п.1 целиком (П3-B.1: safety-нога снята,
lowHpRetreatReady удалён из safetyCanAct); п.11 наполовину (postmatch считает
recovery-owner эпизоды).

**Точки катовера — новая форма (все = tail-кандидаты, НЕ вызовы):**
- **п.3/п.4:** EmergencyRetreat/FwdPullback = `tail()` кандидаты mode_laning **:1101/:1102**
  (скоры 45/44) + функции recovery.lua **:318/:342**. Удаление = снять обе tail-строки +
  функции. Скоры 45/44 освобождаются — дыры в ladder допустимы, НЕ перенумеровывать.
- **п.5:** ActiveLowHp зовётся из кандидата `low-hp-hold` **:1105-1117** (43.2). Растворение
  сносит весь кандидат. ⚠️ **rune-commit yield guard (recovery.lua:230, валидирован 3957992)
  ОБЯЗАН пережить растворение** — перенести в Owner-soft-вход дословно.
- **п.8:** LowHpHoldProbe УЖЕ существует (recovery.lua:370, чистый — фаза A сделала
  половину точки). Катовер: Probe+LowHpHoldState → `Owner.Context`; потребители:
  facts-builder **:1053** (runtimeCtx.lowHpHold + локальный aib_lowHpHold для fwd-suppress)
  и UphillReposition (ctx.lowHpHold) — формула 1:1 внутри Context; `low-hp-limit` умирает
  (заметка в scorecard).
- **п.2 УСИЛЕН (урок 8903952032):** recover-кандидат.action → Owner-soft, И ОДНОВРЕМЕННО
  `recoverCanAct` (mode_laning **:871**, 3-рукая эвристика) заменяется на новый чистый
  **`Recovery.OwnerCanAct(ctx)`** — пробник обязан зеркалить реальные способности Owner.
  Дрейф пробника = класс AFK/твитч (36с AFK, 140aaa5). Кап-семантика СОХРАНЯЕТСЯ:
  hp_gate_no_action, recoverCapFloor=0.25, капнутый проигрывает safe-cs(56).
- **п.6/п.7 + destination (находка 09.07):** ПЕРЕД удалением regenLane (survive:403) /
  heal-pullback (survive:384) портировать **xpRecoveryLoc (survive:54)** в Owner:
  дест эпизода = xpRecoveryLoc для soft-полосы, SafeRetreatTowerLoc для caution/critical.
  Наивное удаление = регресс точки регена (фарм-потеря, против инв. §2.4-6).
- **early-low пре-арбитр (:1014) ОСТАЁТСЯ в этом срезе** — обоснование кап-floor=0.25
  опирается на него (суб-danger ретрит бежит пре-арбитром). Унификация — П3-C.

**Приёмка П3-B.2 (1 матч), поверх §2.6:** hp_gate_no_action продолжает фаерить;
empty≤80; AFK-окон W3/W5-класса нет глазом; reason=rune_commit жив; LH/фарм не хуже
(проверка xpRecoveryLoc-порта).

**Якоря головы для П1-B (ре-пин 19.07, HEAD 140aaa5):** true-emerg :1006 · emergency-low
:1007 · urgent kill/interrupt :1008-1012 · early-low :1014 · Owner(critical) :1015 ·
prewave :1016 · standoff :1017 · merged-election :1027+. Порядок фазы B: urgent-кандидаты
по таблице §3.6, скоры монотонны этому порядку (тот же принцип, что фаза A).

### 2.7 Связь с П1 и порядком работ

Порядок **П1-A → П3 → П1-B/C** (§3.8) сохраняется, НО П3-A/B не зависят от П1-A — можно
параллелить, если П1-A задержится (Owner — внутренняя перестройка recovery, П1-A — обёртка
хвоста тика; пересечение только в удалении :1007/:1013/:1027, координировать в П3-B).
После П1-B Owner = единственный кандидат recovery-полосы (100-130). Windup-гейт П3-C —
частный случай П1 §3.5; П1-C генерализует его на все move-классы.

**Критерий выхода П3 целиком:** stationary>10s при живом враге ≤2/матч (2 матча подряд);
freeze=0 держится; петель fight↔safety нет; windup-cancel нет; jitter_sum: low-hp-вклад
→ эпизоды (≤15/матч); глазная приёмка юзера по смотрибельности low-HP.

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

**⚠️⚠️ ЛОВУШКА ТЕЛЕМЕТРИЧЕСКОЙ ЭКВИВАЛЕНТНОСТИ (найдено 06.07, Opus, при чтении purity):**
не все факты можно посчитать eager в билдере — часть имеет диаг-САЙД-ЭФФЕКТЫ, и eager-вызов
сломает сигнатуру, по которой валидируется фаза A. Конкретно:
- `LowHpHoldState` (recovery.lua:262) пишет `Style.DiagRL(bot,"low-hp-limit",3)` на :269 —
  сейчас вызывается ЛЕНИВО (:1027, только если блоки выше уступили). В билдере фактов
  сработает на бОльшем числе тиков → `low-hp-limit` count вырастет БЕЗ изменения поведения.
- Аналогично проверить КАЖДЫЙ выносимый факт на `Diag/DiagRL/Intent/Blocked/TickOwner/
  Action_*` перед выносом. Чистые (можно eager): `GetBestLastHitCreep` (creeps.lua:9,
  только выбор), `csAllowed/csDistNow/needMove` (арифметика по bot-state), `deathSurvive`
  (GetHeroDeaths+GetHP), lane-front `target_loc` (GetLaneFront*).
**Правило:** факт с диаг/экшн-сайд-эффектом остаётся ЛЕНИВЫМ внутри canAct()/action()
кандидата; в билдер фактов идут ТОЛЬКО чистые чтения. Иначе диф сигнатур vs базлайн
покажет ложный регресс (или замаскирует настоящий).

**ПРЕДУСЛОВИЕ ФАЗЫ A: базлайн-матч на неизменённом HEAD ДО рефактора** — критерий фазы
(«tick-owner/jitter/LH/empty_action не хуже базлайна») требует зафиксированных базовых
чисел. Первый матч сессии = двойного назначения: валидация canonical_farmer + захват
базлайн-сигнатур для фазы A (scorecard + один `grep -c tick-owner`/`low-hp-limit`).

### 3.6.1 Ре-пин реестра (Fable-high 09.07, код HEAD e0bc99f, файл 1263→1302 строк)

Якоря §3.6 сверены заново после concede/hpBehind/ranged-spacing/secure-LH/П3-B.1.

**Голова тика:** true-emergency :986 · emergency-low :987 · kill-lock :990 ·
heal-interrupt :992 · early-low :996 · Recovery.Owner (critical-lock, П3-A) :997 ·
prewave :998 · standoff :999 · desire-арбитр :1000. HandleRespawn :187 (вне арбитра).

**Хвост тика:** safe low-hp CS :1001-1012 · HeroOverCreep :1026 · cs-inrange :1025-1034 ·
idle-heal :1036 · EmergencyRetreat :1040 (→П3-B.2) · FwdPullback :1046 (→П3-B.2) ·
deathSurvive :1050-1051 · EmergencyKillPriority :1056 · LowHpHold/ActiveLowHp :1060-1062
(→П3) · UphillReposition :1066 · **RangedMeleePackSpacing :1073 — НОВЫЙ, в §3.6
отсутствует** · HarassAndChase :1082 · HandleCreepWork :1084 · AbilityHarass :1121 ·
fwd-position :1125-1205 · VisualHoldHeartbeat :1209 · VisualAFK :1210 ·
LaneLineFallback def :689 вызов :1211 · AntiIdleGlobal :1213.
Меж-стадийные записи: csAllowed/needMove :1022-1024 → runtimeCtx :1080-1081 (+ аргументы
HandleCreepWork :1092-1094) · deathSurvive :1050-1051 · lowHpHold :1061.

**Чистота (ловушка §3.6) — перепроверено:** `GetBestLastHitCreep` (creeps.lua:9-30)
чист ✓; csAllowed/needMove/deathSurvive чисты ✓; `LowHpHoldState` ПО-ПРЕЖНЕМУ пишет
`low-hp-limit` (recovery.lua:351) — только ленивый ⚠️; НОВОЕ: `noteRecoveryEpisode`
(recovery.lua:168) пишет Intent + эпизод-стейт — весь ActiveLowHp остаётся ленивым в
action() ⚠️; `recoveryThreatened`/`classifyBand` чисты ✓.

**⚠️ НАХОДКА 1 — скоры §3.6 НЕ монотонны текущему порядку хвоста (ломает эквивалентность
фазы A).** Два инверта: (a) `EmergencyKillPriority` = desire 122, но в коде бежит ПОСЛЕ
lanework-блоков (:1056 после safe-cs/cs-inrange/idle-heal) — со скором 122 он начнёт
преемптить CS, которого сейчас уступает; (b) `UphillReposition` (position 28) бежит ДО
HarassAndChase (lanework 42) — полосная модель инвертирует их, и харасс отберёт тики,
где сейчас бот сначала выходит с лоуграунда (реинтродукция lowground-трейдов).
**Решение для фазы A:** скоры СТРОГО монотонны текущему порядку (EmergencyKill ≈ 44,
Uphill ≈ 43 — временно lanework-диапазон); подъём EmergencyKill к 122 (слияние с
KillLock) и спуск Uphill в position-полосу = осознанные поведенческие изменения фазы C,
каждое со своим матчем. Полосная таблица §3.2 — целевое состояние, не фаза A.

**⚠️ НАХОДКА 2 — RangedMeleePackSpacing двуликий:** самостоятельный блок :1073 И колбэк
внутри HandleCreepWork (:1097). При обёртке кандидатом оборачивается ТОЛЬКО вызов :1073;
колбэк остаётся внутренностью creep-work action() — иначе двойное владение тиком.

**Базлайн фазы A:** первый принятый матч на HEAD `3957992` (rune-guard) — точный пред-P1
код; захватить `grep -c tick-owner` + `low-hp-limit` из него при старте фазы A.
(Ранее назначенный 8888664145 остаётся резервом.)

**ДОПОЛНЕНИЕ К НАМЕРЕННОМУ ИЗМЕНЕНИЮ ФАЗЫ A (Fable 09.07): canAct-капы для ВСЕХ десиров
(siege + recover).** P4-контракт покрыл safety/fight, siege и recover — дыры.
- **siege** (матч 8888743934): побеждает с гистерезисом, удар гейтится (нет волны/healing)
  → 8× empty-win + edge-step↔lane-line пейс у вышки. `siegeNoAction` ≈42 + чистый probe
  (wantsSiege & hpFloor & alliedTank|always & not healing-block & wave/dist — только
  чтения, ловушка §3.6). Сигнатура: `reason=window_no_action`.
- **recover** (матч 8888784979 t=118-123): D на 40-55% за якорем ПОСЛЕ файта — recover:92
  выигрывает с гистерезисом и возвращает empty 2×+ (твитч под вышкой). Существующий
  `recoverUseless`-гейт (:934) требует «не было урона» — пост-файт кейс мимо. `recoverNoAction`
  ≈44 + probe: есть ресурсы (AIB_HasRecoveryResources) ИЛИ не за якорем ИЛИ threatened —
  иначе кап. Сигнатура: `reason=hp_gate_no_action`.
Без капов объединённые выборы фазы A некапнутыми десирами крадут тики у CS хуже текущего.

**SCORE-LADDER ФАЗЫ A (Opus 09.07, готово к имплементации — order-preserving к текущему
порядку хвоста; band-таблица §3.2 = ЦЕЛЬ, подъёмы/спуски = фаза C):**
last-hit 140 · desire(safety/power-rune/fight/recover/siege) 66-135 как есть · safe-cs 56 ·
HeroOverCreep 52 · cs-inrange 50 · idle-heal 46 · EmergencyRetreat 45 · FwdPullback 44 ·
**capы: recoverNoAction 44 / safetyNoAction 44 / siegeNoAction 42 / fightNoAction 40**
(ниже CS 50-56, выше harass) · EmergencyKillPriority 43.5 · UphillReposition 43 ·
RangedMeleePackSpacing(только standalone-блок :1073) 41 · HarassAndChase 40 ·
HandleCreepWork 38 · AbilityHarass 36 · fwd-position 22 · **VisualHold 20** (сохраняет
порядок кода visual→laneline) · LaneLineFallback 18 · VisualAFK 8 · AntiIdleGlobal 2.
3 решения (Opus): (1) интерливинг capов/order-preserving в 40-44 разведён (43.5/43 vs
42/44); (2) VisualHold=20 не 8 (в коде идёт ПЕРЕД lane-line); (3) EmergencyRetreat/
FwdPullback обёрнуты order-preserving (умрут в P3-B.2, пока полнота).
Facts-builder (чистые, до элекции): csAllowed/csDistNow/needMove, deathSurvive,
lowHpHold(через Recovery.Context — low-hp-limit НЕ eager), hitCreep/csSoon, target_loc.
Ленивые (внутри action): LowHpHoldState-диаг, noteRecoveryEpisode, все Action_*.

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
