`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// bulbulator_zx_top.v
// Contact: EU1L@mail.ru
//-------------------------------------------------------------------------------------------------
// Top-level integration of the Atlas ZX Spectrum 128K core on the EBAZ4205 board
// (Xilinx Zynq xc7z010clg400-1), with HDMI video + audio output (720p50).
//
// Clock domains:
//   * fclk100   100 MHz from PS7 FCLK0  -> source for both PLLs.
//   * clk_pixel 74.25 MHz  (HDMI pixel) -> hdmi core + framebuffer read.
//   * clk_ser   371.25 MHz (HDMI x5)    -> TMDS serializer.
//   * clk_audio ~48 kHz                 -> HDMI audio sample.
//   * spclk     ~56.7 MHz (Spectrum)    -> core + mem + keyboard + framebuffer write.
//
// The only clock-domain crossings are (1) the framebuffer's async dual-clock BRAM
// (spclk write / clk_pixel read) and (2) the 2-FF audio resync (spclk -> clk_audio).
//
// Reset: the Atlas core is ACTIVE-LOW reset throughout (T80pa RESET_n, turbosound,
// saa1099 rst_n, memory.v `negedge reset` / `if(!reset)`). A power-on counter holds
// sp_reset_n low until the Spectrum MMCM has been locked for a while, then releases
// it so the core cold-boots ROM0 (the 128K menu). The U19 button also forces reset.
//
// Built with the proven Step-5 PS7/MMCM/audio-clock/OBUFDS scaffold (hdmi-beep);
// only the pixel/audio source was replaced by the real core + framebuffer.
//-------------------------------------------------------------------------------------------------
module bulbulator_zx_top
(
    output wire       TMDS_Clk_p,     // F19
    output wire       TMDS_Clk_n,     // F20
    output wire [2:0] TMDS_Data_p,    // D19 / C20 / B19
    output wire [2:0] TMDS_Data_n,    // D20 / B20 / A20

    input  wire [3:0] btn,            // P19 / T19 / U20 / U19, active-low
    input  wire       ear_in,         // J19, tape audio in (LVCMOS33, PULLDOWN)

    output wire       led_lock,       // D18: Spectrum MMCM locked
    output wire       led_heart       // H18: heartbeat (alive indicator)
);
    //=============================================================================================
    // 100 MHz from the PS (FCLK0, set by ps7_init) - same source Step-5 uses.
    //=============================================================================================
    wire [3:0] fclk;
    (* DONT_TOUCH = "true" *) PS7 ps7_stub (.FCLKCLK(fclk));
    wire fclk100;
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));

    //=============================================================================================
    // HDMI clocks: 100 -> 74.25 (pixel) + 371.25 (serial x5). VCO 742.5 (M=37.125, D=5).
    // (verbatim from Step-5 hdmi_beep_top)
    //=============================================================================================
    wire clk_pix_raw, clk_ser_raw, fb, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.000),
        .CLKFBOUT_MULT_F(37.125), .DIVCLK_DIVIDE(5),
        .CLKOUT0_DIVIDE_F(10.000),   // 742.5 / 10  = 74.25 MHz
        .CLKOUT1_DIVIDE(2)           // 742.5 / 2   = 371.25 MHz
    ) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fb), .CLKFBOUT(fb),
        .CLKOUT0(clk_pix_raw), .CLKOUT1(clk_ser_raw),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked)
    );
    wire clk_pixel, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pixel));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire hdmi_reset = ~locked;   // hdl-util core wants ACTIVE-HIGH reset

    //=============================================================================================
    // 48 kHz audio clock: 74.25 MHz / 1547 = 47996 Hz   (verbatim from Step-5)
    //=============================================================================================
    reg [10:0] adiv = 11'd0;
    reg clk_audio_r = 1'b0;
    always @(posedge clk_pixel) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end

    //=============================================================================================
    // Spectrum master clock (~56.7 MHz) + clock enables from clock_zx.
    //=============================================================================================
    wire spclk;          // ~56.7 MHz Spectrum master
    wire sp_lock;         // Spectrum MMCM locked
    wire pe7M0, ne7M0, pe3M5, ne3M5;
    clock_zx clock_zx_i (
        .fclk100(fclk100),
        .clock  (spclk),
        .power  (sp_lock),
        .ne14M  (),               // unused
        .pe7M0  (pe7M0),
        .ne7M0  (ne7M0),
        .pe3M5  (pe3M5),
        .ne3M5  (ne3M5)
    );

    //=============================================================================================
    // Power-on reset in the Spectrum domain (ACTIVE-LOW: sp_reset_n = 0 holds the core).
    // Hold reset until sp_lock has been high long enough, then release. U19 (btn[3])
    // also forces reset while held (it is also the BREAK key inside kbd_buttons, which
    // is harmless - a momentary press just re-cold-boots).
    //=============================================================================================
    reg  [1:0]  lock_sync = 2'b00;          // sp_lock into spclk domain
    reg  [15:0] por_cnt   = 16'd0;          // power-on hold counter
    reg         sp_reset_n = 1'b0;          // active-low core reset
    wire        lock_in   = lock_sync[1];

    always @(posedge spclk) begin
        lock_sync <= {lock_sync[0], sp_lock};
        if (!lock_in) begin
            // MMCM not (yet) locked: hold reset, restart the counter.
            por_cnt    <= 16'd0;
            sp_reset_n <= 1'b0;
        end else if (por_cnt != 16'hFFFF) begin
            // Locked and counting up: keep the core in reset until the count completes
            // (~1.2 ms at 56.7 MHz) so all clocks are stable before the cold boot.
            por_cnt    <= por_cnt + 16'd1;
            sp_reset_n <= 1'b0;
        end else begin
            // Stable: release the core. It cold-boots ROM0 (the 128 menu).
            sp_reset_n <= 1'b1;
        end
    end

    //=============================================================================================
    // Tape input: synchronise the async ear_in pin into the Spectrum domain (2 FF).
    //=============================================================================================
    reg [1:0] ear_sync = 2'b00;
    always @(posedge spclk) ear_sync <= {ear_sync[0], ear_in};
    wire sp_ear = ear_sync[1];

    //=============================================================================================
    // Keyboard: 4 buttons -> PS/2-set-2 scan-code strobes for the core.
    //=============================================================================================
    wire       kbd_strb, kbd_make;
    wire [7:0] kbd_code;
    kbd_buttons kbd_i (
        .clock(spclk),
        .ce   (pe3M5),
        .btn  (btn),
        .strb (kbd_strb),
        .make (kbd_make),
        .code (kbd_code)
    );

    //=============================================================================================
    // Atlas ZX Spectrum core (main).
    //=============================================================================================
    // Video out (1 bit each)
    wire vid_blank, vid_hsync, vid_vsync, vid_r, vid_g, vid_b, vid_i;
    // Audio out (11-bit unsigned PCM)
    wire [10:0] laudio, raudio;
    // Memory buses
    wire        vmmCe;
    wire [13:0] vmmA1, vmmA2;
    wire [7:0]  vmmD;
    wire        memRf, memRd, memWr;
    wire [18:0] memA;
    wire [7:0]  memD, memQ;

    main core_i (
        .model  (1'b1),          // 128K
        .mapper (1'b0),          // mapper off
        .reset  (sp_reset_n),    // ACTIVE-LOW (see header)
        .nmi    (1'b0),

        .clock  (spclk),
        .pe7M0  (pe7M0),
        .ne7M0  (ne7M0),
        .pe3M5  (pe3M5),
        .ne3M5  (ne3M5),

        .blank  (vid_blank),
        .hsync  (vid_hsync),
        .vsync  (vid_vsync),
        .r      (vid_r),
        .g      (vid_g),
        .b      (vid_b),
        .i      (vid_i),

        .ear    (sp_ear),
        .laudio (laudio),
        .raudio (raudio),
        .midi   (),              // unused

        .strb   (kbd_strb),
        .make   (kbd_make),
        .code   (kbd_code),

        .joy1   (8'h00),
        .joy2   (8'h00),

        .cs     (),              // uSD unused
        .ck     (),
        .miso   (1'b1),
        .mosi   (),

        .vmmCe  (vmmCe),
        .vmmA1  (vmmA1),
        .vmmA2  (vmmA2),
        .vmmD   (vmmD),

        .memCe  (),              // unused
        .memRf  (memRf),
        .memRd  (memRd),
        .memWr  (memWr),
        .memA   (memA),
        .memD   (memD),
        .memQ   (memQ)
    );

    //=============================================================================================
    // Memory subsystem (ROM128 + 128K RAM + screen shadow), all in the Spectrum domain.
    //=============================================================================================
    mem_zx mem_i (
        .clock (spclk),
        .memRf (memRf),
        .memRd (memRd),
        .memWr (memWr),
        .memA  (memA),
        .memQ  (memQ),
        .memD  (memD),       // data back into the core
        .vmmCe (vmmCe),
        .vmmA1 (vmmA1),
        .vmmA2 (vmmA2),
        .vmmD  (vmmD)        // data back into the core
    );

    //=============================================================================================
    // Framebuffer / scaler. Write side = Spectrum domain (pe7M0), read side = clk_pixel.
    // cx/cy come back from the hdmi core (11-bit, see hdmi_wrap).
    //=============================================================================================
    wire [10:0] cx, cy;
    wire [23:0] rgb24;
    framebuffer fb_i (
        // write side : Spectrum domain
        .wr_clk (spclk),
        .wr_ce  (pe7M0),
        .hsync  (vid_hsync),
        .vsync  (vid_vsync),
        .blank  (vid_blank),
        .r      (vid_r),
        .g      (vid_g),
        .b      (vid_b),
        .i      (vid_i),
        // read side : HDMI pixel domain
        .rd_clk (clk_pixel),
        .cx     (cx),
        .cy     (cy),
        .rgb    (rgb24)
    );

    //=============================================================================================
    // Audio: 11-bit UNSIGNED PCM -> signed 16-bit, then resync into clk_audio.
    //
    // Conversion (offset-binary -> two's-complement, shifted up to 16 bits):
    //   left16 = { ~laudio[10], laudio[9:0], 5'b0 }
    // i.e. invert the MSB (centre the unsigned range about 0) and left-shift by 5 so
    // the 11-bit value occupies the top 11 bits of the signed 16-bit sample. This is
    // equivalent to ((sample - 1024) << 5) sign-extended. Same for the right channel.
    //=============================================================================================
    wire [15:0] left16_sp  = { ~laudio[10], laudio[9:0], 5'b0 };
    wire [15:0] right16_sp = { ~raudio[10], raudio[9:0], 5'b0 };

    // Sample in the Spectrum domain, then 2-FF resync into clk_audio. The word changes
    // slowly relative to 48 kHz, so a multi-bit 2-FF synchroniser is acceptable here.
    reg [15:0] left16_a0, left16_a1;
    reg [15:0] right16_a0, right16_a1;
    always @(posedge clk_audio_r) begin
        left16_a0  <= left16_sp;   left16_a1  <= left16_a0;
        right16_a0 <= right16_sp;  right16_a1 <= right16_a0;
    end

    //=============================================================================================
    // HDMI 1.4 (720p50) with stereo audio + OBUFDS to the TMDS pins.
    // (OBUFDS scaffold verbatim from Step-5; wrapper now stereo + real rgb/cx/cy.)
    //=============================================================================================
    wire [2:0] tmds;
    wire       tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser),
        .clk_pixel   (clk_pixel),
        .clk_audio   (clk_audio_r),
        .reset       (hdmi_reset),
        .rgb         (rgb24),
        .audio_left  (left16_a1),
        .audio_right (right16_a1),
        .tmds        (tmds),
        .tmds_clock  (tmds_clock),
        .cx          (cx),
        .cy          (cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi = 0; gi < 3; gi = gi + 1) begin : tb
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    //=============================================================================================
    // Indicators: led_lock = Spectrum MMCM locked; led_heart = ~1.7 Hz heartbeat.
    //=============================================================================================
    assign led_lock = sp_lock;
    reg [25:0] hb = 26'd0;
    always @(posedge clk_pixel) hb <= hb + 26'd1;
    assign led_heart = hb[24];
endmodule
//-------------------------------------------------------------------------------------------------
