# BulbuLator Step 15 — handover эстафеты Claude → GPT

Дата: 2026-07-24, Europe/Berlin  
Автор этого этапа: GPT/Codex  
Проект: `ZX_BulbuLator`, EBAZ4205/Zynq-7010  
Основной каталог: `BulbuLator/research/15-pentagon`

Этот документ — не release note, а подробная инструкция для следующего агента.
Он фиксирует:

- какое состояние было принято после большой сессии Claude;
- какие наблюдения владельца были подтверждены;
- какие причины найдены и какие исправления приняты;
- какие экспериментальные решения отвергнуты;
- что сейчас находится на плате;
- что находится только в исходниках или ещё собирается;
- как продолжить без потери воспроизводимости и без случайной перезаписи
  постоянного `BOOT.BIN`.

Документ следует читать вместе с:

- `/tmp/agent_bridge.md` — канонический append-only журнал GPT/Claude/Hermes;
- `JOYMAP_DESIGN.md`;
- `BUILD_HISTORY.md`;
- `TAPE_MATRIX.md`;
- `artifacts/B004A_v137/MANIFEST.md`;
- `artifacts/B004B_v138/MANIFEST.md`.

## 1. Короткая сводка

После Claude были подхвачены четыре связанные темы:

1. довести нативную машину ZX Spectrum 48K до корректного cold boot;
2. сделать корректный переход 128K ↔ 48K и надёжный автостарт
   `LOAD ""`;
3. проверить реальные 48K timing-тесты и добавить опцию ULA
   Type 1/Early ↔ Type 2/Late;
4. не потерять уже работающий JOYMAP/Kempston и ленточную подсистему.

Закрыто и подтверждено на железе:

- нативный 48K теперь грузится с настоящим 48K BASIC ROM;
- 48K RAM `0xC000..0xFFFF` согласована с ARM snapshot/inject convention;
- cold boot 48K проходит стабильно;
- переход машины делается через guarded reset/wipe, без исполнения кода
  из ROM предыдущей модели;
- автостарт 48K оставлен через настоящий matrix-level `LOAD ""`;
- исправлена потеря второй кавычки;
- `TRAPTEST.tap` загружается и завершает BASIC-путь;
- `3DDeathChase.wav` на 48K загружается и запускается;
- первый этап JOYMAP сохранён: QAOP+Space → Kempston работал у владельца;
- управление Early/Late из меню, config и register plane работает;
- оригинальный timing test найден, скачан и разобран побайтно.

Не закрыто:

- физическая реализация Type 2/Late ещё не принята тестом;
- `sna48k-snow.sna` на BulbuLator выглядит иначе, чем ожидает владелец;
- произвольное назначение всех восьми битов Kempston в меню ещё не сделано;
- постоянный `BOOT.BIN` новыми кандидатами не обновлялся.

Последний проверенный кандидат:

- FPGA `B004E`;
- ARM `v0.15.141`;
- цель — сдвинуть на один CPU T именно CPU-facing `/INT`, который
  измеряет оригинальный timing detector;
- ARM и полный Vivado synth/place/route успешно собраны на ThinkPad;
- timing closure: WNS `+0.205 ns`, TNS `0`, WHS `+0.006 ns`, THS `0`;
- `.bit` и `.elf` скопированы на Mac в `/tmp`, SHA-256 приведены ниже;
- кандидат загружен на плату только волатильно и отвергнут оригинальным
  detector: Early и Late оба дали `TYPE1`;
- persistent image не менялся.

## 2. Безопасность и постоянная прошивка

Главное правило: не выполнять persistent flash/SD update без отдельного
явного `GO` владельца.

Все кандидаты этого этапа загружались или должны загружаться только
волатильно:

- PCAP/no-readback для FPGA;
- JTAG `dow`/run для ARM.

Постоянный файл:

`research/15-pentagon/flash/BOOT.BIN`

SHA-256:

`c656d2c22218b18548473a3c86b72dba00d77bafd8aa422cc66f55c81932aacb`

Это rollback/production image, оставленный Claude. По его последнему
handover это production v136; в старом bridge-журнале присутствует более
ранняя отметка v131. Важен проверенный факт этого этапа: GPT этот файл не
изменял.

Перед любым будущим persistent update:

1. повторно посчитать SHA текущего `BOOT.BIN`;
2. сделать отдельный backup;
3. зафиксировать source snapshot и manifest кандидата;
4. выполнить hardware acceptance;
5. только после явного `GO` владельца собирать новый `BOOT.BIN`;
6. после power cycle выполнить cold-boot smoke.

## 3. Что было принято после Claude

Claude завершил большой ленточный этап и оставил:

- production v136 по своему последнему сообщению;
- стабильный TAP/TZX/WAV/MP3 fallback;
- SMART default YES после sweep `199/199`;
- tape restorer;
- первый аппаратный этап JOYMAP;
- план 48K + JOYMAP + timing.

Из его последней сессии были уже внесены:

- `JOY_STATE` control register;
- capability bit;
- CDC и deadman;
- подключение `joy1` к Kempston core input;
- ARM QAOP+Space → Kempston;
- попытка исправить 48K physical RAM bank;
- guarded смена машины;
- SMART default YES.

Владелец вручную подтвердил первый этап Kempston:

- в EXOLON был выбран Kempston;
- Q/A/O/P/Space управляли персонажем;
- базовое аппаратное соединение JOYMAP считается рабочим.

Незакрытое требование владельца по джойстику:

- произвольное назначение кнопок;
- все восемь бит, а не только пять стандартных;
- отдельная карта для каждого physical pad;
- возможность направлять любой pad в любую машину;
- арбитраж с будущими физическими контроллерами.

Это не было удалено и не должно быть потеряно при продолжении timing-работы.

## 4. Нативный 48K: найденные причины

### 4.1. Банк `0xC000`

Claude правильно нашёл несовпадение:

- ARM snapshot/tier0/ROM-trap записывают верхние 16 KiB 48K-образа в
  physical bank 0 по 128K post-boot convention;
- старый 48K RTL читал `0xC000` из bank 6.

Текущий код:

`sources/atlas_core/memory.v`

```verilog
wire[2:0] ramPage =
    a[15:14] == 2'b01 ? 3'd5 :
    a[15:14] == 2'b10 ? 3'd2 :
    model ? port7FFD[2:0] : 3'd0;
```

Это исправляет black-screen snapshot/inject mismatch.

### 4.2. Главный корень cold-boot: неверная ROM-страница

