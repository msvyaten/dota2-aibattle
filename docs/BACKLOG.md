# AIBattle Backlog

> **Language: Russian.** Working queue. English summary of open work: `docs/STATE.md`.

Только актуальные задачи. Полная форензика и закрытые пункты до 01.08.2026 лежат в истории git:
`git show ae2604d:docs/BACKLOG.md`. Текущий HEAD/LIVE всегда получать командой:

```powershell
python tools\pre_match_state.py
```

## Следующий Gate

⛔ Устарело до 27.08: тут было написано, что последний сыгранный — `8927375253` (`0acf383`).
На диске лежали ещё ЧЕТЫРЕ более поздних лога, не разобранных: `8940466473` (`1bc2f07`, 11.08),
`8964702771` (`93240e8`, 25.08), `8964741391` (`f2ab321`, 25.08), `8968270421` (`81547c2`, 27.08).
Все пять прочитаны 27.08. Долг приёмки всегда брать `git log <билд-из-лога>..HEAD`, не отсюда.

⛔ **Хилящий вард: `seen=0` во ВСЕХ пяти матчах** — на зеркале SF варда (абилка Джаггернаута)
не бывает, приёмка этой правки на текущем матчапе НЕВОЗМОЖНА. Покупка лечения: `bought=5`,
потолок 2 пробит. Остаётся `bottle_empty_pct` 77/72% при лимите 50 — единственный жёсткий FAIL.

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

## Никогда Не Срабатывало (`check_all.py --never-fired 3`, 03.08)

64 из 198 точек эмиссии не появились ни в одном из трёх последних матчей. Каждый вердикт ниже
проверен по логу, а не по рассуждению; опорные числа — за три матча суммарно.

**Объяснимо, не находки (~30):** бутылки нет ни разу (`bottle=` = −1) → шесть бутылочных
веток мертвы; uphill-событий на милише ноль → ренджевые ветки выключены корректно
(`melee-pack-*`, `own-ranged-*`); `dbg-*`; счётчики новее этих матчей; ключи из конкатенации
(`deny-cand-`, `state-`) — ограничение инструмента, не находка.

**1. Руны берутся, но `rune_control` этого не измеряет.** ⛔ Ранее я записал «руны не берутся
никогда» — НЕВЕРНО, юзер поправил по экрану. Что доказано: `rune-grab`
(`mode_rune_generic.lua:426`, поставлен специально для A/B диала `rune_control`) молчит во
всех трёх матчах, при том что руны физически берут. Значит счётчик стоит не на том пути,
которым руна реально достаётся, либо строка недостижима по ветке выше. Плюс нули по
`rune-pressure-*`, `rune-result`, `rune-transaction`, `rune-stage-override`, `recovery-rune`,
`power-rune-yield`. **Диал масштабирует желание (строка 62), но эффект не наблюдаем ничем.**
Различать ТРАССИРОВКОЙ, не чтением.

**2. ЗАКРЫТО 28.08 — и формулировка была частично неверной.** Мёртвыми были ветки в
`M.Pregame` (`pg-disengage`, `pg-uphill-freeze`, `pg-pos`, позиционирование, вызов
`pregameDuel`) — их удалили вместе с флагом `PRECREEP_HOLD_AT_TOWER`, `AIBLaneDuel.Pregame`
и хуком `ctx.pregameDuel`. А `precreep-contact`/`precreep-trade` живут НЕ в `Pregame`, а в
`M.PreCreepStandoff` (`DotaTime() <= 25`) и достижимы: они молчат из-за лицензии
`PreEngageAllowed` — у `canonical_gemini` её нет (`default`/`default`), у `grok` есть
(`hero_priority="always"`). Это вопрос КОНФИГА, не мёртвого кода. Осталось: арматура
`phase == "pregame"` внутри `duelState` (единственный вызов теперь `post_horn`).

**3. Окно смерти открывается 30 раз и не делает НИЧЕГО.** `dw-active=30`, `dw-farm`/`dw-heal`/
`dw-tower` — нули. Враг мёртв, окно открыто, действий нет.

