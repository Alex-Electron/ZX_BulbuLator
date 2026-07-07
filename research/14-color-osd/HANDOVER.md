# BulbuLator Шаг 14.4 — HANDOVER (2026-07-07)

> Читать ПЕРВЫМ. Актуальное состояние шага 14 «ZX-BulbaNavigator» — OSD-файловый менеджер в стиле
> DOS Navigator поверх ZX Spectrum. Прошивка **v0.14.48**, ядро ПЛИС **0xB01B0016**. **НЕ в git.**
> Эталоны дизайна DN — в `refs/` (DN_DESIGN_SPEC.md, DN_COPY_DIALOG.md, DN_TETRIS_PORT.md).

---

## 1. Железо, где что, как собирать и прошивать

- Плата **EBAZ4205 (Zynq-7010)** + **DLC10 JTAG** постоянно на **ThinkPad** (`ssh thinkpad`, юзер lavrinovich, 16 ядер). Мак — только пульт (ssh). Клавиатура PS/2 и HDMI подключены к плате; экран видит только владелец (обратная связь словами).
- Дерево на ThinkPad: `~/bulb-v13/research/14-color-osd/`. Правим Mac-копию `arm/loader_main.c`, синкаем rsync-ом.
- **Битстрим 640×400 + ps2-watchdog УЖЕ синтезирован** (`sources/build/bulbulator_zx_loader.bit`, VERSION 0xB01B0016). Синтез нужен ТОЛЬКО при правке `sources/*.v`.

### Сборка ARM (обычный цикл, БЕЗ синтеза):
```
rsync -a <mac>/research/14-color-osd/arm/loader_main.c thinkpad:~/bulb-v13/research/14-color-osd/arm/
ssh thinkpad 'cd ~/bulb-v13/research/14-color-osd/arm && bash build_loader.sh > /tmp/bl.log 2>&1; \
  grep -q BUILD_OK /tmp/bl.log && (cp ~/sdboot/ws/loader/Debug/loader.elf ./loader.elf; bash /tmp/dlc10_flash14.sh) || grep error: /tmp/bl.log'
```
**ГЕЙТ: флешить только при `BUILD_OK`** (grep "error:" в пайпе даёт ложный успех). Компилятор `-Wall`, НЕ `-Werror` (unused-warnings от мёртвого Winamp/1bpp — норма).

