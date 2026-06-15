`timescale 1ns/1ps
// Minimal self-clocked LED blinker for xc7z010.
// Clock source is the internal CFGMCLK (~50-65 MHz config oscillator) via
// STARTUPE2, so this needs NO PS/FCLK and no external clock routing. It proves
// the JTAG -> PL flow on the 7010 entirely on its own.
// D18 and H18 blink in anti-phase so the alternation is obvious.
module blink (output wire led0, output wire led1);
    wire clk;
    STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) su (
        .CFGMCLK (clk),
        .CLK     (1'b0),
        .GSR     (1'b0),
        .GTS     (1'b0),
        .KEYCLEARB(1'b1),
        .PACK    (1'b0),
        .USRCCLKO(1'b0),
        .USRCCLKTS(1'b1),
        .USRDONEO(1'b1),
        .USRDONETS(1'b1),
        .CFGCLK  (),
        .EOS     (),
        .PREQ    ()
    );
    reg [26:0] cnt = 27'd0;
    always @(posedge clk) cnt <= cnt + 27'd1;
    assign led0 = cnt[24];   // ~1-2 Hz at CFGMCLK
    assign led1 = ~cnt[24];
endmodule
