# HANDOVER — NES/Famicom/Денди машина на BulbuLator (RTL-интеграция)

Цель владельца: **рабочий NES к завтра** + мапинг клавиатуры→джойстик. Токен-дисциплина.
Статус спеки/де-риска: fit доказан (6501 LUT/37%), парсер iNES готов, интерфейс ядра разложен.
Полные спеки: `NES_FPGA_ANALYSIS.json`, память `nes-fpga-port-plan`, `arm-pcap-core-reload-proven`.

## Ядро (вендорено)
`sources/nes_core/` из NESTang pin **5b24a71** (all-Verilog/SV, без savestate-балласта):
`nes.v cart.sv ppu.v apu.v dpram.v compat.v EEPROM_24C0x.sv t65/{T65_Pack,T65_MCode,T65_ALU,T65}.v mappers/*.sv`
Модуль `NES` (nes.v:73). Читать T65 как `-sv`, пакет T65_Pack первым. Мапперы в mappers/.

## Интерфейс NES (nes.v) → швы (см. nes-fpga-port-plan)
- Память: `cpumem_addr[21:0]`+read/write+dout/din[7:0] (CPU:PRG+WRAM), `ppumem_addr[21:0]`+... (PPU:CHR+NT). 8-бит req/resp. `bram_addr[17:0]` = battery-save.
- Видео: `color[5:0]` (индекс палитры) + `cycle[8:0]`/`scanline[8:0]`.
- Вход: `joypad_out[2:0]`(strobe)/`joypad_clock[1:0]`/`joypad1_data[4:0]`/`joypad2_data[4:0]` — серийный NES-протокол.
- Аудио: `sample[15:0]`, `apu_ce`, `audio_channels[4:0]`. Клок: `clk`~21.48МГц, `reset_nes`,`cold_reset`,`sys_type[1:0]`(регион). `mapper_flags[63:0]` = слово из arm/nes_rom.c.

## План интеграции (Раунд 1 = NROM в BRAM, простейший рабочий)
1. **Клок**: +выход MMCM ~21.48МГц (`clknes`) в clock_zx или отдельный модуль. Видео к HDMI развязано фреймбуфером → точность клока некритична для Раунда 1.
2. **Память (Раунд 1: BRAM, NROM)**: `nes_mem_bram.v` — BRAM, отвечает cpumem+ppumem (быстрее окна префетча ядра). PRG до 32КБ + CHR 8КБ = 40КБ < 262КБ BRAM. ARM грузит .nes в эту BRAM через AXI (порт как inject). Раунд 2: AXI-HP DDR для больших картриджей.
3. **Видео-адаптер** `nes_video.v`: из `color[5:0]`+`cycle`+`scanline` сгенерить hsync/vsync/blank + pixel-ce + цвет. Раунд 1a: `color→nearest 4-bit RGBI` (лоссовый, через НЕтронутый fb-тракт). Раунд 1b: 8bpp-индекс + палитра NES в fb_line_disp (SRC_BPP=8, палитро-RAM RGB888, .pal FirebrandX). NES 256×240.
4. **fb_capture_rr**: параметризовать FB_W/FB_H (дефолты ZX 384/302), NES-инстанс = 256/240. fb_line_disp CROP/scale под NES (5×гориз×3×верт=1280×720).
5. **Joypad-shifter** `nes_joypad.v`: JOY_STATE[7:0] (A/B/Select/Start/U/D/L/R) → серийно по strobe/clock → joypad1_data[0]. (Мапинг клавиатуры→JOY_STATE уже есть в ARM — joymap.)
6. **axi_ctl**: тот же control-plane (VERSION=NES id напр. 0xB01BСE01, reset, JOY_STATE, mapper_flags-рег, ROM-load-в-BRAM порт).
7. **top** `bulbulator_nes_top.v`: PS7+MMCM+clock + NES core + mem + video-адаптер + fb_capture(NES-геом)+fb_wr_axi+fb_bufmgr+fb_line_disp+osd+hdmi + axi_ctl + joypad. Переиспользовать наш видео-выход/HDMI/axi.
8. **build**: вариант NES в build.tcl (`-verilog_define NES_CORE`, read nes_core/*), отдельный битстрим `bulbulator_zx_loader_nes.bit` → `NES.bit.bin` в 0:/CORES/.
9. **ARM**: navigator .nes → arm/nes_rom.c parse → DMA PRG/CHR в BRAM(порт) → mapper_flags → release reset. JOY_STATE уже кормится joymap.
10. **Валидация**: JTAG-дамп DDR-фреймбуфера → рендер PNG (как snow_capture) → смотрю сам; HDMI визуально — владелец.

## Порядок (чекпойнты)
- [ ] nes_mem_bram.v + OOC-тест что NES+BRAM элаборится.
- [ ] nes_video.v + nes_joypad.v.
- [ ] bulbulator_nes_top.v (Раунд 1a: RGBI-lossy, fb-тракт как есть с NES-геометрией).
- [ ] build NES-вариант → синтез/тайминг/fit.
- [ ] ARM ROM-load в BRAM + деплой + framebuffer-дамп: рисуется ли SMB.
- [ ] Раунд 1b: палитра NES (нормальные цвета).

## Гочи/константы
7010 17600 LUT. RTL источник правды=ThinkPad `~/bulb-v13/research/15-pentagon/sources`. Билд на ThinkPad (settings64.sh). JTAG hw_server:3121, xsdb Vivado_Lab. Плата: Atlas B0061+v145 (RAM), прод-BOOT не трогать. Тест-ROM'ы ~/nes_roms/nes-test-roms (NROM: смотреть mapper 0 — SMB/Excitebike/Donkey Kong).
СТАТУС: ядро вендорено. Следующий шаг — nes_mem_bram.v + OOC-элаборация NES с нашей памятью.
