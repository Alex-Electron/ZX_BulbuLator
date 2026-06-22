`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// osd_compositor.v  -  BulbuLator OSD MVP step 1: a 1-bpp "toast" strip composited over the live
// HDMI scanout (clk_pixel, RGB888), gated by osd_enable. No Z80 halt, no BRAM tile.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The OSD pixels live in a 256x64 1-bpp panel in DISTRIBUTED RAM (LUTRAM, NOT a BRAM tile - the
// device is 60/60 BRAM-full): 512 words x 32 packed pixels = 16384 bits (256*64). The ARM fills it
// over AXI (axi_ctl OSD_ADDR/OSD_DATA, fclk100 domain) - word count is unchanged from the old 512x32
// strip, so the 9-bit OSD address path is untouched. At HDMI scanout (clk_pixel) the panel window
// [X0,X0+256) x [Y0,Y0+64) is overlaid: a set pixel -> ink (cream); a clear pixel inside the window
// -> dimmed live video (the panel box); outside the window -> live video untouched. A combinational
// mux on the existing rgb path - the picture timing is unchanged (no added pipeline stage).
// This 1-bpp LUTRAM panel is the TEXT tier (help / menus); a future colour file-browser with load-
// screen previews belongs on a DDR-backed OSD layer (reusing the DDR framebuffer), not here.
//
// Pixel packing: word = ry*8 + rx/32 ; bit = rx%32 ; bit0 = leftmost pixel of the 32-pixel group.
//-------------------------------------------------------------------------------------------------
module osd_compositor #(
    parameter [10:0] X0  = 11'd512,        // panel left: horizontally centred (1280-256)/2
    parameter [10:0] Y0  = 11'd28,         // panel top: centred in the TOP grey band (band y 0..119,
                                           //   ZX picture starts at y=120) -> OSD sits above the screen
    parameter [23:0] INK = 24'hFBEABF      // cream (matches the ZX BulbuLator splash title)
)(
    input  wire        clk_pixel,          // HDMI pixel clock (read side)
    input  wire        aclk,               // fclk100 (OSD-buffer write side)
    input  wire        osd_enable_a,       // OSD on/off (aclk domain) - 2FF-synced inside
    input  wire        osd_we,             // aclk 1-cycle write strobe
    input  wire [8:0]  osd_waddr,          // word address 0..511
    input  wire [31:0] osd_wdata,          // 32 packed pixels (bit0 = leftmost)
    input  wire [10:0] cx,                 // HDMI X
    input  wire [10:0] cy,                 // HDMI Y
    input  wire [23:0] rgb_in,             // live RGB888 from fb_display
    output wire [23:0] rgb_out             // to hdmi_wrap
);
    localparam [10:0] W = 11'd256, H = 11'd64;

    // ---- OSD buffer: 256 x 64 bits in distributed RAM (512 words, no BRAM tile) ----
    (* ram_style = "distributed" *) reg [31:0] osd_buf [0:511];
    always @(posedge aclk) if (osd_we) osd_buf[osd_waddr] <= osd_wdata;

    // ---- osd_enable: 2-FF sync aclk -> clk_pixel ----
    reg [1:0] en_s = 2'b00;
    always @(posedge clk_pixel) en_s <= {en_s[0], osd_enable_a};
    wire osd_en = en_s[1];

    // ---- window test + pixel lookup (combinational) ----
    wire        in_win = (cx >= X0) && (cx < X0 + W) && (cy >= Y0) && (cy < Y0 + H);
    wire [10:0] rxv = cx - X0;                       // 0..255 when in_win
    wire [10:0] ryv = cy - Y0;                       // 0..63  when in_win
    wire [8:0]  word_idx = {ryv[5:0], rxv[7:5]};     // ry*8 + rx/32
    wire [4:0]  bit_idx  = rxv[4:0];                 // rx % 32
    wire        pix = osd_buf[word_idx][bit_idx];    // distributed-RAM async read

    // Barely-dimmed background (panel keeps ~7/8 of the live video) - a faint tint, mostly
    // see-through, so the OSD reads as a light haze over the grey field rather than a dark box.
    wire [7:0] dr = rgb_in[23:16], dg = rgb_in[15:8], db = rgb_in[7:0];
    wire [23:0] rgb_dim = { dr - (dr>>3), dg - (dg>>3), db - (db>>3) };
    assign rgb_out = (osd_en && in_win) ? (pix ? INK : rgb_dim) : rgb_in;
endmodule
//-------------------------------------------------------------------------------------------------
