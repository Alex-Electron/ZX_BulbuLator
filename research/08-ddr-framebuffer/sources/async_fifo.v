`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// async_fifo.v  -  classic dual-clock (Cummings) gray-code async FIFO, distributed RAM, FWFT.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The CDC for the capture path: write side = Spectrum spclk, read side = fclk100. Gray-coded
// pointers crossed by 2-FF synchronisers (the only safe multi-bit CDC). dout is combinational
// (LUTRAM async read) -> first-word-fall-through: dout is the head whenever !empty; rd_en advances.
// DEPTH = 2^AW (64) easily absorbs the burst-drain vs steady-fill jitter (~few words occupancy).
//-------------------------------------------------------------------------------------------------
module async_fifo #(
    parameter DW = 64,
    parameter AW = 6                       // 64 entries
)(
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire           wr_en,
    input  wire [DW-1:0]  din,
    output wire           full,

    input  wire           rd_clk,
    input  wire           rd_rst_n,
    input  wire           rd_en,
    output wire [DW-1:0]  dout,
    output wire           empty,

    output reg  [AW:0]    rd_count            // read-domain occupancy (debug)
);
    (* ram_style = "distributed" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    // ---- write domain ----  (full is REGISTERED -> no combinational loop through wr_do)
    reg  [AW:0] wbin = 0, wgray = 0;
    reg  [AW:0] rgray_w1 = 0, rgray_w2 = 0;     // read gray ptr synced into wr_clk
    reg         full_r = 1'b0;
    wire        wr_do      = wr_en & ~full_r;
    wire [AW:0] wbin_next  = wbin + wr_do;
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire        full_next  = (wgray_next == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign      full = full_r;

    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) begin wbin<=0; wgray<=0; full_r<=1'b0; end
        else           begin wbin<=wbin_next; wgray<=wgray_next; full_r<=full_next; end
    always @(posedge wr_clk or negedge wr_rst_n)
        if (!wr_rst_n) begin rgray_w1<=0; rgray_w2<=0; end
        else           begin rgray_w1<=rgray; rgray_w2<=rgray_w1; end

    always @(posedge wr_clk) if (wr_do) mem[wbin[AW-1:0]] <= din;

    // ---- read domain ----  (empty is REGISTERED -> no combinational loop through rd_do)
    reg  [AW:0] rbin = 0, rgray = 0;
    reg  [AW:0] wgray_r1 = 0, wgray_r2 = 0;     // write gray ptr synced into rd_clk
    reg         empty_r = 1'b1;
    wire        rd_do      = rd_en & ~empty_r;
    wire [AW:0] rbin_next  = rbin + rd_do;
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
    wire        empty_next = (rgray_next == wgray_r2);
    assign      empty = empty_r;

    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin rbin<=0; rgray<=0; empty_r<=1'b1; end
        else           begin rbin<=rbin_next; rgray<=rgray_next; empty_r<=empty_next; end
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) begin wgray_r1<=0; wgray_r2<=0; end
        else           begin wgray_r1<=wgray; wgray_r2<=wgray_r1; end

    assign dout  = mem[rbin[AW-1:0]];           // FWFT: head is always presented

    // gray -> binary of the synced write pointer, for an occupancy estimate (debug only)
    integer k; reg [AW:0] wbin_r;
    always @(*) begin
        wbin_r[AW] = wgray_r2[AW];
        for (k=AW-1; k>=0; k=k-1) wbin_r[k] = wbin_r[k+1] ^ wgray_r2[k];
    end
    always @(posedge rd_clk or negedge rd_rst_n)
        if (!rd_rst_n) rd_count <= 0; else rd_count <= wbin_r - rbin;
endmodule
//-------------------------------------------------------------------------------------------------
