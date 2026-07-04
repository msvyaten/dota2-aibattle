# AIBattle × Dota 2 — Handoff Package

> Продуктовый пакет передачи. Цель: техкоманда читает этот файл и понимает,
> что за продукт, что доказано, как устроен движок, что болит и что делать дальше.
> Собрал: Claude (Windows-сторона), 2026-07-04. Сессионная история — `HANDOFF.md`,
> текущее состояние движка — `CURRENT.md`, PM-взгляд — `PM_REVIEW.md`.

---

## 1. Что за продукт и что уже доказано

**Тезис:** пользователь описывает стратегию текстом → LLM превращает текст в конфиг
(dials + rules + item/skill build) → бот-движок исполняет конфиг в реальном матче
Dota 2 (1v1 mid, SF vs SF) → поведение на экране измеримо отличается.

**Доказано матчами (пруфы в `HANDOFF.md` §3):**
- Пайплайн промпт → ChatGPT → конфиг → поведение: ✅
  (8838539380: Pusher towerDmg 7926 vs Ganker 159 — один движок, разные конфиги).
- Bettability: A (Duelist) vs B (Farmer) 3:1 на 8 матчах — исход предсказуем из конфига.
- 8 из 12 диалов и 6+ rules имеют изолированные матч-подтверждения (матрица в §3 HANDOFF).

**Что НЕ доказано / открыто:** `rune_control` (подавлен laning-арбитражем в 1v1),
`farm_focus` (только косвенно), стабильная смотрибельность матча (см. §5).

---

## 2. API продукта: схема конфига

Конфиг — это интерфейс между LLM и движком. Всё остальное — заменяемая подложка.

**12 диалов** (0..1): `harass_desire, farm_focus, forwardness, retreat_caution,
rune_control, execute_threshold, ability_aggro, gank_desire, push_desire,
defend_desire, ward_desire, roshan_desire`.

**9 rules** (enum, активный канон): `respawn_behavior, pregame_behavior, dive_policy,
low_hp_behavior, healing_style, ability_usage, creep_wave_priority, hero_priority,
deny_policy`. В схеме также валидированы: `smoke_usage, buyback_policy`.

**Плюс:** `item_build` (список предметов на героя), `skill_build`.

Канонические конфиги: `bots/Customize/canonical_*.lua` (brawler/farmer/ganker/pusher).
Live-байндинги: `playstyle_radiant.lua` / `playstyle_dire.lua` (однострочный require канона).

### ⚠️ Разрыв: LLM-генератор отстал от схемы
`backend/generate_playstyle.py` знает только **6 диалов из 12** (`DIAL_KEYS`) и
**1 rule из 9** (`respawn_behavior`). Половина поверхности продукта недоступна LLM.
Закрыть этот разрыв = задача с максимальным продуктовым ROI: расширить `DIAL_KEYS`,
whitelist rules и `system_prompt.txt` до полной схемы. Движок трогать не нужно.

---

## 3. Движок: как устроен тик

Оркестратор: `bots/mode_laning_generic.lua` (~950 строк). Поведение — в модулях
`bots/FunLib/aibattle_*.lua` (владельцы перечислены в `ARCHITECTURE.md`).

Порядок тика (13 стадий, детально в `CURRENT.md`):

```
1-2. tempo-гарды (respawn/pregame/dive/death-window) + urgent (kill-lock, channel-interrupt)
3-4. recovery-гейты и critical-recovery lock
5.   prewave-дуэль / pre-creep standoff
6-7. TOP-DESIRE АРБИТР: safety / power-rune / fight / recover / siege
     (скоринг в aibattle_laning_policy.lua, прогон в aibattle_laning_arbiter.lua;
      только победитель исполняет action; empty_action => следующий кандидат)
8-10. last-hit, harass, CS-walk, push/deny/siege, spacing, fwd-position
11-13. visual-hold, lane-line-fallback, anti-idle
```

Слои конфигурации:
- `rules`/`dials` — LLM-facing (см. §2);
- `aibattle_constants.lua` — инженерные пороги (дистанции, кулдауны, HP-банды);
- `aibattle_laning_policy.lua` — превращает rules/dials/constants в решения.

### Телеметрия (актив, забирать как есть)
Каждое решение логируется: `intent=<key> family=<fight|farm|rune|recover|safety|siege>`,
`blocked=<key> reason=<why>`, `tick-owner`, `top-arbiter winner/losers`.
Анализатор: `python tools/match_stats.py [--brief] <matchid>` — KDA/LH, intent-семейства,
арбитр-статистика, empty_action, stationary-спаны, bottle-статистика, `fix_candidate`
(эвристические подсказки багов). Это готовый инструмент отладки поведения.

### Деплой
`tools/deploy.bat [code|playstyle|all|general]` → live Dota scripts.
`tools/check_all.py` — контроль дрифта манифестов (падает, если runtime-модуль не покрыт).
Лобби: Solo Mid, читы ON, `-condebug`, лог `console.<matchid>.log`.

---

## 4. Четыре структурные проблемы и решения

