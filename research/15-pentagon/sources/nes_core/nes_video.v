// nes_video.v - adapt NESTang PPU output (color[5:0] + cycle/scanline) to the BulbuLator
// fb_capture_rr interface (hsync/vsync/blank + r/g/b/i + wr_ce pixel-enable).
//
// NES NTSC PPU raster: 341 dots/line (cycle 0..340), 262 lines/frame (scanline 0..261).
//   visible pixels: cycle 1..256 (256 px) on scanlines 0..239 (240 lines).
//   hblank: cycle 257..340 ; vblank: scanline 241..260 ; 261 pre-render, 240 post-render.
// A new PPU dot lands whenever `cycle` changes -> that is our pixel clock-enable (wr_ce).
//
// Round-1a colour (this file): crude NES 6-bit palette index -> 4-bit ZX RGBI so the picture flows
// through the UNCHANGED fb chain and we can prove the whole pipeline (core->mem->video->fb->HDMI)
// renders SHAPES. Round-1b will widen the capture to an 8-bit index + a real NES RGB888 palette in
// fb_line_disp for correct colours (SRC_BPP=8). Timing signals here are already the real thing.

module nes_video (
    input  wire       clk,
    input  wire [5:0] color,
    input  wire [8:0] cycle,
    input  wire [8:0] scanline,
    input  wire [7:0] h_off,     // v160 picture-in-window pan: 64 = centered (PAPER_H reg, menu Picture X)
    input  wire [7:0] v_off,     // 24 = centered (PAPER_V reg, menu Picture Y)

    output wire       wr_ce,     // 1 for exactly one clk per new PPU dot
    output wire       hsync,
    output wire       vsync,
    output wire       blank,
    output wire       r,
    output wire       g,
    output wire       b,
    output wire       i,
    output wire [7:0] pix8      // v161: raw palette index for the true-colour 8bpp path
);
    assign pix8 = {2'b00, color};
    // new-dot detector
    reg [8:0] cyc_d = 9'd0;
    always @(posedge clk) cyc_d <= cycle;
    assign wr_ce = (cycle != cyc_d);

    // visible window, pannable by +/-64/+/-24 around the PAPER center (owner's "picture inside the
    // machine window" knob): shifting the SAMPLING window pans the captured picture without touching
    // the machine's own timing. Off-window pixels sample whatever the PPU drives there (edge junk ok).
    wire signed [10:0] ho    = $signed({3'b000, h_off}) - 11'sd64;
    wire signed [10:0] vo    = $signed({3'b000, v_off}) - 11'sd24;
    wire signed [10:0] cyc_s = $signed({2'b00, cycle});
    wire signed [10:0] sl_s  = $signed({2'b00, scanline});
    wire vis = (cyc_s >= 11'sd1 + ho) && (cyc_s <= 11'sd256 + ho) && (sl_s >= vo) && (sl_s <= 11'sd239 + vo);
    assign blank = ~vis;

    // hsync during the horizontal blanking gap; vsync during the vertical blank band.
    assign hsync = (cycle >= 9'd280) && (cycle <= 9'd320);
    assign vsync = (scanline >= 9'd245) && (scanline <= 9'd255);

    // ---- Round-1a crude colour: NES color = {luma[5:4], hue[3:0]} -> RGBI ----
    // luma 0..3 (bits5:4); hue 0..15 (bits3:0): 0=grey, 1..C = colours, D/E/F ~ black.
    wire [1:0] luma = color[5:4];
    wire [3:0] hue  = color[3:0];
    wire dark = (hue == 4'hD) || (hue == 4'hE) || (hue == 4'hF) || (color == 6'h0F);
    assign i = (luma >= 2'd2) && ~dark;                 // bright for the upper luma levels
    // map the 12 real hues onto nearest R/G/B primary combo (crude but shapes are legible)
    reg [2:0] rgb;
    always @(*) begin
        if (dark)            rgb = 3'b000;              // black
        else if (hue==4'h0)  rgb = 3'b111;              // grey/white
        else case (hue[3:2]) // coarse hue sextant
            2'b00: rgb = 3'b100;   // reds/oranges     -> R
            2'b01: rgb = 3'b110;   // yellows/greens   -> R+G
            2'b10: rgb = 3'b011;   // cyans/blues      -> G+B
            2'b11: rgb = 3'b101;   // purples/magentas -> R+B
        endcase
    end
    assign {r,g,b} = rgb;
endmodule
