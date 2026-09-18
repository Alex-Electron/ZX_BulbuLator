// tb_geo2 - raster geometry of ep4spectrum's video.v, read out in counts
//
// Companion to Sergey Potapov's tb_intgeo.v: the same module, the same
// clocking (28 MHz CLK, CLKEN every other edge = 14 MHz, hcounter steps
// once per CLKEN, 4 steps per CPU T-state at 3.5 MHz, 2 steps per pixel),
// no CPU. Everything is counted in CLKEN ticks ("counts").
//
// Sampling convention: state is read on the NEGEDGE of CLK that follows
// an enabled posedge (clken was 1 on that posedge, so it reads 0 now), i.e.
// after the registers have taken their new value. "hcounter" in a printed
// position is the value the counter shows AFTER that edge.
//
// Measured, on the second frame after reset:
//   line     : counts between successive hcounter==0
//   frame    : counts between successive nIRQ falling edges
//   irq width: counts nIRQ stays low
//   irq pos  : (line, hcounter) when nIRQ is first seen low
//   pic pos  : (line, hcounter) when picture first rises in the frame
//   INT->pic : counts from nIRQ fall to picture rise (tb_intgeo's figure)
//   INT->cont: counts from nIRQ fall to first CONTENTION=1 in the frame
//   line 100 : hcounter where picture rises/falls, CONTENTION first/last,
//              CONTENTION_IO first/last, PORT_FF_ACTIVE first,
//              hblanking/hsync edges (all as hcounter after the edge)
//   vsync    : lines where vsync rises and falls
// Plusarg: MACHINE=0..3

