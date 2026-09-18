`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// axi_ctl.v  -  BulbuLator Stage-1 control plane (AXI3 slave on Zynq-7010 M_AXI_GP0).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM (PS) reaches the Spectrum (PL) through this register file: HALT the Z80, write RAM,
// inject Z80 registers (T80 DIR vector) and machine ports (7FFD / border) -> load .sna/.z80.
//
// Register map (base = M_AXI_GP0 0x4000_0000), AXI3, 32-bit, single-beat:
//   0x00 VERSION   R   0xB01B0019  (top instantiation overrides this default)
//   0x04 CONTROL   RW  bit0 HALT (1 = freeze the Z80; ARM owns the memory bus)
//   0x08 STATUS    R   bit0 HALT_ACK, bit1 RAM_BUSY
//   0x0C COUNTER   R   free-running aclk counter (liveness)
//   0x10 RAM_ADDR  RW  17-bit Spectrum RAM byte address; auto-increments after each RAM_DATA write
//   0x14 RAM_DATA  W   byte -> RAM[RAM_ADDR], RAM_ADDR++
//   0x18 SCRATCH   RW  spare
//   0x20..0x38 DIR0..DIR6  RW  the 212-bit T80 register-injection vector (7 words; DIR6 = top 20b)
//   0x3C PORT_7FFD RW  bits[5:0] = 128K paging port value
//   0x40 PORT_FE   RW  bits[2:0] = border
//   0x44 COMMIT    W   bit0 = PORT_COMMIT (apply 7FFD+border), bit1 = DIR_COMMIT (pulse DIRSet)
//   0x48 OSD_CTRL  RW  bit0 = OSD_ENABLE (show the toast overlay)
//   0x4C OSD_ADDR  RW  9-bit OSD-buffer word pointer; auto-increments after each OSD_DATA write
//   0x50 OSD_DATA  W   32 packed 1-bpp OSD pixels -> osd_buf[OSD_ADDR], OSD_ADDR++ (LUTRAM, no halt)
//   0x54 KBD_DATA  R   keyboard scancode FIFO head; [9]=release_flag (1=this byte is a break/release)
//                      [8]=empty [7:0]=code.
//                      A READ also POPS the FIFO (one entry per read). The ARM owns all hotkey/OSD
//                      policy -> no function key is decoded in fabric (portable across cores).
//   0x58 KBD_STAT  R   bit0 = FIFO empty (non-popping poll)
//   0x5C KBD_HB    W   any write = deadman heartbeat (keeps the keyboard gate open while ARM lives)
//   0x60 MACHINE_ID R  loaded-core identity for the ARM (here ZX 128K); lets one ARM image serve
//                      many machines: [15:0] machine code, [23:16] variant.
//   0x64 VGEOM     R   captured video geometry probe {frame_lines, vis_last, vis_first} (diagnostic)
//   0x68 OSD_BG    RW  OSD panel background colour (24-bit RGB)
//   0x6C OSD_OP    RW  OSD panel opacity alpha 0..255
//   0x70 OSD_POS   RW  OSD panel position {Y0[26:16], X0[10:0]}
//   0x74 VOL       W   HDMI output volume gain 0..255 (PCM * vol / 256; 255 ~= unity)
//   0x78 AUDIO_CTRL W  bit0 = player active (mux ARM PCM -> HDMI, mute the fabric audio)
//   0x7C AUDIO_FIFO W  push one signed-16 stereo sample {R[31:16], L[15:0]} into the audio FIFO
//   0x80 AUDIO_STAT R  bit0 = FIFO empty, bit1 = FIFO full
//   0x84 BANNER_CTRL W bit0 = independent status-banner overlay enable
//   0x88 BANNER_ADDR W banner LUTRAM word pointer; auto-increments after each BANNER_DATA write
//   0x8C BANNER_DATA W 32 packed 1-bpp banner pixels -> ban_buf[ptr], ptr++
//   0x90 BANNER_POS W  banner window position {Y0[26:16], X0[10:0]}
//   -- Step 14 DDR-RGB true-colour OSD layer --
//   0x94 OSD_DDR_BASE W  DDR byte address of the ARGB8888 OSD canvas (osd_ddr_rd reads it over HP1)
//   (OSD_CTRL 0x48 bit1 = DDR_OSD_EN: enable the DDR true-colour OSD overlay; canvas position = OSD_POS 0x70)
//   0xC0 LOAD_CAPS R  machine-agnostic loader capability mask (reserved; 0 until PULSE lands in 14.2)
//   -- B0071: заливка ПЗУ машины с карты (машино-агностичный механизм) --
//   0x154 ROM_LD     W   один байт ПЗУ по текущему адресу, затем адрес++
//   0x158 ROM_LDCTL  W   bit0 = loading (машина держится в сбросе), bit3 = обнулить адрес
//   0x15C ROM_LDADDR RW  адрес заливки {страница[15:14], смещение[13:0]}; чтение = {loading, адрес}
//   0x144 ROM_LDCNT  R   сколько байт ФАКТИЧЕСКИ легло в BRAM с последнего rewind. Адрес - это
//                        намерение, счётчик - факт: он растёт по тому же условию, по которому
//                        пишется BRAM (we И loading), поэтому заливка с забытым loading видна.
//   LOAD_CAPS бит4 = в этом ядре порт заливки ПЗУ ЕСТЬ (прошивка обязана сбрасывать кэш
//                    возможностей при каждой смене ядра - иначе спросит порт у ядра без него)
//
// Purely aclk (FCLK0). The crossing into the Spectrum clock (HALT level, RAM write strobe, the
// DIRSet pulse, the port-force pulses) lives in inject_cdc.v. The scancode FIFO crossing lives in
// the top (async_fifo, spclk write / aclk read).
//-------------------------------------------------------------------------------------------------
module axi_ctl #(
    parameter [31:0] VERSION    = 32'hB01B0019,
    parameter [31:0] MACHINE_ID = 32'h00805A58,  // 'ZX' (0x5A58) + variant 0x80 (128K)
    parameter [31:0] LOAD_CAPS  = 32'h00000009    // bit0 = JOY_STATE @0x100 present (v0x4A);
                                                  // bit3 = CE28/B0065: КАДР КЛАВИАТУРЫ СОБИРАЕТ ФАБРИКА
                                                  //        (KBD_DATA бит10 = расширенная, префиксы E0/F0
                                                  //        и байты-ответы устройства наружу не идут).
                                                  //        ARM по этому биту выключает свою программную
                                                  //        свёртку префиксов и не ищет ACK в потоке.
)(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [11:0] s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [11:0] s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [11:0] s_rid,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

`ifdef NES_CORE
    // ---- NES core control (NES bitstream only; ZX build compiles without these) ----
    output reg  [63:0] ctl_nes_mapper,     // 0x104/0x108 iNES/NES2.0 mapper_flags
    output reg  [21:0] ctl_nes_ld_addr,    // ROM load address (auto-inc on each 0x10C write)
    output reg  [7:0]  ctl_nes_ld_data,    // ROM load byte
    output reg         ctl_nes_ld_we,      // 1-aclk load-write strobe
    output reg         ctl_nes_ld_sel,     // 0 = PRG target, 1 = CHR target
    output reg         ctl_nes_loading,    // 1 while streaming ROM (core held in reset)
    output reg         ctl_nes_reset,      // 1-aclk reset_nes pulse