Даже после bank fix 48K не проходил boot. CPU исполнял ROM, но экран
оставался чёрным/мусорным.

Причина оказалась не в ESXDOS automapper, а в выборе ROM:

- model 48K выбирал ROM page `00`;
- в combined toastrack ROM это `128-0.rom`, то есть 128K editor/menu ROM;
- настоящая 48K BASIC ROM находится в page `01` (`128-1.rom`).

Текущий код:

```verilog
wire[1:0] romPage =
    model ? {1'b1, port7FFD[4]} : 2'b01;
```

ROM provenance:

| ROM | Назначение | SHA-256 |
|---|---|---|
| `128-0.rom` | 128K editor/menu | `3ba308f23b9471d13d9ba30c23030059a9ce5d4b317b85b86274b132651d1425` |
| `128-1.rom` | standard 48K BASIC | `8d93c3342321e9d1e51d60afcd7d15f6a7afd978c231b43435a7c0757c60b9a3` |
| combined | bank0 + bank1 | `c1ff621d7910105d4ee45c31e9fd8fd0d79a545c78b66c69a562ee1ffbae8d72` |

### 4.3. Смена модели должна сопровождаться reset

Владелец правильно заметил невозможное поведение: после переключения на
48K появлялся 128K loader/menu.

Причина:

- ARM менял `MACHINE_CFG` на живом CPU;
- CPU продолжал исполнять адреса/стек/ROM-контекст старой модели;
- получался код одной модели в ROM другой.

Текущий `apply_machine()` делает guarded transition:

1. halt;
2. reset/wipe при реальной смене модели;
3. записывает `MACHINE_CFG` во время остановленного CPU;
4. снимает halt;
5. same-machine настройку Early/Late применяет без wipe.

Не возвращать hot model flip без reset.

## 5. Воспроизводимый RTL build

До этого Atlas core изменялся внутри dirty dependency checkout, поэтому
битстрим нельзя было надёжно восстановить из step-local sources.

Теперь критичные Atlas-файлы vendored в:

`research/15-pentagon/sources/atlas_core/`

Там находятся:

- `main.v`;
- `memory.v`;
- `video.v`;
- `ps2.v`.

`sources/assemble.sh` копирует именно эти версии в `sources/build/`.

Это важно: не исправлять 48K снова только в `cores/zx` или `zxatlas/src`.
Vivado Step 15 должен получать step-local `sources/atlas_core`.

Команда подготовки:

```sh
cd BulbuLator/research/15-pentagon/sources
sh assemble.sh
```

Проверка после assemble:

```sh
rg -n "romPage|ramPage|B01B004E|irq_late|cpu_irq" \
  build/atlas_core/memory.v \
  build/atlas_core/main.v \
  build/bulbulator_zx_ddr_top.v
```

## 6. Кандидаты B004A/B004B

### B004A / ARM v137

Статус: отвергнутый pre-fix baseline.

Содержал:

- JOYMAP stage 1;
- initial 48K bank fix;
- guarded machine change;
- SMART default YES.

Но 48K выбирал неправильный ROM page и не проходил cold boot.

Артефакты:

`artifacts/B004A_v137/`

Bit SHA:

`9def82842ee45e48d3337988fb5f2f9685f5f9e7a5f6a4f397d1fd2c1261c359`

ELF SHA:

`59905335f958aa518b05e5e7187646be8cc23bff43106f92c59554827901244c`

### B004B / ARM v137-v138

Статус: первый аппаратно принятый 48K base candidate, но не persistent.

FPGA изменения:

- `romPage=01` в 48K;
- `ramPage=0` для 48K `0xC000`;
- vendored build path.

Bit:

`artifacts/B004B_v138/bulbulator_zx_loader_B004B.bit`

SHA:

`cbc7d59e8a4b73840acbeebc708db9e52c48fe5866f5e9c53826c4473d2e2460`

Timing:

- WNS `+0.195 ns`;
- TNS `0`;
- WHS `+0.033 ns`;
- THS `0`.

ARM v138:

`artifacts/B004B_v138/loader_v0.15.138.elf`

SHA:

`0d457b1cb1036bfe540056e18efed9b6e4c55c5d4014709ee294c6f05eaa0bd7`

Hardware evidence:

- native 48K cold boot `3/3`;
- одинаковый screen SHA:
  `c2c7ee9cb8d9d65b84c1e3aa806d4d53a9f64f7054608051665361f6d61abc18`;
- виден `© 1982 Sinclair Research Ltd`;
- `sna48k-timing.sna` доходит до собственного меню;
- `TRAPTEST.tap` проходит;
- `3DDeathChase.wav` проходит.

## 7. Автостарт 48K

### 7.1. Прямой вызов ROM loader был проверен и отвергнут

Владелец предложил не печатать `LOAD ""`, а сразу передавать CPU на
подпрограмму ROM loader.

Был сделан экспериментальный matrix-free `LINE_RUN`.

Почему это ненадёжно:

- ROM loader — не отдельная чистая функция;
- он ожидает корректный BASIC/ROM call frame;
- использует system variables;
- использует stack и alternate registers;
- зависит от состояния, которое готовит BASIC statement path.

На железе прямой запуск не прошёл acceptance. Он не находится в v138 и не
должен быть возвращён без полной формальной подготовки всего ROM ABI.

### 7.2. Принятый путь: настоящий `LOAD ""`

Для native 48K phantom typist делает:

1. `J` — ROM превращает это в keyword `LOAD`;
2. Symbol Shift + `P` — первая кавычка;
3. полный all-keys-up;
4. Symbol Shift + `P` — вторая кавычка;
5. Enter.

Проблема v137:

- две одинаковые quote-комбинации приходили слишком быстро;
- ROM keyboard debounce объединял их;
- на экране реально оставалось `LOAD "`;
- ранний probe ошибочно скрывал это дополнительной задержкой перед
  screen capture.

Исправление v138:

- 180 ms all-keys-up между quote1 и quote2;
- 120 ms перед Enter.

Код:

`arm/loader_main.c`, `zx_tape_autostart()`.

Владельцем выбрано оставить именно этот надёжный путь.

### 7.3. Custom ROM

Поскольку пользователь может подключить custom ROM, автостарт нельзя
считать универсальным только потому, что он работает с stock 48 ROM.

Нужна отдельная будущая задача:

- профиль ROM;
- способ автостарта:
  - matrix `LOAD ""`;
  - известный ROM entry point;
  - отключённый автостарт;
