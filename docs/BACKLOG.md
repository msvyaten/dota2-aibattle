# AIBattle Backlog

Только актуальные задачи. Полная форензика и закрытые пункты до 01.08.2026 лежат в истории git:
`git show ae2604d:docs/BACKLOG.md`. Текущий HEAD/LIVE всегда получать командой:

```powershell
python tools\pre_match_state.py
```

## Следующий Gate

Нужен один матч на текущем задеплоенном коде с зафиксированными Grok/Gemini bindings.

Проверить:

- `Script Runtime Error = 0`, `AIB ERR = 0`, last hits > 0 у обеих сторон;
- общий attack-edge не заводит SF в melee pack при KillLock/HealInterrupt/PassingHeroTrade;
- siege commit отпускается после исчезновения волны и не блокирует следующий владелец;
- после объединения runtime context нет новых `empty_action` и отсутствующих полей;
- stationary/jitter окна и bottle-rune transaction читаются по полной временной линии.

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

## Поведение

- **Rune economy / `rune_control`.** Диал должен влиять на плановую добычу руны, а не только
  на power-rune pressure. Считать завершённые транзакции, не только empty bottle percentage.
- **Recovery no-action.** Recover не должен выигрывать на 40-55% HP, если за safe-якорем нет
  предмета, руны, угрозы или полезного перемещения.
- **Anti-idle ownership.** Ветки combat/creep/push должны перейти к соответствующим владельцам;
  watchdog только обнаруживает отсутствие прогресса.
- **Tower-aggro CS.** Вернуться к controlled aggro-pull под своей T1 после P3, если симптом
  подтверждается новым матчем.
- **Uphill и low-ground travel.** Не добавлять очередной step-back; решать через единый combat
  path/position owner.

## Bettability

После следующего матча расширить `tools/betting.py` и общий telemetry contract:

- HP advantage и опасные low-HP окна во времени;
- tower HP/progress и давление с живой волной;
- уровни/net-worth proxy вместо одного unspent gold;
- kill pressure, rune power windows и реально использованные преимущества;
- lead changes, comeback depth, dead tail и время до первого значимого события;
- series aggregation с frozen build/config и обязательным side swap.

Новые betting-поля добавлять в общий parser (`tools/aibattle_log.py`) и покрывать тестами,
чтобы `match_stats`, `postmatch` и `betting` не читали одну строку по-разному.

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
