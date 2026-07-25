//-------------------------------------------------------------------------------------------------
// ps2.v - PS/2 keyboard decoder.
//
// Derived from the ZX Spectrum core by Sorgelig and contributors
// (sorgelig/ZX_Spectrum-128K_MIST; downstream AtlasFPGA/zx), licensed GPL-2.0-or-later.
// Modified for BulbuLator: a watchdog that resyncs the PS/2 bit counter (fixes fuzzy keys),
// and a `perr` parity/framing-error output that drives the fabric host-RESEND.
// Copyright (C) 2016-2019 Sorgelig; modifications Copyright (C) 2026 Alexander Lavrinovich.
//
// This program is free software: you can redistribute it and/or modify it under the terms of
// the GNU General Public License as published by the Free Software Foundation, either version 2
// of the License, or (at your option) any later version.
// SPDX-License-Identifier: GPL-2.0-or-later
//-------------------------------------------------------------------------------------------------
module ps2
//-------------------------------------------------------------------------------------------------
(
	input  wire      clock,
	input  wire      ce,
	input  wire      ps2Ck,
	input  wire      ps2D,
	output reg       strb,
	output reg       make,
	output reg [7:0] code,
	output reg       perr        // Step 15: 1-cycle pulse on a parity/framing error (a dropped byte) -> host RESEND
);
//-------------------------------------------------------------------------------------------------

reg      ps2c;
reg      ps2n;
reg      ps2d;
reg[7:0] ps2f;

always @(posedge clock) if(ce)
begin
	ps2n <= 1'b0;
	ps2d <= ps2D;
	ps2f <= { ps2Ck, ps2f[7:1] };

	if(ps2f == 8'hFF)
	begin
		ps2c <= 1'b1;
	end
	else if(ps2f == 8'h00)
	begin
		ps2c <= 1'b0;
		if(ps2c) ps2n <= 1'b1;
	end
end

//-------------------------------------------------------------------------------------------------

reg parity;

reg[8:0] data;
reg[3:0] count;
reg[10:0] wdt;   // inter-bit watchdog. A PS/2 frame never pauses more than ~100us between clock
                 // edges, so >400us of silence mid-frame means edges were lost (glitch/EMI/missed
                 // sample). Without this the bit counter stays out of phase for EVERY following
                 // byte until a stop bit + parity happen to line up again - keys turn "fuzzy"
                 // (lost makes/breaks). On timeout resync to idle and wait for a fresh start bit.

always @(posedge clock) if(ce)
begin
	strb <= 1'b0;
	perr <= 1'b0;
	if(count == 4'd0 || ps2n) wdt <= 11'd0;
	else                      wdt <= wdt + 11'd1;
	if(count != 4'd0 && wdt == 11'd1417)           // 1417 ce ticks @ 3.5417 MHz = 400 us
		count <= 4'd0;                              // dead frame -> idle (watchdog resync)
	else if(ps2n)
	begin
		if(count == 4'd0)
		begin
			parity <= 1'b0;
			if(!ps2d) count <= count+1'd1;
		end
		else
		begin
			if(count < 4'd10)
			begin
				data <= { ps2d, data[8:1] };
				count <= count+1'd1;
				parity <= parity ^ ps2d;
			end
			else if(ps2d)
			begin
				count <= 1'd0;
				if(parity)
				begin
					strb <= 1'b1;
					code <= data[7:0];
				end
				else perr <= 1'b1;
			end
			else begin count <= 1'd0; perr <= 1'b1; end
		end
	end
end

//-------------------------------------------------------------------------------------------------

always @(posedge clock) if(ce) if(strb) make <= code == 8'hF0;

//-------------------------------------------------------------------------------------------------
endmodule
//-------------------------------------------------------------------------------------------------
