`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// osd_compositor.v  -  BulbuLator OSD MVP step 1: a 1-bpp "toast" strip composited over the live
// HDMI scanout (clk_pixel, RGB888), gated by osd_enable. No Z80 halt, no BRAM tile.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// STEP-13 LOCAL COPY. Same osd_compositor as Step 11, plus (1) the independent banner_compositor
// module this step adds, and (2) a CDC fix: osd_bg / osd_op now use the same settle-latch as the
// position bus (Step 11 shipped them as a plain 2-FF, which can bit-skew a colour for one frame on
// a menu pick). Step 11's own osd_compositor.v is left exactly as published; assemble.sh for this
// step copies THIS file (from $HERE), not Step 11's - keeping earlier steps immutable.
//-------------------------------------------------------------------------------------------------
// The OSD pixels live in a 256x128 1-bpp panel in DISTRIBUTED RAM (LUTRAM, NOT a BRAM tile - the
// device is 60/60 BRAM-full): 1024 words x 32 packed pixels = 32768 bits (256*128). The ARM fills it
// over AXI (axi_ctl OSD_ADDR/OSD_DATA, fclk100 domain) - word count is 1024 (vs the old 512x32
// strip, so the 10-bit OSD address path is used. At HDMI scanout (clk_pixel) the panel window
// [X0,X0+256) x [Y0,Y0+128) is overlaid: a set pixel -> ink (cream); a clear pixel inside the window
// -> dimmed live video (the panel box); outside the window -> live video untouched. A combinational
// mux on the existing rgb path - the picture timing is unchanged (no added pipeline stage).
// This 1-bpp LUTRAM panel is the TEXT tier (help / menus); a future colour file-browser with load-
// screen previews belongs on a DDR-backed OSD layer (reusing the DDR framebuffer), not here.
//
// Pixel packing: word = ry*8 + rx/32 ; bit = rx%32 ; bit0 = leftmost pixel of the 32-pixel group.
//-------------------------------------------------------------------------------------------------
module osd_compositor #(
    parameter [23:0] INK = 24'hFBEABF      // cream text (matches the ZX BulbuLator splash title)
)(                                          // panel position X0/Y0 now come from osd_pos_a (a register)
    input  wire        clk_pixel,          // HDMI pixel clock (read side)
    input  wire        aclk,               // fclk100 (OSD-buffer write side)
    input  wire        osd_enable_a,       // OSD on/off (aclk domain) - 2FF-synced inside
    input  wire        osd_we,             // aclk 1-cycle write strobe
    input  wire [9:0]  osd_waddr,          // word address 0..1023 (256x128/32)
    input  wire [31:0] osd_wdata,          // 32 packed pixels (bit0 = leftmost)
    input  wire [23:0] osd_bg_a,           // user-chosen panel background colour (aclk domain)
    input  wire [7:0]  osd_op_a,           // panel opacity alpha 0..255 (bg fraction; 255=opaque, 0=clear)
    input  wire [31:0] osd_pos_a,          // OSD panel position: [10:0]=X0 (left), [26:16]=Y0 (top)
    input  wire [10:0] cx,                 // HDMI X
    input  wire [10:0] cy,                 // HDMI Y
    input  wire [23:0] rgb_in,             // live RGB888 from fb_display
    output wire [23:0] rgb_out             // to hdmi_wrap
);
    localparam [10:0] W = 11'd256, H = 11'd128;

    // ---- OSD buffer: 256 x 128 bits in distributed RAM (1024 words, no BRAM tile) ----
    (* ram_style = "distributed" *) reg [31:0] osd_buf [0:1023];
    always @(posedge aclk) if (osd_we) osd_buf[osd_waddr] <= osd_wdata;

    // ---- osd_enable: 2-FF sync aclk -> clk_pixel ----
    reg [1:0] en_s = 2'b00;
    always @(posedge clk_pixel) en_s <= {en_s[0], osd_enable_a};
    wire osd_en = en_s[1];

    // ---- osd_bg colour + opacity alpha + position: aclk -> clk_pixel ----
    // All three are multi-bit buses that change rarely (on a menu pick). A plain 2-FF sync can
    // bit-skew on the change cycle (several bits flip at once) and momentarily present a garbage
    // value. So 3-FF each and LATCH only a settled value (two equal samples in a row) -> the 1-cycle
    // skew value never reaches the blend/window logic. (Step 11 settle-latched only position; here
    // bg/op get the same treatment.)
    reg [23:0] bg_s1 = 24'h101840, bg_s2 = 24'h101840, bg_s3 = 24'h101840, bg_q = 24'h101840;
    reg [7:0]  op_s1 = 8'd204, op_s2 = 8'd204, op_s3 = 8'd204, op_q = 8'd204;   // default alpha ~80%
    reg [31:0] pos_s1 = 32'h00B00200, pos_s2 = 32'h00B00200, pos_s3 = 32'h00B00200, pos_q = 32'h00B00200;
    always @(posedge clk_pixel) begin
        bg_s1<=osd_bg_a;  bg_s2<=bg_s1;  bg_s3<=bg_s2;  if (bg_s2==bg_s3)   bg_q<=bg_s2;
        op_s1<=osd_op_a;  op_s2<=op_s1;  op_s3<=op_s2;  if (op_s2==op_s3)   op_q<=op_s2;
        pos_s1<=osd_pos_a; pos_s2<=pos_s1; pos_s3<=pos_s2; if (pos_s2==pos_s3) pos_q<=pos_s2;
    end
    wire [10:0] x0r = pos_q[10:0], y0r = pos_q[26:16];
    wire [10:0] x0 = (x0r > 11'd1024) ? 11'd1024 : x0r;  // HW clamp: panel can NEVER leave the 1280x720
    wire [10:0] y0 = (y0r > 11'd592 ) ? 11'd592  : y0r;  // screen, whatever the register holds (also kills x0+W overflow)

    // ---- window test + pixel lookup (combinational) ----
    wire        in_win = (cx >= x0) && (cx < x0 + W) && (cy >= y0) && (cy < y0 + H);
    wire [10:0] rxv = cx - x0;                       // 0..255 when in_win
    wire [10:0] ryv = cy - y0;                       // 0..127 when in_win
    wire [9:0]  word_idx = {ryv[6:0], rxv[7:5]};     // ry*8 + rx/32
    wire [4:0]  bit_idx  = rxv[4:0];                 // rx % 32
    wire        pix = osd_buf[word_idx][bit_idx];    // distributed-RAM async read

    // Panel background = osd_bg blended with live video by alpha (op_q, 0..255): bg*a + video*(255-a) >>8.
    // Alpha set from the menu in 5% steps; higher = dimmer/more opaque. Screen still shows faintly through.
    wire [7:0]  br = bg_q[23:16], bgc = bg_q[15:8], bb = bg_q[7:0];
    wire [7:0]  dr = rgb_in[23:16], dg = rgb_in[15:8], db = rgb_in[7:0];
    wire [7:0]  ia = 8'd255 - op_q;
    wire [15:0] mr = br*op_q + dr*ia;
    wire [15:0] mg = bgc*op_q + dg*ia;
    wire [15:0] mb = bb*op_q + db*ia;
    wire [23:0] rgb_bg = { mr[15:8], mg[15:8], mb[15:8] };
    assign rgb_out = (osd_en && in_win) ? (pix ? INK : rgb_bg) : rgb_in;
endmodule
//-------------------------------------------------------------------------------------------------
// banner_compositor.v  -  INDEPENDENT status BANNER overlay, composited OVER the OSD output. Own
// enable (BANNER_ENABLE) + position (BANNER_POS) - visible whether or not osd_enable is set.
// 256x64 1bpp in distributed LUTRAM (512 words). Mirrors the proven osd_compositor CDC + blend.
// Shows: PAUSE marker / playing track / app name + full SD path. ARM fills the buffer over AXI.
//-------------------------------------------------------------------------------------------------
module banner_compositor #(
    parameter [23:0] INK = 24'hFFFFFF,        // white status text
    parameter [23:0] BG  = 24'h202020,        // dark grey strip
    parameter [7:0]  OP  = 8'd200             // ~78% opaque
)(
    input  wire        clk_pixel,
    input  wire        aclk,
    input  wire        ban_enable_a,
    input  wire        ban_we,
    input  wire [8:0]  ban_waddr,
    input  wire [31:0] ban_wdata,
    input  wire [31:0] ban_pos_a,
    input  wire [10:0] cx,
    input  wire [10:0] cy,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out
);
    localparam [10:0] W = 11'd256, H = 11'd64;

    (* ram_style = "distributed" *) reg [31:0] ban_buf [0:511];
    always @(posedge aclk) if (ban_we) ban_buf[ban_waddr] <= ban_wdata;

    reg [1:0] en_s = 2'b00;
    always @(posedge clk_pixel) en_s <= {en_s[0], ban_enable_a};
    wire ban_en = en_s[1];

    reg [31:0] pos_s1 = 32'h02800200, pos_s2 = 32'h02800200, pos_s3 = 32'h02800200, pos_q = 32'h02800200;
    always @(posedge clk_pixel) begin
        pos_s1<=ban_pos_a; pos_s2<=pos_s1; pos_s3<=pos_s2;
        if (pos_s2==pos_s3) pos_q<=pos_s2;
    end
    wire [10:0] x0r = pos_q[10:0], y0r = pos_q[26:16];
    wire [10:0] x0 = (x0r > 11'd1024) ? 11'd1024 : x0r;
    wire [10:0] y0 = (y0r > 11'd656 ) ? 11'd656  : y0r;   // 720-64

    wire        in_win = (cx >= x0) && (cx < x0 + W) && (cy >= y0) && (cy < y0 + H);
    wire [10:0] rxv = cx - x0;
    wire [10:0] ryv = cy - y0;
    wire [8:0]  word_idx = {ryv[5:0], rxv[7:5]};
    wire [4:0]  bit_idx  = rxv[4:0];
    wire        pix = ban_buf[word_idx][bit_idx];

    wire [7:0]  br = BG[23:16], bgc = BG[15:8], bb = BG[7:0];
    wire [7:0]  dr = rgb_in[23:16], dg = rgb_in[15:8], db = rgb_in[7:0];
    wire [7:0]  ia = 8'd255 - OP;
    wire [15:0] mr = br*OP + dr*ia;
    wire [15:0] mg = bgc*OP + dg*ia;
    wire [15:0] mb = bb*OP + db*ia;
    wire [23:0] rgb_bg = { mr[15:8], mg[15:8], mb[15:8] };
    assign rgb_out = (ban_en && in_win) ? (pix ? INK : rgb_bg) : rgb_in;
endmodule
//-------------------------------------------------------------------------------------------------