Нумерация закреплена, ссылки на неё — в коммитах и обсуждениях.

### П1. Арбитр не владеет тиком целиком
Desire-арбитр — стадия 6 из 13. До него бьют kill-lock/critical-recovery/prewave,
после — last-hit/harass/fwd-position/lane-line-fallback/anti-idle. Осцилляции — это
пары хэндлеров по разные стороны границы арбитра, дерущиеся за тик на чередующихся
тиках (наблюдались: uphill-reposition ↔ lane-line-fallback; critical-lock ↔ low-hp-back).

**Решение (техкоманда, средний размер):** втянуть стадии 1-5 и 8-13 в арбитр как
кандидатов с фиксированными приоритетными полосами: urgent≈150+, recovery≈100-130,
desire≈60-120 (как сейчас), position/fallback≈10-30. Один арбитр = один владелец тика,
пары исчезают по построению.
**Критерий выхода:** ≥95% тиков имеют ровно одного tick-owner; осцилляционных пар
в tick-owner-сэмплах нет в 2 матчах подряд.
**До того:** П2 снимает большую часть симптомов дёшево.

### П2. ~55 независимых точек движения → дерганье
55 вызовов `Action_MoveToLocation` по laning-модулям, у каждого хэндлера свой кулдаун
(`aib_*Last`). Дерганье — эмерджентное поведение N независимых регуляторов на одном
актуаторе. Рабочий паттерн уже изобретён в коде трижды (critical-recover dest/until,
pre-duel back dest/until, rune staging target): **committed destination** — цель +
окно фиксации, в котором другие хэндлеры не перехватывают движение.

**Решение (делаем здесь, малое):** модуль `aibattle_motor.lua` (~60 строк):
```lua
Motor.Claim(bot, owner, dest, ttl, prio) -- true, если свободно/тот же owner/prio выше
Motor.Owner(bot)                          -- активный владелец или nil
Motor.Release(bot, owner)
```
Хэндлер, проигравший клейм, логирует `blocked=motor reason=owned_by:<owner>` и уступает.
Мигрировать ТОЛЬКО участников осцилляционных пар: low-hp-* кластер, lane-line-fallback,
uphill-reposition, critical-recover, prewave-duel-back. Остальные 40+ точек не трогать.
**Критерий выхода:** сумма `low-hp-nudge + low-hp-back + lane-line-fallback +
uphill-reposition` ≤ 60/матч (сейчас ~270-360) в 2 матчах подряд.

### П3. Low-HP поведение размазано по ~6 владельцам
`ThinkIfAllowed, ActiveLowHp, CriticalLock, EmergencyRetreat, ForwardLowHpPullback,
LowHpHoldState` + recovery в `survive.lua`. В арбитре и safety-, и recover-кандидаты
в итоге зовут один и тот же `ActiveLowHp(retreatOnly=true)` — выбор арбитра между ними
часто косметический (петли fight→safety→fight в логах). Все жалобы «дергается/АФК под
вышкой на лоу хп» — из этого кластера.

**Решение (после Gate 1, одна scoped-задача):** один владелец `Recovery.Owner(ctx)`
с тремя HP-полосами: critical <25% → committed retreat к safe-якорю (через Motor);
soft 25-45% → hold за якорем + безопасный CS, если крип в радиусе; 45-55% → lane work
с осторожностью. `EmergencyRetreat`/`ForwardLowHpPullback` — роутить через него, не звать
напрямую. Safety-кандидат перестаёт дублировать recover.
**Критерий выхода:** stationary-спанов >10s при живом враге рядом ≤ 2/матч;
low-hp jitter-метрика из П2 держится.

### П4. Контракт кандидата арбитра (empty_action)
Кандидаты скорятся без проверки «смогу ли действовать»; победитель возвращает false →
`empty_action` → провал к следующему. Уже приемлемо (66-74/матч против базлайна 278/212).

**Решение (только документировать):** контракт — action обязан вернуть false ДО
потребления тика, если действовать не может; желательно дешёвый `canAct()` при скоринге.
За нулём не гнаться — perfectionism trap.
**Критерий:** empty_action ≤ 80/матч. Выполнен.

### Порядок работ
```
Gate 0 (VScript-шум) → Gate 1 (сравнение с phase-22) →
П2 Motor (здесь, ~1 день) → П3 low-HP owner (здесь, scoped, критерий выхода жёсткий) →
П1 полный арбитр + П4-контракт (техкоманда) →
LLM-генератор до полной схемы (§2 — можно параллельно, движок не трогает)
```

---

## 5. Скоркард смотрибельности (критерий приёмки матча)

Считается из `match_stats.py`. Матч прошёл скоркард → поведение принято,
простыня `fix_candidate` НЕ разбирается. Это защита от бесконечной полировки
(см. правило процесса в `PM_REVIEW.md`).

