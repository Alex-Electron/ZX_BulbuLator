# GS: затык между паттернами — офлайн-разбор (2026-08-10)

## Симптом (плата)
На v0.15.321+ при игре MOD через Z-Player — заметные затыки на смене строки/паттерна.
Прибор: `lgap` (виртуальные такты GS между чтениями окна `#6000..#7FFF`).

## Что НЕ виновато
| Кандидат | Вердикт |
|---|---|
| Частота INT 37.5 kHz / 320 тактов | Совпадает с docs + MiSTer `gs.v` |
| Underrun ЦАП / debt | На живой игре было avg=12.0, debt=0 |
| Mute «анти-sticky» (v320) | Убран в v322 (хуже железа: тишина вместо hold) |

## Что виновато / частичные фиксы
1. **Долгий DI без защёлок** на стыке (плата: 100k..300k тактов ≈ 8..25 мс hold сэмпла).
2. **v324 rush ×8 навсегда на холостом** (latch=7 после init → starve вечный → avg~8, debt=max). Починено **v326**: rush только при `gs_n_int>0` и gap∈(2k, 2M).
3. **INT до emulate + догон `int_left`** (v324/325) — корректнее модель уровня, не лечит virtual lgap.

## Хост A/B (30 с virtual, `gs_render`, 3 MOD)
Сборка: текущий `gs_arm` / `gs_host_fx_test` (instrumented lgap).  
Файлы: `/tmp/gsprof/wizardry.mod`, `/tmp/2-3song6.mod`, `/tmp/sykse.mod`.

| MOD | rush | worst lgap (virtual) | ~ms @12MHz | spikes>50k | latches/30s |
|---|---|---:|---:|---:|---:|
| wizardry | on | 59608 | 5.0 | 2 | 4.21M |
| wizardry | off | 59599 | 5.0 | 2 | 4.06M |
| 2-3song6 | on | 525 | 0.04 | 1* | 4.15M |
| 2-3song6 | off | 525 | 0.04 | 1* | 4.15M |
| sykse | on | 32261 | 2.7 | 1* | 3.62M |
| sykse | off | 32136 | 2.7 | 1* | 3.50M |

\* spike на старте play (~4 s virtual) — отсев max_gap фильтром `<12e6`; в WORST не входит.

### Вывод A/B
- **Rush не уменьшает virtual lgap** (и не должен: DI-секция та же по тактам Z80).
- Rush **должен** сжимать **настенное** время hold (250→2000 тактов/сэмпл ЦАП): 60k тактов → ~5 мс wall без rush, ~0.6 мс с rush.
- На хосте worst mid-play gap **5 мс virtual**, на плате раньше мерили **до 25 мс** — на плате, вероятно, **добавляется** нагрузка ZX (опросы `#60..`, FDD/IDE, главный цикл), не только ROM DI.
- **2-3song6** почти без mid-play spike — затык **зависит от модуля/паттерна**.

## Прошивка на SD
**v0.15.326 + B0120** (`BOOT_B0120_v326` / `flash/BOOT.BIN`).

## Когда владелец у платы
1. F12 → v0.15.326.
2. Z-Player → wizardry (или тот же MOD, что бесил) → Play.
3. Слышимый стык: лучше / так же / хуже.
4. JTAG (без остановки плеера): `sgap` @ `KMB+0x5A4C`, `lgap` @ `+0x5A30`, avg/debt.

## Дальше (если 326 мало)
- На плате во время игры снять `sgap` + `acc` (нагрузка опросов).
- Хост: wall-time gap (счётчик сэмплов ЦАП между latch), не только virtual.
- Разобрать PC `2FCx` / `5C3x` в RAM плеера на spike (что делает gs105b ~60k тактов).
- Не возвращать mute; не rush на idle.

Логи A/B: `/tmp/gs_ab_{rush,norush}_{wizardry,song6,sykse}.log`

## 2026-08-11 live + v0.15.328

Плата v327 во время Z-Player (дискета): avg=12 debt=0, **sgap sticky 1741767** (~145 ms).
x8+cap4000 → ~9 ms wall — мало. **v328:** burst min(starve,24000)/sample, cap 24000 → ~1.5 ms.
BOOT_B0120_v328 на SD после warm_sd_reboot; live string v0.15.328.
Ждём слух владельца.

## 2026-08-11: карта @ZX_MURMULATOR (Hermes) → наш GS/Z-Player