### Ресинтез битстрима (только при правке RTL sources/*.v):
```
ssh thinkpad 'cd ~/bulb-v13/research/14-color-osd && source /tools/Xilinx/Vivado/2023.1/settings64.sh && ./build.sh'  # ~6-8 мин
# свежий бит sources/build/*.bit → скопировать в корень шага перед прошивкой
```
Прошивка: `/tmp/dlc10_flash14.sh` (bootgen bin → PCAP-конфиг ПЛИС + загрузка loader.elf на Cortex-A9#0). Читает VERSION из рег 0x00 (должно быть 0xB01B0016).

### Версионирование
`#define BULB_FW "v0.STEP.PATCH"` в loader_main.c (сейчас **v0.14.46**), инкремент на КАЖДОМ билде. Показывается в правом верхнем углу навигатора.

### Бэкапы прошивок (ThinkPad /tmp): loader_v0142{6,7}, v0143{0,1}_backup.elf.

### 🔴 JTAG-диагностика на живой плате (non-halting):
```
ssh thinkpad → source /tools/XilinxVitis/Vitis/2023.1/settings64.sh
ADDR=$(arm-none-eabi-nm ~/sdboot/ws/loader/Debug/loader.elf | grep " СИМВОЛ$" | cut -d" " -f1)
xsdb -eval "connect; targets -set -filter {name =~ \"*Cortex-A9*0*\"}; puts [mrd -value 0xADDR]"
# адреса сдвигаются после КАЖДОГО билда — пере-выводить.
```

---

## 2. 🥇 RTL-фикс, который НАДО закоммитить перед публикацией

**Watchdog-ресинк в `ps2.v`** — вылечил «нечёткие клавиши» (корень был с шага 11, не был внесён). Межбитовый таймаут 400 мкс: сбитый глитчем кадр PS/2 больше не рассинхронизирует все последующие байты.
- Патч в чекауте форка: `~/bulb-v13/cores/zx/src/ps2.v` (ThinkPad) + копия `research/14-color-osd/notes/ps2_watchdog_patched.v` (Mac).
- **⚠️ Перед публикацией шага: закоммитить в форк `Alex-Electron/zx` + обновить SHA в `get_deps.sh`**, иначе `get_deps.sh` перекачает ядро и затрёт патч. Бит с ним уже собран (0xB01B0016).

---

## 3. Что СДЕЛАНО (на железе, v0.14.46)

### 3.1 Единый ввод (архитектура) — «этап 1»
- `kbd_note(code,release)` — ОДНА таблица состояния клавиш `g_kd[256]`. И главный цикл, и модальный `get_keysym_blocking()` кормят её каждым popнутым FIFO-словом. Одиночные клавиши срабатывают по фронту (rising), навигация — на каждый make (автоповтор). Устранило «нечёткость» и «F6 с 3 раза» (был баг: два независимых читателя KBD_DATA + залипавшие флажки).
- Формат KBD_DATA (рег 0x54): `{22'd0, break[9], empty[8], code[7:0]}`. Пусто = бит8=1 (НЕ 0xFFFFFFFF!). Модификаторы kb_alt/g_kb_shift = зеркала g_kd[0x11]/[0x12|0x59].

### 3.2 Клавиши (браузер)
F1=Help(DN-окно) · F2=play mode (5 режимов) · F3=sort (Alt+F3 реверс) · **F5=Copy** · **F6=Rename/Move** (TC-стиль) · **F7=MkDir** · **F8=Delete** · F9=меню-бар · F10=пауза машины · F11=хард-ресет · **F12=скрыть/показать навигатор** · Space=пауза/резюм музыки или старт · **BackSpace=СТОП воспроизведения/загрузки ленты** (одна функция; вверх по папкам — через «..» + Enter) · Esc=назад/закрыть · KP+/−=громкость · Enter=открыть/загрузить/играть · ↑↓/PgUp/PgDn=навигация.

### 3.3 OSD / дизайн DN
- Канвас DDR ARGB8888 **640×400 @ 80×25** (CP866 8×16), 0x0F800000, слой OSD_CTRL bit1. 1bpp (bit0) = легаси-резерв.
- **Позиция навигатора = Window X/Y** (opt_x/opt_y → DDR_OSD_POS, apply_pos), дефолт 320,160 (центр 1280×720), диапазон 0..640/0..320.
- Палитра/символы — по `refs/DN_DESIGN_SPEC.md`. Тело диалога серое (0x70), рамка+заголовок белые (0x7F), поле ввода чёрное (0x0F), кнопки ЗЕЛЁНЫЕ (по скриншоту владельца; дефолтная — циан-надпись + треугольные маркеры ►◄ ПО КРАЯМ кнопки), тень 0x08, меню-hotkey красный. Маркер скрытых = ░ (0xB0) в конце имени.

### 3.4 Каркас диалогов (переиспользуемый, TV-стиль)
- `dn_win_draw(l,t,W,H,title)` — тень+непрозрачная заливка+двойная рамка+центр-заголовок. Все 4 диалога через него.
- `box_backup/box_restore(&g_bs[i])` — снапшот фона под окном (буфер 48 ячеек шир. макс; шире → `render_browser()` на закрытии, как dn_help).
- `dn_button(cx,cy,lab,def,minface)` — DN-кнопка, единая ширина, треугольники по краям у дефолтной.
- `dn_radio`/`dn_check` — виджеты (ГОТОВЫ, пока НЕ используются — под будущий Copy-диалог).
- `dn_input_dialog` (поле+OK/Cancel, Tab-фокус), `dn_confirm` (Yes/No), `dn_help` (список клавиш).

### 3.5 Движок файловых операций (рекурсия + прогресс)
- `pg_open/pg_tick/pg_close` + `g_pg_*` — DN-диалог прогресса (бар done/total байт + имя текущего + кнопки **Pause[P/Space] / Cancel[Esc]**).
- `count_tree(path)` — сумма байт (знаменатель бара). `copy_file_pg` (чанки через snapbuf 160КБ), `copy_entry` (рекурсия файл/папка), `rmdir_recursive` (рекурсивное удаление), `copy_move_run` (общий: copy + опц. remove-source = move).
- **🥇 ВСЕ длинные проходы качают `player_pump()` (в т.ч. count_tree!)** — иначе музыка на фоне глохла (кольцо опустошалось).
- **🥇 Непрерывная музыка во время файл-операций (v0.14.47):** `pump_autoadvance()` в `bg_pump` (меню/диалоги) и `pg_tick` (copy/delete/move) — если трек кончился ВО ВРЕМЯ операции, следующий (в т.ч. RANDOM) стартует сразу. Флаг `g_suppress_browser_draw` не даёт `play_index` рисовать список поверх диалога и НЕ двигает курсор операции (иначе ломалась пост-op логика bcursor). `snapbuf` (копир.) изолирован от плеера — конфликта нет.
- **Copy (F5)**: рекурсивно файлы И папки, с баром. Создаёт недостающие папки назначения.
- **Delete (F8)**: файл/пустая папка — мгновенно; непустая — двойное подтверждение → рекурсия с баром.
- **Rename/Move (F6, TC-стиль)**: поле предзаполнено ПОЛНЫМ путём. Папка та же → `f_rename` мгновенно; папка другая → copy+delete с баром. Пустое→имя = переименование в текущей папке; путь с `/` в конце = папка-назначение с сохранением имени.
- **MkDir (F7)**: `f_mkdir`, вложенность по цепочке пути.
- FatFs: FF_FS_READONLY=0, FF_FS_MINIMIZE=0 (есть f_rename/f_unlink/f_mkdir/f_getfree/f_stat/f_lseek), **FF_USE_LFN=1 (LFN ВКЛЮЧЁН!** через `ffconf.h`→`xparameters.h` FILE_SYSTEM_USE_LFN=1, `ffunicode.o` слинкован — длинные имена до 255 и точный регистр работают; в loader храним NAMELEN=96, длиннее — усекается), **FF_USE_CHMOD=0**.
- **Переименование в тот же регистр («test»→«Test»)**: FAT-поиск регистронезависим → прямой `f_rename` даёт FR_EXIST; делаем в ДВА шага через temp-имя `_BLBTMP_` (стандартная техника Windows/git), LFN сохраняет точный регистр. См. rename_selected (caseonly-ветка).

### 3.6 Меню (menubar_exec, 2 уровня)
Files/Play/Tape/Options/Help. Дропдаун бара + ОДНО вложенное подменю (g_bs[0]+g_bs[1], LIFO restore). Options▸Settings — вложенный дропдаун из `opt_items[]` (value-items). Play mode — в меню Play + F2 + глиф в статусе (из Settings убран). Стрелка подменю = треугольник. Хоткеи-буквы, Left/Right между барами, Esc/F9-уровень-вверх. На выходе — `render_browser()` (без артефактов).

### 3.7 Статусы
- Верх справа (menubar): [глиф ▶зел/‖красн = работа/пауза машины] тип-машины `Vol:NN%` версия. Обновляется на пауза/громкость.
- Низ (row 24): контекстная строка клавиш, **равномерно распределена по ширине** (dn_keybar со слэком). Браузер: F1/F3/F5/F6/F7/F8/F9/F12/Esc. Диалоги — свои.
- Row 22: музыка/лента — глиф+имя + **глифы play-mode** (scope ≡папка/─файл + behaviour →once/○loop; random ⤬) + M:SS/M:SS + прогресс-бар. Маркиза длинных имён.

### 3.8 Опции (Settings) — почищены
Осталось: Show hidden, Scroll speed, Scroll delay, Pause on music, Volume, OSD dim, **Window X/Y**, Tape sound, MP3 as tape, Long leader, MP3 preload, MP3 sens. УБРАНЫ: Folders, Player X/Y, Time display, Play mode (переехал в Play). Конфиг `0:/bulbulator.ini`.

---

## 4. Аудио (фон) — состояние
Неблокируемое P0 сделано ранее (FIFO-clock consumer, кольцо 10.9с RB_LEN=524288, guard=16). См. волт `AUDIO_ENGINE_PLAN.md`. Осталось (не трогали в этой сессии): **4b per-source DC-block на фабричной ноге (RTL, ресинт)** — щелчок старт/стоп; баг «внезапное ускорение ~0.3с» (мерить фабрик-FIFO underrun); P2 предзагрузка файла в RAM.

---

## 5. BACKLOG (задачи на будущее, по приоритету)

**A. Полноценный диалог копирования DN** (владелец хочет «все фичи»). Всё разобрано в `refs/DN_COPY_DIALOG.md`:
   1. Диалог 78×15: поле пути + радиогруппа 6 режимов (Overwrite/Append/Resume/Skip/Refresh/Ask) + чекбоксы + OK/Cancel/Tree/Help. Виджеты dn_radio/dn_check готовы; нужен многоконтрольный модал с Tab-фокусом (линейный focus-ring: input→радио→чеки→кнопки).
   2. Реализовать разрешение конфликта в copy_file_pg: Overwrite=CREATE_ALWAYS, Skip=пропуск существующих (f_stat), Refresh=перезапись если src новее (fdate/ftime), Resume=f_lseek докачка, Append=FA_OPEN_APPEND, Ask=подиалог per-file (Overwrite/Append/Resume/Rename/Skip/Cancel + «для всех»).
   3. Чекбоксы: Check free space (f_getfree), Remove source=Move (уже есть), Verify writes (перечитать+CRC, P2). **Убрать из UI: Copy descriptions, Copy access rights** (нет на FAT).

**B. Дерево каталогов [Tree]** (`refs/DN_COPY_DIALOG.md` §4): плоский pre-order список узлов (Level, биты «есть брат»/«есть дети»), сканирование f_opendir/f_readdir, отрисовка `├└─┬│` (195/192/196/194/179), отступ 3 кол/уровень, кэш. Выбор папки → путь в поле назначения. Также как F10 навигация.

**C. История ввода ▼** (THistory-подобная): ~16 уникальных путей на контекст, dropdown по ▼, сохранять в ini.

**D. MkDir-диалог**: подпись «Directory name» (как DN), ▼ история, кнопка Help.

**E. Выпил легаси**: весь Winamp-код (skin_*.h, winamp_draw + виджеты) — ДОСТИЖИМ только через мёртвый cmPlayerWin, безопасно удалить. 1bpp-экраны (show_help/show_header/render_browser_1bpp/titlebar/draw_title*/browser_status-легаси). bit0 остаётся в RTL как резерв.

**F. DN-окно плеера** (Enter/F8): модальное CD-player-окно + прогресс + текст-спектр (FFT+блок-символы) + режимы + ID3, кнопка «в фон». См. волт `MUSIC_PLAYER_ROADMAP.md`.

**G. Тетрис** — порт по `refs/DN_TETRIS_PORT.md` (поле 12 ячеек, 7 фигур, вращение без kick, скорости, очки, глиф █).

**G2. 🆕 F3 = гибкий ПРОСМОТРЩИК (Viewer, DN/NC F3)** — освободить F3 (сортировка → в меню Files / на другую клавишу). Показывать: **скрин приложения, вытащенный из .tap/.tzx/.z80/.sna** (для .z80/.sna — распаковать экранную область 0x4000, 6912 байт ZX-экрана → ARGB; для .tap/.tzx — найти блок с загрузочным экраном); **картинки**; **текстовые файлы (все кодировки — CP866/CP1251/UTF-8/KOI8)**; для **музыки** — все метаданные: частота дискретизации, битрейт, все теги (ID3 и пр.). Гибкий, авто-детект типа.

**H. Аудио до идеала**: 4b DC-block (RTL), баг-ускорение (мерить), P2 RAM-preload.

**I. Правильный Eject** (f_sync перед unmount, когда появится запись держащихся файлов).

**J. Публикация шага 14**: сперва закоммитить ps2.v в форк zx + SHA в get_deps.sh; потом humanizer (EN) + DeepL (RU) на доки, коммит в ветку/main (git-личность только Alexander Lavrinovich, БЕЗ co-author/generated-by).

---

## 6. Известные нюансы / на что смотреть
- **LFN ВКЛЮЧЁН** (был неверный вывод ранее про 8.3): длинные имена/регистр работают. Ограничение только наше: NAMELEN=96 в flist (имена >96 усекаются в списке; при переименовании таких — берётся усечённое). macOS-dotfiles видны реальными именами → фильтр скрытых по '.' работает.
- Рекурсия copy/delete/count/tree: ~100-150 Б/кадр стека (DIR+FILINFO), стек _STACK_SIZE=0x20000 — глубокие деревья ок.
- Verify writes на SD дорого (двойное чтение) — по умолчанию off/P2.
- Меню на закрытии делает полный render_browser (разово, не мерцает в работе).
- Старый баг (на потом): AlterEgo — пауза игры 4 раза → сброс машины.

## 7. Правила владельца (не забыть)
Сборка на ThinkPad · НИКОГДА не урезать функционал (только богаче) · только инкрементальная отрисовка (полный редроу = мерцание, кроме разовых действий) · DN 1:1 (зелёные кнопки, циан-треугольники) · переиспользовать фреймворк (методы/примитивы, не копипаст) · humanizer на публичные тексты · RU-доки через DeepL · git-личность только Alexander Lavrinovich <7916859+Alex-Electron@users.noreply.github.com>, без AI-футеров · волт обновлять после каждого шага.