- пользовательская настройка/metadata;
- отсутствие жёсткой привязки к адресу stock ROM loader.

Текущий безопасный default для stock 48K — matrix `LOAD ""`.

## 8. Принятые 48K тесты

### TRAPTEST.tap

Параметры:

- native 48K;
- FAST8;
- Sync off;
- Smart off.

Результат:

- descriptor fingerprint `11852 / 16EB5D5A`;
- gaps/resumes `1/0`;
- видны:
  - `Program: TRAPTEST`;
  - `TRAPOK`;
  - `0 OK, 10:1`.

Screen artifact:

`artifacts/B004B_v138/b004b_v138_traptest.bin`

### 3DDeathChase WAV

Файл:

`0:/loadtest/TurboLoad/3DDeathChase(1983)(Micromega)[a].wav`

Параметры:

- native 48K;
- AUTO `8→4`;
- Sync off;
- Smart off.

Результат:

- fingerprint `364281 / 3460475C`;
- gaps/resumes `1/0`;
- PC `0x60B7`, game RAM;
- видна цветная игровая сцена.

Screen artifact:

`artifacts/B004B_v138/b004b_v138_3ddc.bin`

## 9. Early/Type 1 и Late/Type 2

### 9.1. Что уже работает

ARM/control plane:

- `MACHINE_CFG` bit 2;
- `opt_ulalate` в fixed non-cacheable mailbox `KMB+0x3C`;
- menu item `ULA TIMING`;
- отдельное сохранение:
  - `zx48.ula_late`;
  - `zx128.ula_late`;
- default Early;
- Pentagon подавляет этот бит и сохраняет собственные `INT H/V`.

Readback smoke подтвердил:

```text
ULA48_EARLY_OK cfg=00000002
ULA48_LATE_OK  cfg=00000006
ULA128_EARLY_OK cfg=00000000
ULA128_LATE_OK  cfg=00000004
ULA48_RESTORE_OK cfg=00000002
```

Следовательно, неисправность была не в menu/ARM/CDC.

### 9.2. Отвергнутый B004C / v139

Гипотеза:

- сдвинуть raw `/INT` 48K на `-1T`;
- остальной raster/contention оставить.

Результат:

- `MACHINE_CFG=6`;
- `opt_late=1`;
- оригинальный тест всё равно показывает Early.

Кандидат отвергнут.

Bit:

`/tmp/bulbulator_zx_loader_B004C.bit`

SHA:

`78e7b84a1e704cadfff30cf57672e2611e319ba5384ee1fd3fd2908950e3c1c5`

ARM:

`/tmp/loader139.elf`

SHA:

`965241c3280d65339493fe58b9b9336f29e26448f1cc2410e45450af774fa207`

### 9.3. Отвергнутый B004D / v140

Гипотеза была взята из Fuse:

```c
if(settings_current.late_timings)
    machine->line_times[0]++;
```

В RTL:

- raw `/INT` оставлен fixed frame reference;
- введены `hUla/vUla`;
- display, contention, floating bus, blank/sync сдвинуты на `+1T`;
- опция добавлена также в Sinclair 128K;
- Pentagon исключён.

Bit:

`/tmp/bulbulator_zx_loader_B004D.bit`

SHA:

`eac1479a38ad7bb1ff8cf86c37c7640dff5db6d504b9dd0fae3856b367ad9a16`

Bit.bin:

`/tmp/bulbulator_zx_loader_B004D.bit.bin`

SHA:

`d635898ca084e129fc077354e992a279caa266aa13aa9b3a017e04d2dbc9cda3`

ARM:

`/tmp/loader140.elf`

SHA:

`40f4c918c930fe00965556d0723884bf0b0ffba6696e477e3c29665a86cda3f2`

Timing:

- WNS `+0.385 ns`;
- TNS `0`;
- WHS `+0.033 ns`;
- THS `0`.

Clean hardware verdict:

```text
VER=B01B004D
MACHINE_CFG=00000006
opt_late=1
TYPE1 (Early) timings detected
```

Кандидат отвергнут как решение detector task.

Сдвиг display/contention сам по себе может быть физически осмыслен, но
он не меняет CPU-visible interrupt phase, которую измеряет этот тест.

## 10. Оригинальный timing test: точный разбор

Чтобы не продолжать угадывать, был найден оригинальный файл:

`Timing_Tests-48k_v1.0.sna`

Источник:

Wayback snapshot официального `zxspectrum4.net`.

Локальная копия:

`/tmp/Timing_Tests-48k_v1.0.sna`

SHA-256:

`b30fa49bd85dc5cefaf014a3088c6568256796f1a8541fca6ed9edce46bce9cf`

Файл был:

- распарсен как SNA;
- дизассемблирован SkoolKit;
- BASIC program восстановлен;
- исполнение протрассировано в SkoolKit.

Ключевой BASIC-классификатор:

```basic
IF x=2 AND y=0 AND z=49478 THEN
  "TYPE1 (Early) timings detected."

IF x=122 AND y=0 AND z=49478 THEN
  "TYPE2 (Late) timings detected."
```

Адреса:

- `x = PEEK 61184 = PEEK 0xEF00`;
- `y = word at 0xEF01`;
- `z = word at 0xEF03`;
- `49478 = 0xC146`.

Механика:

1. код выравнивается по frame interrupt через HALT;
2. ставит IM2;
3. запускает `JP (HL)` на `0xC146`;
4. loop находится в uncontended RAM;
5. IM2 handler делает `LD A,R`;
6. значение `R` сохраняется в `0xEF00`;
7. BASIC классифицирует Type 1/Type 2.

Следствие:

- тест не смотрит на изображение;
- не смотрит на contention;
- не использует floating bus;
- он измеряет момент, когда Z80 принимает `/INT`.

### Ключевая особенность Atlas

В `sources/atlas_core/main.v` raw ULA interrupt не идёт прямо в T80.

Исторический путь:

```verilog
reg irq = 1'b1;
always @(posedge clock)
    if(pc3M5)
        irq <= vduI;
```

T80 получает пересэмплированный `irq`.

Поэтому:

- raw сдвиг B004C мог исчезнуть на `pc3M5` boundary;
- display-only сдвиг B004D вообще не мог повлиять на тест.

Сравнение с MiSTer:

- repo: `/private/tmp/ZX-Spectrum_MISTer`;
- commit:
  `9388aac649c881140c061fab85d5cf37336cf802`;
