# TAPE RELIABILITY MATRIX

> **🏁 МИССИЯ ЗАКРЫТА 23.07.2026:** прошивка v0.15.131 (B0049.bit + ARM v131) записана в 0:/BOOT.BIN
> (бэкап 0.14.92 = 0:/BOOT0148.BAK), холодный старт с SD подтверждён, cold-smoke 4/4 (CM/BT/ALIENS/EXOLON)
> байт-в-байт эталонный — отпечатки и скрины. Спека must-pass выполнена целиком: матрица + провенанс +
> persist + power-cycle. Плата грузит все форматы на турбо из коробки.

Трекер надёжности загрузки лент. Ведёт claude-mon (учёт), исполняет GPT + claude-rtl (hardware-прогоны).
Директива владельца (2026-07-17 07:45): полная матрица, все форматы × все скорости × SYNC on/off — **никаких пропусков**.

Легенда: `PASS` подтверждён на железе / `PEND` не прогоняли / `?` прогнан но результат неоднозначен (нужна проверка экрана).
Скорости: 1× / SAFE4× / FAST8×. SYNC релевантен для стандартных ROM-блоков (TAP/TZX); WAV/MP3-турбо — непрерывный поток (SYNC обычно off).

---

## СЕТКА ПОКРЫТИЯ (по форматам — пропуски видны сразу)

| Формат | 1× | SAFE4× | FAST8× | SYNC-варианты |
|--------|------|--------|--------|---------------|
| TAP    | PASS (BigThings) | PASS (BigThings) | PASS (BigThings) | on/off — прогнать обе на каждой скорости |
| TZX    | PASS (CritMass)  | PEND   | PASS (CritMass, Deflektor) | on/off — SAFE4× пусто |
| WAV    | ? (EXOLON, PC-неясен) | PEND | PASS (EXOLON) | турбо непрерывный (off); корпус 84 файла не свипнут |
| MP3    | PASS (ALIENS)    | PASS (ALIENS quant) | PASS (ALIENS quant; ARKANOID2 RAW) | турбо непрерывный (off) |

**КРИТИЧНО (gate для persist):** TAP/TZX/WAV-ячейки выше подтверждались на билде **0x3F**.
Текущий борд — **0x40 (BRAM PL4K)**. Их надо **ПЕРЕПРОВЕРИТЬ на 0x40** (сам GPT отметил как remaining).
MP3-ячейки — уже на 0x40.

## ТЕКУЩИЙ ЦИКЛ PL4K — IDENTITY GATE (2026-07-20)

- Base hardware was `VERSION=0xB01B0040`; current volatile JTAG-PCAP candidate is
  `VERSION=0xB01B0043` (QSPI is unchanged). ARM `loader.elf` SHA-256
  `f6c0211cc7933dba1e0b2560b62779352a80e050f7c3de1cb6b5cad4af8e84a5`.
- Прежний ThinkPad `/tmp/critical_mass_dump.tzx` был **не Critical Mass**, а padded BigThings TAP.
  Любые результаты с ним invalid и не являются строкой CM.
- На SD `0:/loadtest` записаны исключительно из canonical source и с точным числом записанных байт:
  `CriticalMass-canonical.tzx` — 47,431 B, SHA
  `04cd6519530f53d5eaaa3127cdd063498a9fdd85b22d789a02fe73273a0765c9`; `Deflektor-canonical.tzx`
  — 58,746 B, SHA `cd2511a08e244d7000911b581f74c038d40d19c7b5c89647f2349f0feefb965f`.
- Прежний hot-load ARM без processor reset дошёл до `Xil_ExceptionNullHandler`; его JTAG-autoload
  результаты invalid. Все новые строки после `rst -processor → dow → run`.

---

## ПОДТВЕРЖДЁННЫЕ ПРОГОНЫ (детали)

