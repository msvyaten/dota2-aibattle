# Дрейф промпта генератора — что обязано попасть в новый system_prompt

Составлено 2026-07-21 (Opus). Вход для ре-дизайна промпта.

**Живой промпт = `backend/system_prompt.txt`** (84 стр., последний тач 05.07, `287c445`).
`docs/llm_system_prompt.md` (278 стр., 25.06) — производный/устаревший, на 10 дней СТАРШЕ живого.
Валидация значений — `backend/generate_playstyle.py:10-28` (`DIAL_KEYS` / `RULE_VALUES`).

С 05.07 в движок легло ~15 коммитов (`git log 287c445..HEAD -- bots/`): фаза A арбитра,
C.1 idle-band, пять engine-floor'ов, честная метрика. Промпт описывает движок ДО них.

---

## A. Дыры в наборах значений (LLM физически не может выдать то, что нужно)

**A1 — `pregame_behavior` НЕ содержит `"default"`. Критично.**
Промпт (:30) и whitelist (`generate_playstyle.py:19`) разрешают только
`"safe_tower" | "aggressive_mid" | "jungle_pressure"`. Но `canonical_farmer.lua:70`
использует **`"default"`**, и движок гейтит pre-creep трейд на `preMode=="aggressive_mid"`
(`06361e0`): всё НЕ-aggressive_mid = пассивный hold якоря. То есть:

- LLM не может сгенерить пассивный prewave вообще — только `safe_tower` (не то же самое),
  `aggressive_mid` (трейдит на реке) или `jungle_pressure`.
- Эталонный рукописный фармер использует значение, недоступное генератору.
- **Прямая связь с юзер-симптомом «стоит на воде до крипов пока его бьют»**: LLM-конфиг
  почти наверняка выберет `aggressive_mid` для любого не-трусливого промпта.

Действие: добавить `"default"` в whitelist + промпт и описать разницу
safe_tower / default / aggressive_mid. Проверить, что `jungle_pressure` вообще
реализован в 1v1 mid — иначе выкинуть.

**A2 — `ability_usage`: whitelist имеет `"basic"` (`:23`), промпт (:41) его не документирует.**
LLM не знает о трети допустимых значений.

---

## B. Engine-floor'ы, которые теперь БЬЮТ конфиг (промпт обещает то, чего движок больше не делает)

Продуктовый принцип «любой LLM-конфиг смотрибелен» реализован серией floor'ов.
Промпт описывает до-floor'ную семантику → LLM обещает пользователю поведение,
которого не будет. Каждый пункт обязан быть отражён.

| ручка / значение | что говорит промпт | что делает движок сейчас |
|---|---|---|
| `dive_policy:"always"` (:35) | «tower damage never stops the chase» | **Ложь.** MayDive survival floor (`dd74e76`, style.lua): hp<0.30 — никогда; deaths≥1 & hp<0.40 — никогда. Бьёт ЛЮБУЮ политику. |
| `low_hp_behavior:"fight_back"` (:37) | «never retreat» | Перебивается concede-floor (`6e131f8`), HP-disadvantage trade-гейтом (`243dd04`/`a336587`), early-low пре-арбитром. |
| `low_hp_behavior:"regen_lane"` (:38) | «step back ~400u and regen near lane» | + фонтан-floor hp<0.22 (`39cf203`) и **новый `no_sustain_floor`** hp<0.35 при исчерпанном сустейне (`181b1f2`, survive.lua). |
| `healing_style:"never"` (:40) | «suppress all healing» | critical-stuck buy escape (`9bb91a2`) всё равно тратит золото на сустейн. |
| `forwardness` (:9) | «0 = glued to own tower, 1 = far up the lane» | Pre-creep якорь **капнут 0.40** для не-aggressive_mid (`9f6b6cc`); standoff держит якорь весь марш крипов (`4e2dee2`); пассивный не наступает (`06361e0`). Верхняя половина шкалы до крипов не работает. |
| `creep_wave_priority:"last_hit_only"` (:47) | «only kill-window hits» | C.1 (`37e83af`): anti-idle больше не бьёт/не догоняет вражьих крипов; новый **wave-watch hold** — бот СТОИТ когда крипы в range+250 и добивать нечего. |
| `tower_aggression:"never"` (:51) | «never attack towers» | + antiIdlePush гейтится `≠never` & hp≥0.45 (C.1); есть позитивная лог-сигнатура (`6c37858`). |
| `execute_threshold` (:12) | «commits to the kill» | Гейтится вышкой: не добивать под вражьей вышкой (`3c4dfc7`) + MayDive floor. |
| `rune_control` (:11) | «contest and stage for rune spawns» | Стейджинг переписан: dead-window abort (`21d3145`), threat_abort при hp<0.30 (`cae1950`), critical rune-reach до 4500u (`39cf203`), rune-commit yield guard (`3957992`). |
| `retreat_caution` (:10) | шкала «отступать рано» | Недокументировано, что это ПРЯМО задаёт fallback-порог `0.20 + 0.20*caution (+0.08 за смерть)` (survive.lua). Ручка сильнее, чем звучит. |

**Вывод для дизайна промпта:** нужен отдельный раздел «Engine floors — что движок гарантирует
независимо от твоего конфига», иначе LLM пишет конфиги против несуществующей семантики.

---