| Метрика | Базлайн (8874174746) | Порог приёмки |
|---|---|---|
| AIB ERR / VScript runtime errors | 0 / 57 | 0 / 0 |
| LH обеих сторон | 18 / 32 | > 0 (норм ~25+/10мин) |
| `empty_action` | 66 / 74 | ≤ 80 |
| stationary-спаны >10s при враге рядом | ~8-10 | ≤ 2 |
| jitter: `low-hp-nudge+back+fallback+reposition` | ~270-360 | ≤ 60 |
| бутылка пустая, % сэмплов | 93% / 62% | ≤ 50% |
| исход | смерть вышки | kill/fight-финиш желателен |

---

## 6. Известные открытые баги (не блокеры, с пруфами)

- ✅ ДИАГНОСТИРОВАНО (Claude, 2026-07-04) — VScript-шум, блокер Gate 0. Два класса:
  1. `Script Runtime Error: error in error handling`×20 — КОРЕНЬ:
     `ability_item_usage_generic.lua:8319-8322` (`UseGlyph`): `GetTeamMember(2):IsBot()`
     без nil-гарда. В 1v1 слоты 2-5 кикнуты → GetTeamMember(2)=nil → index nil.
     Механика: стартовый КД глифа истекает на 3:00 → с t=180 условие
     `GetGlyphCooldown()>0` перестаёт отсекать → краш каждые 2.0s (троттлинг
     `BuybackUsageThink`, строка 8405), оба бота в одном кадре (=пары), движок
     глушит идентичный спам после 10 повторов (=ровно 20 ошибок, тишина после 3:20).
     Подтверждено в 4 матчах: burst строго t=180-200 (8874174746, 8874134176,
     8874100152, 8869519932). «error in error handling» вместо текста — потому что
     движковый error-хэндлер зовёт debug.traceback, а debug в бот-песочнице урезан.
     ФИКС (Codex): nil-гард на GetTeamMember(2..5) в UseGlyph (nil-член = пропустить).
     Бонус: тот же паттерн в `jmz_func.lua:4613` (GetCoresTotalNetworth) — мёртвый
     код, никем не вызывается, можно не трогать.
  2. `invalid index`×37-38 — НЕ баг бота: `CLocalize::FindSafe failed to localize:
     'invalid index'` — клиентский UI-шум от пустых (кикнутых) слотов лобби.
     Первые строки на 11:41:09 — до загрузки бот-скриптов. Исключить из подсчёта
     ошибок Gate 0 (match_stats/критерий приёмки), чинить нечего.
  3. `Item can't be used from stash` — уже 0 в 8874174746 (закрыто e28c2a5/f4e59a4).
- KillLock целится в мёртвого врага (`ehp=-66600`, нет `IsAlive()`-гейта) — 8874134176.
- Pregame uphill-петля у Dire: `pg-duel-uphill-back`=179 за прегейм (8874174746);
  фикс f4e59a4 помог Radiant-стороне, Dire-сторона крутится.
- Бутылка: Radiant 93% сэмплов пустая; emergency-staging окно сужено до 20s (d9e593c),
  проверить матчем.
- `rune_control` не изолирован в 1v1 (laning desire=1.0 подавляет rune-режим).

## 7. Мандат Codex — что делать СЕЙЧАС

> Codex: этот блок — твоя рабочая очередь. Остальной документ — контекст.

**Сейчас (до зачёта Gate 0):**
- ЕДИНСТВЕННАЯ задача: убрать VScript-шум (`Script Runtime Error`, `invalid index`)
  до нуля. Один прицельный фикс → матч → проверка. Поведенческие фиксы НЕ брать,
  даже очевидные — записывай их в `CURRENT.md` watchlist.
- `fix_candidate` из матчей до зачёта Gate 0 — игнорировать, если не про краши.

**После Gate 0 + Gate 1 (сравнение с phase-22, играет Windows):**
- П2 Motor (§4): реализация по дизайну из этого файла. Мандат: 1 новый модуль
  `aibattle_motor.lua`, миграция ТОЛЬКО 5 перечисленных хэндлеров, deploy/check
  манифесты обновить. Критерий выхода: jitter-метрика ≤ 60/матч, 2 матча подряд.
  Вышел за критерий — стоп, не расширять миграцию без нового мандата.
- Затем П3 (low-HP owner) — отдельный мандат, не начинать вместе с П2.

**Не твоё (не трогать):** конфиги `Customize/canonical_*` / `playstyle_*`;
LLM-генератор `backend/` (закрывается параллельно, зона Claude);
П1 (полный арбитр) — уходит техкоманде, не начинать.

## 8. Процессные правила (выучены дорого)

- Рефакторинг = отдельная задача с мандатом И критерием выхода. Фоновый рефакторинг
  под телеметрию `fix_candidate` = бесконечная полировка (см. PM_REVIEW, неделя 20-26.06).
- Один прицельный фикс на провал критерия, потом повторный матч. Не дробить движок.
- Чистота кода ≠ поведение на экране. Приёмка — только по скоркарду §5.
- Конфиги (`Customize/canonical_*`, `playstyle_*`) — зона Claude/стратегии;
  runtime-код — зона движковой роли (Codex). Не смешивать в одном коммите.