**4. Четыре ветки осады не берутся** (`siege-tower`, `siege-wave-tower`, `siege-hold-creep`,
`siege-no-tank-tower`) при `commit/terminal` = 146 — проверять перед правкой осады.

**5. Пять низко-hp веток по нулям** (`low-hp-cs`, `low-hp-fight`, `emerg-retreat`,
`heal-pullback`, `heal-break-contact`) при трети матча ниже 45% hp. Четыре не проверены.

## Открыто После `8926148548`

- **Взаимная уступка лечения и похода на фонтан.** Одним тиком:
  `blocked=heal-item reason=fountain_trip_committed` и
  `blocked=fountain-floor reason=heal_in_hand`. Питьё уступает походу, поход уступает питью,
  не действует никто; дальше `water_rune` возвращает `blocked` (руны нет) и бот уходит из
  лейна на 15 секунд с салвом в сумке. Три раза за матч (t=796/855/931). Та же форма, что
  `b7209fd`. Решение о том, кто перестаёт быть вежливым, за пользователем.
- **Промпт генератора не просит item build, а рантайм его поддерживает.** `aibattle_style.lua`
  парсит `item_build` (включая три именованные сборки через `build_style`) и `item_rules`, но
  `backend/system_prompt.txt` и `backend/style_schema.py` о них не знают ни слова. Поэтому
  `Style.GetItemBuild()` пуст всегда, обе стороны играют вендорскую сборку, и после
  `power_treads` копят на компонент Maelstrom за 1600 — в 16-минутную 1v1 он не приезжает.
  Это и есть ответ на «куда уходит золото»: вопрос продукта, а не цикла покупки. Менять
  промпт — решение пользователя: это меняет то, что производят модели, то есть сам предмет
  замера.
- **Какая нога `anti-idle` уводит бота ВПЕРЁД на низком HP.** `8926148548` t=266: `recover`
  выиграл со счётом 102 и вернулся пустым, тик упал на `anti-idle:2`, бот шёл к врагу с 35%
  до 8% HP. Матч проигран здесь. Ноги считаются `DiagRL(5s)` — инструментировать, не гадать.

## Поведение

- **Rune economy / `rune_control`.** Диал должен влиять на плановую добычу руны, а не только
  на power-rune pressure. Считать завершённые транзакции, не только empty bottle percentage.
- **Recovery no-action.** Recover не должен выигрывать на 40-55% HP, если за safe-якорем нет
  предмета, руны, угрозы или полезного перемещения.
- **Anti-idle ownership.** Ветки combat/creep/push должны перейти к соответствующим владельцам;
  watchdog только обнаруживает отсутствие прогресса.
- **Tower-aggro CS.** Controlled aggro-pull под своей T1 — после P3 и только если симптом
  подтвердится новым матчем.
- **Uphill и low-ground travel.** Не добавлять очередной step-back; решать через единый combat
  path/position owner.

## Bettability

Сделано (Codex, `2d86ed6`): `state markets` в `tools/betting.py` — HP/level/lane-pressure,
окна low-HP и kill-pressure, `strategy_fingerprints`, `check_frozen_config`. ⭐ Оттуда главное
число проекта: **`mutual low`**. Было `0s in 0 windows` в каждом матче — до `8968270421`
(`81547c2`, 27.08), где впервые **10s в 2 окнах**. Между ним и предыдущим матчем РОВНО ОДИН
коммит `81547c2`, и его сигнатура сработала (`ranged spacing hold` 32/22 → 0/0). ⚠️ 10s = 2%
короткого одностороннего матча (0 смен лидерства, `deficit_overcome` 35). Сигнал, не победа.

Осталось:

- tower HP/progress и давление с живой волной;
- net-worth proxy вместо одного unspent gold (сейчас unspent gold обманывает: он высокий
  потому, что герой копит на недостижимый компонент, а не потому, что не умеет тратить);
- реально использованные преимущества (rune power windows, а не только их наличие);
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
