# AIBattle Backlog

> **Language: Russian.** Working queue. English summary of open work: `docs/STATE.md`.

Только актуальные задачи. Полная форензика и закрытые пункты до 01.08.2026 лежат в истории git:
`git show ae2604d:docs/BACKLOG.md`. Текущий HEAD/LIVE всегда получать командой:

```powershell
python tools\pre_match_state.py
```

## Следующий Gate

⛔ Перед разбором брать долг билдов: `git log <билд-из-лога>..HEAD`.

🧊 **Заморожено до матчапа с Джаггернаутом:** нога подхода к хилящему варду — упирается в
ДОСТИЖИМОСТЬ, не в прицеливание (`seen=18-26`, `out-of-reach=18-25`). На SF варда нет.

Читать `python tools/postmatch.py <id>` сверху вниз; панели написаны под конкретные правки:

- `runtime_errors`/`aib_err` = 0 и last hits > 0 у обеих сторон — всегда первым;
- **`sustain:`** — `bought`/`drunk` ВВЕРХ, `budget_cap` ≈ 0, `stand-and-regen` ВНИЗ;
- `deny probe`/`deny kill-test` — `deny-act` ВНИЗ при `dn` не ниже;
- `tower pokes` — `backoff` > 0, `parked` вместо пустого владения, commit/terminal ДЕРЖАТСЯ;
- `buy loop` — `stalled` остаётся 0; `anti-idle` — только пара `enter`/`idle`.

До этого матча не складывать новые изменения владельцев тика.

## Структурный Порядок

1. **P1-B — urgent head в общий арбитр.** KillLock, HealInterrupt и остальные ранние
   short-circuit решения должны конкурировать в одной election, сохраняя текущие приоритеты.
2. **P3-B.2 — один destination-aware Recovery.Owner.** Убрать параллельные low-HP movers,
   сохранив `regen_lane` и XP-safe позицию.
3. **P3-C — семантика recovery.** Windup gate, безопасный CS в SOFT band, достижимая руна,
   эскалация в fountain только когда lane recovery действительно невозможен.
4. **P1-C — упрощение commit/suppression.** Один refractory/commit механизм, Motor v1 retire,
   anti-idle перестаёт играть в Dota и остаётся только сторожем.

Каждый пункт разбивать на один наблюдаемый срез и матч. Мандаты и критерии находятся в
`docs/SPECS.md`.

## Пустые Победы `fight` — Главная Находка 28.08 (по 5 логам, игра не нужна)

**Разрыв предикатов.** `fightCanAct = enemy ~= nil and not concedeLane and fightReach` — ТРИ
условия против **38 точек отказа** в действии; 19 инструментировано 28.08, немых 7 из 38
(намеренно). Панель `postmatch.py` печатает долю названных причин: 40→80% R, 33→52% D.
`c2ed8ac` добавил четвёртое условие (`uphill`), Codex — пятое (`abilityReady`). Осталось ~33.

⛔⛔ **`empty_action` — НЕ сожжённый тик** ([aibattle_laning_arbiter.lua:92-128]): арбитр
проваливается вниз, тик берёт кандидат ниже, а хвостовые уступают молча по замыслу. Цена в том,
что СЧЁТ ЛЖЁТ — выборы берут со 124, работу делают с 40. Настоящее пустое владение это
`return true` без действия: он обрывает лестницу, до анти-AFK сторожей (8 и 2) тик не доходит.
**Следствие: разделение `fight` чинит телеметрию, а не поведение — не начинать рефактор под
этим предлогом.** ⚠️ Расширение капа `mutual low` не создаст: `low_hp`/`uphill`/`unsafe` —
законные отказы. Глубже: конфиги не создают ситуаций, где обе стороны берут риск.

⛔ Метод `--never-fired`: вердикт о КОНКРЕТНЫХ матчах, всегда перепроверять (03.08 три его
пункта оказались неверны на свежих логах).

## Приёмка Правок 29.08 (сигнатуры следующего матча)

- **`c2ed8ac` uphill в `fightCanAct`:** `hero-contact/uphill` уходит из панели причин.
- **`d377da7` wave-watch:** `wave-watch-step` до единиц, отношение с `wave-watch-atk`
  переворачивается, `yoyo` у R обратно к ~2, появляется `reason=not_finishable`.
- **`200ccce` kill-lock/MayDive:** `chase_into_tower` уходит из причин **при неизменных
  смертях**. Смерти выросли → лицензия шире, чем `finish_only`, спрашивать `MayDive` про
  КОНКРЕТНОГО врага.
- **`4b9b3bf` creep-aggro:** пара `creep-aggro-hero-yield`/`-hit`, обе плейн, одна шкала.

## Открыто После `8972598364`

- **Фонтан пешком.** `blocked=fountain-floor reason=heal_in_hand` держит владельца похода вне
  тика, а ТП домой и обратно принадлежит ИМЕННО ему → бота ведёт `anti-idle:2`. Из 5 походов
  один `fountain-tp-lane`. Панель уже печатает `heal_in_hand: 4 (wants 0)`.