`timescale 1ns / 1ps

module tb_geo2;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	integer     v;
	initial if ($value$plusargs("MACHINE=%d", v)) machine = v[1:0];

	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire nirq, cont, cont_io, ffact;

	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(cont), .CONTENTION_IO(cont_io),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(ffact), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd0),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(), .nIRQ(nirq)
	);

	// sample after each enabled edge
	wire tick = (clken == 1'b0);
	integer t = 0;                 // running count of enabled edges since reset release

	reg  prev_nirq = 1'b1, prev_pic = 1'b0, prev_cont = 1'b0, prev_cio = 1'b0;
	reg  prev_ff = 1'b0, prev_hbl = 1'b0, prev_hs = 1'b0, prev_vs = 1'b0;
	reg  [9:0] prev_hc = 10'd0;
	integer irq_falls = 0;
	integer t_irq_fall = -1, t_irq_rise = -1, t_line0 = -1, t_pic = -1, t_cont = -1;
	integer line_len = -1, frame_len = -1, irq_w = -1, int2pic = -1, int2cont = -1;
	integer irq_line = -1, irq_hc = -1, pic_line = -1, pic_hc = -1, cont_line = -1, cont_hc = -1;
	integer l100_pic_on = -1, l100_pic_off = -1, l100_cont_on = -1, l100_cont_off = -1;
	integer l100_cio_on = -1, l100_cio_off = -1, l100_ff_on = -1;
	integer l100_hbl_on = -1, l100_hbl_off = -1, l100_hs_on = -1, l100_hs_off = -1;
	integer vs_on_line = -1, vs_off_line = -1;
	integer pic_lines_first = -1, pic_lines_last = -1;
	reg measuring = 1'b0;   // set at the 2nd nIRQ fall, cleared at the 3rd
	reg pic_seen = 1'b0, cont_seen = 1'b0;
	integer cont_lead_l100;
	integer vl;

	always @(negedge clk) if (nreset && tick) begin
		t = t + 1;
		// line length: hcounter wrapped to 0
		if (vid.hcounter == 10'd0 && prev_hc != 10'd0) begin
			if (t_line0 >= 0 && line_len < 0 && measuring) line_len = t - t_line0;
			t_line0 = t;
		end
		// nIRQ falling
		if (prev_nirq == 1'b1 && nirq == 1'b0) begin
			irq_falls = irq_falls + 1;
			if (irq_falls == 2) begin
				measuring = 1'b1;
				t_irq_fall = t;
				irq_line = vid.vcounter[9:1];
				irq_hc   = vid.hcounter;
				pic_seen = 1'b0; cont_seen = 1'b0;
			end else if (irq_falls == 3) begin
				frame_len = t - t_irq_fall;
				measuring = 1'b0;
				cont_lead_l100 = l100_pic_on - l100_cont_on;
				$display("MACHINE %0d", machine);
				$display("  line length            : %0d counts (%0d T at 4 counts/T)", line_len, line_len / 4);
				$display("  frame length (INT->INT): %0d counts (%0d T)", frame_len, frame_len / 4);
				$display("  nIRQ low width         : %0d counts (%0d T)", irq_w, irq_w / 4);
				$display("  nIRQ fall seen at      : line %0d, hcounter %0d (value after the edge)", irq_line, irq_hc);
				$display("  first picture at       : line %0d, hcounter %0d", pic_line, pic_hc);
				$display("  INT fall -> picture    : %0d counts = %0d T + %0d counts", int2pic, int2pic / 4, int2pic % 4);
				$display("  INT fall -> CONTENTION : %0d counts = %0d T + %0d counts (first at line %0d, hcounter %0d)",
					int2cont, int2cont / 4, int2cont % 4, cont_line, cont_hc);
				$display("  picture lines          : %0d..%0d", pic_lines_first, pic_lines_last);
				$display("  line 100: picture on/off hcounter      %0d / %0d", l100_pic_on, l100_pic_off);
				$display("  line 100: CONTENTION first/last hc     %0d / %0d  (lead vs picture: %0d counts = %0d T)",
					l100_cont_on, l100_cont_off, cont_lead_l100, cont_lead_l100 / 4);
				$display("  line 100: CONTENTION_IO first/last hc  %0d / %0d", l100_cio_on, l100_cio_off);
				$display("  line 100: PORT_FF_ACTIVE first hc      %0d", l100_ff_on);
				$display("  line 100: hblanking on/off hc          %0d / %0d", l100_hbl_on, l100_hbl_off);
				$display("  line 100: hsync on/off hc              %0d / %0d", l100_hs_on, l100_hs_off);
				$display("  vsync on/off at lines                  %0d / %0d", vs_on_line, vs_off_line);
				$display("DONE");
				$finish;
			end
		end
		if (prev_nirq == 1'b0 && nirq == 1'b1 && measuring && irq_w < 0)
			irq_w = t - t_irq_fall;
		// picture
		if (measuring && prev_pic == 1'b0 && vid.picture == 1'b1) begin
			if (!pic_seen) begin
				pic_seen = 1'b1;
				int2pic = t - t_irq_fall;
				pic_line = vid.vcounter[9:1];
				pic_hc   = vid.hcounter;
			end
			vl = vid.vcounter[9:1];
			if (pic_lines_first < 0 || vl < pic_lines_first) pic_lines_first = vl;
			if (vl > pic_lines_last) pic_lines_last = vl;
			if (vid.vcounter[9:1] == 9'd100) l100_pic_on = vid.hcounter;
		end
		if (measuring && prev_pic == 1'b1 && vid.picture == 1'b0 && vid.vcounter[9:1] == 9'd100)
			l100_pic_off = vid.hcounter;
		// contention
		if (measuring && prev_cont == 1'b0 && cont == 1'b1) begin
			if (!cont_seen) begin
				cont_seen = 1'b1;
				int2cont = t - t_irq_fall;
				cont_line = vid.vcounter[9:1];
				cont_hc   = vid.hcounter;
			end
			if (vid.vcounter[9:1] == 9'd100 && l100_cont_on < 0) l100_cont_on = vid.hcounter;
		end
		if (measuring && prev_cont == 1'b1 && cont == 1'b0 && vid.vcounter[9:1] == 9'd100)
			l100_cont_off = vid.hcounter - 1;
		if (measuring && prev_cio == 1'b0 && cont_io == 1'b1 && vid.vcounter[9:1] == 9'd100 && l100_cio_on < 0)
			l100_cio_on = vid.hcounter;
		if (measuring && prev_cio == 1'b1 && cont_io == 1'b0 && vid.vcounter[9:1] == 9'd100)
			l100_cio_off = vid.hcounter - 1;
		if (measuring && prev_ff == 1'b0 && ffact == 1'b1 && vid.vcounter[9:1] == 9'd100 && l100_ff_on < 0)
			l100_ff_on = vid.hcounter;
		if (measuring && vid.vcounter[9:1] == 9'd100) begin
			if (prev_hbl == 1'b0 && vid.hblanking == 1'b1) l100_hbl_on = vid.hcounter;
			if (prev_hbl == 1'b1 && vid.hblanking == 1'b0) l100_hbl_off = vid.hcounter;
			if (prev_hs == 1'b0 && vid.hsync == 1'b1) l100_hs_on = vid.hcounter;
			if (prev_hs == 1'b1 && vid.hsync == 1'b0) l100_hs_off = vid.hcounter;
		end
		if (measuring && prev_vs == 1'b0 && vid.vsync == 1'b1) vs_on_line = vid.vcounter[9:1];
		if (measuring && prev_vs == 1'b1 && vid.vsync == 1'b0) vs_off_line = vid.vcounter[9:1];

		prev_nirq = nirq; prev_pic = vid.picture; prev_cont = cont; prev_cio = cont_io;
		prev_ff = ffact; prev_hbl = vid.hblanking; prev_hs = vid.hsync; prev_vs = vid.vsync;
		prev_hc = vid.hcounter;
	end

	initial begin
		nreset = 1'b0;
		repeat (40) @(posedge clk);
		nreset = 1'b1;
	end

	initial begin
		#120_000_000;
		$display("TIMED OUT");
		$finish;
	end
endmodule
