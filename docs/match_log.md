# Match Log — AIBattle × Dota 2

Формат матчей: Solo Mid 1v1, SF vs SF, читы ON, хост-зритель.
Данные из `python tools/match_stats.py <id>`. Слот1 = Radiant, слот129 = Dire.
История до 09.06.2026 — `docs/history/HANDOFF-full-2026-06-09.md`.

**Примечание по конфигу:** cfg-анонс (`AIB[R] harass=...`) был слишком длинным (~220 символов)
и молча дропался Dota-чатом (лимит ~160 символов). Исправлено в phase-16 (12.06.2026):
разбито на 2 сообщения. Матчи до fix имеют конфиг вручную из playstyle-файлов.
Начиная со следующего матча `match_stats.py` покажет `cfg:` и `dial:` таблицу автоматически.

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
**Переменная:** cw=push (Radiant) vs cw=freeze (Dire), потом свап
**Проблема в матчах:** боты уходили на шрайны — water rune DESIRE_HIGH 3200 радиус (FIXED после этих матчей)

| MatchID | Dur | Победитель | R K/D LH/м | D K/D LH/м | Конфиг R / D | Заметки |
|---|---|---|---|---|---|---|
| 8852107561 | 10.9м | **Dire** | 1/2 2.4 DN 9 | 2/1 4.0 DN 3 | freeze+hero=always / push+hero=always | уходили на шрайны (water-rune, side_shop — не пофикшено); push побил freeze ✅ |
| 8852131228 | 7.2м | **Radiant** | 2/1 3.6 DN 4 | 1/2 **0.0 LH** DN 4 | push+hero=always / freeze+hero=always | свап сторон; Dire freeze+always = 0 LH 🐛 (csAllowed=false блокировал ласт-хиты) |

**Итог:** push > freeze при одинаковом hero=always (2:0). Обнаружен критический баг: `cw=freeze` блокировал **все** атаки по крипам → 0 LH. `hero-prio-always D#180` подтверждает: бот атаковал героя, но не крипов. **FIXED** в mode_laning_generic.lua: freeze теперь разрешает ласт-хиты, только блокирует push-блок.

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