- `rtl/ula.sv` подаёт `nINT` в T80 напрямую;
- отдельного Atlas-style `if(pc3M5) irq <= vduI` там нет.

## 11. Отрицательный кандидат B004E / v141

Цель:

- оставить Early path без функционального изменения;
- для Late добавить один полный CPU T именно в CPU-facing `/INT`;
- сохранить B004D `hUla/vUla` для screen/contention phase;
- сохранить pulse width.

Текущий код:

```verilog
reg irq = 1'b1;
reg irq_late = 1'b1;

always @(posedge clock) if(pc3M5) begin
    irq      <= vduI;
    irq_late <= irq;
end

wire cpu_irq = ula_late ? irq_late : irq;
```

T80 получает:

```verilog
.irq(cpu_irq)
```

FPGA version:

`B01B004E`

ARM version:

`v0.15.141`

Состояние сборки:

- source assembly прошёл;
- итоговый build содержит `B01B004E`, `irq_late`, `cpu_irq`;
- ARM build завершён;
- ELF на ThinkPad:
  `/tmp/loader141.elf`;
- полный Vivado synth/place/route и `write_bitstream` завершились успешно;
- timing:
  - WNS `+0.205 ns`;
  - TNS `0`;
  - WHS `+0.006 ns`;
  - THS `0`;
- bitstream на ThinkPad и Mac:
  `/tmp/bulbulator_zx_loader_B004E.bit`;
- SHA-256 bitstream:
  `7f133ff3af0a6b7bf653230dc7023f4d01d272629bedef9c21458b21ecea7131`;
- ARM ELF на ThinkPad и Mac:
  `/tmp/loader141.elf`;
- SHA-256 ELF:
  `168f7527d044dcd1d0eb505137a0e2cdb46ebca1383c2775d473ce59cbe0e57a`;
- `.bit.bin` SHA-256:
  `74c2b28e0887f3e63848942b4b188eda2614f2c1399d63916c71f0e694cc019c`;
- B004E/v141 загружены волатильно через PCAP/JTAG;
- readback после загрузки:
  - `VERSION=B01B004E`;
  - Early `MACHINE_CFG=00000002`;
  - Late `MACHINE_CFG=00000006`;
- clean Early snapshot:
  - экран сообщает `TYPE1 (Early) timings detected`;
  - screen SHA-256
    `f5fe2b24d28f05ce3d62f8553e48ab85d0600643ce69c8527eadb0c9ca9be197`;
- clean Late snapshot:
  - экран также сообщает `TYPE1 (Early) timings detected`;
  - screen SHA-256 совпадает побайтно:
    `f5fe2b24d28f05ce3d62f8553e48ab85d0600643ce69c8527eadb0c9ca9be197`;
- B004E отвергнут как реализация Type2.

Вывод: следующий вариант нельзя собирать простой заменой направления
задержки. Сначала нужно наблюдать T80 interrupt acceptance и проверить,
что `ula_late` реально доходит до выбранного mux в собранном netlist.

Искомый критерий будущего кандидата остаётся:

```text
Early -> TYPE1
Late  -> TYPE2
```

на одном и том же оригинальном SNA.

## 12. `sna48k-snow.sna`

Новый файл владельца:

`/Users/alex/zxwork/loadtest/sna48k-snow.sna`

SHA-256:

`b0fcab765d11eb40b5383448418ed3dbd16e8bd9fd05c9f8af5f81798856c4cd`

SNA:

- 48K;
- PC после восстановления snapshot `0x33B1`;
- interrupts disabled в snapshot;
- IM1;
- border 7.

Фактический machine code:

```asm
8068 DI
8069 LD HL,7E00
806C LD DE,7E01
806F LD BC,0100
8072 LD (HL),80
8074 LD A,H
8075 LD I,A
8077 LDIR
8079 LD HL,807F
807C IM 2
807E EI
807F JP (HL)
```

IM2 vector table:

- `I=0x7E`;
- refresh/vector area находится в contended range;
- handler меняет `R`;
- это намеренно провоцирует 48K ULA snow.

Screen attributes:

- 768 bytes;
- ни одного FLASH attribute;
- значения только `8`, `16`, `24`, `32`.

Следовательно, если экран мигает, это не обычный Spectrum FLASH bit.

Текущий Atlas snow path:

```verilog
assign vmmA1 = {
    vmmPage,
    va[12:7],
    !rfsh && addr01 ? a[6:0] : va[6:0]
};
```

Риск:

- модель может быть слишком широкой или иметь неверную фазу;
- она подменяет младшие семь адресных линий при refresh;
- нужно проверить точную ULA fetch phase и ограничение только 48K;
- текущий код не содержит явного `!model`, поэтому snow path потенциально
  активен и в 128K, хотя реальная 128K ULA snow bug исправила;
- build system уже поддерживает `NO_SNOW`/`nosnow`, но default собран со
  snow enabled.

Не делать немедленный вывод, что статичная картинка эмулятора является
эталоном реального 48K:

- многие эмуляторы вообще не моделируют snow;
- сам файл явно предназначен для вызова snow;
- на реальной 48K при `I=0x40..0x7F` snow ожидаем.

Нужное продолжение:

1. выяснить, какой именно emulator использовал владелец и включена ли там
   snow emulation;
2. найти референсное видео/trace на настоящем 48K;
3. сравнить default и `nosnow` build;
4. снять frame-by-frame screen mirror;
5. проверить, является ли наблюдаемое мерцание корректным snow или
   ошибочной слишком широкой подменой адреса;
6. обязательно добавить `!model` gate для 128K, если snow path сохраняется.

Snow-задачу не смешивать с Type 2 `/INT`: это два разных тракта.

## 13. JOYMAP: текущее состояние

FPGA:

- capability `LOAD_CAPS bit0`;
- `JOY_STATE @ GP0+0x100`;
- 7-bit register index space, потому что старое `0xC4` конфликтовало с
  `PENT_INT`;
- CDC;
- deadman;
- `joy1` подключён к core Kempston;
- `joy2` зарезервирован.

ARM:

- `joymap_eval()`;
- default QAOP+Space;
- клавиатурный state хранится и обновляется на make/release;
- stage 1 подтверждён владельцем.

Нужно сделать дальше:

- меню назначения каждого из восьми битов;
- P1/P2;
- хранение профилей;
- arbitrary key → arbitrary Kempston bit;
- physical pad arbitration;
- no stuck bit при открытии OSD/смене профиля;
- сохранение deadman fail-safe.

