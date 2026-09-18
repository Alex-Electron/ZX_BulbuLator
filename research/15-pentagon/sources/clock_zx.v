`timescale 1ns/1ps
// ZX Spectrum 128K master clock for the EBAZ4205 (7010), from PS FCLK0 (100 MHz).
// STEP-15 LOCAL COPY (research/06 original stays as published; assemble.sh copies THIS one).
// Delta: a `warp` input for FAST TAPE LOAD. When warp=1 the WHOLE clock-enable set (pe7M0/ne7M0/
// pe3M5/ne3M5) is generated on a SHORTER period so the ENTIRE core (CPU + ULA/video + contention +
// tape, all locked to these enables) runs 4x faster IN LOCK-STEP. Because every enable scales by the
// same factor, ALL timing ratios are preserved exactly - this is "whole-core warp" (like an emulator's
// full-speed mode), so border/ULA-timed effects and TZX pauses load correctly (unlike CPU-only warp).
// 4x is the ceiling: a pe/ne pair needs 2 master cycles, so the 7 MHz enables max out at 28 MHz
// (period 2) and the 3.5 MHz CPU enables at 14 MHz (period 4). The HDMI output keeps its own fixed
// pixel clock (reads the DDR framebuffer), so during a warp load the screen just updates/flickers
// faster - cosmetic, and explicitly acceptable. `warp` is adopted only at the /16 boundary (ce==0)
// so the change lands on a clean T-state boundary (no dropped/added half-tick in the T80pa handshake).
module clock_zx (
    input  wire fclk100,        // 100 MHz from PS7 FCLK0
    input  wire warp,           // 1 = full warp: run the whole enable set 4x (14 MHz CPU / 28 MHz ULA)
    input  wire warp2,          // 1 = diagnostic whole-core 2x (7 MHz CPU / 14 MHz ULA)
    output wire clock,          // ~56.7 MHz Spectrum master
    output wire power,          // MMCM locked
    output wire warp_ack,       // a requested non-native schedule has been adopted on a clean boundary
    output reg  ne14M,
    output reg  pe7M0,
    output reg  ne7M0,
    output reg  pe3M5,
    output reg  ne3M5
);
    // 100 -> ~56.667 MHz.  VCO = 100*34/3 = 1133.33 MHz (in -1 range), /20 = 56.667 MHz.
    wire clk_raw, fb, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.000),
        .CLKFBOUT_MULT_F(34.000), .DIVCLK_DIVIDE(3),
        .CLKOUT0_DIVIDE_F(20.000)
    ) mmcm (
        .CLKIN1(fclk100), .CLKFBIN(fb), .CLKFBOUT(fb),
        .CLKOUT0(clk_raw),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(), .CLKOUT3B(), .CLKFBOUTB(),
        .RST(1'b0), .PWRDWN(1'b0), .LOCKED(locked)
    );
    BUFG bufg (.I(clk_raw), .O(clock));
    assign power = locked;

    // Native is the Atlas /16 pattern.  Whole2 uses /8 and whole4 /4; each keeps the same
    // phase ordering and ratios.  Switching only at ce==0 preserves a complete T-state boundary.
    reg [3:0] ce = 4'd1;
    reg [1:0] warp_l = 2'd0; // 0=native, 1=whole2, 2=whole4
    assign warp_ack = |warp_l;
    always @(negedge clock) if (power) begin
        ce <= ce + 1'd1;
        if (ce == 4'd0) begin                           // adopt a new schedule only at a T-state boundary
            if      (warp)  warp_l <= 2'd2;
            else if (warp2) warp_l <= 2'd1;
            else            warp_l <= 2'd0;
        end
        if (warp_l == 2'd2) begin                       // 4x whole-core warp
            ne14M <= 1'b1;
            pe7M0 <=  ce[0];
            ne7M0 <= ~ce[0];
            pe3M5 <= (ce[1:0] == 2'd2);
            ne3M5 <= (ce[1:0] == 2'd0);
        end else if (warp_l == 2'd1) begin              // B0047 diagnostic: doubles each native enable rate
            ne14M <= ~ce[0];
            pe7M0 <= (ce[1:0] == 2'd2);
            ne7M0 <= (ce[1:0] == 2'd0);
            pe3M5 <= (ce[2:0] == 3'd4);
            ne3M5 <= (ce[2:0] == 3'd0);
        end else begin                                  // normal 3.5/7/14 MHz (Atlas)
            ne14M <= ~ce[0] & ~ce[1];
            pe7M0 <= ~ce[0] & ~ce[1] &  ce[2];
            ne7M0 <= ~ce[0] & ~ce[1] & ~ce[2];
            pe3M5 <= ~ce[0] & ~ce[1] & ~ce[2] &  ce[3];
            ne3M5 <= ~ce[0] & ~ce[1] & ~ce[2] & ~ce[3];
        end
    end
endmodule
