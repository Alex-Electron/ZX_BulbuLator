`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// ps2_tx.v  -  Step 15: PS/2 HOST->DEVICE transmitter.
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM writes a byte (AXI KBD_TX); this FSM runs the host-to-device handshake so the ARM can send
// keyboard commands - 0xED set-LEDs, 0xF3 typematic-rate, 0xFE resend, 0xFF reset. It is entirely
// hardware-timed, so it is immune to ARM / audio-ISR jitter (the reason we do NOT bit-bang it from
// software). The CLK/DATA lines are OPEN-DRAIN: *_low=1 pulls the line to 0, *_low=0 releases it
// (the board's 4k7 pull-up to 3.3 V returns it high). clk = spclk (~56.7 MHz).
//
// Host-to-device sequence (device generates the clock; host changes DATA just after each CLK falling
// edge, device samples on the following rising edge):
//   1. pull CLK low >= 100 us  (request-to-send / inhibit)
//   2. pull DATA low (start bit), release CLK  -> device begins clocking
//   3. on falling edges 1..8  drive data bits 0..7 (LSB first); edge 9 = odd parity; edge 10 = stop
//      (release DATA); edge 11 = device pulls DATA low = ACK -> sampled here.
// A ~9 ms watchdog aborts if the device never clocks (unplugged / dead), so busy can never latch.
//-------------------------------------------------------------------------------------------------
module ps2_tx #(
    parameter integer INHIBIT  = 8000,     // spclk cycles of CLK-low request-to-send (~141 us @ 56.7 MHz)
    parameter integer TIMEOUT  = 500000    // ~9 ms overall watchdog
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,               // 1-cycle strobe: begin sending tx_data
    input  wire [7:0] tx_data,
    input  wire       ps2c_in,             // synced CLK pin read (1 = released/high, 0 = low)
    input  wire       ps2d_in,             // synced DATA pin read
    output reg        clk_low,             // 1 = drive CLK low  (open-drain enable)
    output reg        data_low,            // 1 = drive DATA low (open-drain enable)
    output reg        busy,
    output reg        done,                // 1-cycle pulse when a send finishes (or times out)
    output reg        ackok                // 1 = device ACK bit was low (byte accepted)
);
    localparam S_IDLE=3'd0, S_INHIBIT=3'd1, S_START=3'd2, S_BITS=3'd3, S_STOP=3'd4, S_ACK=3'd5, S_FIN=3'd6;
    reg [2:0]  st;
    reg [18:0] tmr;
    reg [3:0]  bcnt;
    reg [7:0]  sh;
    reg        par;
    reg        pc_d;                        // CLK edge-detect flop
    wire       clk_fall = pc_d & ~ps2c_in;  // device pulled CLK low

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; clk_low<=1'b0; data_low<=1'b0; busy<=1'b0; done<=1'b0; ackok<=1'b0;
            tmr<=19'd0; bcnt<=4'd0; pc_d<=1'b1; sh<=8'd0; par<=1'b0;
        end else begin
            done <= 1'b0;
            pc_d <= ps2c_in;
            if (st!=S_IDLE) tmr <= tmr + 19'd1;
            if (st!=S_IDLE && st!=S_INHIBIT && tmr>=TIMEOUT) begin   // dead device -> abort cleanly
                clk_low<=1'b0; data_low<=1'b0; ackok<=1'b0; done<=1'b1; busy<=1'b0; st<=S_IDLE;
            end else case (st)
                S_IDLE: begin
                    clk_low<=1'b0; data_low<=1'b0; busy<=1'b0;
                    if (start) begin sh<=tx_data; par<=~(^tx_data); busy<=1'b1; tmr<=19'd0; st<=S_INHIBIT; end
                end
                S_INHIBIT: begin
                    clk_low<=1'b1;                                    // hold CLK low (request-to-send)
                    if (tmr>=INHIBIT) begin
                        data_low<=1'b1;                              // start bit (DATA low)
                        clk_low <=1'b0;                              // release CLK -> device clocks
                        st<=S_START;
                    end
                end
                S_START: if (clk_fall) begin                          // edge 1: drive data bit 0
                    data_low<=~sh[0]; sh<={1'b0,sh[7:1]}; bcnt<=4'd1; st<=S_BITS;
                end
                S_BITS: if (clk_fall) begin
                    if (bcnt<4'd8) begin data_low<=~sh[0]; sh<={1'b0,sh[7:1]}; bcnt<=bcnt+4'd1; end  // data 1..7
                    else          begin data_low<=~par;   st<=S_STOP; end                            // edge 9: parity
                end
                S_STOP: if (clk_fall) begin data_low<=1'b0; st<=S_ACK; end                            // edge 10: release (stop)
                S_ACK:  if (clk_fall) begin ackok<=~ps2d_in; st<=S_FIN; end                           // edge 11: sample ACK
                S_FIN:  begin clk_low<=1'b0; data_low<=1'b0; busy<=1'b0; done<=1'b1; st<=S_IDLE; end
            endcase
        end
    end
endmodule
//-------------------------------------------------------------------------------------------------
