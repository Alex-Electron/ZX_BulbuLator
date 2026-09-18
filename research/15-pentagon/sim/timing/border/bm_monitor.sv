//------------------------------------------------------------------------- МОНИТОР БОРДЮРА (border/)
// Добавлено в копии стенда для sim/timing/border. Все события фиксируются на posedge clock в ОДНОМ
// always-блоке, значения сигналов - те, что видны В АКТИВНОЙ ФАЗЕ этого фронта (до неблокирующих
// обновлений), то есть "значение, действовавшее в интервале до этого фронта".
//   BM INT   - первый фронт, на котором виден низкий dut.Video.irq (сырой /INT ULA)
//   BM CIRQ  - то же для dut.cpu_irq (то, что видит T80)
//   BM WR    - первый фронт, на котором видны iorq=0 & wr=0 & a[0]=0 (запись в окно #FE).
//              T_pc/T_pe = число фронтов с pc3M5/pe3M5 = 1 в полуинтервале [E_int, E_wr)
//              (шаг, который ВЫСТАВИЛ iorq&wr, входит; сам фронт E_wr - нет). hc/vc - координаты
//              пикселя, который НАЧАЛСЯ на том же фронте, что и запись (hc, видимый на E_wr).
//   BM WREND - первый фронт, где iorq&wr сняты.
//   BM LATCH - первый фронт, на котором виден новый dut.border (защёлка main.v на pe7M0).
//   BM PIX   - на фронте с ne7M0: старый цвет {i,r,g,b} отличается от предыдущего отсчёта ->
//              пиксель с колонкой hc (старое) строки vc (старое) первым несёт новый цвет.
//              px_since_wr = число фронтов ne7M0 в (E_wr, E_pix] (проверочная величина).
integer bm_on = 0;
integer bm_frame = 0;
integer bm_int_n = 0;
integer bm_t_pc = -1, bm_t_pe = -1, bm_px_int = -1;
integer bm_t_pc_c = -1, bm_t_pe_c = -1;
integer bm_px_wr = -1;
integer bm_wr_n = 0;
integer bm_wr_col = -1, bm_wr_line = -1;
integer bm_wr_tpc = -1;
reg bm_irq_p = 1'b1, bm_cirq_p = 1'b1, bm_iowr_p = 1'b0;
reg [2:0] bm_border_p = 3'd7;
reg [3:0] bm_rgbi_p = 4'd0;
wire [3:0] bm_rgbi = {i, r, g, b};
wire bm_iowr = ~dut.iorq & ~dut.wr & ~dut.a[0];

initial if ($value$plusargs("BMON=%d", bm_on)) ;

always @(posedge clock) if (bm_on && reset_n) begin
	// 1) спад /INT: обнулить счётчики (фронт E_int входит в счёт ниже)
	if (bm_irq_p && !dut.Video.irq) begin
		bm_int_n = bm_int_n + 1; bm_t_pc = 0; bm_t_pe = 0; bm_px_int = 0; bm_wr_n = 0;
		$display("BM INT n=%0d frame=%0d line=%0d hc=%0d hCount=%0d vCount=%0d ce=%0d pc3M5=%b m1=%b halt_pc=%04h",
			bm_int_n, bm_frame, dut.Video.vc, dut.Video.hc, dut.Video.hCount, dut.Video.vCount, ce, dut.pc3M5, dut.m1, dut.a);
	end
	bm_irq_p = dut.Video.irq;
	if (bm_cirq_p && !dut.cpu_irq) begin
		bm_t_pc_c = 0; bm_t_pe_c = 0;
		$display("BM CIRQ frame=%0d line=%0d hc=%0d ce=%0d T_pc_since_int=%0d T_pe_since_int=%0d", bm_frame, dut.Video.vc, dut.Video.hc, ce, bm_t_pc, bm_t_pe);
	end
	bm_cirq_p = dut.cpu_irq;
	// 2) пиксель (ne7M0): старый цвет / старые координаты
	if (ne7M0) begin
		if (dut.Video.hc == 9'd0 && dut.Video.vc == 9'd0) bm_frame = bm_frame + 1;
		if (bm_px_wr >= 0) bm_px_wr = bm_px_wr + 1;
		if (bm_px_int >= 0) bm_px_int = bm_px_int + 1;
		if (bm_rgbi !== bm_rgbi_p) begin
			$display("BM PIX frame=%0d line=%0d col=%0d colour=%0d->%0d px_since_wr=%0d wr_col=%0d wr_line=%0d wr_tpc=%0d T_pc_since_int=%0d px_since_int=%0d",
				bm_frame, dut.Video.vc, dut.Video.hc, bm_rgbi_p, bm_rgbi, bm_px_wr, bm_wr_col, bm_wr_line, bm_wr_tpc, bm_t_pc, bm_px_int);
			bm_rgbi_p = bm_rgbi;
		end
	end
	// 3) защёлка border (main.v, pe7M0)
	if (dut.border !== bm_border_p) begin
		$display("BM LATCH frame=%0d line=%0d hc=%0d ce=%0d border=%0d->%0d T_pc_since_int=%0d T_pe_since_int=%0d px_since_wr=%0d",
			bm_frame, dut.Video.vc, dut.Video.hc, ce, bm_border_p, dut.border, bm_t_pc, bm_t_pe, bm_px_wr);
		bm_border_p = dut.border;
	end
	// 4) запись в #FE (до счёта T на этом фронте -> полуинтервал [E_int, E_wr))
	if (bm_iowr && !bm_iowr_p) begin
		bm_wr_n = bm_wr_n + 1;
		bm_px_wr = 0; bm_wr_col = dut.Video.hc; bm_wr_line = dut.Video.vc; bm_wr_tpc = bm_t_pc;
		$display("BM WR int=%0d wr=%0d frame=%0d line=%0d hc=%0d hCount=%0d ce=%0d q=%02h a=%04h T_pc=%0d T_pe=%0d px=%0d T_pc_c=%0d T_pe_c=%0d contend=%b cn=%b cpuck=%b",
			bm_int_n, bm_wr_n, bm_frame, dut.Video.vc, dut.Video.hc, dut.Video.hCount, ce, dut.q, dut.a,
			bm_t_pc, bm_t_pe, bm_px_int, bm_t_pc_c, bm_t_pe_c, dut.contend, dut.vduC, dut.cpuck);
	end
	if (!bm_iowr && bm_iowr_p)
		$display("BM WREND int=%0d wr=%0d line=%0d hc=%0d ce=%0d T_pc=%0d T_pe=%0d px_since_wr=%0d",
			bm_int_n, bm_wr_n, dut.Video.vc, dut.Video.hc, ce, bm_t_pc, bm_t_pe, bm_px_wr);
	bm_iowr_p = bm_iowr;
	// 5) счёт T
	if (dut.pc3M5 === 1'b1) begin
		if (bm_t_pc >= 0) bm_t_pc = bm_t_pc + 1;
		if (bm_t_pc_c >= 0) bm_t_pc_c = bm_t_pc_c + 1;
	end
	if (pe3M5) begin
		if (bm_t_pe >= 0) bm_t_pe = bm_t_pe + 1;
		if (bm_t_pe_c >= 0) bm_t_pe_c = bm_t_pe_c + 1;
	end
end
