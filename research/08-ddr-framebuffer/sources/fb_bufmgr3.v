`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_bufmgr3.v  -  TRIPLE-buffer manager for a CONTINUOUS source (live video capture).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Unlike the pattern generator (which could stall), a live ULA capture cannot be paused, so the
// writer must always have a free buffer -> three buffers. The writer fills `wr_buf`; on frame_done
// the just-written buffer is PUBLISHED as ready_buf and the writer immediately advances to the one
// remaining free buffer (neither displayed nor just-published) -> never stalls, never collides with
// the scanout. The loader latches disp_buf <= ready_buf only on the HDMI vblank -> tear-free.
//
// Race fix: if a writer_done and a frame_kick land on the SAME cycle, the writer's next-buffer pick
// uses the buffer disp is ABOUT to become (ready_buf), so wr_buf can never equal the new disp_buf.
//-------------------------------------------------------------------------------------------------
module fb_bufmgr3 #(
    parameter [31:0] FB0    = 32'h0FF0_0000,
    parameter [31:0] STRIDE = 32'h0001_0000
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire        frame_done,      // writer finished a frame into wr_buf
    input  wire        frame_kick,      // HDMI vblank (latch the display buffer)

    output wire [31:0] wr_base,         // DDR base for the writer
    output wire [31:0] disp_base,       // DDR base for the loader
    output wire [1:0]  wr_buf_o,
    output wire [1:0]  disp_buf_o,
    output wire [1:0]  ready_buf_o
);
    reg [1:0] wr_buf, ready_buf, disp_buf;
    assign wr_buf_o=wr_buf; assign disp_buf_o=disp_buf; assign ready_buf_o=ready_buf;

    function [31:0] base_of(input [1:0] b); base_of = FB0 + (STRIDE * b); endfunction
    assign wr_base   = base_of(wr_buf);
    assign disp_base = base_of(disp_buf);

    // the free buffer = the one that is neither r nor d (or, if r==d, any other)
    function [1:0] pick_w(input [1:0] r, input [1:0] d);
        pick_w = (r == d) ? ((r == 2'd2) ? 2'd0 : r + 2'd1) : (2'd3 - r - d);
    endfunction

    // disp as it will be AFTER this cycle (accounts for a concurrent vblank latch)
    wire [1:0] disp_next = frame_kick ? ready_buf : disp_buf;

    always @(posedge clk) begin
        if (!resetn) begin
            wr_buf<=2'd0; ready_buf<=2'd1; disp_buf<=2'd2;     // distinct at start
        end else begin
            if (frame_done) begin
                ready_buf <= wr_buf;                           // publish
                wr_buf    <= pick_w(wr_buf, disp_next);        // advance to the free buffer
            end
            if (frame_kick) disp_buf <= ready_buf;             // tear-free swap
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