`endif

    // ---- B0075 ДИСКОВОД: мост подачи секторов (машино-агностичные слоты, смысл - у машины) ----
    // 0x160 FDC_STAT  R : телеметрия контроллера (запрос сектора, LBA, состояние)
    // 0x164 FDC_CTL   W : команда+уровни (см. beta_disk.v: [3:0] команда, [4] wp, [5] ready,
    //                     [8:6] size_code, [9] layout, [31:12] размер образа)
    // 0x168 FDC_DATA  W : байт сектора (адрес в буфере считает фабрика)
    output reg  [31:0] ctl_fdc_ctl,
    output reg         ctl_fdc_ctl_we,   // однотактовый строб
    // General Sound: свой блок регистров (0x174 R / 0x178 W). Отдельный, а не биты в чужом
    // слове - иначе устройства начнут мешать друг другу, чего владелец требует избегать.
    input  wire [31:0] gs_stat2_in,    // 0x194 R: B0119 {потеряно БАЙТОВ[27:16], удержаний шины[11:0]}
    input  wire [31:0] gs_stat3_in,    // 0x198 R: B0119 {сторож[31:30], тактов процессора,
                                       //          проведённых в ожидании[19:0]}
    input  wire [31:0] gs_stat_in,     // 0x174 R: {ovr7[31], ovr0[30], er7[28], ev7[27], ev0[26],
                                       //           b7[22], b0[21], cmd[15:8], data[7:0]}
    output reg  [31:0] ctl_gs_ctl,     // 0x178 W: B0107 ЗЕРКАЛО состояния эмулятора -
                                       //   {en[31], b7[30], b0[29], эхо er7[28]/ev7[27]/ev0[26],
                                       //    сброс липких переполнений[25], dout[7:0]}
    output reg         ctl_gs_ctl_we,  // B0106: ТОГГЛ, а не импульс - переходит в домен машины
    // B0107: пики ARM-ноги звука (0x17C R). Пик-метр 0x170 наполняет МАШИНА, а General Sound живёт
    // на ARM и в те слоты не попадает - без своего прибора «музыку рабочей объявлять нельзя».
    input  wire [31:0] aud_pk_in,      // 0x17C R: {пик ARM-ноги[23:16], пик итогового микса[7:0]},
                                       //           отсчёт 0..127 = полная шкала (старший байт |PCM|)
    // B0108: упругая очередь записей #B3 (машина -> карта). Читается ПО ОДНОМУ БАЙТУ с извлечением
    // на чтении - тот же приём, что у клавиатурного FIFO (pop после того, как ARM защёлкнул голову).
    // B0112 NEMO-IDE: 0x184 W управление и буфер, 0x188 R состояние трапа
    output reg  [31:0] ctl_nemo,
    output reg         ctl_nemo_we,      // ТОГГЛ в домен машины, как у General Sound
    input  wire [31:0] nemo_stat_in, nemo_stat2_in,
    // B0116 мышь Kempston: 0x190 W - координаты и кнопки от ARM (чтение того же адреса возвращает
    // записанное: без обратного чтения нечем доказать по JTAG, что оболочка вообще шевелит мышь)
    output reg  [31:0] ctl_kmouse,
    output reg         ctl_kmouse_we,    // ТОГГЛ в домен машины, как у NEMO-IDE и General Sound
    /* DivMMC: карта SD живёт в фабрике (дедлайн ответа у esxDOS 130.1 мс против 134 мс худшего
       прохода нашего главного цикла), а том, CSD/CID, FAT и запись - здесь. Слов восемь:
       0x19C управление и подтверждения, 0x1A0/0x1A4/0x1A8 буфер (указатель, запись, чтение),
       0x1AC состояние, 0x1B0 адрес запрошенного сектора, 0x1B4 счётчики, 0x1B8 ёмкость карты. */
    output reg  [31:0] ctl_dmmc,         // 0x19C W
    output reg         ctl_dmmc_we,      // ТОГГЛ, флаг на два такта позже данных
    output reg  [31:0] ctl_dmmc_cap,     // 0x1B8 W: ёмкость карты в секторах (0 = предел не задан)
    output reg  [31:0] ctl_dmmc_bufa,    // 0x1A0 W: адрес в буфере, автоинкремент на 4
    output reg         ctl_dmmc_bufa_we,
    output reg  [31:0] ctl_dmmc_bufw,    // 0x1A4 W: четыре байта в буфер
    output reg         ctl_dmmc_bufw_we,
    output reg         ctl_dmmc_bufr_re, // 0x1A8 R: строб «слово забрали», ставится ПО ЗАВЕРШЕНИИ
    input  wire [31:0] dmmc_bufa_in, dmmc_bufr_in, dmmc_stat_in, dmmc_lba_in, dmmc_dbg_in,
    input  wire [7:0]  gs_rq_dout,     // 0x180 R: голова очереди
    input  wire        gs_rq_empty,
    input  wire [8:0]  gs_rq_cnt,      //          занятость (сколько байт лежит)
    output reg         gs_rq_rd,       //          однотактовый импульс извлечения
    output reg  [7:0]  ctl_fdc_data,
    output reg         ctl_fdc_data_we,  // однотактовый строб
    input  wire [31:0] fdc_stat_in,
    input  wire [31:0] fdc_stat2_in,

    // ---- ЗАГРУЗКА ПЗУ МАШИНЫ ARM-ом (машино-агностично, ВНЕ NES-ifdef - как QUIESCE) ----
    // 0x154 ROM_LD    W: один байт по текущему адресу, затем адрес++
    // 0x158 ROM_LDCTL W: bit0 = loading (уровень: машина держится в сбросе), bit3 = обнулить адрес
    // 0x15C ROM_LDADDR RW: адрес загрузки целиком (для перехода на страницу и для СВЕРКИ после заливки)
    output reg  [15:0] ctl_rom_ld_addr,    // {страница[1:0], смещение[13:0]}, автоинкремент
    output reg  [7:0]  ctl_rom_ld_data,
    output reg         ctl_rom_ld_we,      // однотактовый строб записи
    output reg         ctl_rom_loading,    // 1 пока ARM льёт ПЗУ (машина в сбросе)

    // ---- control-plane interface (aclk domain) ----
    output reg         ctl_halt,
    output reg         ctl_ram_we,        // 1-aclk pulse
    output reg  [16:0] ctl_ram_addr,      // running pointer (post-inc; for readback)
    output reg  [16:0] ctl_ram_waddr,     // this write's address (pre-inc; what the CDC latches)
    output reg  [7:0]  ctl_ram_data,
    output reg  [211:0] ctl_dir,          // Z80 register-injection vector
    output reg  [5:0]  ctl_7ffd,
    output reg  [2:0]  ctl_border,
    output reg         ctl_dir_commit,    // 1-aclk pulse
    output reg         ctl_port_commit,   // 1-aclk pulse
    output reg         ctl_reset,         // 1-aclk pulse: machine RESET+wipe (CONTROL bit2) - cold reset Z80 + all peripherals
    // ---- OSD overlay write port (aclk) ----
    output reg         ctl_osd_enable,
    output reg         ctl_osd_we,        // 1-aclk pulse
    output reg  [9:0]  ctl_osd_waddr,     // OSD buffer word address (1024 words; 256x128/32)
    output reg  [31:0] ctl_osd_wdata,
    output reg  [23:0] ctl_osd_bg,        // user-chosen OSD panel background colour (0x68)
    output reg  [7:0]  ctl_osd_op,        // OSD panel opacity alpha 0..255 (0x6C)
    output reg  [31:0] ctl_osd_pos,       // OSD panel position {Y0[26:16],X0[10:0]} (0x70)
    // ---- Step 14 DDR-RGB true-colour OSD layer (aclk) ----
    output reg  [31:0] ctl_osd_ddr_base,  // DDR byte address of the ARGB OSD canvas (0x94)
    output reg         ctl_ddr_osd_en,    // OSD_CTRL bit1: enable the DDR true-colour OSD overlay
    output reg  [31:0] ctl_ddr_osd_pos,   // DDR OSD canvas position {Y0[26:16],X0[10:0]} (0x98) - independent of the 1bpp OSD_POS
    // ---- Step 14.2 tape station (machine-agnostic PULSE loader; see STEP_14_TAPE_DESIGN) ----
    output reg         ctl_tape_run,      // 0x9C bit0: tape replay enable
    output reg         ctl_tape_earmux,   // 0x9C bit1: feed tape_ear into the core's ear input
    output reg         ctl_tape_mute,     // 0x9C bit2: silence the tape loading sound (still loads real-time)
    output reg  [1:0]  ctl_tape_fmode,    // 0x9C [4:3]: FAST LOAD mode 0=off 1=FAST(8x CPU-only) 2=SAFE(4x whole-core)
    output reg         ctl_tape_sync,     // 0x9C bit5: SYNC LOADER (demand tape) - freeze tape between blocks until the CPU samples
    output reg         ctl_tape_more,     // 0x9C bit6: tape_more_data - ARM still delivering the tape; keep a tail FIFO underrun CPU-frozen (glitch-free) instead of leaking a stale edge into the loader
    output reg         ctl_tape_we,       // 1-aclk pulse: push ctl_tape_data into the tape FIFO (0xA0)
    output reg  [31:0] ctl_tape_data,     // {level[31], duration[23:0] in T-states}
    input  wire        tape_full,         // tape FIFO full (0xA4 status; backpressure)
    input  wire        tape_playing,      // tape actively replaying (0xA4 status)
    input  wire [31:0] tape_diag_count,   // passive tape-player probes (read through REG0..REG3 while ROMTRAP=0)
    input  wire [31:0] tape_diag_hash,
    input  wire [31:0] tape_diag_gaps,
    input  wire [31:0] tape_diag_resumes,
    input  wire [31:0] fe_trace_count,  // B0048: one event per CPU IN-FE read while tape RUN is high
    input  wire [31:0] fe_trace_hash,   // CPU-observed DI/PC/paging hash
    input  wire [31:0] fe_trace_last,   // ULA/IRQ/contention/mapper hash (legacy port name retained)
    // ---- independent BANNER overlay write port (aclk) ----
    output reg         ctl_ban_enable,
    output reg         ctl_ban_we,        // 1-aclk pulse
    output reg  [8:0]  ctl_ban_waddr,     // banner buffer word address (512 words; 256x64/32)
    output reg  [31:0] ctl_ban_wdata,
    output reg  [31:0] ctl_ban_pos,       // banner position {Y0[26:16],X0[10:0]} (0x90)
    output reg  [7:0]  ctl_vol,           // HDMI volume gain 0..255 (PCM sample * vol / 256); 0x74
    output reg         ctl_player_en,     // 0x78 bit0: ARM audio player active (mux player PCM -> HDMI)
    output reg         ctl_aud_sum,       // 0x78 bit1: B0107 СУММИРОВАТЬ ARM-ногу с машиной, а не
                                          //   скрещивать. Плеер машину ЗАМЕНЯЕТ (кроссфейд), а
                                          //   General Sound - это ДОВЕСОК К машине: его выход обязан
                                          //   складываться с AY, иначе включение GS глушит машину.
    output reg         ctl_audio_we,      // 1-aclk pulse: push ctl_audio_data into the audio FIFO (0x7C)
    output reg  [31:0] ctl_audio_data,    // {R[31:16], L[15:0]} signed-16 stereo sample
    input  wire        aud_full,          // audio FIFO status (read at 0x80)
    input  wire        aud_empty,
    input  wire [7:0]  aud_rdcount,
    // ---- keyboard scancode FIFO (control-plane tap; machine-agnostic) ----
    input  wire [9:0]  kbd_fifo_dout,   // CE28: [9]=расширенная, [8]=отпускание, [7:0]=код     // {make, code[7:0]} FWFT head
    input  wire        kbd_fifo_empty,
    input  wire [31:0] ps2_diag_in,       // CE28: {resend, parity} от приёмника оболочки -> 0x13C
    output reg         kbd_fifo_rd,       // 1-aclk pop pulse (on a completed KBD_DATA read)
    output reg         kbd_deadman_kick,  // 1-aclk pulse (on a KBD_HB write)
    output reg  [8:0]  ctl_kbd_inject,    // 0xA8 W: {make[8], scancode[7:0]} - ARM injects a synthetic key into the core (bypasses the gate)
    output reg         ctl_kbd_inject_we, // 1-aclk pulse on a KBD_INJECT write
    output reg  [7:0]  ctl_kbd_tx_data,   // 0xB0 W: byte for the PS/2 host transmitter (LEDs / typematic / resend)
    output reg         ctl_kbd_tx_we,     // 1-aclk pulse on a KBD_TX write
    output reg         ctl_pentagon,      // 0xBC MACHINE_CFG bit0: 1 = Pentagon timing (aclk; CDC'd to spclk in top)
    output reg         ctl_model48,       // 0xBC MACHINE_CFG bit1: 1 = 48K ROM/RAM model (bit0 must be 0)
    output reg         ctl_ula_late,      // 0xBC MACHINE_CFG bit2: Sinclair ULA Late
    output reg         ctl_force_atlas,   // 0xBC MACHINE_CFG bit3
    output reg         ctl_snow_off,      // 0xBC MACHINE_CFG bit4: 1 = ULA snow OFF (clean); 0 = faithful 128 snow (default) - Atlas only, live
    // v165/CE16: СЫРОЕ слово MACHINE_CFG наружу. Отдельные провода выше - ZX-семантика; но регистр
    // МАШИННО-ЗАВИСИМ: ARM (machine_cfg_word) для NES кладёт туда region[1:0] | palette[5:4] | sprlimit[6].
    // Ядрам, у которых своя раскладка, нужен весь word, а не ZX-имена. ZX-топы этот порт не подключают.
    output reg  [31:0] ctl_mach_cfg,      // 0xBC MACHINE_CFG как есть (aclk)
    output reg  [31:0] ctl_mem_cmd,       // 0x148: слово команды к памяти машины
    output reg         ctl_mem_we,        // 0x148: строб (1 такт aclk)
    input  wire [31:0] mem_stat_in,       // 0x14C: состояние от ddr_mem
    input  wire [31:0] mach_dbg_in,       // 0x150: слот отладки машины (наполняет топ машины)
    input  wire [31:0] rom_dbg_in,        // B0147 0x1BC: прибор трапа Beta Disk -
                                          //   {взводов[31:24], снятий[23:16], адрес последнего взвода[15:0]}.
                                          //   Счётчики НАСЫЩАЮТСЯ на 255: дельту после этого не мерить.
    input  wire [31:0] aud_dbg_in,        // 0x170: B0088 пики звука по источникам (тоже от машины)
    output reg         ctl_pal_we,        // 0x140: строб записи палитры (1 такт aclk)
    output reg  [7:0]  ctl_pal_addr,
    output reg  [23:0] ctl_pal_rgb,
    output reg  [31:0] ctl_pent_int,      // 0xC4 PENT_INT: {v[24:16], hc[8:0]} Pentagon INT position (default 239/326)
    output reg  [8:0]  ctl_paper_h,       // 0xC8 PAPER_H: h start of paper (left border) for live wider-border tuning
    output reg  [8:0]  ctl_paper_v,       // 0xCC PAPER_V: v start of paper (top border) for live tuning
    output reg  [31:0] ctl_joy,           // 0xC4 JOY_STATE: generic gamepad mask, 2 players (aclk, v0x4A)
    output reg  [31:0] ctl_scr_pos,        // 0xD0 SCR_POS: {vmargin[15:0], hmargin[15:0]} whole-frame HDMI position
    output reg  [31:0] ctl_ula_tune,       // 0x1C0: primary live 48K timing controls
    output reg  [31:0] ctl_ula_tune2,      // 0x1C4: floating-bus/memory-contention/border-mode controls
    // ---- 0x11C..0x138 DDR PROBE: аппаратный замер пути PL->память (ddr_probe.v). Машино-агностично:
    //      это диагностика ОБОЛОЧКИ, а не машины, и она же дименсионирует будущий DDR-картридж. ----
    output reg  [31:0] ctl_probe_base,    // 0x120 W: базовый адрес цели (DDR 0x0xxxxxxx или OCM 0xFFFC0000)
    output reg  [31:0] ctl_probe_ctrl,    // 0x11C W: {mode[31:30], len_code[29:28], count[15:0]}
    output reg         ctl_probe_start,   // 1-такт импульс на запись 0x11C
    input  wire [31:0] probe_stat,        // 0x124 R
    input  wire [31:0] probe_lat_min,     // 0x128 R
    input  wire [31:0] probe_lat_max,     // 0x12C R
    input  wire [31:0] probe_lat_sum,     // 0x130 R
    input  wire [31:0] probe_cycles,      // 0x134 R
    input  wire [31:0] probe_beats,       // 0x138 R
    output reg  [31:0] ctl_scr_scale,     // 0x118 SCR_SCALE: {ymul[7:4]... } -> {28'x, ymul[7:4], xmul[3:0]} live integer upscale (per machine)
    output reg  [31:0] ctl_crop_a,        // 0xD4 CROP_A: {sy0[15:0], sx0[15:0]}   crop origin (trims left/top)
    output reg  [31:0] ctl_crop_b,        // 0xD8 CROP_B: {croph[15:0], cropw[15:0]} crop size (trims right/bottom)
    output reg  [31:0] ctl_warp_hold,     // 0xDC WARP_HOLD: fast-load continuous-warp idle-release timeout in CPU T-states (0 = hold until tape-run clears)
    output reg  [31:0] ctl_sync_hold,     // 0x1C SYNC_HOLD: SYNC-loader hysteretic-hold sustained-quiet release threshold in CPU T-states (genuine inter-block pause detect)
    input  wire        kbd_tx_busy,       // 0xB4 R bit0: PS/2 host TX in progress
    input  wire        kbd_tx_ack,        // 0xB4 R bit1: device ACK bit of the last send
    input  wire [31:0] kbd_diag,          // 0xB8 R: {resend_cnt[31:16], parity_err_cnt[15:0]}
    output reg         ctl_quiesce,       // 0x114 W bit0: v158 QUIESCE PL DDR masters (safe PL reload)
    input  wire        axi_idle,          // 1 = all PL DDR masters idle (STATUS bit3)
    input  wire [31:0] memwr_cnt,         // 0xAC R: core RAM-write counter (tape-load verification probe)
    input  wire [31:0] disp_diag,         // 0x1C8 R: B0196 приборы читателя строк {отложенных пусков[31:16], недогрузок[15:0]}
    input  wire        halt_ack,
    input  wire        ram_busy,
    input  wire        reset_busy,        // machine reset/wipe in progress (STATUS bit2; from inject_cdc)
    input  wire [31:0] cap_geom,          // frame-geometry probe (read-only, 0x64)
    // ---- Step 15 ROM-trap (machine-intercept) ----
    output reg         ctl_romtrap_en,     // 0xE0 bit0: enable ROM-trap (level; CDC'd to spclk in top)
    output reg         ctl_romtrap_done_we,// 0xE0 bit1: 1-aclk pulse - ARM handled the trapped block
    input  wire        rt_pending_a_in,    // trap pending (spclk latch synced to aclk)
    input  wire [5:0]  p7ffd_s1_in,        // live 7FFD paging value (synced to aclk)
    input  wire [211:0] reg_rd1_in,        // 212-bit CPU register snapshot (synced to aclk)
    input  wire [15:0]  sync_diag_in,      // passive demand-tape diagnostics (spclk -> aclk synchronized in top)
    // ---- BulbuLator screen-mirror readback (AXI-GP window @ 0x8000; separate from the DDR path) ----
    output reg  [10:0]  ctl_scr_raddr,     // word address into the 2048x32 mirror BRAM (0..1727 used)
    input  wire [31:0]  scr_rdata          // mirror BRAM read data (valid 1 aclk after ctl_scr_raddr)
);
    localparam IDX_VERSION = 6'h00, IDX_CONTROL = 6'h01, IDX_STATUS = 6'h02,
               IDX_COUNTER = 6'h03, IDX_RAMADDR = 6'h04, IDX_RAMDATA = 6'h05,
               IDX_SCRATCH = 6'h06,
               IDX_SYNCHOLD= 6'h07, // 0x1C SYNC_HOLD (W/R: SYNC-loader hysteretic-hold sustained-quiet release threshold in CPU T-states)
               IDX_DIR0    = 6'h08, // 0x20..0x38 = DIR0..DIR6
               IDX_P7FFD   = 6'h0F, // 0x3C
               IDX_PFE     = 6'h10, // 0x40
               IDX_COMMIT  = 6'h11, // 0x44
               IDX_OSDCTRL = 6'h12, IDX_OSDADDR = 6'h13, IDX_OSDDATA = 6'h14, // 0x48/0x4C/0x50
               IDX_KBDDATA = 6'h15, IDX_KBDSTAT = 6'h16, IDX_KBDHB   = 6'h17, // 0x54/0x58/0x5C
               IDX_MACHID  = 6'h18,                                          // 0x60
               IDX_VGEOM   = 6'h19,                                          // 0x64 (frame geometry)
               IDX_OSDBG   = 6'h1A,                                          // 0x68 (OSD bg colour RGB)
               IDX_OSDOP   = 6'h1B,                                          // 0x6C (OSD opacity alpha)
               IDX_OSDPOS  = 6'h1C,                                          // 0x70 (OSD panel X0/Y0)
               IDX_VOL     = 6'h1D,                                          // 0x74 (HDMI volume gain 0..255)
               IDX_ACTL    = 6'h1E,                                          // 0x78 AUDIO_CTRL (bit0 player_en)
               IDX_AFIFO   = 6'h1F,                                          // 0x7C AUDIO_FIFO (W: push {R,L})
               IDX_ASTAT   = 6'h20,                                          // 0x80 AUDIO_STAT (R: full/empty/count)
               IDX_BANCTRL = 6'h21,                                          // 0x84 BANNER_CTRL (bit0 BANNER_ENABLE)
               IDX_BANADDR = 6'h22,                                          // 0x88 BANNER_ADDR (9-bit word ptr, auto-inc)
               IDX_BANDATA = 6'h23,                                          // 0x8C BANNER_DATA (W: 32 packed px)
               IDX_BANPOS  = 6'h24,                                          // 0x90 BANNER_POS ({Y0[26:16],X0[10:0]})
               IDX_ODBASE  = 6'h25,                                          // 0x94 OSD_DDR_BASE (W)
               IDX_ODPOS   = 6'h26,                                          // 0x98 DDR_OSD_POS (RW, canvas X0/Y0)
               IDX_TAPECTL = 6'h27,                                          // 0x9C TAPE_CTRL (run/earmux/mute)
               IDX_TAPEFIFO= 6'h28,                                          // 0xA0 TAPE_FIFO (W: {level,dur})
               IDX_TAPESTAT= 6'h29,                                          // 0xA4 TAPE_STATUS (R: full/playing)
               IDX_KBDINJ  = 6'h2A,                                          // 0xA8 KBD_INJECT (W: {make,code})
               IDX_MEMWR   = 6'h2B,                                          // 0xAC MEMWR_CNT (R: core RAM writes)
               IDX_KBDTX   = 6'h2C,                                          // 0xB0 KBD_TX (W: byte -> PS/2 host TX)
               IDX_KBDTXST = 6'h2D,                                          // 0xB4 KBD_TXSTAT (R: bit0 busy, bit1 ack)
               IDX_KBDDIAG = 6'h2E,                                          // 0xB8 KBD_DIAG (R: {resend[31:16], parity_err[15:0]})
               IDX_MACHCFG = 6'h2F,                                          // 0xBC MACHINE_CFG (bit0 pentagon, bit1 48K, bit2 Sinclair ULA late)
               IDX_LOADCAPS= 6'h30,                                          // 0xC0 LOAD_CAPS (R)
               IDX_JOY     = 7'h40,                                          // 0x100 JOY_STATE W/R (v0x4A; 7-bit index space - 0x00..0x3F is full)
               IDX_PENTINT = 6'h31,                                          // 0xC4 PENT_INT (W: {v[24:16], hc[8:0]} - Pentagon INT position tuner)
               IDX_PAPERH  = 6'h32,                                          // 0xC8 PAPER_H (W: h_paper_start for live tuning)
               IDX_PAPERV  = 6'h33,                                          // 0xCC PAPER_V (W: v_paper_start for live tuning)
               IDX_SCRPOS  = 6'h34,                                          // 0xD0 SCR_POS (W: {vmargin[15:0], hmargin[15:0]})
               IDX_CROPA   = 6'h35,                                          // 0xD4 CROP_A (W: {sy0[15:0], sx0[15:0]})
               IDX_CROPB   = 6'h36,                                          // 0xD8 CROP_B (W: {croph[15:0], cropw[15:0]})
               IDX_WARPHOLD= 6'h37,                                          // 0xDC WARP_HOLD (W/R: fast-load continuous-warp idle-release timeout in CPU T-states; 0 = hold until tape-run clears)
               IDX_ROMTRAP = 6'h38,                                          // 0xE0 ROMTRAP (W: bit0 en / bit1 done; R: bit0 rt_pending, [13:8] live 7FFD)
               IDX_REG0    = 6'h39, IDX_REG1 = 6'h3A, IDX_REG2 = 6'h3B,      // 0xE4/0xE8/0xEC REG0..REG2 (R-only 212-bit reg snapshot)
               IDX_REG3    = 6'h3C, IDX_REG4 = 6'h3D, IDX_REG5 = 6'h3E,      // 0xF0/0xF4/0xF8 REG3..REG5
               IDX_REG6    = 6'h3F;
    localparam IDX_PROBECTL = 7'h47, IDX_PROBEBASE= 7'h48, IDX_PROBESTAT= 7'h49,  // 0x11C/0x120/0x124
               IDX_PROBEMIN = 7'h4A, IDX_PROBEMAX = 7'h4B, IDX_PROBESUM = 7'h4C,  // 0x128/0x12C/0x130
               IDX_PROBECYC = 7'h4D, IDX_PROBEBEAT= 7'h4E;                        // 0x134/0x138
    localparam IDX_SCRSCALE= 7'h46;                                   // 0x118 W: {ymul[7:4], xmul[3:0]} live integer upscale (per-machine screen scale)
    localparam IDX_MEMCMD  = 7'h52;   // 0x148 W: доступ ARM к памяти машины в DDR (испытательный стенд
                                      //          и загрузчик образов): [31]=1 запись/0 чтение,
                                      //          [27:8]=адрес (20 бит = 1 МБ), [7:0]=данные
    localparam IDX_MACHDBG = 7'h54;   // 0x150 R: слот отладки МАШИНЫ (её смысл - у машины).
                                      // ZX/Пентагон: {req8, 2'd0, eff7[7:0], 2'd0, 7FFD[5:0], банк[5:0]}
    localparam IDX_MEMSTAT = 7'h53;   // 0x14C R: [7:0] последний прочитанный байт, [8] занято,
                                      //          [31:16] счётчик выполненных транзакций
    localparam IDX_PALWR   = 7'h50;   // 0x140 W: палитра одним словом {addr[31:24], R[23:16], G[15:8], B[7:0]}
                                      // Машина приносит свои цвета с собой: у C64 их 16 (VIC-II),
                                      // у NES 64 (2C02), у Atari будет 128. Раньше таблица была
                                      // вшита в общий с ZX файл, и это блокировало третью машину.
    localparam IDX_PS2DIAG = 7'h4F;   // 0x13C R: {resend[31:16], parity[15:0]} - СВОЙ диаг PS/2 оболочки.
                                      // 0xB8 KBD_DIAG остаётся машинно-зависимым (на NES там отладка
                                      // памяти ядра) - логику ввода на нём строить нельзя, это уже
                                      // стоило регрессии v186. Теперь есть машино-агностичный адрес.
    localparam IDX_QUIESCE = 7'h45;                                   // 0x114 W: bit0 = v158 QUIESCE (shared by ALL cores, outside NES ifdef)                                          // 0xFC REG6 = {12'd0, reg_rd1[211:192]}
    // B0071: заливка ПЗУ машины с карты. Тоже ВНЕ NES-ifdef - это машино-агностичный механизм
    // (у ZX 4 страницы по 16КБ; у другой машины смысл страниц свой, порт тот же).
    localparam IDX_ROMLD = 7'h55, IDX_ROMLDCTL = 7'h56, IDX_ROMLDADDR = 7'h57; // 0x154 / 0x158 / 0x15C
    localparam IDX_FDCSTAT = 7'h58, IDX_FDCCTL = 7'h59, IDX_FDCDATA = 7'h5A, IDX_FDCST2 = 7'h5B; // 0x160/4/8/C
    localparam IDX_ROMDBG  = 7'h6F;   // 0x1BC R: B0147 прибор трапа Beta Disk (см. rom_dbg_in)
    // B0157: dedicated, collision-free ULA lab registers.  0x114 remains exclusively QUIESCE.
    localparam IDX_ULATUNE = 7'h70, IDX_ULATUNE2 = 7'h71; // 0x1C0 / 0x1C4 RW
    localparam IDX_AUDDBG  = 7'h5C;   // 0x170 R: B0088 пики звука {SAA, AY2, AY1, SpecDrum, бипер}
    localparam IDX_GSSTAT  = 7'h5D;   // 0x174 R: состояние General Sound
    /* B0119 ПРИБОР ОБРАТНОГО ДАВЛЕНИЯ. Считаем ПОТЕРЯННЫЕ БАЙТЫ, а не эпизоды: эпизод не
       говорит о размере ущерба, а именно его и надо знать. Отдельно - сколько раз и на
       сколько тактов процессора пришлось придержать шину: это цена корректности, и она
       обязана быть видна, иначе мы молча заплатим за неё скоростью машины. */
    localparam IDX_GSST2   = 7'h65;   // 0x194 R
    localparam IDX_GSST3   = 7'h66;   // 0x198 R
    localparam IDX_GSCTL   = 7'h5E;   // 0x178 W: управление General Sound
    localparam IDX_AUDPK   = 7'h5F;   // 0x17C R: B0107 пики ARM-ноги звука и итогового микса
    localparam IDX_NEMOCTL = 7'h61;   // 0x184 W
    /* B0114: флаг отдаём НА ДВА ТАКТА ПОЗЖЕ данных. Слово и его тоггл менялись одним фронтом,
       и при плотных записях домен машины ловил СМЕСЬ БИТОВ двух соседних слов: адрес от одной
       записи, данные от другой. Это наше же правило CDC, оплаченное памятью Пентагона. */
    reg ctl_nemo_rq = 1'b0;
    reg [1:0] ctl_nemo_dly = 2'b00;
    localparam IDX_NEMOST  = 7'h62;   // 0x188 R
    localparam IDX_NEMOST2 = 7'h63;   // 0x18C R: полный адрес LBA
    localparam IDX_DMMCCTL = 7'h67, IDX_DMMCBUFA = 7'h68, IDX_DMMCBUFW = 7'h69,  // 0x19C/0x1A0/0x1A4
               IDX_DMMCBUFR= 7'h6A, IDX_DMMCSTAT = 7'h6B, IDX_DMMCLBA  = 7'h6C,  // 0x1A8/0x1AC/0x1B0
               IDX_DMMCDBG = 7'h6D, IDX_DMMCCAP  = 7'h6E,                        // 0x1B4/0x1B8
               IDX_DISPDIAG = 7'h72;   // 0x1C8 DISP_DIAG (R: B0196 {отложенных пусков[31:16], недогрузок[15:0]})
    /* Тот же сдвиг флага на два такта, что у NEMO-IDE и мыши (B0114/B0116). У карты цена ошибки
       выше: в слове едут подтверждение запроса и НОМЕР этого запроса, и смесь битов двух записей
       означала бы подтверждение чужого сектора - то есть молча не тот блок в файле. */
    reg ctl_dmmc_rq = 1'b0;
    reg [1:0] ctl_dmmc_dly = 2'b00;
    localparam IDX_KMOUSE  = 7'h64;   // 0x190 W/R: мышь Kempston {en[31], кнопки[18:16], Y[15:8], X[7:0]}
    /* Тот же сдвиг флага на два такта, что и у NEMO (B0114): слово и его тоггл, изменённые
       ОДНИМ фронтом, дают в домене машины СМЕСЬ БИТОВ двух соседних записей. У мыши
       это особенно важно: координаты обновляются часто (десятки раз в секунду на разгоне),
       а смешанные X и Y из разных отсчётов - это рывок курсора на полэкрана. */
    reg ctl_km_rq = 1'b0;
    reg [1:0] ctl_km_dly = 2'b00;
    localparam IDX_GSRQ    = 7'h60;   // 0x180 R: B0108 очередь данных GS {занятость[24:16], пусто[8], байт[7:0]}
    localparam IDX_ROMLDCNT = 7'h51;  // 0x144 R: сколько байт ФАКТИЧЕСКИ легло в BRAM с последнего rewind.
                                      // Адрес (0x15C) - это НАМЕРЕНИЕ, а этот счётчик - ФАКТ: он растёт
                                      // строго по тому же условию, по которому пишется BRAM.
`ifdef NES_CORE
    localparam IDX_NESMAP0 = 7'h41, IDX_NESMAP1 = 7'h42, IDX_NESLD = 7'h43, IDX_NESLDCTL = 7'h44; // 0x104/8/C/0x110 NES: mapper_flags lo/hi, ROM load byte (auto-inc), load ctrl