Не переносить JOY register назад на `0xC4`: этот адрес занят.

## 14. Файлы, изменённые GPT

Критичные актуальные файлы:

- `sources/atlas_core/memory.v`
  - 48K ROM page;
  - 48K top RAM bank;
- `sources/atlas_core/main.v`
  - ULA Late input;
  - B004E CPU-facing `/INT`;
- `sources/atlas_core/video.v`
  - `hUla/vUla`;
  - fixed raw `/INT` reference;
- `sources/axi_ctl.v`
  - `MACHINE_CFG bit2`;
  - JOY register space;
- `sources/bulbulator_zx_ddr_top.v`
  - version;
  - CDC;
  - machine routing;
- `arm/loader_main.c`
  - v141 tag;
  - guarded machine transition;
  - ULA menu/config;
  - 48K quote delay;
  - retained JOYMAP;
- `sources/assemble.sh`
  - vendored Atlas inputs;
- `tools/jtag_set_ula_late.tcl`;
- `tools/jtag_b004d_ula_phase_probe.tcl`;
- `tools/jtag_snapshot_phase_capture.tcl`.

Артефакты и manifests:

- `artifacts/B004A_v137/`;
- `artifacts/B004B_v138/`.

B004C/B004D пока находятся в `/tmp`; следующий агент должен либо
заархивировать их с manifests как rejected experiments, либо явно оставить
временными. Не выдавать их за production.

## 15. Текущее состояние платы

Последнее подтверждённое волатильное состояние:

```text
FPGA version: B01B004E
ARM version:  v0.15.141
machine:      native 48K
ULA setting:  Late
MACHINE_CFG:  00000006
```

На экране был оригинальный timing test, который сообщил Type 1/Early.

Persistent image не менялся.

Power cycle должен вернуть production image, а не B004D/v140.

Перед дальнейшим hardware test пассивно прочитать:

- version register `0x40000000`;
- `MACHINE_CFG 0x400000BC`;
- fixed mailbox:
  - machine;
  - `opt_ulalate`.

Не использовать full smoke, который в конце автоматически возвращает Early,
если владелец в этот момент смотрит Late test. Такой случай уже привёл к
неоднозначному первому наблюдению.

## 16. Как продолжить B004E

### 16.1. Remote build уже проверен

Фактический результат:

- `write_bitstream completed successfully`;
- WNS `+0.205 ns`;
- TNS `0`;
- WHS `+0.006 ns`;
- THS `0`.

Артефакты:

- `/tmp/loader141.elf`;
- `/tmp/bulbulator_zx_loader_B004E.bit`.

Оба уже скопированы на Mac, SHA-256 приведены в разделе 11.

### 16.2. До загрузки на плату

Проверить:

```sh
rg -n "B01B004E|irq_late|cpu_irq" \
  research/15-pentagon/sources/build
```

Создать `.bit.bin` только из готового routed bitstream.

Не собирать BOOT.BIN.

### 16.3. Волатильная загрузка — выполнена

1. PCAP/no-readback FPGA;
2. ARM v141 через JTAG;
3. прочитать version;
4. проверить menu/control-plane Early/Late;
5. загрузить оригинальный timing SNA.

### 16.4. Acceptance — не пройдена

Обязательный тест:

1. native 48K;
2. Early;
3. clean restart snapshot;
4. дождаться строки;
5. должно быть Type 1;
6. переключить Late;
7. clean restart того же snapshot;
8. должно быть Type 2;
9. снова Early;
10. снова Type 1.

Минимум `E/L/E`, лучше `3/3` каждого режима.

Нельзя принимать:

- только register readback;
- только визуальный сдвиг картинки;
- только один Late run;
- результат без clean snapshot restart.

### 16.5. После timing acceptance

Регрессии:

- 48K cold boot;
- 48K `TRAPTEST.tap`;
- 48K `3DDeathChase.wav`;
- 128K boot/menu;
- Pentagon boot;
- Critical Mass TZX;
- BigThings TAP;
- Deflektor TZX;
- EXOLON;
- JOYMAP QAOP+Space → Kempston;
- Early/Late не должен менять Pentagon;
- 128K Late требует отдельного timing-aware теста, не только 48K detector.

Только после этого кандидат может стать release candidate.

## 17. Что не делать

- Не прошивать persistent `BOOT.BIN` без `GO`.
- Не считать menu readback доказательством Type 2.
- Не возвращать B004C raw `/INT -1T`.
- Не считать B004D display shift достаточным для timing detector.
- Не удалять `hUla/vUla` без отдельного сравнения contention/floating bus.
- Не возвращать direct ROM `LINE_RUN` как default.
- Не делать hot model switch без reset.
- Не менять 48K `romPage` обратно на `00`.
- Не менять 48K upper RAM обратно на bank 6.
- Не собирать Step 15 из dirty `cores/zx` вместо vendored
  `sources/atlas_core`.
- Не выдавать static snow-картинку эмулятора за доказательство реального
  48K поведения без включённой snow emulation.
- Не двигать JOY register на занятый адрес `0xC4`.
- Не запускать destructive smoke, пока владелец смотрит интерактивный тест,
  без предупреждения.

## 18. Канал связи с Claude и Hermes

Единственный канонический файл:

`Mac /tmp/agent_bridge.md`

Правила:

- append-only;
- блоки `### FROM gpt → claude` / `### FROM claude → gpt`;
- перед board mutation ставить lock;
- после hardware verdict дописывать точные version/config/hash/result;
- не использовать ThinkPad-копию как канон;
- отвечать на вопросы Hermes/Telegram в этот же файл.

Последний запрос Claude:

- независимо проверить B004D;
- теперь дополнен clean negative;
- отдельно разобрать `sna48k-snow.sna`;
- предложить snow RTL-корень, не смешивая его с `/INT`.

Перед продолжением прочитать хвост:

```sh
tail -200 /tmp/agent_bridge.md
```

## 19. Приоритет продолжения

Текущий порядок:

1. B004E/v141 загружен и дал Type1 в Early и Late;
2. не собирать B004F вслепую:
   - снять точный CPU `/INT` phase;
   - проверить T80 acceptance edge;
   - сравнить raw `vduI`, `irq`, `irq_late`, `pc3M5`, T80 M1 boundary;