## C. Ручки, которые движок читает, но LLM их не видит

Из `grep -rhoE "rules\.[a-z_]+" bots/`:

| ручка | чтений в движке | статус |
|---|---|---|
| `low_hp_hold` | **4** | НЕ в whitelist, НЕ в промпте. Значимая — решить: экспонировать или задокументировать как внутреннюю. |
| `rune_use_policy` | 2 | НЕ экспонирована. Актуально: bottle_empty — хронический north-star FAIL. |
| `buyback_policy` / `aegis_policy` / `smoke_usage` | по 1 | Для 1v1 mid нерелевантны — задокументировать как сознательно вне скоупа. |
| `debug_skeleton_laning`, `debug_disable_forwardness_fallbacks` | 1+1 | Отладочные — **правильно** не экспонированы, не добавлять. |

Обратной дыры нет: все 11 ключей whitelist движком читаются, мёртвых ручек в промпте нет.

---

## D. Инфра / мета

1. **Два источника промпта** — `backend/system_prompt.txt` (живой) и `docs/llm_system_prompt.md`
   (на 10 дней старше). Риск отредактировать не тот. Решить: либо doc помечается как
   производный, либо удаляется.
2. **`generate_playstyle.py:7` `MODEL = "gpt-5.5"`** с комментарием «current flagship (June 2026)» —
   проверить актуальность перед прогоном. (Опция к обсуждению: перевести генератор на Claude —
   продуктовое решение, не техническое.)
3. **Блокер E2E: `OPENAI_API_KEY`** (watchlist #4, не менялся).
4. **Дефолт диалов** `DEFAULT_DIAL = 0.5` (:30) + правило промпта «если не подразумевается — 0.5»
   (:84). При 12 диалах это даёт много нейтральных конфигов; проверить, что 0.5 forwardness
   не воспроизводит ровно ту prewave-проблему, из-за которой мы правим движок.

---

## E. Аудит валидности ВСЕХ значений правил (21.07)

Проверены все 38 значений 11 правил: реализовано ли значение в движке, достижима ли ветка,
совпадает ли поведение с описанием. ⚠️ Методика: греп по литералам даёт ложные «мёртвые»
(сравнение часто идёт с локальной переменной — `policy == "never"`, а не `dive_policy == ...`),
и `style.lua` содержит И таблицы валидации, И реализацию. Каждый кандидат проверен глазами.

**Здоровы (8 правил, все значения):** `respawn_behavior`, `pregame_behavior`, `dive_policy`,
`healing_style`, `ability_timing`, `hero_priority`, `deny_policy`, `tower_aggression`.

**Три реальные проблемы:**

**E1 — `creep_wave_priority = "freeze"` НЕ РЕАЛИЗОВАН, и ведёт себя ПРОТИВОПОЛОЖНО описанию.**
Движок ветвится по cwp только на `"push"` (`laning_creeps.lua:135`, `laning_siege.lua:42/126/204`)
и на `"last_hit_only"` (`style.lua:705`). На `freeze` не ветвится НИГДЕ. Следствие: в анти-айдл
сторожке `style.lua:705` стоит `if cwp == "last_hit_only" then return false end` — `freeze`
проваливается мимо и **атакует вражеских крипов**. Промпт (:48) обещает «never touch enemy creeps
(drags the wave back to own tower)» — на деле freeze пушит волну сильнее, чем last_hit_only.
Фикс: либо реализовать freeze (гейт в тех же точках + не бить крипов), либо убрать из whitelist.

**E2 — `ability_usage = "basic"` = молчаливый алиас на `"default"`** (`style.lua:343`:
`if au == "basic" then au = "default" end  -- backward compat`). В whitelist
(`generate_playstyle.py:23`) предлагается как отдельный выбор, в промпте не документирован (см. A2).
LLM, выбравший «basic», молча получает «default». Фикс: убрать из whitelist или задокументировать
как алиас.

**E3 — `low_hp_behavior = "walk_fountain"` ТЕЛЕПОРТИРУЕТСЯ вопреки собственному определению.**
`style.lua:86` описывает его как «no TP escape; walk to own fountain on foot», но
`survive.lua:633` даёт TP обоим: `if tp and (behavior == "tp_fountain" or behavior == "walk_fountain")`.
⚠️ Было латентно, пока TP-ветка была мертва (getItem требовал ITEM_SLOT_TYPE_MAIN, а свиток лежит
в TP-слоте); после фикса `edd7a44` ветка ожила → расхождение стало РЕАЛЬНЫМ. Ни один канонический
конфиг сейчас walk_fountain не использует, но он в whitelist → LLM его выдаст.
Фикс: убрать `walk_fountain` из условия TP (тогда падает в пеший путь (c), как заявлено).

## Порядок работ

1. **A1 (`pregame_behavior:"default"`)** — самое дорогое и самое связанное с текущей юзер-болью.
2. **B — раздел engine-floors** в промпте (иначе LLM врёт про поведение).
3. **C — решение по `low_hp_hold` / `rune_use_policy`** (экспонировать или явно закрыть).
4. **A2 + D** — мелочь, за один проход.

⚠️ Не начинать до закрытия текущей 2-фазной приёмки fountain-фиксов (`181b1f2`) —
prewave engine-floor может ещё изменить семантику `forwardness`/`pregame_behavior`,
и промпт придётся переписывать дважды.