`endif

    reg [31:0] counter;
    reg [31:0] reg_scratch;
    reg [31:0] rom_ld_cnt;              // B0071: фактически записанных байт ПЗУ (сбрасывается rewind-ом)
    // Сторож заливки ПЗУ. `loading` держит МАШИНУ В СБРОСЕ, а снять его может только ARM: если ARM
    // упал/сорвался посреди заливки, машина осталась бы в сбросе НАВСЕГДА - ни F11, ни RESET из меню
    // этот сброс не снимают (они поднимают свои clr_active/rst_cnt, а не этот вход). Поэтому через
    // ~167 мс без единой записи в ROM_LD флаг снимается сам. Заливка столько не молчит: файл читается
    // с карты ДО подъёма loading, а между байтами идут доли микросекунды.
    reg [23:0] rom_ld_wd;
    always @(posedge aclk) begin
        if (!aresetn)                                    rom_ld_wd <= 24'd0;
        else if (ctl_rom_ld_we || !ctl_rom_loading)      rom_ld_wd <= 24'd0;
        else                                             rom_ld_wd <= rom_ld_wd + 24'd1;
    end
    wire rom_ld_timeout = (rom_ld_wd == 24'hFFFFFF);
    reg [9:0]  osd_ptr;                 // running OSD-buffer word pointer (auto-inc, 1024 words)
    reg [8:0]  ban_ptr;                 // running banner-buffer word pointer (auto-inc, 512 words)
    always @(posedge aclk) counter <= aresetn ? counter + 32'd1 : 32'd0;
    /* B0114: тоггл догоняет данные через два такта - см. комментарий у объявления */
    always @(posedge aclk) begin
        ctl_nemo_dly <= {ctl_nemo_dly[0], ctl_nemo_rq};
        ctl_nemo_we  <= ctl_nemo_dly[1];
        ctl_km_dly   <= {ctl_km_dly[0], ctl_km_rq};      // B0116: тот же сдвиг у мыши
        ctl_kmouse_we<= ctl_km_dly[1];
        ctl_dmmc_dly <= {ctl_dmmc_dly[0], ctl_dmmc_rq};  // DivMMC: то же правило
        ctl_dmmc_we  <= ctl_dmmc_dly[1];
    end


    //---------------------------------------------------------------------------------------------
    // Write channel.
    //---------------------------------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;
    reg [1:0]  wstate;
    reg [11:0] awid_q;
    reg [6:0]  awidx_q;   // v0x4A: 7-bit index (0x00..0x1FC)

    always @(posedge aclk) begin
        ctl_ram_we       <= 1'b0;       // default: one-cycle pulses
        ctl_mem_we       <= 1'b0;       // CE30: строб доступа к памяти - тоже одноцикловый
        ctl_pal_we       <= 1'b0;       // CE29: строб палитры - тоже одноцикловый, и ОБЯЗАН жить
                                        // в этом же блоке: сброс в чужом always даёт второй драйвер
        ctl_dir_commit   <= 1'b0;
        ctl_port_commit  <= 1'b0;
        ctl_reset        <= 1'b0;
        ctl_osd_we       <= 1'b0;
        ctl_ban_we       <= 1'b0;
        ctl_audio_we     <= 1'b0;
        ctl_tape_we      <= 1'b0;
        kbd_deadman_kick <= 1'b0;
        ctl_kbd_inject_we <= 1'b0;
        ctl_kbd_tx_we    <= 1'b0;
        ctl_probe_start <= 1'b0;      // 1-такт импульс (как остальные we)
        ctl_romtrap_done_we <= 1'b0;
        ctl_fdc_ctl_we <= 1'b0; ctl_fdc_data_we <= 1'b0;                   // B0075: однотактовые стробы
        /* B0106: у GS это НЕ строб, а тоггл - здесь его не сбрасываем. Однотактовый импульс
           терялся при переходе 100 МГц -> 56 МГц, и подтверждения пропадали через раз. */
        ctl_rom_ld_we <= 1'b0;                                            // B0071: строб заливки ПЗУ
        ctl_dmmc_bufa_we <= 1'b0; ctl_dmmc_bufw_we <= 1'b0;                // DivMMC: буфер карты
        // Инкремент адреса и счётчик фактов ОБА загейтены по loading - тем же условием, по которому
        // BRAM реально пишется (топ гейтит строб как rom_ld_we & rom_loading). Иначе заливка без
        // поднятого loading прогоняла бы адрес до конца, и сверка «залилось N байт» дала бы PASS при
        // НУЛЕ записанных байт - то есть соврала бы ровно там, где её и завели.
        if (ctl_rom_ld_we && ctl_rom_loading) begin
            ctl_rom_ld_addr <= ctl_rom_ld_addr + 16'd1;                   // адрес растёт ПОСЛЕ записи
            rom_ld_cnt      <= rom_ld_cnt + 32'd1;                        // ФАКТ записи в BRAM
        end
        if (ctl_rom_loading && rom_ld_timeout) ctl_rom_loading <= 1'b0;   // сторож: не морозить машину
`ifdef NES_CORE
        ctl_nes_ld_we <= 1'b0; ctl_nes_reset <= 1'b0;   // 1-aclk strobes default low
        if (ctl_nes_ld_we) ctl_nes_ld_addr <= ctl_nes_ld_addr + 22'd1;