Источник: сводка Hermes по t.me/ZX_MURMULATOR (Chiptune 16541, Кодинг 42804, pico-spec 241767, SpeccyP 241406, …).

### Три разных «стыка» (часто путают)

| # | Класс (чат) | Механика | У нас (BulbuLator) | Прибор |
|---|---|---|---|---|
| **1** | Pattern transition spike | Bxx/Dxx/E6x + **9xx sample offset** в один тик: плеер «не успевает» (Alex Spawn 178840, professional_tracker.mod) | Z-Player на ZX → прошивка GS (gs105b) на **нашем** Z80: долгий **DI без latch** #6000.. | **sgap/lgap** вирт. такты; v327 sticky **~1.74e6** (~145 мс hold @12 МГц) |
| **2** | Note-on click | signed/unsigned, vol*data, нет ramp/zero-cross (Eugene GS, 215545…) | `gs_mix` / защёлка сэмпла | **игла** на waveform, не дыра; peak/слуховой A/B |
| **3** | Buffer/IO underrun | SD/PSRAM, маленький ring, blocking read mid-row | Сэмплы уже в ОЗУ GS после загрузки; ARM FIFO ЦАП | **avg/debt/gaps**: live **12.0 / 0 / ~0** → класс 3 **не главный** |

### Что чат говорит полезного

1. **Эталон тяжести:** `hoffman_and_daytripper_-_professional_tracker.mod` (msg 178721) — jump + sample offset.
2. Pattern loop/jump/break — зависания/бесконечные loop (178723, 184127), не наш «слышный стык».
3. Тяжёлые/пакованные семплы, «шипит» на больших MOD (Z-player 248530) — лимиты 4ch/RAM.
4. Щелчок **первого кванта** нового семпла ≠ DI-gap, но на смене паттерна куча note-on → на слух «стык».
5. PicoMite MODBUFF / SPI PSRAM — другой pipeline (ESP/Pico), не soft-GS.

### Наш путь (не путать с soft-MOD на ARM)

```
ZX Z-Player → порты GS → ARM: Z80 gs105b + RAM + DAC FIFO → audio
```

Стык v322–327: **класс 1 на стороне GS-Z80** (virtual lgap), wall = f(want,cap).
Underrun ARM (класс 3) приборами **снят**. Класс 2 — если после 328 останутся **щелчки** без «дыры».

### Что уже сделано vs чеклист чата

| Чеклист MURMULATOR | Статус у нас |
|---|---|
| professional_tracker.mod A/B | ещё не гоняли на плате |
| простой 4ch без Bxx/9xx | offline song6 почти clean |
| waveform: дыра / игла / stretch | дыра hold = sgap; иглу не снимали |
| preload samples (не SD mid-row) | после load — GS RAM; FDD poll = ZX |
| crossfade/ramp note-on | нет (gs_mix hold) |
| FIFO / double-buffer pattern | FIFO ЦАП есть; decode = внутри GS ROM |
| **сжать wall DI** | **v0.15.328**: burst min(starve,24k)/sample |

### Ссылки (Telegram)

- jump+offset: https://t.me/ZX_MURMULATOR/16541/178840
- pattern effects hang: https://t.me/ZX_MURMULATOR/16541/184127
- professional_tracker.mod: https://t.me/ZX_MURMULATOR/16541/178721
- packed samples: https://t.me/ZX_MURMULATOR/16541/198642
- GS clicks: https://t.me/ZX_MURMULATOR/42804/215402 , …/215545
- SPI PSRAM MOD: https://t.me/ZX_MURMULATOR/241767/269287
- Z-player large hiss: https://t.me/ZX_MURMULATOR/241406/248530

### Следующие шаги (после слуха по v328)

1. Владелец: v328 + тот же трек → лучше/так же/хуже.
2. Если лучше, но щелчки: класс 2 — signed/vol ramp в `gs_mix`.
3. Если так же: sticky sgap после 30 с; при sgap≫100k — burst↑ или PC spike.
4. A/B: professional_tracker.mod vs простой 4ch.

## 2026-08-11 v328 FAIL → v329 rollback

Owner: v328 worse — tempo shifts at pattern joints + squeaks.

Cause: burst min(starve,24k) Z80 cycles per DAC sample = pitch-up during DI.

**v0.15.329** on SD (live): back to rush x8 + cap 4000 only when gs_n_int>0 (like v326). No full-starve catch-up.

Next: not wall-burst. Candidates: note-on/mix (class 2), PC on sgap — not time warp.


