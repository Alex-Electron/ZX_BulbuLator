`timescale 1ns/1ps
// FCLK0 от PS без PS7-IP: голый примитив PS7 (стаб) + BUFG.
// Частоту FCLK0 (100 МГц от кварца 33.333) настраивает ps7_init через JTAG.
module clkgen (output wire fclk0);
    wire [3:0] fclk;
    (* DONT_TOUCH = "true" *) PS7 ps7_stub (.FCLKCLK(fclk));
    BUFG bufg_fclk (.I(fclk[0]), .O(fclk0));
endmodule