`endif
        if (!aresetn) begin
            wstate <= W_IDLE; s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
            s_bresp <= 2'b00; s_bid <= 12'd0;
            ctl_halt <= 1'b0; ctl_ram_addr <= 17'd0; ctl_ram_waddr <= 17'd0; ctl_ram_data <= 8'd0;
            ctl_dir <= 212'd0; ctl_7ffd <= 6'd0; ctl_border <= 3'd0; reg_scratch <= 32'd0;
            ctl_osd_enable <= 1'b0; osd_ptr <= 10'd0; ctl_osd_waddr <= 10'd0; ctl_osd_wdata <= 32'd0;
            ctl_osd_bg <= 24'h101840;   // default panel bg: dark blue (readable with cream ink)
            ctl_osd_op <= 8'd204;       // default opacity alpha ~80% (more dim/opaque)
            ctl_osd_pos <= 32'h00B00200;// default {Y0=176, X0=512}: upper-third centre
            ctl_ban_enable <= 1'b0; ban_ptr <= 9'd0; ctl_ban_waddr <= 9'd0; ctl_ban_wdata <= 32'd0;
            ctl_ban_pos <= 32'h02800200;// default {Y0=640, X0=512}: bottom-centre strip, clear of the OSD
            ctl_vol <= 8'd255;          // default full volume (unity gain)
            ctl_player_en <= 1'b0; ctl_aud_sum <= 1'b0; ctl_audio_data <= 32'd0;
            ctl_osd_ddr_base <= 32'd0; ctl_ddr_osd_en <= 1'b0;
            ctl_ddr_osd_pos <= 32'h00A80180;// default {Y0=168, X0=384}: centre the 512x384 canvas in 1280x720
            ctl_tape_run <= 1'b0; ctl_tape_earmux <= 1'b0; ctl_tape_mute <= 1'b0; ctl_tape_fmode <= 2'd0; ctl_tape_sync <= 1'b0; ctl_tape_more <= 1'b0; ctl_tape_data <= 32'd0;
            kbd_deadman_kick <= 1'b0;
            ctl_kbd_inject <= 9'd0;
            ctl_kbd_tx_data <= 8'd0;
            ctl_pentagon <= 1'b0; ctl_model48 <= 1'b0; ctl_ula_late <= 1'b0; ctl_snow_off <= 1'b0; ctl_quiesce <= 1'b0;
            ctl_mach_cfg <= 32'd0;
            ctl_pal_we <= 1'b0; ctl_pal_addr <= 8'd0; ctl_pal_rgb <= 24'd0;
            ctl_mem_we <= 1'b0; ctl_mem_cmd <= 32'd0;
            ctl_pent_int <= 32'h012B013E;   // owner-tuned Pentagon INT default: v=299 (0x12B), hc=318 (0x13E) -> boot shows correct, no post-config jump
            ctl_paper_h  <= 9'd0;
            ctl_paper_v  <= 9'd60;          // owner-tuned Pentagon paper defaults (match ARM baked -> no boot jump)
            ctl_scr_pos   <= 32'h003A0100;
            ctl_ula_tune  <= 32'd0;  // lab disabled: exact baked B0154 timing selection
            ctl_ula_tune2 <= 32'd0;
            ctl_probe_base  <= 32'h0F000000;   // безопасное окно DDR по умолчанию (вне кадра и вне FS_BUF)
            ctl_probe_ctrl  <= 32'h00000100;
            ctl_probe_start <= 1'b0;
            ctl_scr_scale<= 32'h00000022;   // default {ymul=2, xmul=2} = the historical XSH/YSH=1 (x2/x2)
            ctl_joy <= 32'd0;               // v0x4A: joystick released at reset
            ctl_crop_a   <= 32'h00000000;   // default sy0=0, sx0=0 (no crop)
            ctl_crop_b   <= 32'h012E0180;   // default croph=302 (0x12E), cropw=384 (0x180)
            ctl_warp_hold<= 32'h00200000;   // fast-load: hold continuous warp through ~2.1M idle CPU T-states before releasing (generous backstop; ARM clearing tape-run is the primary release)
            ctl_sync_hold<= 32'h00004000;   // SYNC loader: release the demand-tape hold after ~16384 idle CPU T-states of sustained quiet (a genuine inter-block pause; JTAG-tunable at 0x1C)
            ctl_romtrap_en <= 1'b0;         // Step 15: ROM-trap disabled at reset
            ctl_rom_ld_addr <= 16'd0; ctl_rom_ld_data <= 8'd0; ctl_rom_loading <= 1'b0;  // B0071
            rom_ld_cnt <= 32'd0;
            ctl_fdc_ctl <= 32'd0; ctl_fdc_data <= 8'd0;
            ctl_gs_ctl  <= 32'd0; ctl_nemo <= 32'd0;
            ctl_dmmc <= 32'd0; ctl_dmmc_cap <= 32'd0;      // карта не вставлена, предел не задан
            ctl_dmmc_bufa <= 32'd0; ctl_dmmc_bufw <= 32'd0;
            ctl_kmouse  <= 32'd0;            // B0116: мышь выключена, пока оболочка не разрешила
`ifdef NES_CORE
            ctl_nes_mapper <= 64'd0; ctl_nes_ld_addr <= 22'd0; ctl_nes_ld_data <= 8'd0;
            ctl_nes_ld_sel <= 1'b0; ctl_nes_loading <= 1'b0;
