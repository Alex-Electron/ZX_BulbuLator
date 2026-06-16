`timescale 1ns/1ps
// ZX Spectrum 128K master clock for the EBAZ4205 (7010), from PS FCLK0 (100 MHz).
// 128K master ~= 56.75 MHz (the original uses 56.7504 from a 50 MHz board). The
// framebuffer decouples the Spectrum frame rate from the HDMI 720p50 output, so a
// close value is fine. Enables (pe7M0/ne7M0/pe3M5/ne3M5) match Atlas clock.v.
module clock_zx (
    input  wire fclk100,        // 100 MHz from PS7 FCLK0
    output wire clock,          // ~56.7 MHz Spectrum master
    output wire power,          // MMCM locked
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

    // Clock enables, exactly as Atlas clock.v derives them from the master.
    reg [3:0] ce = 4'd1;
    always @(negedge clock) if (power) begin
        ce    <= ce + 1'd1;
        ne14M <= ~ce[0] & ~ce[1];
        pe7M0 <= ~ce[0] & ~ce[1] &  ce[2];
        ne7M0 <= ~ce[0] & ~ce[1] & ~ce[2];
        pe3M5 <= ~ce[0] & ~ce[1] & ~ce[2] &  ce[3];
        ne3M5 <= ~ce[0] & ~ce[1] & ~ce[2] & ~ce[3];
    end
endmodule