- **Руны: `nearest=inf`** ×22 R / ×5 D. Скан смотрит только `RUNE_POWERUP_1/2` и требует
  `RUNE_STATUS_AVAILABLE` (то есть видимость). ⭐ R за рунами ХОДИЛ (`phase=commit` 1970→582) и
  дважды опоздал (`gone`), у D скан пуст при том же коде. Почему — НЕ диагностировано.
- **У D `kill pressure` = 0s в 0 окнах** за весь матч при 157с (29%) на низком hp.


## Открыто После `8926148548`

- **Взаимная уступка лечения и фонтана.** Одним тиком `blocked=heal-item
  reason=fountain_trip_committed` и `blocked=fountain-floor reason=heal_in_hand`: питьё ждёт
  похода, поход ждёт питья, не действует никто, бот уходит из лейна на 15с с салвом в сумке.
  Три раза за матч (t=796/855/931), та же форма что `b7209fd`. Кто перестаёт быть вежливым —
  решение юзера.
- **⛔ УТОЧНЕНО 28.08: тракт `item_build` готов, а ЖИВЫЕ конфиги пусты.** Промпт просит,
  `style_schema.py` знает, `aibattle_style.lua:340` парсит — но `canonical_gemini`,
  `canonical_grok`, `canonical_deepseek` содержат НОЛЬ `item_build` (сгенерены до правки).
  Отсюда `buy loop: saving x66 target=item_lifesteal cost=900 gold=196`. Регенерация —
  решение юзера: она меняет то, что производят модели, т.е. сам предмет замера.
- **Какая нога `anti-idle` уводит бота ВПЕРЁД на низком HP.** `8926148548` t=266: `recover`
  выиграл со счётом 102 и вернулся пустым, тик упал на `anti-idle:2`, бот шёл к врагу с 35%
  до 8% HP. Матч проигран здесь. Ноги считаются `DiagRL(5s)` — инструментировать, не гадать.

## Поведение

- ⭐ **`ability_aggro` выведен 28.08 — и его надо ВЕРНУТЬ переработанным.** Он гейтил только
  `Style.AbilityHarass`, где SF-записи имели `type = "point"` (`82aa8ee`, 10.06), а Shadowraze
  точку не берёт → `invalid order (101)` на КАЖДЫЙ каст: 293 за `8968270421`, 1:1 со счётчиком
  пути, 188 матчей. Рейзил всегда вендорный `hero_nevermore.lua` (`ActionQueue_UseAbility`).
  Наш путь был вторым, сломанным, возвращал `true` и ЗАБИРАЛ ТИК. Убрано; `ability_usage`
  остался выключателем; схема 12 → 11. **Открыто:** дать модели ручку интенсивности, не заводя
  второй путь каста. Приёмка: `invalid order (101)` = 0, рейзы визуально остаются.

- **`rune_control`.** Диал должен влиять на плановую добычу руны, а не только на power-rune
  pressure; считать завершённые транзакции, не empty-bottle процент.
- **Tower-aggro CS.** Controlled aggro-pull под T1 — после P3 и только по новому симптому.
- **Uphill / low-ground travel.** Не очередной step-back, а единый combat path/position owner.

## Bettability

Сделано (Codex, `2d86ed6`): `state markets` в `tools/betting.py` — HP/level/lane-pressure,
окна low-HP и kill-pressure, `strategy_fingerprints`, `check_frozen_config`. ⭐ Оттуда главное
число проекта: **`mutual low`**. Было `0s in 0 windows` в каждом матче — до `8968270421`
(`81547c2`, 27.08), где впервые **10s в 2 окнах**. Между ним и предыдущим матчем РОВНО ОДИН
коммит `81547c2`, и его сигнатура сработала (`ranged spacing hold` 32/22 → 0/0). ⚠️ 10s = 2%
короткого одностороннего матча (0 смен лидерства, `deficit_overcome` 35). Сигнал, не победа.

Осталось:

- tower HP/progress и давление с живой волной;
- net-worth proxy вместо unspent gold (он высок из-за копления на недостижимый компонент);
- реально использованные преимущества (rune power windows, а не только наличие);
- series aggregation с frozen build/config и обязательным side swap.

Новые поля — в общий parser `tools/aibattle_log.py` и под тесты, иначе `match_stats`,
`postmatch` и `betting` прочитают одну строку по-разному.

## Инфраструктура

- Сокращать `mode_laning_generic.lua`, `aibattle_style.lua`, `aibattle_survive.lua` только через
  перенос ownership, а не механическое дробление файлов.
- `tools/project_inventory.py`: следить за direct action sites, dead helpers и shared writers.
- `tools/check_schema_contract.py`: сохранять Python/Lua/prompt/config schema синхронной.
- Старую форензику добавлять в `docs/history`, а не возвращать в активный BACKLOG/HANDOFF.

## Инварианты

- Модель выбирает стратегию; engine constants не становятся LLM-facing rules.
- Один тик — один фактический владелец действия.
- Кандидат, который не может действовать, не удерживает арбитр.
- Один risky behavior batch — одна ожидаемая сигнатура — один матч.
- Сравнивать значения в минуту и всегда привязывать матч к build SHA из лога.
- Конфиги и live bindings коммитить только по прямой команде пользователя.
