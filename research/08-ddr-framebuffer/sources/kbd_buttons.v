//-------------------------------------------------------------------------------------------------
// kbd_buttons.v   -   Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// Four EBAZ4205 expansion-board push-buttons -> PS/2-set-2 scan-code TAPS for the
// Atlas ZX core (main.v / keyboard.v).
//
// Each physical press makes exactly ONE short key tap: a make strobe, the key held
// "down" for ~40 ms (long enough for the 128 ROM keyboard scan to register it, far
// below the ROM's auto-repeat delay ~0.7 s), then a break strobe - regardless of how
// long the button stays held. Holding the button does NOT keep the key down, so the
// menu moves exactly one step per press. (The previous version left the key down for
// the whole hold, so the ROM auto-repeated and the menu flew past / locked up.)
//
// keyboard.v maps these PS/2 set-2 codes to the ZX matrix:
//   72 = DOWN (CS+6)   75 = UP (CS+7)   5A = ENTER   76 = BREAK (CS+SPACE)
// Buttons (ACTIVE-LOW): btn0=P19 DOWN, btn1=T19 UP, btn2=U20 ENTER, btn3=U19 BREAK.
//
// CRITICAL - 'make' POLARITY IS INVERTED in the Atlas core: ps2.v does
// `make <= (code == 8'hF0)` (F0 = the PS/2 BREAK/release prefix), and keyboard.v does
// `key[..] <= make`, where the ZX matrix reads 0 = pressed. So in this core
//   make = 0  ->  key PRESSED      make = 1  ->  key RELEASED.
// A press tap therefore sends make=0, then auto-releases with make=1. (Sending make=1
// for "press" leaves the key held = 0 in the matrix -> ROM auto-repeat -> runaway.)
//
// Pure Verilog-2001. Synthesises in Vivado 2023.1 for xc7z010.
//-------------------------------------------------------------------------------------------------
module kbd_buttons
(
    input  wire       clock,   // ~56.7 MHz Spectrum clock
    input  wire       ce,      // slow enable (pe3M5 ~3.5 MHz); all logic gated by it
    input  wire [3:0] btn,     // raw async buttons, ACTIVE-LOW (pressed = 0)
    output reg        strb,
    output reg        make,
    output reg [7:0]  code
);
    localparam [7:0] SC_DOWN = 8'h72, SC_UP = 8'h75, SC_ENTER = 8'h5A, SC_BREAK = 8'h76;

    // 1) synchronise the async, active-low buttons; invert to active-high "pressed".
    reg [3:0] s0 = 4'd0, s1 = 4'd0;
    always @(posedge clock) if (ce) begin s0 <= ~btn; s1 <= s0; end

    // 2) debounce: a level must hold stable for the whole window before it is accepted.
    localparam DBW = 14;                         // ~4.7 ms at 3.5 MHz
    reg [3:0]     db = 4'd0, dbp = 4'd0;          // debounced level + its delayed copy
    reg [DBW-1:0] c0 = 0, c1 = 0, c2 = 0, c3 = 0; // per-button stability counters
    always @(posedge clock) if (ce) begin
        if (s1[0]==db[0]) c0<=0; else if (&c0) begin db[0]<=s1[0]; c0<=0; end else c0<=c0+1'b1;
        if (s1[1]==db[1]) c1<=0; else if (&c1) begin db[1]<=s1[1]; c1<=0; end else c1<=c1+1'b1;
        if (s1[2]==db[2]) c2<=0; else if (&c2) begin db[2]<=s1[2]; c2<=0; end else c2<=c2+1'b1;
        if (s1[3]==db[3]) c3<=0; else if (&c3) begin db[3]<=s1[3]; c3<=0; end else c3<=c3+1'b1;
        dbp <= db;
    end
    wire [3:0] pedge = db & ~dbp;                 // press edges (0 -> 1)

    // 3) tap FSM: one press + auto-release per press edge.
    function [7:0] codeOf;
        input [1:0] i;
        case (i) 2'd0: codeOf=SC_DOWN; 2'd1: codeOf=SC_UP; 2'd2: codeOf=SC_ENTER; default: codeOf=SC_BREAK; endcase
    endfunction

    localparam [17:0] TAP_HOLD = 18'd140000;      // ~40 ms key-down at 3.5 MHz
    localparam [15:0] SETTLE   = 16'd17500;       // ~5 ms gap after release

    reg [2:0]  st   = 3'd0;
    reg [1:0]  sel  = 2'd0;
    reg [17:0] tc   = 18'd0;
    reg [3:0]  pend = 4'd0;                        // latched pending press requests
    reg [3:0]  clr;                                // per-cycle "consume request" mask

    initial begin strb = 1'b0; make = 1'b1; code = 8'h00; end  // make=1 = released (idle)

    always @(posedge clock) if (ce) begin
        strb <= 1'b0;
        clr   = 4'b0000;
        case (st)
            3'd0: begin                            // idle: service one pending button
                if      (pend[0]) begin sel<=2'd0; clr[0]=1'b1; st<=3'd1; end
                else if (pend[1]) begin sel<=2'd1; clr[1]=1'b1; st<=3'd1; end
                else if (pend[2]) begin sel<=2'd2; clr[2]=1'b1; st<=3'd1; end
                else if (pend[3]) begin sel<=2'd3; clr[3]=1'b1; st<=3'd1; end
            end
            3'd1: begin strb<=1'b1; make<=1'b0; code<=codeOf(sel); tc<=TAP_HOLD;      st<=3'd2; end // make=0 = PRESS
            3'd2: if (tc==18'd0) st<=3'd3; else tc<=tc-1'b1;       // hold key down ~40 ms
            3'd3: begin strb<=1'b1; make<=1'b1; code<=codeOf(sel); tc<={2'b00,SETTLE}; st<=3'd4; end // make=1 = RELEASE
            3'd4: if (tc==18'd0) st<=3'd0; else tc<=tc-1'b1;       // settle, then idle
            default: st<=3'd0;
        endcase
        pend <= (pend | pedge) & ~clr;             // latch new edges, drop serviced
    end
endmodule
//-------------------------------------------------------------------------------------------------