## 2026-08-11 PiCard + GSTATE (owner)

### GSTATE = 0x7E
- Пикард: init GSSTAT=0x00 ломал игры с GS (ждут 0x7E); MOD мог играть. В zip уже GSSTAT=0x7e.
- У нас УЖЕ: status = (outp?0x80:0)|0x7E|(cmd?1:0). Для MOD-стыка не причина.
- Важно для handshake игр, не для стыка паттернов.

### PiCard GS
- Soft-Z80 + gs105b, ExecZ80(dt*12)+IntZ80 в аудио. Mix (ch-128)*vol.
- Не копировать костыли mix/L-R. Time-warp запрещён (v328).
- Цель: безстыково, без щелчков и без смены темпа.

## 2026-08-11 КЛЮЧЕВОЙ A/B владельца (ZYNAP vs Z-Player)

Источник: диалог владельца (RemX / личный лог 11.08 ~10:04).

### Факты
1. **ZYNAP_GS.TRD** — музыка **хорошо**, **стыков между паттернами нет**.
2. Ребут машины так, что **GS продолжил играть** (карта независима — ожидаемо).
3. Выход в **TR-DOS** — музыка **продолжает**, **стыков нет**.
4. Запуск **Z-Player** — «подхватил» уже играющий модуль: экран, трек, имя, сэмплы, бежит.
5. **Как только загрузился Z-Player — стыки между паттернами появились.**
6. Вывод владельца: стыки **только при рабочем Z-Player**; TR-DOS / без Z-Player — на слух чисто.

### Следствия (обязательны для следующего фикса)
| Не виновато (как главная причина) | Скорее виновато |
|---|---|
| «MOD сам по себе всегда рвётся на soft-GS» | **Нагрузка ZX/Z-Player** на порты GS + главный цикл ARM |
| GSTATE 0x7E (игра играет) | Опросы **#BB status** / UI Z-Player / протокол во время play |
| class-2 note-on click (щелчков нет) | Wall-stretch `gs_run`: тот же virtual DI → дольше hold, пока ARM обслуживает Z-Player |
| time-warp burst (запрещён) | Возможно команды/синхронизация Z-Player на смене паттерна |

Модуль **тот же** (из игры) — стык появляется **с хостом Z-Player**, не с другим файлом.

### Что мерить дальше
1. `gs_m_poll` (status polls/s) во время **игры** vs **Z-Player** (после 1 с окна).
2. avg/min10/debt/sgap в обоих режимах (одно чтение sticky после play).
3. Не mid-play heavy JTAG.

### Направление фикса (не burst)
- Дешевле/реже зеркало status в фабрику при лавине опросов.
- Приоритет `gs_pump`/`gs_render` над FDD/UI, пока GS live.
- Разобрать, что Z-Player шлёт на смене order/row (не разгонять Z80 GS).


## 2026-08-11 КЛЮЧЕВОЙ A/B + v0.15.330

### Находка владельца (10:04)
- **ZYNAP** — музыка хорошо, **стыков нет**
- Ребут ZX, GS **продолжил** играть; **TR-DOS** — стыков нет
- Запуск **Z-Player** → подхватил тот же модуль (имя, сэмплы, трек бежит)
- **Стыки появились сразу с Z-Player**
- Вывод: стыки **только при рабочем Z-Player**, не «MOD всегда рвётся»

### Разбор кода (уже было в комментариях v299)
- Z-Player окно трекера шлёт **#60..#64** (позиция/ноты/громкости) — `gs_cmd_is_query`
- «Когда окно плеера закрыто — музыка без сбоев» — тот же эффект, что A/B
- Игра/TR-DOS **не** долбят эти опросы → pure GS playback гладкий
- Лавина опросов + `gs_flags_pump` (дорогие AXI) **перед** сэмплами + `disk_service` **перед** GS → wall-hold

### Fix v0.15.330 (на SD, live)
1. **gs_pump:** сначала порция `gs_render` (64–128 сэмплов), потом `gs_flags_pump`, потом долив — **не** time-warp
2. **main loop:** если `g_gs_live` — `gs_service` **до** `disk_service` (не после net)

BOOT: `BOOT_B0120_v330.BIN`. Запрет v328 burst остаётся.

### Если стыки на 330 ещё есть
- Считать `gs_m_poll` Z-Player vs ZYNAP
- Дальше: ещё удешевить status mirror; не burst Z80
