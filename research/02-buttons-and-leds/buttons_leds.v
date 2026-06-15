`timescale 1ns/1ps
// Step 2 for the EBAZ4205 (xc7z010): the four shield buttons drive the two LEDs.
// Clock is the internal CFGMCLK (STARTUPE2), so, like Step 1, this needs no PS,
// no external clock, and no DDR.
//
// Buttons are active-low with internal pull-ups: not pressed = 1, pressed = 0.
// The bitstream maps FPGA pins to functions; the physical KEY1..KEY4 labels on a
// given shield may not line up with these pins. Each does something while held:
//   btn0 (P19): freeze the blink   (stops the counter, LEDs hold)
//   btn1 (T19): both LEDs ON
//   btn2 (U20): both LEDs OFF
//   btn3 (U19): blink faster
// With nothing pressed, the LEDs blink in anti-phase, same as Step 1.
module buttons_leds (
    input  wire btn0, btn1, btn2, btn3,   // P19/T19/U20/U19, active-low
    output reg  led0, led1                 // D18, H18
);
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

    // Two-flop synchronizers, and turn active-low pins into active-high "pressed".
    reg [1:0] s0 = 2'b00, s1 = 2'b00, s2 = 2'b00, s3 = 2'b00;
    always @(posedge clk) begin
        s0 <= {s0[0], ~btn0};
        s1 <= {s1[0], ~btn1};
        s2 <= {s2[0], ~btn2};
        s3 <= {s3[0], ~btn3};
    end
    wire k1 = s0[1];   // freeze
    wire k2 = s1[1];   // both on
    wire k3 = s2[1];   // both off
    wire k4 = s3[1];   // faster

    // Free-running blink counter. KEY1 freezes it by gating the increment.
    reg [26:0] cnt = 27'd0;
    always @(posedge clk) if (!k1) cnt <= cnt + 27'd1;

    // KEY4 picks a faster bit of the counter.
    wire tick = k4 ? cnt[22] : cnt[24];

    // Priority: ON override, then OFF override, then the (possibly frozen) blink.
    always @(*) begin
        if (k2)      {led0, led1} = 2'b11;
        else if (k3) {led0, led1} = 2'b00;
        else         {led0, led1} = {tick, ~tick};
    end
endmodule