`endif
        end else begin
            case (wstate)
                W_IDLE: begin
                    s_bvalid <= 1'b0; s_awready <= 1'b1;
                    if (s_awvalid && s_awready) begin
                        awid_q <= s_awid; awidx_q <= s_awaddr[8:2];
                        s_awready <= 1'b0; s_wready <= 1'b1; wstate <= W_DATA;
                    end
                end
                W_DATA: if (s_wvalid && s_wready) begin
                    case (awidx_q)
                        IDX_CONTROL: begin ctl_halt <= s_wdata[0]; ctl_reset <= s_wdata[2]; end  // bit2 = machine RESET+wipe pulse
                        IDX_RAMADDR: ctl_ram_addr <= s_wdata[16:0];
                        IDX_RAMDATA: begin
                            ctl_ram_data  <= s_wdata[7:0];
                            ctl_ram_we    <= 1'b1;
                            ctl_ram_waddr <= ctl_ram_addr;
                            ctl_ram_addr  <= ctl_ram_addr + 17'd1;
                        end
                        IDX_SCRATCH: reg_scratch <= s_wdata;
                        IDX_MACHCFG: begin
                            ctl_mach_cfg <= s_wdata;   // v165/CE16: весь word для не-ZX ядер
                            ctl_pentagon <= s_wdata[0];
                            ctl_model48  <= s_wdata[1];
                            ctl_ula_late <= s_wdata[2];
                    ctl_force_atlas <= s_wdata[3];
                            ctl_snow_off <= s_wdata[4];
                        end
                        IDX_MEMCMD: begin ctl_mem_cmd <= s_wdata; ctl_mem_we <= 1'b1; end
                        IDX_PALWR: begin                            // CE29/B0066: палитра машины
                            ctl_pal_addr <= s_wdata[31:24];
                            ctl_pal_rgb  <= s_wdata[23:0];
                            ctl_pal_we   <= 1'b1;
                        end
                        IDX_PENTINT: ctl_pent_int <= s_wdata;      // Step 15: Pentagon INT position tuner
                        IDX_PAPERH:  ctl_paper_h  <= s_wdata[8:0]; // Step 15: live paper h offset (left border)
                        IDX_PAPERV:  ctl_paper_v  <= s_wdata[8:0]; // Step 15: live paper v offset (top border)
                        IDX_SCRPOS:  ctl_scr_pos  <= s_wdata;
                        IDX_ULATUNE:  ctl_ula_tune  <= s_wdata;
                        IDX_ULATUNE2: ctl_ula_tune2 <= s_wdata;
                        IDX_SCRSCALE:ctl_scr_scale<= s_wdata;
                        IDX_PROBEBASE: ctl_probe_base <= s_wdata;
                        IDX_PROBECTL:  begin ctl_probe_ctrl <= s_wdata; ctl_probe_start <= 1'b1; end      // CE21: live integer upscale {ymul,xmul} (per machine)
                        IDX_JOY:     ctl_joy <= s_wdata;         // v0x4A JOY_STATE
                        IDX_CROPA:   ctl_crop_a   <= s_wdata;      // Step 15: live crop origin {sy0, sx0}
                        IDX_CROPB:   ctl_crop_b   <= s_wdata;      // Step 15: live crop size {croph, cropw}
                        IDX_WARPHOLD:ctl_warp_hold <= s_wdata;      // fast-load: continuous-warp idle-release timeout (CPU T-states; 0 = hold until tape-run clears)
                        IDX_SYNCHOLD:ctl_sync_hold <= s_wdata;      // SYNC loader: hysteretic-hold sustained-quiet release threshold (CPU T-states)
                        IDX_ROMTRAP: begin ctl_romtrap_en <= s_wdata[0]; if (s_wdata[1]) ctl_romtrap_done_we <= 1'b1; end
                        IDX_QUIESCE: ctl_quiesce <= s_wdata[0];       // v158 QUIESCE for safe PL reload  // Step 15: bit0 enable, bit1 = ARM handled the trap
                        // B0071: заливка ПЗУ. Байт пишется по ТЕКУЩЕМУ адресу, инкремент - в блоке
                        // дефолтов выше (такт после строба), ровно как у картриджа NES.
                        IDX_ROMLD:    begin ctl_rom_ld_data <= s_wdata[7:0]; ctl_rom_ld_we <= 1'b1; end
                        IDX_ROMLDCTL: begin ctl_rom_loading <= s_wdata[0];
                                            if (s_wdata[3]) begin ctl_rom_ld_addr <= 16'd0;
                                                                  rom_ld_cnt <= 32'd0; end end  // bit3 = в начало
                        IDX_ROMLDADDR: ctl_rom_ld_addr <= s_wdata[15:0];  // переход на страницу
                        IDX_FDCCTL:  begin ctl_fdc_ctl  <= s_wdata;      ctl_fdc_ctl_we  <= 1'b1; end
                        IDX_FDCDATA: begin ctl_fdc_data <= s_wdata[7:0]; ctl_fdc_data_we <= 1'b1; end
                        IDX_GSCTL:   begin ctl_gs_ctl   <= s_wdata;      ctl_gs_ctl_we   <= ~ctl_gs_ctl_we; end
                        IDX_NEMOCTL: begin ctl_nemo     <= s_wdata;      ctl_nemo_rq     <= ~ctl_nemo_rq; end
                        IDX_KMOUSE:  begin ctl_kmouse   <= s_wdata;      ctl_km_rq       <= ~ctl_km_rq;   end
                        IDX_DMMCCTL: begin ctl_dmmc     <= s_wdata;      ctl_dmmc_rq     <= ~ctl_dmmc_rq; end
                        IDX_DMMCCAP:       ctl_dmmc_cap <= s_wdata;
                        IDX_DMMCBUFA:begin ctl_dmmc_bufa<= s_wdata;      ctl_dmmc_bufa_we<= 1'b1; end
                        IDX_DMMCBUFW:begin ctl_dmmc_bufw<= s_wdata;      ctl_dmmc_bufw_we<= 1'b1; end
`ifdef NES_CORE
                        IDX_NESMAP0: ctl_nes_mapper[31:0]  <= s_wdata;
                        IDX_NESMAP1: ctl_nes_mapper[63:32] <= s_wdata;
                        IDX_NESLD:   begin ctl_nes_ld_data <= s_wdata[7:0]; ctl_nes_ld_we <= 1'b1;
                                            end   // write byte @ current addr, then advance
                        IDX_NESLDCTL:begin ctl_nes_loading <= s_wdata[0]; ctl_nes_ld_sel <= s_wdata[1];
                                           if (s_wdata[2]) ctl_nes_reset   <= 1'b1;           // bit2 = pulse reset_nes
                                           if (s_wdata[3]) ctl_nes_ld_addr <= 22'd0; end      // bit3 = rewind load address