3. отдельно закрыть snow;
4. прогнать 48/128/Pentagon regression после нового доказанного кандидата;
5. после timing stability вернуться к полноценному 8-bit JOYMAP menu;
6. custom ROM profiles оставить отдельной архитектурной задачей;
7. persistent release только после manifest, matrix и `GO`.

## 20. Критерий завершения этой эстафеты

Этап 48K считается реально закрытым, когда одновременно выполнено:

- 48K cold boot стабилен;
- stock ROM выбран правильно;
- snapshot/inject RAM соответствует runtime mapping;
- смена машин не оставляет чужой ROM/CPU state;
- `LOAD ""` печатается полностью и запускается;
- 48K TAP/WAV проходят;
- Early test показывает Type 1;
- Late test показывает Type 2;
- snow имеет доказанное real-hardware поведение или честную опцию;
- 128K/Pentagon не сломаны;
- JOYMAP stage 1 не регрессировал;
- исходники и bitstream воспроизводимы;
- persistent image обновлён только с разрешения владельца.

До выполнения всех пунктов B004B/B004D/B004E — исследовательские
волатильные кандидаты, не новая production прошивка.

## 21. Оперативное дополнение после первой версии handover

### 21.1. B004E отвергнут не из-за synthesis/control plane

Post-route DCP был открыт в Vivado. Фактически существуют:

- `ula_late_s_reg[0]`;
- `ula_late_s_reg[1]`;
- `core_i/irq_reg`;
- `core_i/irq_late_reg`.

LUT принятия прерывания T80:

`core_i/Cpu/Cpu/u0/IntCycle_i_2`

имеет отдельными реальными входами:

- `irq`;
- `ula_late_sp`;
- `irq_late`.

Следовательно:

- CDC присутствует;
- mux присутствует;
- Late не был оптимизирован;
- B004E отрицателен по смыслу выбранного направления задержки.

### 21.2. Новый независимый источник по направлению Early/Late

Клонирован Spectrusty:

- repo `/private/tmp/spectrusty`;
- commit
  `7ee89841e904fb69268a69c0274a0a9386957bff`.

Реализация Late:

```rust
fn is_irq(&mut self, VideoTs{ vc, hc }: VideoTs) -> bool {
    vc == 0 && (hc + Ts::from(self.late_timings)) & !31 == 0
}
```

Его unit test ожидает границу:

- Early `28`;
- Late `27`.

То есть Late делает CPU-visible interrupt на один T раньше в координатах
CPU/video timestamp.

Fuse commit:

`57cbfc9caa06942fb8b3030d01bd0f50bc510ae3`

делает эквивалент в другой системе координат:

```c
if( settings_current.late_timings )
    machine->line_times[0]++;
```

При фиксированном interrupt reference ULA display/contention происходят
на один T позже.

### 21.3. Доказанный план B004F

Исторический Atlas:

```verilog
always @(posedge clock)
    if(pc3M5)
        irq <= vduI;
```

T80 принимает решение об `IntCycle` на том же master edge. Из-за
registered/nonblocking semantics он видит предыдущее значение `irq`.

Минимальный следующий кандидат:

```verilog
wire cpu_irq = ula_late ? vduI : irq;
```

Смысл:

- Early сохраняется побитово;
- Late bypass-ит один исторический resample stage;
- T80 видит raw ULA interrupt на текущем `CEN_p`;
- это на один CPU T раньше;
- `vduI` локально синхронен тому же `spclk`, поэтому это не CDC;
- B004D `hUla/vUla` shift остаётся для display/contention relative phase.

Перед сборкой запрошена независимая проверка Клода.

### 21.4. Snow: поправка к первичному выводу

В Atlas snow уже частично моделируется:

```verilog
assign vmmA1 = {
    vmmPage,
    va[12:7],
    !rfsh && addr01 ? a[6:0] : va[6:0]
};
```

`rfsh` — это active-low `RFSH_n`, поэтому `!rfsh` означает активный
refresh. Код уже подменяет младшие биты ULA fetch address на `R`.

Вероятный дефект не в полном отсутствии snow, а в слишком широком
phase window:

- подмена действует весь active refresh;
- нет явного native-48 gate;
- нет точного ULA cell-fetch qualifier.

Spectrusty разрешает snow corruption только в узких фазах:

- `hc` после коррекции `-2`;
- `hc & 7` равно `0/1` или `2/3`;
- IR должен попадать в contended range.

Следующий snow A/B:

1. текущая default модель;
2. `NO_SNOW`;
3. native48-gated narrow-phase модель;
4. несколько последовательных frame dumps для каждого варианта.

### 21.5. JOYMAP stage 2 от Клода

Клод добавил в текущий `loader_main.c`, не меняя RTL:

- mutable `g_joymap[8]`;
- захват raw PS/2 make code;
- wizard для RIGHT/LEFT/DOWN/UP/FIRE/FIRE2/FIRE3/BIT7;
- Space снимает назначение;
- Enter сохраняет текущее;
- Esc/F9 откатывает весь wizard;
- пункт `JOYSTICK MAP`;
- INI serialization:
  `joymap=hh,hh,hh,hh,hh,hh,hh,hh`.

Проверено, что:

- `BULB_FW` в общем source остаётся `v0.15.141`;
- machine/ULA/autostart правки не откатились;
- следующий единый ARM build должен получить новую версию `v0.15.142`;
- отдельный ELF с устаревшим именем v138 не следует грузить на текущую
  плату; нужно пересобрать общий кандидат.

### 21.6. Hardware burst для `sna48k-snow.sna`

На волатильном B004E/v141 выполнены две серии по восемь
последовательных захватов ZX screen RAM:

- Early, `MACHINE_CFG=2`:
  `/tmp/snow_b004e_early_00.bin` ... `_07.bin`;
- Late, `MACHINE_CFG=6`:
  `/tmp/snow_b004e_late_00.bin` ... `_07.bin`.

Во всех шестнадцати случаях SHA-256 внутри своей серии различается.
Соседние Early-захваты отличаются примерно на 2528 байт из 6912.
Рендеры:

- `/tmp/snow_b004e_early_00.png`;
- `/tmp/snow_b004e_early_01.png`.

показывают радикально разные цветные полосы/мишени. Это доказывает:

- текущий snow mux действительно влияет на ULA fetch;
- наблюдаемая нестабильность не является обычным FLASH-атрибутом;
- B004E Late не стабилизирует покадровую фазу.

Поскольку тест в каждом IM2 handler выполняет `LD R,A`, сначала следует
проверить B004F: правильная CPU-visible фаза INT сама может сделать
snow-паттерн статичным. Отдельный narrow-phase snow RTL до этого
строить нельзя — иначе смешаются две независимые причины.

