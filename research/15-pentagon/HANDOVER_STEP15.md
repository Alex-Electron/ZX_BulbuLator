# BulbuLator — Шаг 15: ПОЛНЫЙ хэндовер для продолжения (передача агенту)

Этот документ самодостаточен: по нему можно принять Шаг 15 и продолжить с нуля, не читая историю чата. Читать вместе с `HANDOVER_SMART_LOADER.md` (детали загрузчика) и `BUILD_HISTORY.md` (журнал билдов). В волте владельца всегда-актуальная версия — `state/HANDOVER.md`.

Дата снимка: 2026-07-14. Прошивка **v0.15.77**, битстрим **0xB01B003E**.

---

## 0. Что это за проект

BulbuLator — эмулятор ретро-машин на плате EBAZ4205 (Zynq-7010, ARM Cortex-A9 + FPGA). Модель: **FPGA-ядра = движок машины, ARM = control plane** (OSD, SD, ввод, загрузчик — как в MiSTer). Реальный Z80 (ядро T80) крутится в ПЛ; ARM им управляет через AXI. Публичная репа `github.com/Alex-Electron/ZX_BulbuLator`, лицензия GPL-2.0-or-later.

**Шаг 15** = Pentagon 128/256/1024 + идеальная кассетная загрузка + сетевой KVM. Сейчас в фокусе — **универсальный умный загрузчик лент** (цель владельца: грузить ЛЮБУЮ ленту на макс.скорости, гарантированно без сбоев, авто-выбор режима).

---

## 1. Окружение и доступ

