`timescale 1ns/1ps
// Step 5: a bouncing square that beeps over HDMI *audio* when it hits a wall.
// 1280x720@50 video + 48 kHz PCM audio through the hdl-util/hdmi core
// (real HDMI data islands, not DVI). Clocked from the PS (FCLK0 = 100 MHz).
module hdmi_beep_top (
    output wire       TMDS_Clk_p,
    output wire       TMDS_Clk_n,
    output wire [2:0] TMDS_Data_p,
    output wire [2:0] TMDS_Data_n,
    output wire       led_lock,    // D18: MMCM locked
    output wire       led_heart    // H18: pixel-clock heartbeat
);
    // --- 100 MHz from the PS (FCLK0, set by ps7_init) ---
    wire [3:0] fclk;
    (* DONT_TOUCH = "true" *) PS7 ps7_stub (.FCLKCLK(fclk));
    wire fclk100;
    BUFG bufg100 (.I(fclk[0]), .O(fclk100));

    // --- 100 -> 74.25 (pixel) + 371.25 (serial x5). VCO 742.5 (M=37.125, D=5) ---
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
    wire clk_pix, clk_ser;
    BUFG b0 (.I(clk_pix_raw), .O(clk_pix));
    BUFG b1 (.I(clk_ser_raw), .O(clk_ser));
    wire reset = ~locked;

    // --- 48 kHz audio clock: 74.25 MHz / 1547 = 47996 Hz ---
    reg [10:0] adiv = 11'd0;
    reg clk_audio_r = 1'b0;
    always @(posedge clk_pix) begin
        adiv <= (adiv >= 11'd1546) ? 11'd0 : adiv + 11'd1;
        clk_audio_r <= (adiv < 11'd773);
    end

    // --- raster position comes back from the HDMI core ---
    wire [10:0] cx, cy;

    // --- bouncing square ---
    localparam integer W = 1280, H = 720, SZ = 96, SPD = 6;
    reg [10:0] bx = 11'd200, by = 11'd150;
    reg dirx = 1'b1, diry = 1'b1;
    reg bounce = 1'b0;
    reg [7:0] fcnt = 8'd0;
    wire frame_tick = (cy == 11'd720) && (cx == 11'd0);  // once per frame (vblank)
    always @(posedge clk_pix) begin
        bounce <= 1'b0;
        if (frame_tick) begin
            fcnt <= fcnt + 8'd1;
            if (dirx) begin
                if (bx + SZ + SPD >= W) begin dirx <= 1'b0; bounce <= 1'b1; end
                else bx <= bx + SPD;
            end else begin
                if (bx <= SPD)           begin dirx <= 1'b1; bounce <= 1'b1; end
                else bx <= bx - SPD;
            end
            if (diry) begin
                if (by + SZ + SPD >= H) begin diry <= 1'b0; bounce <= 1'b1; end
                else by <= by + SPD;
            end else begin
                if (by <= SPD)           begin diry <= 1'b1; bounce <= 1'b1; end
                else by <= by - SPD;
            end
        end
    end

    wire in_sq = (cx >= bx) && (cx < bx + SZ) && (cy >= by) && (cy < by + SZ);
    wire [23:0] rgb24 = in_sq ? {fcnt, ~fcnt, 8'hFF} : 24'h001028;

    // --- beep: on a bounce, play a ~1.5 kHz tone for ~60 ms ---
    localparam integer DUR = 2880;          // 48000 * 0.06 s
    reg [11:0] beep_cnt = 12'd0;
    reg [5:0]  ph = 6'd0;
    reg ca_d = 1'b0;
    wire sample_tick = clk_audio_r & ~ca_d; // one pulse per audio sample
    always @(posedge clk_pix) begin
        ca_d <= clk_audio_r;
        if (bounce) beep_cnt <= DUR[11:0];
        else if (sample_tick && beep_cnt != 12'd0) begin
            beep_cnt <= beep_cnt - 12'd1;
            ph <= ph + 6'd1;
        end
    end
    wire tone = ph[4];                       // 48000 / 32 = 1500 Hz
    wire [15:0] audio_pcm = (beep_cnt != 12'd0) ? (tone ? 16'h1800 : 16'hE800) : 16'h0000;

    // --- HDMI 1.4 with audio + OBUFDS to the TMDS pins ---
    wire [2:0] tmds;
    wire tmds_clock;
    hdmi_wrap hdmi_ (
        .clk_pixel_x5(clk_ser), .clk_pixel(clk_pix), .clk_audio(clk_audio_r),
        .reset(reset),
        .rgb(rgb24), .audio_pcm(audio_pcm),
        .tmds(tmds), .tmds_clock(tmds_clock),
        .cx(cx), .cy(cy)
    );
    OBUFDS obuf_clk (.I(tmds_clock), .O(TMDS_Clk_p), .OB(TMDS_Clk_n));
    genvar gi;
    generate for (gi = 0; gi < 3; gi = gi + 1) begin : tb
        OBUFDS obuf_d (.I(tmds[gi]), .O(TMDS_Data_p[gi]), .OB(TMDS_Data_n[gi]));
    end endgenerate

    assign led_lock = locked;
    reg [25:0] hb = 26'd0;
    always @(posedge clk_pix) hb <= hb + 26'd1;
    assign led_heart = hb[24];
endmodule