## 22. Итог исследования Early/Late: абсолютный сдвиг INT не является переключателем Type

После B004E/B004F был сделан не очередной однократный патч, а
инструментированный аппаратный sweep.

### 22.1. B0050: runtime-тюнер и пассивный trace

B0050 добавил для native 48K:

- signed half-T сдвиги IRQ и ULA;
- выбор legacy/raw/opposite-half INT;
- применение многобитной конфигурации только на VSYNC;
- атомарный trace первого внешнего interrupt acknowledge
  `!M1_n && !IORQ_n`;
- raster h/v, PC, R, sequence и ages выбранного/raw INT;
- чтение trace через свободные diagnostic-регистры.

Артефакт:

- WNS `+0.378ns`, TNS `0`;
- bit SHA
  `ee159cd36ef386743ea89391868e179cd1fc692d9e0d75104dfdcfa60099fed1`;
- PCAP-bin SHA
  `14bd267c9829ee249f68b4dcfff763c7cb768e12401c586c0e658b522ccd49fe`;
- только volatile PCAP, ARM v142;
- исходный Timing Tests остался Type1, screen SHA
  `f5fe2b24d28f05ce3d62f8553e48ab85d0600643ce69c8527eadb0c9ca9be197`.

Trace доказал существование дискретных окон принятия INT T80, но также
нашёл ошибку самого тюнера: большой отрицательный h-offset заворачивался
в конец той же строки 248 вместо предыдущей строки 247.

### 22.2. B0052: правильный межстрочный перенос

B0052 исправил отрицательный wrap. При raw INT и ULA delta `+2` получены
монотонно более ранние кластеры:

- delta `-4..0` -> ACK `(v248,h26,PC15F7)`;
- `-16..-5` -> `(v248,h2,PC15ED)`;
- `-28..-17` -> `(v247,h438,PC15EC)`;
- `-32..-29` -> `(v247,h426,PC15EB)`.

На representative points `-4`, `-5`, `-17`, `-29` исходный snapshot
каждый раз загружался заново, но результат всё равно оставался exact
Type1 SHA `f5fe2b...`.

Исторический тег B0051 уже был занят отвергнутым FAST8-экспериментом,
поэтому новый диагностический артефакт сознательно получил B0052.

### 22.3. B0053: гипотеза IRQ-only окончательно опровергнута

B0053 расширил signed IRQ axis до `-256..+255` half-T:

- WNS `+0.358ns`, TNS `0`;
- bit SHA
  `25e48ea82fe8ea231891610af3ec017908315bfcc92b358763b801c8017d0332`;
- PCAP-bin SHA
  `93b310aa8ee1e66085e62b35849c28f611609b15421fb8b0a75c23b775483f61`;
- PCAP no-readback PASS;
- volatile `VERSION=B01B0053`, ARM v142;
- persistent image не изменялся.

При raw source, ULA delta `+2` и полном независимом reload исходного
Timing Tests:

- IRQ `-64` -> exact Type1;
- `-128` -> exact Type1;
- `-192` -> exact Type1;
- `-256` -> exact Type1.

Trace одновременно доказывает, что IRQ действительно двигался:
interrupt-ack PC ушёл вплоть до `0x10B4` на `-256`.

Следовательно, Type1/Type2 в этом тесте нельзя реализовать простым
переносом абсолютной позиции каждого кадрового INT. Тест измеряет
JP(HL)-loop между последовательными кадровыми прерываниями; одинаковый
перенос начала каждого кадра вычитается из измеряемого интервала.

Практический вывод:

- прежний Atlas-переключатель Early/Late нельзя считать корректным;
- перенос display и IRQ независимыми ручками создаёт несуществующий
  гибридный профиль;
- надпись Early/Type1 сама по себе не означает плохую эмуляцию.

Комментарии в `sources/atlas_core/video.v` и
`tools/int_trace_decode.py` исправлены, чтобы эта ложная гипотеза не
вернулась.

## 23. Эксперимент с официальным MiSTer ZX Spectrum core

Вместо полного переноса MiSTer framework выбран минимальный backend:

- upstream `ZX-Spectrum_MISTer`, commit
  `9388aac649c881140c061fab85d5cf37336cf802`;
- `rtl/ula.sv`;
- T80pa v0250 и шесть его VHDL-зависимостей.

Не переносятся MiSTer `emu`, HPS I/O, Altera PLL, SDRAM/DDRAM, HDMI,
диски, DivMMC, GS, AY/SAA и MiSTer tape player.

Сохраняются BulbuLator:

- Zynq PS и AXI control plane;
- Navigator/SD/tape parser/snapshot loader;
- `mem_zx`;
- tape FIFO/player и EAR;
- клавиатура и Kempston;
- HDMI/OSD/audio transport;
- register snapshot и JTAG screen mirror.

Полный дизайн и границы порта записаны в
`research/15-pentagon/MISTER48_PORT.md`.

Лицензия совместима: MiSTer ULA — GPL-3.0-or-later, проект уже
GPL-2.0-or-later и фактически содержит GPL-3.0-or-later JT49.
Перед production merge всё равно обязательно добавить attribution,
pin зависимости и воспроизводимое получение upstream в
`THIRD_PARTY.md`/build flow. Сейчас upstream staging экспериментальный.

### 23.1. B0054: чистый A/B только T80

Добавлен build target:

```text
build.tcl -tclargs mistert80
```

Atlas ULA, memory и glue не менялись; заменён только T80 v0247 на
MiSTer T80pa v0250.

Результат:

- WNS `+0.386ns`, TNS `0`;
- bit SHA
  `e0193c0e21de96962cb7f844497df1e854cf932d2adaedc967be6358b057470a`;
- PCAP-bin SHA
  `73680aa4f1b2e1191ef9e96a61342e89f85108bd685f32bba69ce022a7ad687e`;
- volatile PASS, ARM v142, `VERSION=B01B0054`;
- Timing Tests снова exact Type1 SHA `f5fe2b...`.

Вывод: ревизия T80 сама по себе не является причиной.

### 23.2. Новый `mister48_core.sv`

Добавлен compile-time target:

```text
build.tcl -tclargs mister48
```

Новый `sources/mister48_core.sv` адаптирует MiSTer ULA+T80 к
BulbuLator. Для native 48K сохранено физическое отображение, совместимое
с ARM snapshot/tier0 injection:

```text
0000-3FFF -> 48 BASIC ROM, ROM page 1
4000-7FFF -> RAM bank 5
8000-BFFF -> RAM bank 2
C000-FFFF -> RAM bank 0
```

CPU CE берутся непосредственно из MiSTer ULA `ce_cpu_sp/sn`. ARM halt
гейтирует T80, но не останавливает сам raster ULA.

### 23.3. B0055: первый полный boot

- WNS `+0.221ns`, TNS `0`;
- bit SHA
  `02eab70bc1b855ac7db221ac58cc2187f56e2729edf0d04b7e40e78d0252af12`;
- PCAP-bin SHA
  `d560624a61c4938c1319e266d3946d675881da179cea42db9ae31045cc9bf749`;
- volatile PCAP + ARM v142 PASS;
- CPU исполнил исходный timing snapshot;
- экран снова exact Type1 SHA `f5fe2b...`.

Это важный результат: официальный фиксированный 48K-профиль MiSTer
сам определяется тестом как Type1/Early. Это нормальный вариант ULA, а
не оценка качества core.

### 23.4. B0056/B0057: исправление измерительного зеркала

B0056 сохранял fetch по фактически искажённому source address. Для snow
это скрывает визуальное смещение: байт снова попадает туда, откуда был
прочитан.

B0057 начал сохранять байт по номинальной позиции луча, но в адресе
атрибута отсутствовал `vc[4:3]`, из-за чего диагностический экран мог
быть чёрным.

Обе итерации были только volatile diagnostic builds, не production
кандидаты.

### 23.5. B0058: корректный raster observer и решающий snow-результат

B0058 исправляет nominal attribute destination:

```verilog
{3'b110, cap_v[7:3], cap_h_next[7:4], cap_h_next[2]}
```

Артефакт:

- WNS `+0.137ns`, TNS `0`;
- bit SHA
  `1ad907c69a3b536fcd9fcb7a9e058ed17814b1396f375f92709527fb4784bc8e`;
- PCAP-bin SHA
  `4b247a7000b435dbdf7e3589a0c569c9808fa9742862e08bcf38f8049527adb5`;
- volatile PCAP + ARM v142 PASS;
- `VERSION=B01B0058`;
- persistent BOOT/SD/QSPI не тронуты.

Timing:

- три последовательных кадра exact
  `f5fe2b24d28f05ce3d62f8553e48ab85d0600643ce69c8527eadb0c9ca9be197`.

Snow:

- SNA SHA
  `b0fcab765d11eb40b5383448418ed3dbd16e8bd9fd05c9f8af5f81798856c4cd`;
- initial screen SHA
  `3aae4c8c7c66f412537e1432de90d6519c3f23862cd24dfd6fd27043b9283bd5`;
- восемь последовательных аппаратно отрисованных кадров имеют ровно
  тот же SHA;
- `tools/snow_diff.py` выдаёт `VERDICT: CLEAN`;
- CPU при этом исполняет программу, а не заморожен:
  `PC=8087 SP=FF3D AF=692C BC=0069 DE=7F01 HL=807F IX=FF00
  IY=5C3A I=7E R=88 IM=2`.

Это первое решающее улучшение относительно Atlas: ранее мигающий и
гуляющий snow-тест теперь стабилен и побайтно совпадает с ожидаемым
статическим экраном SNA.

## 24. Новые и изменённые файлы MiSTer-ветки

- `sources/mister48_core.sv` — native48 adapter;
- `sources/bulbulator_zx_ddr_top.v` — compile-time backend select и
  version tags;
- `assemble.sh` — staging нового adapter;
- `build.tcl` — `mistert80` и `mister48` targets;
- `MISTER48_PORT.md` — архитектура, лицензия, pin и acceptance plan;
- `tools/diag_pcap.bif` — generic volatile PCAP BIF;
- `tools/jtag_snapshot_frames.tcl` — repeated rendered-frame capture;
- `tools/jtag_fs_put.tcl` — запись тестового файла через ARM FS mailbox;
- `tools/jtag_z80_regs.tcl` — read-only register snapshot;
- `sources/atlas_core/video.v` и `tools/int_trace_decode.py` —
  исправленные выводы по IRQ-only гипотезе.

Файл `/Users/alex/zxwork/loadtest/sna48k-snow.sna` был скопирован через
ARM FS mailbox на SD как `0:/loadtest/sna48k-snow.sna` (49179 байт)
только для аппаратного теста. Firmware/BOOT при этом не изменялись.

## 25. Текущее состояние и следующий обязательный gate

На момент записи:

- на плате временно B0058 + ARM v142;
- native48 timing и snow приняты машинными проверками;
- Atlas 128K/Pentagon backend не удалён и не должен удаляться;
- production firmware не прошивался;
- persistent BOOT SHA должен оставаться
  `c656d2c22218b18548473a3c86b72dba00d77bafd8aa422cc66f55c81932aacb`.

Реальный pulse-path тест `CAVE48K.TAP` на 1x завершён успешно:

- count `638916`;
- hash `FF7A8101`;
- gaps `1`, resumes `0`;
- `PC=C84B`, `SP=FFF9`;
- screen SHA
  `1d03cbb3bc3d8ede962333f9f37c58c6d2b61f8bde9c4b35dcaf074ca3ffe588`.

SAFE4 whole-core также завершён успешно:

- тот же exact count/hash/gaps/resumes;
- `PC=C8A3`, `SP=FFF9`;
- экран побайтно идентичен 1x и имеет тот же SHA.

Следовательно, B0058 уже совместим с существующим ARM pulse transport
на 1x и SAFE4.

B0059 добавляет отдельный phase-safe CPU-only FAST8:

- вход только после фактического MiSTer ULA `NE`;
- строгие локальные пары `PE,NE` на master clock;
- выход только после FAST `NE`;
- подавление случайного native `NE` до следующего native `PE`;
- tape duration теперь считает фактический `cpu_ten`, поданный T80.

На момент обновления B0059 синтезируется на ThinkPad.

После него:

1. route/PCAP B0059 и повторить timing/snow smoke;
2. проверить CAVE FAST8 по count/hash/PC/screen;
3. проверить keyboard/Kempston, EAR/beeper;
4. прогнать native48 tape/SNA regression corpus;
5. пока оставить Atlas для 128K и Pentagon;
6. только после зелёной батареи обсуждать production merge и
   persistent flashing с владельцем.