`endif

                        6'h08: ctl_dir[ 31:  0] <= s_wdata;          // DIR0
                        6'h09: ctl_dir[ 63: 32] <= s_wdata;          // DIR1
                        6'h0A: ctl_dir[ 95: 64] <= s_wdata;          // DIR2
                        6'h0B: ctl_dir[127: 96] <= s_wdata;          // DIR3
                        6'h0C: ctl_dir[159:128] <= s_wdata;          // DIR4
                        6'h0D: ctl_dir[191:160] <= s_wdata;          // DIR5
                        6'h0E: ctl_dir[211:192] <= s_wdata[19:0];    // DIR6 (top 20 bits)
                        IDX_P7FFD: ctl_7ffd   <= s_wdata[5:0];
                        IDX_PFE:   ctl_border <= s_wdata[2:0];
                        IDX_COMMIT: begin
                            ctl_port_commit <= s_wdata[0];
                            ctl_dir_commit  <= s_wdata[1];
                        end
                        IDX_OSDCTRL: begin ctl_osd_enable <= s_wdata[0]; ctl_ddr_osd_en <= s_wdata[1]; end
                        IDX_OSDBG:   ctl_osd_bg     <= s_wdata[23:0];
                        IDX_OSDOP:   ctl_osd_op     <= s_wdata[7:0];
                        IDX_OSDPOS:  ctl_osd_pos    <= s_wdata;
                        IDX_VOL:     ctl_vol        <= s_wdata[7:0];
                        IDX_ACTL:    begin ctl_player_en <= s_wdata[0]; ctl_aud_sum <= s_wdata[1]; end   // B0107 бит1 = суммировать, а не скрещивать
                        IDX_AFIFO:   begin ctl_audio_data <= s_wdata; ctl_audio_we <= 1'b1; end
                        IDX_OSDADDR: osd_ptr        <= s_wdata[9:0];
                        IDX_OSDDATA: begin
                            ctl_osd_wdata <= s_wdata;
                            ctl_osd_we    <= 1'b1;
                            ctl_osd_waddr <= osd_ptr;
                            osd_ptr       <= osd_ptr + 10'd1;
                        end
                        IDX_BANCTRL: ctl_ban_enable <= s_wdata[0];
                        IDX_BANPOS:  ctl_ban_pos    <= s_wdata;
                        IDX_BANADDR: ban_ptr        <= s_wdata[8:0];
                        IDX_BANDATA: begin
                            ctl_ban_wdata <= s_wdata;
                            ctl_ban_we    <= 1'b1;
                            ctl_ban_waddr <= ban_ptr;
                            ban_ptr       <= ban_ptr + 9'd1;
                        end
                        IDX_ODBASE:  ctl_osd_ddr_base <= s_wdata;
                        IDX_ODPOS:   ctl_ddr_osd_pos  <= s_wdata;
                        IDX_TAPECTL: begin ctl_tape_run<=s_wdata[0]; ctl_tape_earmux<=s_wdata[1]; ctl_tape_mute<=s_wdata[2]; ctl_tape_fmode<=s_wdata[4:3]; ctl_tape_sync<=s_wdata[5]; ctl_tape_more<=s_wdata[6]; end
                        IDX_TAPEFIFO:begin ctl_tape_data<=s_wdata; ctl_tape_we<=1'b1; end
                        IDX_KBDHB: kbd_deadman_kick <= 1'b1;   // heartbeat: keep the gate open
                        IDX_KBDINJ: begin ctl_kbd_inject <= s_wdata[8:0]; ctl_kbd_inject_we <= 1'b1; end
                        IDX_KBDTX:  begin ctl_kbd_tx_data <= s_wdata[7:0]; ctl_kbd_tx_we <= 1'b1; end
                        default: ;
                    endcase
                    if (s_wlast) begin
                        s_wready <= 1'b0; s_bid <= awid_q; s_bresp <= 2'b00;
                        s_bvalid <= 1'b1; wstate <= W_RESP;
                    end
                end
                W_RESP: if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; wstate <= W_IDLE; end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    //---------------------------------------------------------------------------------------------
    // Read channel.
    //---------------------------------------------------------------------------------------------
    localparam R_IDLE = 2'd0, R_DATA = 2'd1, R_WAIT = 2'd2;
    reg [1:0]  rstate;
    reg [11:0] arid_q;
    reg [6:0]  aridx_q;   // v0x4A: 7-bit index
    reg        r_win;                  // current read targets the screen-mirror window (araddr[15]=1)
    reg        rd_was_empty;           // B0110: признак «пусто», ушедший В ЭТИ ЖЕ данные

    always @(posedge aclk) begin
        kbd_fifo_rd <= 1'b0;           // default: one-cycle pop pulse (set on a completed KBD_DATA read)
        gs_rq_rd    <= 1'b0;           // B0108: то же для очереди данных General Sound
        ctl_dmmc_bufr_re <= 1'b0;      // DivMMC: то же для буфера карты
        if (!aresetn) begin
            rstate <= R_IDLE; s_arready <= 1'b0; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rlast <= 1'b0; s_rdata <= 32'd0; s_rid <= 12'd0;
            kbd_fifo_rd <= 1'b0; gs_rq_rd <= 1'b0; ctl_dmmc_bufr_re <= 1'b0;
            ctl_scr_raddr <= 11'd0; r_win <= 1'b0;
            rd_was_empty <= 1'b1;
        end else case (rstate)
            R_IDLE: begin
                s_rvalid <= 1'b0; s_arready <= 1'b1;
                if (s_arvalid && s_arready) begin
                    arid_q <= s_arid; aridx_q <= s_araddr[8:2];
                    ctl_scr_raddr <= s_araddr[12:2];       // screen-mirror word index (for a 0x8000+ window read)
                    r_win <= s_araddr[15];                 // araddr[15]=1 -> screen-mirror window
                    s_arready <= 1'b0;
                    rstate <= s_araddr[15] ? R_WAIT : R_DATA;  // R_WAIT: 1 aclk for the BRAM read to settle
                end
            end
            R_WAIT: rstate <= R_DATA;   // scr_rdata (BRAM dout of ctl_scr_raddr) is valid now
            R_DATA: begin
                s_rid <= arid_q; s_rresp <= 2'b00; s_rlast <= 1'b1;
                if (r_win) s_rdata <= scr_rdata;   // screen-mirror window read
                else case (aridx_q)
                    IDX_VERSION: s_rdata <= VERSION;
                    IDX_CONTROL: s_rdata <= {31'd0, ctl_halt};
                    IDX_STATUS:  s_rdata <= {28'd0, axi_idle, reset_busy, ram_busy, halt_ack};   // bit3 = v158 axi_idle (quiesce done)  // bit2 reset_busy, bit1 ram_busy, bit0 halt_ack
                    IDX_COUNTER: s_rdata <= counter;
                    IDX_RAMADDR: s_rdata <= {15'd0, ctl_ram_addr};
                    IDX_SCRATCH: s_rdata <= reg_scratch;
                    IDX_OSDCTRL: s_rdata <= {30'd0, ctl_ddr_osd_en, ctl_osd_enable};
                    IDX_OSDBG:   s_rdata <= {8'd0, ctl_osd_bg};
                    IDX_OSDOP:   s_rdata <= {24'd0, ctl_osd_op};
                    IDX_OSDPOS:  s_rdata <= ctl_osd_pos;
                    IDX_BANCTRL: s_rdata <= {31'd0, ctl_ban_enable};
                    IDX_BANPOS:  s_rdata <= ctl_ban_pos;
                    IDX_BANADDR: s_rdata <= {23'd0, ban_ptr};
                    IDX_VOL:     s_rdata <= {24'd0, ctl_vol};
                    IDX_ASTAT:   s_rdata <= {22'd0, aud_rdcount, aud_full, aud_empty};
                    IDX_OSDADDR: s_rdata <= {22'd0, osd_ptr};
                    IDX_KBDDATA: begin s_rdata <= {21'd0, kbd_fifo_dout[9], kbd_fifo_dout[8], kbd_fifo_empty, kbd_fifo_dout[7:0]};
                                       rd_was_empty <= kbd_fifo_empty; end   // B0110: см. извлечение ниже
                    IDX_PS2DIAG: s_rdata <= ps2_diag_in;
                    IDX_MEMSTAT: s_rdata <= mem_stat_in;
                    IDX_MACHDBG: s_rdata <= mach_dbg_in;
                    IDX_ROMDBG:  s_rdata <= rom_dbg_in;
                    IDX_AUDDBG:  s_rdata <= aud_dbg_in;   // B0088
                    IDX_GSSTAT:  s_rdata <= gs_stat_in;   // General Sound
                    IDX_GSST2:   s_rdata <= gs_stat2_in;  // B0119 потери и удержания
                    IDX_GSST3:   s_rdata <= gs_stat3_in;  // B0119 сторож и цена удержаний
                    IDX_AUDPK:   s_rdata <= aud_pk_in;    // B0107 пик-метр ARM-ноги
                    IDX_NEMOST:  s_rdata <= nemo_stat_in;      // B0112
                    IDX_NEMOST2: s_rdata <= nemo_stat2_in;     // B0113
                    IDX_KMOUSE:  s_rdata <= ctl_kmouse;        // B0116: обратное чтение слова мыши
                    IDX_DMMCCTL: s_rdata <= ctl_dmmc;          // обратное чтение: чем оболочка рулит картой
                    IDX_DMMCCAP: s_rdata <= ctl_dmmc_cap;
                    IDX_DMMCBUFA:s_rdata <= dmmc_bufa_in;      // ЖИВОЙ указатель, а не записанный
                    IDX_DMMCBUFR:s_rdata <= dmmc_bufr_in;
                    IDX_DMMCSTAT:s_rdata <= dmmc_stat_in;
                    IDX_DMMCLBA: s_rdata <= dmmc_lba_in;
                    IDX_DMMCDBG: s_rdata <= dmmc_dbg_in;
                    IDX_GSRQ:    begin s_rdata <= {7'd0, gs_rq_cnt, 7'd0, gs_rq_empty, gs_rq_dout};
                                       rd_was_empty <= gs_rq_empty; end      // B0110: см. извлечение ниже
                    IDX_KBDSTAT: s_rdata <= {31'd0, kbd_fifo_empty};
                    IDX_MACHID:  s_rdata <= MACHINE_ID;
                    IDX_VGEOM:   s_rdata <= cap_geom;
                    IDX_ODBASE:  s_rdata <= ctl_osd_ddr_base;
                    IDX_ODPOS:   s_rdata <= ctl_ddr_osd_pos;
                    IDX_TAPECTL: s_rdata <= {25'd0, ctl_tape_more, ctl_tape_sync, ctl_tape_fmode, ctl_tape_mute, ctl_tape_earmux, ctl_tape_run};
                    IDX_TAPESTAT:s_rdata <= {30'd0, tape_playing, tape_full};
                    IDX_MEMWR:   s_rdata <= memwr_cnt;
                    IDX_DISPDIAG: s_rdata <= disp_diag;   // B0196 приборы читателя строк
                    IDX_KBDTXST: s_rdata <= {30'd0, kbd_tx_ack, kbd_tx_busy};
                    IDX_KBDDIAG: s_rdata <= kbd_diag;
                    IDX_PROBESTAT: s_rdata <= probe_stat;
                    IDX_PROBEMIN:  s_rdata <= probe_lat_min;
                    IDX_PROBEMAX:  s_rdata <= probe_lat_max;
                    IDX_PROBESUM:  s_rdata <= probe_lat_sum;
                    IDX_PROBECYC:  s_rdata <= probe_cycles;
                    IDX_PROBEBEAT: s_rdata <= probe_beats;
                    IDX_LOADCAPS:s_rdata <= LOAD_CAPS;
                    // B0071: обратное чтение адреса заливки ПЗУ. Без него нельзя доказать, что
                    // залилось ровно N байт (у картриджа NES этого нет, и это его недостаток).
                    IDX_ROMLDADDR: s_rdata <= {15'd0, ctl_rom_loading, ctl_rom_ld_addr};
                    IDX_ROMLDCNT:  s_rdata <= rom_ld_cnt;   // ФАКТ: сколько байт легло в BRAM
                    IDX_FDCSTAT:   s_rdata <= fdc_stat_in;  // B0075: телеметрия дисковода
                    IDX_FDCST2:    s_rdata <= fdc_stat2_in; // B0077: команда/дорожка/сектор от TR-DOS
                    IDX_JOY:     s_rdata <= ctl_joy;
                    IDX_PAPERH:  s_rdata <= {23'd0, ctl_paper_h};
                    IDX_PAPERV:  s_rdata <= {23'd0, ctl_paper_v};
                    IDX_ULATUNE:  s_rdata <= ctl_ula_tune;
                    IDX_ULATUNE2: s_rdata <= ctl_ula_tune2;
                    IDX_WARPHOLD:s_rdata <= ctl_warp_hold;
                    IDX_SYNCHOLD:s_rdata <= ctl_sync_hold;
                    IDX_ROMTRAP: s_rdata <= {sync_diag_in, 2'd0, p7ffd_s1_in, 7'd0, rt_pending_a_in};  // bit0 pending, [13:8] 7FFD, [31:16] SYNC diag
                    // B0071: отдаём ЦЕЛОЕ слово, а не пять защёлок. Раньше читались только биты 0..4,
                    // поэтому записанный хостом бит (бит8 = трап TR-DOS, бит6 = sprlimit у NES) читался
                    // как ноль - и приборная проверка «включился ли трап» была невозможна в принципе.
                    IDX_MACHCFG: s_rdata <= ctl_mach_cfg;  // 0xBC: bit0 Pentagon, bit1 48K, bit2 ULA Late, bit3 force_atlas, bit4 snow_off, bit8 TR-DOS trap
                    // ROM-trap owns REG0..REG6 only while enabled. With it off, expose passive
                    // tape diagnostics and the B0048 IN-FE trace without consuming another GP0 address.
                    IDX_REG0:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[ 31:  0] : tape_diag_count;
                    IDX_REG1:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[ 63: 32] : tape_diag_hash;
                    IDX_REG2:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[ 95: 64] : tape_diag_gaps;
                    IDX_REG3:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[127: 96] : tape_diag_resumes;
                    IDX_REG4:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[159:128] : fe_trace_count;
                    IDX_REG5:    s_rdata <= ctl_romtrap_en ? reg_rd1_in[191:160] : fe_trace_hash;
                    IDX_REG6:    s_rdata <= ctl_romtrap_en ? {12'd0, reg_rd1_in[211:192]} : fe_trace_last;
                    default:     s_rdata <= 32'hDEADBEEF;
                endcase
                s_rvalid <= 1'b1;
                if (s_rvalid && s_rready) begin
                    s_rvalid <= 1'b0; s_rlast <= 1'b0; rstate <= R_IDLE;
                    /* 🥇 B0110: ИЗВЛЕКАТЬ ТОЛЬКО ТО, ЧТО ОБОЛОЧКА ДЕЙСТВИТЕЛЬНО ПОЛУЧИЛА. Импульс
                       извлечения ставится по ЗАВЕРШЕНИЮ чтения, а данные (вместе с признаком «пусто»)
                       защёлкнуты РАНЬШЕ. Если байт пришёл в это окно, оболочка видела «пусто» и
                       уходила, а FIFO его уже вытолкнул - байт исчезал бесследно. На потоке модуля
                       это дало 71 одиночную потерю на 22 КБ в случайных местах (замерено сверкой
                       принятого потока с файлом), и модуль после такой заливки не играл. Теперь
                       извлечение гейтится тем же признаком, который ушёл в данные. Та же болезнь
                       была и у клавиатурного FIFO - «пропала клавиша» без всяких следов. */
                    if (!r_win && aridx_q == IDX_KBDDATA && !rd_was_empty) kbd_fifo_rd <= 1'b1;
                    if (!r_win && aridx_q == IDX_GSRQ    && !rd_was_empty) gs_rq_rd    <= 1'b1;
                    /* Указатель буфера карты двигаем ТОЖЕ по завершении чтения, а не при его
                       начале: иначе слово, которое оболочка не успела забрать, было бы пропущено
                       - ровно болезнь B0110, только вместо байта звука пропал бы байт сектора. */
                    if (!r_win && aridx_q == IDX_DMMCBUFR) ctl_dmmc_bufr_re <= 1'b1;
                end
            end
            default: rstate <= R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
