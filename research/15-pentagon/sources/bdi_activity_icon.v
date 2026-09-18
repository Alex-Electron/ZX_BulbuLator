`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// bdi_activity_icon.v - Hardware floppy activity LED outside the machine window.
// Bottom-right of the 1280x720 HDMI frame. Lights (with hold) on Beta Disk / FDC traffic so the
// owner sees disk reads and writes without opening the OSD. Pure fabric: no ARM involvement.
//-------------------------------------------------------------------------------------------------
module bdi_activity_icon #(
    parameter integer X0 = 1240,          // left edge of 24x24 icon (1280-40)
    parameter integer Y0 = 680,           // top edge (720-40)
    parameter integer SIZE = 24,
    parameter [23:0] COL_ON  = 24'hF0C040, // amber body when active
    parameter [23:0] COL_DIM = 24'h403010, // dark body when idle (barely visible hub)
    parameter [23:0] COL_LED = 24'h40F060  // green "access" LED
)(
    input  wire        clk_pixel,
    input  wire        aclk,
    input  wire [31:0] fdc_stat_a,        // live FDC_STAT from axi (aclk domain)
    input  wire [10:0] cx,
    input  wire [10:0] cy,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    // FDC_STAT packing (beta_disk.v):
    //  [22] sd_ack, [21] DRQ, [19] busy, [17] sd_wr, [16] sd_rd
    wire act_raw_a = fdc_stat_a[22] | fdc_stat_a[21] | fdc_stat_a[19]
                   | fdc_stat_a[17] | fdc_stat_a[16];

    // Hold ~150 ms at 100 MHz so short sector bursts stay visible.
    reg [24:0] hold_a = 25'd0;
    always @(posedge aclk) begin
        if (act_raw_a)
            hold_a <= 25'd15_000_000;
        else if (hold_a != 0)
            hold_a <= hold_a - 25'd1;
    end
    wire act_hold_a = (hold_a != 0);
    // Distinguish write vs read while the command is live (for LED colour).
    wire wr_live_a = fdc_stat_a[17];

    (* ASYNC_REG = "TRUE" *) reg [2:0] act_s = 3'b000;
    (* ASYNC_REG = "TRUE" *) reg [2:0] wr_s  = 3'b000;
    always @(posedge clk_pixel) begin
        act_s <= {act_s[1:0], act_hold_a};
        wr_s  <= {wr_s[1:0],  wr_live_a};
    end
    wire act = act_s[2];
    wire wr  = wr_s[2];

    // Slow blink (~5 Hz) while active so the icon "pulses" during a long load.
    reg [23:0] blink_div = 24'd0;
    always @(posedge clk_pixel) blink_div <= blink_div + 24'd1;
    // 74.25 MHz / 2^23 ≈ 8.9 Hz half-period → ~4.5 Hz full blink
    wire blink_on = blink_div[23];

    wire in_icon = (cx >= X0[10:0]) && (cx < X0[10:0] + SIZE[10:0])
                && (cy >= Y0[10:0]) && (cy < Y0[10:0] + SIZE[10:0]);
    wire [4:0] ix = cx - X0[10:0];   // 0..23
    wire [4:0] iy = cy - Y0[10:0];

    // 24x24 floppy glyph. 1 = body, 2 = window/label, 3 = hub, 4 = access LED.
    // Drawn oversized and blocky so it reads at a glance on HDMI.
    reg [2:0] pix;
    always @* begin
        pix = 3'd0;
        // outer body
        if (ix >= 2 && ix <= 21 && iy >= 1 && iy <= 22)
            pix = 3'd1;
        // top shutter / metal slider
        if (ix >= 4 && ix <= 19 && iy >= 2 && iy <= 6)
            pix = 3'd2;
        // label window
        if (ix >= 5 && ix <= 18 && iy >= 9 && iy <= 14)
            pix = 3'd2;
        // hub ring
        if (ix >= 9 && ix <= 14 && iy >= 16 && iy <= 20)
            pix = 3'd3;
        // access LED hole (bottom-left of face)
        if (ix >= 4 && ix <= 6 && iy >= 17 && iy <= 19)
            pix = 3'd4;
        // cut corners (classic 3.5" look)
        if ((ix <= 2 && iy <= 2) || (ix >= 21 && iy <= 2))
            pix = 3'd0;
    end

    wire show_body = (pix == 3'd1) || (pix == 3'd2) || (pix == 3'd3);
    wire show_led  = (pix == 3'd4);

    // Idle: very dim outline so the corner is not empty. Active: bright body + blinking LED.
    // Write activity: LED red-ish; read: green.
    wire [23:0] body_col = act ? COL_ON : COL_DIM;
    wire [23:0] led_col  = wr ? 24'hF04040 : COL_LED;
    wire        led_lit  = act && blink_on;

    reg [23:0] rgb_sel;
    always @* begin
        rgb_sel = rgb_in;
        if (in_icon) begin
            if (show_led && led_lit)
                rgb_sel = led_col;
            else if (show_body && (act || pix == 3'd1 || pix == 3'd3))
                rgb_sel = (pix == 3'd2) ? (act ? 24'hE0E0C0 : 24'h303028)
                                        : (pix == 3'd3) ? (act ? 24'h808090 : 24'h202028)
                                                        : body_col;
            else if (show_led && act)
                rgb_sel = 24'h202020; // LED socket dark between blinks
        end
    end
    assign rgb_out = rgb_sel;
endmodule
//-------------------------------------------------------------------------------------------------