- **Плата** EBAZ4205 (Zynq-7010) подключена к **ThinkPad** (не к маку). Экран/клавиатура ZX у платы — на них смотрит владелец.
- **JTAG:** Xilinx Platform Cable USB II → `hw_server` :3121 (ThinkPad). См. `../JTAG.md`.
- **Мак** (где работает агент) = пульт: всё делается через `ssh thinkpad` (юзер `lavrinovich`, 16 ядер). Синтез, сборка, прошивка, JTAG — ВСЁ на ThinkPad.
- **Тулчейн на ThinkPad:** Vivado 2023.1 (`/tools/Xilinx/Vivado/2023.1/settings64.sh`), Vitis 2023.1 (`/tools/XilinxVitis/Vitis/2023.1/`), `arm-none-eabi-gcc`, `xsct`, `hw_server`. `vivado`/`xsct` НЕ в PATH при ssh — сорсить settings64.sh.
- **Дерево:** `~/bulb-v13/research/15-pentagon/` (репо-шаг). Ядра — `~/bulb-v13/cores/` (fetch'атся по SHA).

⚠️ Гоча SSH: фоновые процессы через `ssh thinkpad '... &'` рвут сессию — запускать `nohup … >log 2>&1 &` и проверять состояние отдельной командой.

---

## 2. Архитектура control plane (ARM ↔ ПЛ)

- **AXI-GP0 регистры** (база `0x40000000`), стабильный протокол. Ключевые:
  - `0x04` IJ_CTRL (bit0 HALT, bit2 RESET+wipe), `0x08` IJ_STAT (bit0 HALT_ACK, bit1 RAM_BUSY, bit2 RESET_BUSY).
  - `0x5C` KBD_HB (любая запись = кормёжка deadman-таймера фабрики; звать в любых долгих циклах ARM).
  - `0x60` MACHINE_ID (=0x00805A58), `0xA8` KBD_INJECT (матричный ввод, обход OSD-гейта).
  - `0x9C` TAPE_CTRL (W): bit0 run, bit1 ear_mux, bit2 mute, [4:3] fmode(0=1×,1=8×,2=4×), bit5 sync, bit6 more, **bit7 smart_en, bit8 byte_ready, [16:9] byte**.
  - `0xA4` TAPE_STATUS (R): bit0 full, bit1 playing, **bit2 byte_wait, bit3 sampling_active**.
  - `0xAC` MEMWR_CNT (R: счётчик записей RAM ядра — верификация загрузки/активности).
  - `0xB0` SMP_CNT (R: сырой счётчик чтений порта FE — классификатор кастом-загрузчика).
  - PC Z80: `mwr 0x40000004 1; poll 0x40000008&1; read 0x400000EC` — но 0x04 = IJ_CTRL, т.е. это ХАЛТИТ CPU. Только для снапшота, НЕ в живой загрузке.
- **Зеркало экрана** GP-BRAM @ `0x40008000` (6912Б ZX-скрин, некэшируемое, не крадёт цикл у ядра) — для KVM и JTAG-диагностики.
- **NC-мейлбокс** `KMB=0x0F700000` (некэшируемое DDR-окно, 9МБ сверху): управляющие переменные, к которым JTAG обращается КОГЕРЕНТНО. ⚠️ D-cache ON → JTAG-poke в КЭШИРУЕМЫЕ глобалы НЕ доходит до core0 (и чтение врёт). Всё, что трогается по JTAG, — в мейлбоксе:
  - `+0x00` g_autotrig, `+0x04..0x14` g_fs_cmd/done/err/len/n, `+0x18` g_tape_on, `+0x1C` opt_fastload, `+0x20` opt_wavfast, `+0x24` opt_tapesync, `+0x28` opt_autostart, `+0x2C` opt_defmachine, `+0x30` opt_romtrap, `+0x34` opt_smartload, `+0x38` g_dbg_ferate(debug), `+0x100` g_autodir, `+0x180` g_autoname, `+0x200` g_fs_path, `+0x400` g_fs_path2, `+0x800` g_fs_out(8КБ).
  - `FS_BUF_ADDR=0x0F900000` — NC-скретч для файловых операций (upload/copy/tap-map).

---

## 3. Что работает (проверено на железе)

- **Pentagon 128/256/1024 + ZX 128** — ядро, видео, звук, клавиатура, меню.
- **Цветной DDR-OSD** (Шаг 14) + **DN-навигатор** (файл-браузер в стиле DOS Navigator, 640×400, CP866).
- **Музыкальный плеер** (Шаг 13) + аудио-движок (без underrun'ов).
- **Загрузка лент** — TAP/TZX/WAV/MP3, импульсный путь + warp (SAFE 4× / FAST 8×). 8× тесного турбо = физпотолок клока (whole-core капнут на 4×).
- **🆕 УМНЫЙ ЗАГРУЗЧИК (v0.15.75)** — авто-классификатор режима. Детали в `HANDOVER_SMART_LOADER.md`. Кратко:
  - SMART byte-inject (мгновенно, стандартный ROM-загрузчик) — TRAPTEST, ALIENS, BigThings (+анимация).
  - Авто-детект кастом-загрузчика по темпу чтений FE (SMP_CNT) + sampling_active → PULSE-fallback — EXOLON.
  - Опция `SMART LOAD` (F9 → Options → Tape → Smart load), дефолт OFF; + чекбокс в веб-KVM.
  - **Как грузить EXOLON (и любой кастом):** SMART LOAD=YES + SPEED на вкус, обычная загрузка .tap. Гибрид: BASIC мгновенно byte-инжектом → классификатор ловит опрос ленты (ferate≈27000/0.5с) → PULSE 8× для 25КБ-блока → игра на 0x6625 (~24с). Проверено v0.15.77.
- **🆕 ROM-trap RETIRED (v0.15.76→77).** Model A (freeze+inject) архитектурно мёртв (carry в ALU-латче), грузил НИЧЕГО. Убран из меню (заменён на Smart load), ветка `if(opt_romtrap)` удалена из `tape_start`, `opt_romtrap` форсится в 0 на каждой загрузке. ⚠️ Урок: «спрятать из меню» мёртвую фичу МАЛО — если её флаг застрял =1 (мейлбокс/конфиг) и её ветка стоит первой в диспетчере (`tape_start`), она блокирует ВСЁ (симптом v0.15.76: «ничего не грузится независимо от SMART LOAD»). Надо удалять ветку из логики, а не только UI.
- **🆕 Навигатор прячется после smart-загрузки** (v0.15.76): smart_tape_load теперь скрывает OSD-оверлей (как load_snapshot) — экран отдаётся машине.
- **Веб-KVM** (JTAG-транспорт): `zxstream2.py` :8088 (экран/браузер/клавиши/опции + чекбокс SMART LOAD) + `zxctl.tcl` (петля). Баг путей (гонка потоков за fs-буфер) — ИСПРАВЛЕН (сериализация + путь-заголовок в ответе).

---

## 4. Рабочий процесс (build / flash / test)

```bash
# 1. СИНТЕЗ битстрима (~3.5мин; ТОЛЬКО при правке sources/**/*.v или cores/zx/src/*.v):
cd ~/bulb-v13/research/15-pentagon && source /tools/Xilinx/Vivado/2023.1/settings64.sh
nohup ./build.sh > /tmp/synth.log 2>&1 &     # ждать "write_bitstream completed successfully", "0 Errors"

# 2. ПРОШИВКА (PCAP бит + dow loader.elf; ассертит VERSION):
bash /tmp/reload3a_usb.sh                      # ждать ">>> STEP assert-version: OK PL=0xB01B00XX"

# 3. ПЕРЕСБОРКА прошивки (после правки arm/loader_main.c; синтез НЕ нужен):
cp arm/loader_main.c ~/sdboot/ws/loader/Debug/../src/main.c
cd ~/sdboot/ws/loader/Debug && source /tools/XilinxVitis/Vitis/2023.1/settings64.sh
arm-none-eabi-gcc -O0 -g3 -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I~/sdboot/ws/browser/Debug/_sdk/bsp/ps7_cortexa9_0/include -o src/main.o ../src/main.c
bash /tmp/build_loader.sh && cp loader.elf.new loader.elf   # линк
# затем снова reload3a_usb.sh
```

- **Версии:** `BULB_FW` в loader_main.c = `v0.STEP.PATCH` (патч на КАЖДЫЙ билд). PL VERSION `0xB01B00xx` (макрос `.VERSION` в top.v) = битстрим; бампать при правке RTL И синхронно в `/tmp/reload3a_usb.sh` (5 мест, `sed -i`).
- **Диагностика по JTAG** (xsct-скрипты в /tmp): читать MEMWR/TAPE_STATUS/SMP_CNT/мейлбокс/экран. Готовые: `/tmp/smart2.tcl`, `/tmp/tapmap.tcl` (карта блоков через fs cmd 9), рендер экрана — питон в /tmp.
- **KVM:** `bash /tmp/startsrv.sh` (сервер) + `bash /tmp/startloop.sh` (JTAG-петля). ⚠️ Петля держит JTAG — перед своими JTAG-тестами `pkill -f "[z]xctl.tcl"`, после — рестарт.

⚠️ **ГЛАВНАЯ ГОЧА СБОРКИ:** `build.sh`→`assemble.sh` делает `rm -rf sources/build` и пересобирает: `build/zx`=симлинк на `cores/zx` (main.v ВЫЖИВАЕТ), но `bulbulator_zx_ddr_top.v`+`axi_ctl.v` КОПИРУЮТСЯ из мастеров `sources/*.v`. **RTL-правки:** top.v/axi_ctl → в `sources/*.v`; main.v → в `cores/zx/src/main.v`. НИКОГДА не в `sources/build/`.

---

## 5. Ключевые файлы

| Файл | Что |
|------|-----|
| `arm/loader_main.c` | Вся прошивка ARM (OSD, браузер, плеер, загрузчик, fs_service, KVM-мейлбокс). ~5000 строк. Мастер на ThinkPad. |
| `cores/zx/src/main.v` | Ядро-топ ZX: T80, память, ULA, smart-tape byte-inject FSM + мукс шины данных. |
| `sources/axi_ctl.v` | AXI control-plane регистры (мастер). |
| `sources/bulbulator_zx_ddr_top.v` | Топ-уровень: CDC, DDR-OSD, зеркало экрана, детектор загрузчика (smp_edge/sampling_active), инстансы. VERSION здесь. |
| `sources/build/128-1.rom` | 48K BASIC ROM (для дизасма LD-BYTES). |
| `BUILD_HISTORY.md` | Журнал билдов (строка на билд). |
| `HANDOVER_SMART_LOADER.md` | Детали умного загрузчика. |
| ThinkPad `/tmp/*.tcl`, `/tmp/*.sh`, `/tmp/*.py` | JTAG-скрипты, флешеры, рендеры (эфемерны — при ребуте /tmp чистится; ключевые продублировать в репо при передаче). |

---

## 6. Тест-ленты (SD, покрывают классы загрузчиков)

- `0:/loadtest/TRAPTEST.tap` — крошечный чистый стандарт (эталон SMART).
- `0:/loadtest/ALIENS.TAP` — реальная игра, стандарт.
- `0:/demos/demo48/BigThings.tap` — стандарт + анимация в паузах (проверка «не свалиться ложно в pulse»).
- `0:/games/best-tested-tap/EXOLON_KONSTANTIN_KALANTAI.tap` — кастом-загрузчик (проверка гибрида/классификатора).

Карта блоков любой ленты: fs cmd 9 (`pokestr путь → 0x0F700200`, `mwr 0x0F700004 9`, читать `0x0F700800`).

---

## 7. Открытые задачи / роадмап

**Ближайшее (умный загрузчик до идеала — цель владельца «макс.скорость гарантированно без сбоев»):**
1. Прогресс-баннер в PULSE-фазе гибрида (сейчас приблизительный, стартует с середины ленты).
2. Матрица «лента → рабочий режим/скорость» — прогнать библиотеку, занести в HANDOVER_SMART_LOADER.
3. Порог классификатора 800 чтений/0.5с проверен на EXOLON(27146)/BigThings(217) — большой запас; при новых лентах свериться, при нужде тюнить (g_dbg_ferate @ мейлбокс+0x38).

**Выполнено 14.07.2026 (интеграция TZX и Auto-Fallback):**
- **TZX Smart Load:** TZX файлы теперь обрабатываются по умному пути (как и TAP). Блоки 0x10, 0x11, 0x14 инжектируются напрямую. Метаданные пропускаются.
- **PULSE Auto-Fallback Speed:** Вместо слепого использования `cur_fmode()` при падении в PULSE, прошивка автоматически снижает 8x до 4x (если `g_dbg_ferate` < 20000) или до 1x (если < 10000). Теперь нестандартные загрузчики не отваливаются от warp'а.

**Дальше по Шагу 15 / проекту:**
- Нативный Ethernet веб-KVM с DHCP (GEM0/RGMII/PHY@0, lwIP+xemacps в BSP) — вынести KVM с JTAG-транспорта на сетевой (issue #9). Разведка в памяти `ebaz-ethernet-kvm-bringup`.
- Следующее ядро (NES/Dendy) + ремап клавиатуры→джойпад.
- Model A ROM-трапа (freeze+inject) ЗАКРЫТ (латчи ALU/flag не пишутся регистрами) — не возрождать.

---

## 8. Жёсткие ограничения (соблюдать всегда)

- **Общение с владельцем — по-русски.** Владелец тестирует на живом железе и ОЦЕНИВАЕТ успех загрузки сам; не заявлять успех без его подтверждения на экране.
- **Telegram-канал:** `echo "текст" | ssh thinkpad 'python3 ~/.hermes/send_to_user.py'`. Слать первые ощутимые результаты / когда есть что тестировать / по просьбе. Токены `~/.hermes/.env` — НИКОГДА не эхо/лог/коммит.
- **Git-личность публичных артефактов — ТОЛЬКО** `Alexander Lavrinovich <7916859+Alex-Electron@users.noreply.github.com>` (author И committer). Никаких Koznov/рабочей почты. Никаких co-author/generated-by футеров.
- **Упоминание ИИ:** в личных проектах — только обобщённо «ИИ»/«AI», НИКОГДА не называть конкретную модель/агента. В git-сообщениях ИИ не упоминать вообще.
- **Волт Обсидиана** (`~/Documents/Obsidian Vault/Projects/Lichnoe/BulbuLator/`) — журнал после каждого шага: `state/HANDOVER.md`+`STATUS.md`+`state/current.md`. Дублировать суть в файловую память агента.
- **Хьюманайзер** на все публичные тексты (README/доки) перед коммитом. RU-переводы — через DeepL, не LLM-калькой.
- **Никогда не урезать функционал** — только богаче/лучше.
- **Сверять заявленное состояние с волтом** (центр правды) — при расхождении озвучить.

---

## 9. Резюме статуса одной строкой

Умный загрузчик лент авто-классифицирует и грузит стандарт мгновенно (byte-inject), кастом — через pulse-fallback с авто-детектом за ~0.5с; проверено TRAPTEST/ALIENS/BigThings/EXOLON. ROM-trap retired. Прошивка v0.15.77, бит 0xB01B003E. Следующее — авто-подбор безопасной скорости pulse-фазы + проверка новых кастом-лент (Deflector @ 0:/loadtest/custom Loader/ — в работе).

---
### Статус на конец дня (24 июля 2026)
- **Баг с навигацией OSD**: починен в `loader_main.c` (меню корректно отображает имена машин).
- **Баг со снегом (sna48k-snow)**: 
  - Исправлены тайминги BRAM в `mem_zx.v`. 
  - Полосы цветного снега – это хардварно-корректное поведение 48K (из-за наложения I и R регистров).
  - "Дрифт" (переливание) полос возникает из-за микро-погрешностей T80-ядра в `mister48`.
- **Новая фича**: в меню `loader_main.c` добавлена машина **ZX SPECTRUM 48K (Atlas)**. Проброшен сигнал `force_atlas` (4-й бит `MACHINE_CFG`) в `axi_ctl.v` и `hybrid_zx_core.sv`.
- **Незавершенное**: Требуется запустить `./build.sh` для синтеза FPGA-битстрима с новыми патчами, а затем прошить (`loader_run.sh`) и протестировать. 
- *Подробный отчет:* см. `HANDOVER_CURRENT.md`.