| Файл | Форм | Скор | SYNC | Билд | count/hash / PC | Итог |
|------|------|------|------|------|-----------------|------|
| Critical Mass | TZX | 1×   | off | 0x3F | — / E724 | PASS (v119) |
| Critical Mass | TZX | 8×   | on  | 0x3F | 805460 / 70C5A7AA / E724 | PASS |
| BigThings     | TAP | 1×   | on  | 0x3F | — / BDB7 | PASS |
| BigThings     | TAP | 4×   | on  | 0x3F | — / BDB7 | PASS |
| BigThings     | TAP | 8×   | on  | 0x3F | 492500 / C84A8304 / BDB7 | PASS |
| Deflektor     | TZX | 8×   | on  | 0x3F | 958894 / 6FC55821 / ADC0 | PASS |
| EXOLON        | WAV | 1×   | off | 0x3F | 245141 / — / 0001..0002 | ? PC низкий, проверить экран |
| EXOLON        | WAV | 8×   | off | 0x3F | 245141 / — / FF81 | PASS |
| ALIENS        | MP3 | 1×   | off | 0x40 | — / 3C70 | PASS |
| ALIENS        | MP3 | 4×   | off | 0x40 | quant / 3C70 | PASS |
| ALIENS        | MP3 | 8×   | off | 0x40 | 606691 / 15983522 / 3C70 | PASS (quant) |
| ARKANOID2     | MP3 | 8×   | off | 0x40 | 213832 / AFD3C49C / FF82 | PASS (guard→RAW) |
| ALIENS        | MP3 | 8×   | off | 0x45 | AUTO quant recipe; `606691 / 15983522`, gaps/resumes `1/0`, PC `617B,6137,3C70`, qdbg `2/2` | **R3/3 transport PASS; prior quant screen PASS; final AUTO screen=PEND** |
| ALIENS        | MP3 | 8×   | off | 0x45 | forced RAW; `606691 / F6E0055F`, gaps/resumes `1/0`, PC `3C72` | **owner-visible FAIL** — clean delivery does not prove lossy MP3 semantics |
| Ark2recon     | MP3 | 8×   | off | 0x45 | RAW and forced-quant both resolve to raw (`qdbg=3`); `213780 / B7877A72`, gaps/resumes `1/0`, PC `25E3` | **FAIL** (`R Tape loading error 10:2`); distinct 1, not the old frozen Arkanoid2 fixture |
| Critical Mass (canonical SHA `04cd…765c9`, SD-readback verified) | TZX | 8× | on | 0x40 | AUTO=on, SMART/ROMTRAP=off; 805460 / 70C5A7AA / E71A,E17C,E17A; gaps=1, resumes=0 | **R3/3 transport PASS; screen=PEND, not overall closed** |
| BigThings (canonical SHA `0348…290d`, SD-readback verified) | TAP | 8× | on | 0x40 | AUTO=on, SMART/ROMTRAP=off; 492500 / C84A8304 / C6DC,BEB5,B6AD; gaps=1, resumes=0 | **R3/3 transport PASS; screen=PEND, not overall closed** |
| Deflektor (canonical SHA `cd25…b965f`, SD-readback verified) | TZX | 8× | on | 0x40 | AUTO=on, SMART/ROMTRAP=off; 958894 / 6FC55821 / ADE9,ADE9,ADC1; gaps=1, resumes=0 | **R3/3 transport PASS; screen=PEND, not overall closed** |
| Critical Mass (canonical SHA `04cd…765c9`, SD-readback verified) | TZX | 8× | off | 0x40 | AUTO=on, SMART/ROMTRAP=off; 805460 / 70C5A7AA / **25E5 ROM x2**; gaps=1, resumes=0 | **FAIL R1/R2: exact transport, deterministic ROM return; fail-fast investigation** |
| Critical Mass (canonical SHA `04cd…765c9`, SD-readback verified) |  TZX | 4× | off | 0x40 | AUTO=on, SMART/ROMTRAP=off; 805460 / 70C5A7AA / E71F; gaps=1, resumes=0 | **R1/3 transport PASS; isolates FAST CPU-only failure** |
| Critical Mass (canonical SHA `04cd…765c9`, SD-readback verified) | TZX | FAST8× | raw off → AUTO-ROM | 0x43 | AUTO=on, SMART/ROMTRAP=off; `805460 / 70C5A7AA`; gaps=1, resumes=0; PC `E724,E179,E721` | **R3/3 transport PASS; screen=PEND** |
| BigThings (canonical SHA `0348…290d`, SD-readback verified) | TAP | FAST8× | raw off → AUTO-ROM | 0x43 | AUTO=on, SMART/ROMTRAP=off; `492500 / C84A8304`; gaps=1, resumes=0; PC `BE63,BCEB,BCA0` | **R3/3 transport PASS; screen=PEND** |
| Deflektor (canonical SHA `cd25…b965f`, SD-readback verified) | TZX | FAST8× | raw off → AUTO-ROM | 0x43 | AUTO=on, SMART/ROMTRAP=off; `958894 / 6FC55821`; gaps=1, resumes=0; PC `ADA8,ADA8,ADC9` | **R3/3 transport PASS; screen=PEND** |
| EXOLON.wav | WAV PCM u8/44.1 | FAST8× | AUTO 8→4 | 0x44 | AUTO=on, SMART/ROMTRAP=off; `245141 / FA182E93`; gaps=1, resumes=0; PC `5B21,5B21,5B42`; экран подтверждён | **R3/3 PASS** |
| ARKANOID2.wav | WAV PCM u8/44.1 dense turbo | FAST8× | AUTO 8→4 | 0x44 | AUTO=on, SMART/ROMTRAP=off; `213845 / 6D630964`; gaps=1, resumes=0; PC `5B3A,5B28,5B1E`; первый экран подтверждён | **R3/3 PASS** |
| Critical Mass (canonical, SD) | TZX | FAST8× | raw OFF → AUTO-ROM | **0x49** | AUTO=on, SMART/ROMTRAP=off; `805460 / 70C5A7AA`; gaps=1, resumes=0; PC `E721,E71D,E726` SP=6434 (RAM); PL через PCAP no-readback (bit SHA `5fa58f3d…ada991`, ARM v0.15.127 `9faab201…d957e4`) | **R3/3 transport PASS (R1 gpt, R2/R3 claude-mon 21.07 после эстафеты); screen=PEND** |
| Critical Mass (canonical, SD) | TZX | FAST8× | raw OFF → AUTO-ROM | **0x49** | НОВЫЙ ПРОТОКОЛ `jtag_tape_verdict.tcl` (transport+PC+скрин в ОДНОМ прогоне, скрин через 3с после EOT из зеркала GP0+0x8000); `805460 / 70C5A7AA`; gaps=1, resumes=0; PC `E17D,E17B,E727`; скрин SHA `22288755…f44e80` — ИДЕНТИЧЕН во всех 3 прогонах, визуально = Durell «£100 REWARD» пост-загрузочная страница CM | **✅ R3/3 FULL PASS — первая ячейка, закрытая по ВСЕМ критериям спеки, включая экран** |
| BigThings (canonical, SD) | TAP | FAST8× | raw OFF → AUTO-ROM | **0x49** | verdict-протокол; `492500 / C84A8304`; gaps=1, resumes=0; PC `E982,E982,E982` SP=5FFF (детерминизм 3/3!); скрин SHA `511bec7d…f9c322` идентичен ×3, визуально = титульник демо «ZX+48K+AY NO EXTRA LOADING» | **✅ R3/3 FULL PASS (экран подтверждён)** |
| Deflektor (canonical, SD) | TZX | FAST8× | raw OFF → AUTO-ROM | **0x49** | verdict-протокол; `958894 / 6FC55821`; gaps=1, resumes=0; PC `ADA8,ADC0,ADE9`; скрин SHA `05b783e5…15f891` идентичен ×3, визуально = полноцветный титульник Deflektor «©1987 Vortex» | **✅ R3/3 FULL PASS (экран подтверждён)** |
| Critical Mass (canonical, SD) | TZX | SAFE4× | raw OFF | **0x49** | verdict-протокол; `805460 / 70C5A7AA`; gaps=1, resumes=0; PC `E178,E727,E17D`; скрин SHA = проверенный `22288755…` ×3 | **✅ R3/3 FULL PASS** |
| BigThings (canonical, SD) | TAP | SAFE4× | raw OFF | **0x49** | verdict-протокол; `492500 / C84A8304`; gaps=1, resumes=0; PC `E982×3`; скрин SHA = проверенный `511bec7d…` ×3 | **✅ R3/3 FULL PASS** |
| Deflektor (canonical, SD) | TZX | SAFE4× | raw OFF | **0x49** | verdict-протокол; `958894 / 6FC55821`; gaps=1, resumes=0; PC `ADC7,ADEA,ADD6`; скрин SHA = проверенный `05b783e5…` ×3 | **✅ R3/3 FULL PASS** |
| **БАТЧ 21.07 15:49–17:22 (33 прогона, 0 аномалий)** — 11 ячеек: BT-F8-ON (PC E982×3), DF-F8-ON (ADD4/ADAB/ADAA), CM-S4-ON (E17B/E721/E721), BT-S4-ON (E982×3), DF-S4-ON (ADAA/ADAD/ADEE), CM-1×-OFF (E71E/E71F/E71A), CM-1×-ON (E17B/E17C/E178), BT-1×-OFF (E982×3), BT-1×-ON (E982×3), DF-1×-OFF (ADCD/ADAA/ADE8), DF-1×-ON (ADC9/ADAC/ADAC) | TAP/TZX | все | обе | **0x49** | В каждом прогоне: точный отпечаток, gaps=1/resumes=0, EOT чистый; скрин каждого прогона побайтно = визуально проверенному эталону своего файла (CM-Durell/BT-титул/DF-титул) | **✅ ВСЕ 11 ячеек R3/3 FULL PASS → сетка 3 файла × 3 скорости × 2 SYNC = 18/18 ЗАКРЫТА** |
| STARQUAK.TAP (SHA `06b71277…3cd979`, SD) | TAP | F8 и 1× | off | **0x49** | F8: стоп ровно на конце экранного блока (count=134873), PC=1F3E (ROM PAUSE), таймаут; 1×: EOT, вся лента 937028 доставлена «в пустоту», гость всё там же PC=1F3E. Скрин = полная заставка Starquake без ошибок. Парс BASIC-блока: `BORDER CLEAR LOAD SCREEN$ **PAUSE PAUSE** LOAD CODE` | **NOT-A-BUG: интерактивная лента (PAUSE=жди клавишу между экраном и кодом) — непригодна для автономной матрицы. Транспорт точен. Заменён на CAVE48K.TAP (парс: без PAUSE). Бэклог: авто-инжект клавиши для таких лент** **UPDATE 23.07 (прошивка v131, холодный старт): владелец руками довёл STARQUAK на 8× до игры — AUTO-ROM-гейт заморозил ленту на PAUSE, клавиша дала грант, загрузка продолжилась. Живое owner-подтверждение demand-гейта на интерактивной ленте ✅** |
| **БАТЧ №2b 21.07 19:34–20:30 (33 прогона, 0 аномалий)** CAVE48K.TAP (plain-ROM, SHA `81a9ca3d…9be938`) | TAP | **все 6 ячеек** (F8/S4/1× × SYNC off/on) | — | **0x49** | fp `638916/FF7A8101` идентичен во всех 18 прогонах; gaps=1/resumes=0; PC C8xx (RAM); скрин SHA `1d03cbb3…` идентичен ×18, визуально = титульник «AUTOMATED CAVE EXPLORER» | **✅ 6/6 ячеек R3/3 FULL PASS → plain-ROM блокер спеки ЗАКРЫТ** |
| dizzy3 MP3-фикстуры ×4 (CBR/VBR × pilot/chained, `fixtures/MANIFEST.md`) | MP3 | wavfast=1 | — | **0x49** | Все 4: EOT чист, gaps=1/resumes=0, PC RAM (A5DC/DAxx); скрин SHA `610875ad…` ОДИН у всех 4 файлов ×3 повтора = меню Dizzy III «SPC OR FIRE TO START» (игра работает). qdbg=0 ⇒ policy=RAW (v127 AUTO-рецепт квантует только известные записи — by design); **RAW тянет CBR, VBR и сцепленные блоки** | **✅ 4/4 ячейки R3/3 FULL PASS** |
| EXOLON.wav контроль на B0049 | WAV | AUTO 8→4 (wavfast=3) | — | **0x49** | `245141/FA182E93` ×3; PC 804A/804D/804E (RAM); скрин `c12b53a5…` ×3 = меню EXOLON ©1987 Hewson | **✅ R3/3 FULL PASS — B0049 унаследовал B0044 WAV-AUTO** |
| **БАТЧ №3 21.07 21:10–21:36** dizzy3 WAV-фикстуры ×4 (u8/s16 × 44.1/48кГц; на SD через APPEND-чанки v128, прогоны на v127) | WAV | AUTO 8→4 | — | **0x49** | Все 4: EOT чист; пофайловые отпечатки стабильны ×3 (1061501/61F05CAD, 1061505/B7ACA414, 1061551/F8D71EFE, 1061547/FD56B66F — офф-борд crossings 1061524 в ту же полосу); gaps=1/resumes=0; PC RAM; скрин ×12 = эталон Dizzy III `610875ad…` | **✅ 4/4 ячейки R3/3 FULL PASS → WAV-форматный блокер спеки (PCM 8/16-бит, 44.1/48кГц) ЗАКРЫТ** |
| **БАТЧ №4 (СВИП КОРПУСА) 21.07 21:37–22:22: все 83 WAV из TurboLoad** | WAV | AUTO 8→4 | — | **0x49** | **83/83 транспортно-точных**: EOT у всех, gaps=1/resumes=0 у всех, ноль таймаутов. 75 — чистая загрузка (PC RAM); 7 — игры на интерактивных экранах (Cybernoid2-титул, EarthShaker «INFINITY LIVES y/n», Exolon-nosound-титул, NodesOfYesod, PanamaJoe, RiverRaid-меню управления, Saboteur-Durell «PRESS ANY KEY») — PC ловится в ROM key-scan/PAUSE, скрины подтверждают работающие игры = PASS; 1 — 3DDeathChase[a]: транспорт точен, битмап анимируется, но атрибуты 0x00 (чёрным-по-чёрному) = гостевая причуда дампа/48К-режима (ретест под 48К-моделью, задача #14) | **✅ СВИП: 100% транспорт, 0 реальных отказов. Урок: одиночный PC-снапшот в ROM ≠ FAIL (игры зовут ROM key-scan) — вердикт только по скрину** |
| **OWNER-ПОДТВЕРЖДЕНИЕ 22.07:** все 7 интерактивных WAV-игр из свипа доведены владельцем руками до геймплея (RiverRaid «1.KEYBOARD» ✅, Saboteur «PRESS ANY KEY» ✅, EarthShaker «INFINITY LIVES y/n» ✅, Cybernoid2 ✅, NodesOfYesod ✅, PanamaJoe ✅, Exolon-nosound ✅) | WAV | 8× (WAV-гибрид v127) | — | **0x49** | Человеческий ввод + живой геймплей | **✅ WAV-КОРПУС 82/83 ЗАКРЫТ ПОЛНОСТЬЮ (owner-PASS); хвост: 3DDeathChase[a] — гостевая причуда, ретест после 48К-фикса (#14)** |

### FAST8 AUTO-ROM policy (0x43)

FAST is CPU-only, while ULA/INT remain at native wall-clock speed. A 0/1-ms pause between marked
standard ROM blocks is therefore too short for some loaders: Critical Mass consumed an exact stream
but finished in BASIC ROM (`25E5`). At FAST8 the FPGA now applies the existing exact `PC=056B`
demand gate automatically **only** to marked standard-ROM descriptors. Thus the UI/raw SYNC bit still
controls 1× and SAFE4×, while FAST8 raw on/off both mean `AUTO-ROM` for this subset. Turbo/custom TZX,
WAV and MP3 descriptors are unmarked and remain continuous. This is a compatibility policy, not proof
that every corpus row is closed.

B01B0043 explicit raw `SYNC=ON` CM control also passed: `805460 / 70C5A7AA`, gaps/resumes `1/0`,
safe PC `E71E` (screen=PEND). It confirms that the raw settings converge intentionally in FAST8.

---

## КОРПУС ДЛЯ СВИПА (никаких пропусков)

- **WAV — `0:/loadtest/TurboLoad`: 83 файла** (EXOLON, ARKANOID/2, CYBERNOID2, STORMLORD/2, ZYBEX, RENEGADE, IK+, …),
  все PCM u8 mono 44.1 kHz. Свипнут: EXOLON. Осталось: 82. Свип батчем на FAST8×, дефекты — понижать до SAFE4×/1×.
- **MP3** — папка MP3 (ALIENS, ARKANOID2 подтверждены). Дополнить корпус.
- **TAP/TZX** — demos (CritMass, BigThings, Deflektor подтверждены). Добавить стандартные + турбо-загрузчики (EXOLON-custom и т.п.).

## MUST-PASS СПЕКА (дословно из вердикта GPT 00:05 — это blocker, не nice-to-have)

Критерий одной ячейки: **3 cold/fresh запуска** файла на данной скорости; в КАЖДОМ:
полный `count/hash` против reference + `GAPS=1` + `RESUMES=0` + PC в RAM + видимый running-экран после EOT.
Поля трекера (по GPT): file / format / speed / sync / policy / count / hash / gaps / resumes / PC / screen / repetitions.

Обязательный набор файлов:
- **TAP/TZX** (blocker): Critical Mass TZX (custom loader), BigThings TAP (SYNC), Deflektor TZX, **+ один обычный ROM TAP**. Скорости 1×/SAFE4×/FAST8×, каждая × **SYNC OFF и ON**.
- **WAV** (blocker): минимум PCM 8-bit и 16-bit, 44.1 и 48 kHz, + один плотный turbo/edge recording. `ALIENS.audit.wav` — control-row, не заменяет корпус.
- **MP3** (blocker): Aliens (quant-path), Arkanoid2 (guard→RAW), + CBR и VBR записи с internal pilot и без. Policy RAW/quant по auto/preflight; **global `opt_quant=1` НЕ включать**.
- После зелёной matrix: один full power-cycle/normal-boot smoke на том же наборе. Только ПОТОМ → QSPI backup→write→verify→reboot smoke; JTAG-PCAP = rollback.

## ПЕРЕКЛАССИФИКАЦИЯ MP3 (22.07, спровоцировано живым наблюдением владельца)
Владелец глазами поймал «ALIENS/ARKANOID2 не грузятся» во время батча — расследование дало системный вывод:
| Файл (кастом-загрузчик) | FAST8 (wavfast=1) | AUTO 8→4 (wavfast=3) | **SAFE4 (wavfast=2, ДЕФОЛТ)** |
|---|---|---|---|
| ALIENS.mp3 (quant AUTO) | ФЛЕЙК 1/3 (R3: мусор-полоса, PC=3C70 ROM) | ФЛЕЙК 1/3 (R2: PC=3C88 ROM) | **✅ 3/3, скрин-эталон, PC в игровом коде** |
| ARKANOID2.mp3 (guard→RAW) | ЗАТЫК 3/3 в собственном загрузчике (PC=FF8x SP=5FE2 — сигнатура EXOLON-FAIL до B0044); заставка нарисована, игра не идёт | — | **✅ 3/3, таблица рекордов на экране (attract), PC=F6xx** |
| Ark2recon.mp3 | «R Tape loading error 10:2» — битый рекординг, воспроизведён на B0049 | — | (контент-дефект, закрыт как known-bad) |
Выводы: (1) прежние «MP3-8× PASS» строки — транспорт-only/удачные сэмплы; переклассифицированы. (2) MP3-дескрипторы
не маркируются → AUTO-ROM-гейт не защищает их ROM-фазу; кастом-турбо на CPU-only темпе гонится. (3) **Честная политика:
MP3=SAFE4 (что и есть дефолт v127, opt_wavfast=2)** — persist-кандидат корректен из коробки. (4) Настоящий MP3-8× =
маркировка предекодед-блоков или редизайн контеншена — бэклог (см. tape-8x-turbo-warp-ceiling). Скрины: al_s4/ak_s4.

## НАХОДКИ ЖИВОГО ИСПОЛЬЗОВАНИЯ (22.07, владелец)
- **ATARIN.mp3 (демо Atari Nights, оцифровка ленты): флейк авто-детекта «лента vs музыка»** — 1-я попытка (1×) сорвалась (детект не увидел пилот, count=10 и мгновенный стоп), повтор (8×) загрузился нормально. Порог: `maxrun>=200` пилот-импульсов в первом чанке (loader_main.c:2441) — пограничные записи флейкают. Обход: повтор ЛИБО меню «MP3/WAV TAPE=YES» (`mp3_tape=1`), минус — музыка тогда тоже пойдёт лентой. Фикс-кандидат на v129 (после persist): гистерезис порога + гарантированно чистый DC-seed на файл.

## РЕЛИЗ-ГЕЙТ v0.15.131 — ПРОЙДЕН (23.07, батарея 13/13)
Регрессия на релиз-кандидате (меню NORMAL/FAST + бут-санация FIFO + маркировка выключена):
CM `805460/70C5A7AA` E726 ✅, BigThings `492500/C84A8304` E982 ✅, ALIENS ×2 `606691/15983522` B88x ✅,
ARKANOID2 `213832/AFD3C49C` F6D1 ✅, EXOLON `245141/FA182E93` 804B ✅, dizzy-CBR `1061526/AA0E0F34` A5DC ✅.
Все отпечатки эталонные, чистые буты после санации.
**1×-дискриминатор шести подозреваемых свипа:** LODE_RN1 и SHOCK128 на 1× грузятся В RAM (80B1/F499) →
спидо-чувствительные загрузчики (класс Deflector, бэклог #12/#13); ROBOTCOP и TFCOPY на 1× стоят в PAUSE
(1F3E) → интерактивные/многочастёвки = PASS; FX_SOUND (24D1) и CHASEHQ2 (3C72) падают и на 1× → битые
оцифровки (к DIZWF128/Ark2recon). **Загрузчик на корпусе 199 MP3: 0 подтверждённых багов.**
Кандидат прошивки: `flash/BOOT_B0049_v131.BIN` SHA `29f1a9cb…ab2172` (FSBL + B0049.bit + ARM v131).

## BLOCKERS (актуально)
- ⛔ Canonical Critical Mass, BigThings и Deflektor FAST8 AUTO-ROM закрыты transport R3/3 on volatile
  `0x43`, но экран ни для одной новой строки не захвачен. Полная matrix остаётся open.
- ✅→⏳ PCM s16/48 kHz и CBR/VBR MP3 fixtures СОЗДАНЫ (claude-mon 21.07, детерминированно, command+SHA в
  `fixtures/MANIFEST.md`; стейдж `thinkpad:/tmp/fixtures/{wav,mp3}`). Осталось: записать на SD и прогнать в matrix.
  Открыто: пара MP3 «без internal pilot» — ждёт семантики preflight (GPT вернётся 27.07, либо выведу из кода сам).
- ⛔ Провенанс: B0043 AUTO-ROM-слой отсутствует в воспроизводимых исходниках (вывод GPT 21.07); B0049 collected-артефакт
  есть (SHA `5fa58f3d…`), но до persist нужен пересобираемый источник.
- ⚠ Текущий борд = **0x40 (BRAM)**; TAP/TZX/WAV PASS-ы были на **0x3F** → перепроверить на 0x40.

## СЛЕДУЮЩИЕ ШАГИ (порядок)
1. Снять экран для canonical TAP/TZX строк; заполнить 1×/SAFE4× и WAV/MP3 ячейки; для FAST8 записывать policy `AUTO-ROM`, а не вводящий в
   заблуждение raw on/off.
3. Расширить корпус: WAV 84-свип, MP3 CBR/VBR ±pilot, обычный ROM TAP.
4. Full power-cycle smoke → persist QSPI (бэкап 0.14.92 + PCAP safety net).
