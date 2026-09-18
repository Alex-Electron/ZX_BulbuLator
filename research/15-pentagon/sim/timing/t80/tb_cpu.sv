// tb_cpu - стенд процессора BulbuLator: модуль cpu (обёртка T80pa) с набором VHDL сборки
// (T80_Pack/T80_Reg/T80_MCode/T80_ALU/T80pa + форк t80_bulb/T80.vhd).
//
// Тактование как в машине (sources/clock_zx.v, ветка "normal"): мастер 56.667 МГц, счётчик ce
// на negedge, разрешения регистрируются на negedge:
//   ce==0 : ne3M5 + ne7M0      ce==4 : pe7M0
//   ce==8 : pe3M5 + ne7M0      ce==12: pe7M0
// contend=1, cpu_hold=0 -> pe = pe3M5, ne = ne3M5.
//
// Единица "такт Z80" = один импульс pe3M5 (posedge clock при pe3M5=1). T-состояние начинается на
// pe и его середина - следующий ne (через 8 мастер-тактов).
//
// Все наблюдения делаются на NEGEDGE clock: там уже видны выходы процессора после posedge,
// а разрешения ещё показывают значение, которое действовало на этом posedge.

`timescale 1ns/1ps

module tb_cpu;

    // ---------------------------------------------------------------- такты
    reg clock = 1'b0;
    always #8.8235 clock = ~clock;            // 17.647 нс = 56.667 МГц

    reg [3:0] ce = 4'd1;
    reg pe7M0 = 0, ne7M0 = 0, pe3M5 = 0, ne3M5 = 0;
    always @(negedge clock) begin
        ce    <= ce + 1'd1;
        pe7M0 <= ~ce[0] & ~ce[1] &  ce[2];
        ne7M0 <= ~ce[0] & ~ce[1] & ~ce[2];
        pe3M5 <= ~ce[0] & ~ce[1] & ~ce[2] &  ce[3];
        ne3M5 <= ~ce[0] & ~ce[1] & ~ce[2] & ~ce[3];
    end

    // ---------------------------------------------------------------- процессор
    reg reset_n = 1'b0;
    reg irq_n   = 1'b1;
    reg nmi_n   = 1'b1;
    wire rfsh, mreq, iorq, m1, rd, wr;
    wire [15:0] a;
    wire [7:0]  q;
    reg  [7:0]  d;
    wire [211:0] reg_out;

    cpu dut (
        .clock(clock), .pe(pe3M5), .ne(ne3M5), .reset(reset_n),
        .rfsh(rfsh), .mreq(mreq), .iorq(iorq), .nmi(nmi_n), .irq(irq_n),
        .m1(m1), .rd(rd), .wr(wr), .d(d), .q(q), .a(a),
        .dirset(1'b0), .dir(212'd0), .reg_out(reg_out)
    );

    // ---------------------------------------------------------------- память и порты
    reg [7:0] mem [0:65535];
    reg [7:0] port_in   = 8'hBF;   // байт, который отдаёт любой IN (режим 0)
    reg       port_mode = 1'b0;    // 1 = IN отдаёт счётчик мастер-тактов (кто защёлкнул - видно по A)
    reg [7:0] buscnt    = 8'd0;
    always @(negedge clock) buscnt <= buscnt + 1'd1;   // меняется вместе с разрешениями, стабилен на posedge
    reg [7:0] vec = 8'h00;         // байт вектора в цикле подтверждения INT (M1 & IORQ)

    always @* begin
        if (!iorq && !m1)      d = vec;
        else if (!iorq)        d = port_mode ? buscnt : port_in;
        else                   d = mem[a];
    end

    // запись в память: как её увидела бы простая SRAM - по posedge при активном MREQ&WR
    always @(posedge clock) if (reset_n && !mreq && !wr) mem[a] <= q;

    // ---------------------------------------------------------------- наблюдатели
    integer tcnt = 0;          // счётчик импульсов pe3M5 = T-состояний
    integer mcyc = 0;          // счётчик мастер-тактов
    reg     m1_prev = 1'b1;
    reg     wr_prev = 1'b1, mreq_prev = 1'b1, iorq_prev = 1'b1, rd_prev = 1'b1;
    integer m1_tcnt = 0;       // tcnt на последнем спаде M1
    integer m1_prev_tcnt = 0;
    reg [15:0] m1_addr = 16'h0;
    integer m1_num = 0;
    integer ack_tcnt = -1;     // tcnt спада M1 того цикла, где M1&IORQ были активны вместе (подтверждение INT)
    reg     m1_isack = 1'b0;
    reg trace_en = 1'b0;
    reg m1log_en = 1'b0;
    reg outlog_en = 1'b0;
    event ev_m1;
    event ev_outfe;

    // OUT-лог: защёлкивание порта - на posedge при IORQ&WR, как это делает ULA/бордюр на pe7M0
    reg [7:0] outval [0:255];
    integer i0;
    initial for (i0 = 0; i0 < 256; i0 = i0 + 1) outval[i0] = 8'hxx;
    always @(posedge clock) if (reset_n && !iorq && !wr && m1) begin
        outval[a[7:0]] <= q;
    end

`ifdef HIER
    wire [2:0] h_mc = dut.Cpu.MCycle;
    wire [2:0] h_ts = dut.Cpu.TState;
`else
    wire [2:0] h_mc = 3'bxxx;
    wire [2:0] h_ts = 3'bxxx;
`endif

    always @(negedge clock) begin
        mcyc = mcyc + 1;
        if (pe3M5) tcnt = tcnt + 1;
        if (trace_en && (pe3M5 || ne3M5))
            $display("  %s t=%0d mc=%0d ce=%0d MC=%0d TS=%0d m1=%b mreq=%b iorq=%b rd=%b wr=%b rfsh=%b a=%04h d=%02h q=%02h",
                     pe3M5 ? "pe" : "ne", tcnt, mcyc, ce, h_mc, h_ts, m1, mreq, iorq, rd, wr, rfsh, a, d, q);
        if (trace_en && !(pe3M5 || ne3M5) &&
            (wr != wr_prev || mreq != mreq_prev || iorq != iorq_prev || rd != rd_prev))
            $display("  !! смена шинных сигналов ВНЕ pe/ne: mc=%0d ce=%0d mreq=%b iorq=%b rd=%b wr=%b", mcyc, ce, mreq, iorq, rd, wr);
        // бордюр в main.v защёлкивается на pe7M0 при !ioFE && !wr: отметить каждый такой posedge
        if (trace_en && pe7M0 && !iorq && !wr && m1)
            $display("  ** pe7M0 with IORQ&WR active: t=%0d mc=%0d ce=%0d a=%04h q=%02h  (border/OUT latch point in main.v)", tcnt, mcyc, ce, a, q);
        wr_prev = wr; mreq_prev = mreq; iorq_prev = iorq; rd_prev = rd;
        if (m1_prev && !m1) begin
            m1_num = m1_num + 1;
            m1_prev_tcnt = m1_tcnt;
            m1_tcnt = tcnt;
            m1_addr = a;
            if (m1log_en)
                $display("  M1 #%0d a=%04h op=%02h t=%0d dT=%0d %s", m1_num, a, mem[a], tcnt, tcnt - m1_prev_tcnt,
                         pe3M5 ? "" : "(M1 fell NOT on pe!)");
            -> ev_m1;
        end
        m1_prev = m1;
        if (!m1 && !iorq && !m1_isack) begin m1_isack = 1'b1; ack_tcnt = m1_tcnt; end
        if (m1) m1_isack = 1'b0;
    end

    // момент защёлкивания DI в T80pa (DI_Reg) - только с иерархическим доступом
`ifdef HIER
    reg di_mon = 1'b0;
    always @(dut.Cpu.DI_Reg) if (di_mon)
        $display("  DI_Reg <= %02h  (t=%0d mc=%0d ce=%0d pe=%b ne=%b MC=%0d TS=%0d iorq=%b mreq=%b rd=%b)",
                 dut.Cpu.DI_Reg, tcnt, mcyc + 1, ce, pe3M5, ne3M5, h_mc, h_ts, iorq, mreq, rd);
`endif

    // ---------------------------------------------------------------- служебные задачи
    task load(input string f);
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
            $readmemh(f, mem);
        end
    endtask

    task do_reset;
        begin
            reset_n = 1'b0; irq_n = 1'b1; nmi_n = 1'b1;
            repeat (64) @(negedge clock);
            @(negedge clock);
            reset_n = 1'b1;
            m1_prev = 1'b1; m1_num = 0;
        end
    endtask

    // ждать спада M1 по адресу addr (n-й по счёту); сторож - 3000 спадов M1
    task wait_m1(input [15:0] addr, input integer n);
        integer k;
        begin
            k = 0;
            while (k < n) begin
                @(ev_m1);
                if (m1_addr == addr) k = k + 1;
                if (m1_num > 3000) begin $display("  !! wait_m1(%04h) не дождался", addr); k = n; end
            end
        end
    endtask

    // ждать n-го спада M1 от сброса
    task wait_m1num(input integer n);
        begin
            while (m1_num < n) @(ev_m1);
        end
    endtask

    // ================================================================ ТЕСТ 1: Q-флаг
    task test_qflag;
        begin
            $display("");
            $display("=== ТЕСТ 1: Q-флаг, SCF/CCF (prog_qflag) ===");
            load("prog_qflag.hex");
            port_mode = 0;
            do_reset();
            wait_m1(16'h0000 + 16'd0, 1); // первый M1
            // ждём HALT: адрес halt = последний байт программы; ищем опкод 76
            begin : wq
                forever begin
                    @(ev_m1);
                    if (mem[m1_addr] == 8'h76) disable wq;
                end
            end
            repeat (200) @(negedge clock);
            $display("  case A  F=$28 A=$00, POP AF, SCF : F=$%02h   (Zilog $29, XY-из-A $01)", outval[1]);
            $display("  case B  F=$00 A=$28, POP AF, SCF : F=$%02h   (Zilog $29, XY-из-A $29)", outval[2]);
            $display("  case C0 A=0 B=$28, CP B           : F=$%02h   (Zilog $BB: S H X Y N C, XY от операнда)", outval[4]);
            $display("  case C  A=0 B=$28, CP B, SCF      : F=$%02h   (Zilog $81, F|A-без-Q $A9, XY-из-A $81)", outval[3]);
            $display("  case A' F=$28 A=$00, POP AF, CCF : F=$%02h   (Zilog $29, XY-из-A $01)", outval[5]);
            $display("  case B' F=$00 A=$28, POP AF, CCF : F=$%02h   (Zilog $29, XY-из-A $29)", outval[6]);
            $display("  case D  F=$29 A=$00, POP AF, CCF : F=$%02h   (Zilog $38, XY-из-A $10)", outval[7]);
            // (строка вердикта - ASCII: xsim портит не-ASCII байты в %s)
            $display("  Verdict by tb_qflag criterion (A and B both $29 = Zilog): %s",
                     (outval[1] == 8'h29 && outval[2] == 8'h29) ? "ZILOG" :
                     (outval[1] == 8'h01 && outval[2] == 8'h29) ? "NOT Zilog: XY taken from A only (NEC-like)" : "NOT Zilog (other)");
        end
    endtask

    // ================================================================ ТЕСТ 2: приём прерывания
    // Возвращает стоимость приёма = (t спада M1 обработчика) - (t спада M1 последней команды) - 4.
    // m_off = через сколько мастер-тактов после спада M1 опорной команды опустить линию.
    task test_int(input string name, input bit im2, input bit halted, input bit use_nmi, input integer m_off,
                  output integer cost, output integer fetches_between);
        integer t_ref, t_h, n_between, k;
        integer lt [0:7];
        reg [15:0] la [0:7];
        reg [7:0] lo [0:7];
        reg [15:0] hnd;
        begin
            load("prog_int.hex");
            if (im2)    mem[16'h0009] = 8'h5E;
            if (halted) mem[16'h000B] = 8'h76;
            hnd = use_nmi ? 16'h0066 : (im2 ? 16'h9000 : 16'h0038);
            vec = 8'h00;
            do_reset();
            // di, ld sp, ld a, ld i,a(2 M1), im(2 M1), ei, halt = 9 спадов M1; 12-й = 3-я итерация под HALT
            if (halted) wait_m1num(12);
            else        wait_m1(16'h0014, 1);
            t_ref = m1_tcnt;
            repeat (m_off) @(negedge clock);
            if (use_nmi) nmi_n = 1'b0; else irq_n = 1'b0;
            ack_tcnt = -1;
            n_between = 0;
            begin : wh
                forever begin
                    @(ev_m1);
                    if (n_between < 8) begin lt[n_between] = m1_tcnt; la[n_between] = m1_addr; lo[n_between] = mem[m1_addr]; end
                    n_between = n_between + 1;
                    if (m1_addr == hnd) disable wh;
                    if (m1_num > 400) begin $display("  %s: handler NOT reached", name); disable wh; end
                end
            end
            t_h = m1_tcnt;
            // ещё 4 T, чтобы детектор подтверждения (M1&IORQ) успел отметить цикл; потом отпускаем линию
            repeat (16*4) @(negedge clock);
            irq_n = 1'b1; nmi_n = 1'b1;
            fetches_between = n_between - 1;
            cost = use_nmi ? (t_h - lt[n_between-2]) : (t_h - ack_tcnt);
            $write("  %-14s off=%0d: ref M1 t=%0d(%04h)", name, m_off, t_ref, halted ? 16'h000C : 16'h0014);
            for (k = 0; k < n_between && k < 8; k = k + 1)
                $write(" -> M1 t=%0d a=%04h%s", lt[k], la[k], (lt[k] == ack_tcnt) ? "(INTACK)" : (la[k] == hnd) ? "(HANDLER)" : "");
            $write("\n");
            $display("  %-14s off=%0d: from ref M1 to handler M1 = %0d T; M1 between = %0d; cost (last M1 before handler -> handler M1) = %0d T; ack M1 t=%0d",
                     name, m_off, t_h - t_ref, fetches_between, cost, ack_tcnt);
            // ждём остановки обработчика на jr $ - не нужно, следующий тест делает сброс
            repeat (16*8) @(negedge clock);
        end
    endtask

    // ================================================================ ТЕСТ 3/4: трасса шины
    task test_bus;
        begin
            $display("");
            $display("=== ТЕСТ 3/4: трасса шинных циклов (prog_bus); IN отдаёт счётчик мастер-тактов mc (d) ===");
            $display("  Колонки: pe/ne = какое разрешение стояло на этом posedge; t = номер T (pe-импульса); mc = мастер-такт; ce = счётчик clock_zx");
            load("prog_bus.hex");
            port_mode = 1;
            do_reset();
            wait_m1(16'h0009, 1);
            trace_en = 1; m1log_en = 1;
`ifdef HIER
            di_mon = 1;
`endif
            wait_m1(16'h0020, 1);
            repeat (16*10) @(negedge clock);
            trace_en = 0; m1log_en = 0;
`ifdef HIER
            di_mon = 0;
`endif
            $display("  IN A,($FE) защёлкнул байт $%02h (=mc того posedge, на котором взят d)", mem[16'h4001]);
            $display("  IN A,(C)   защёлкнул байт $%02h", mem[16'h4002]);
            $display("  mem[$4000]=%02h (LD (HL),A) mem[$4003]=%02h (LD (nn),A)", mem[16'h4000], mem[16'h4003]);
            port_mode = 0;
        end
    endtask

    // ================================================================ ТЕСТ 5: длительности
    task test_dur;
        integer k;
        begin
            $display("");
            $display("=== ТЕСТ 5: длительности команд (prog_dur): лог спадов M1, dT = T от предыдущего спада M1 ===");
            load("prog_dur.hex");
            do_reset();
            m1log_en = 1;
            // под HALT адрес M1 = PC+1 (байт ПОСЛЕ HALT), поэтому конец - по числу спадов M1:
            // программа даёт ~45 спадов, остальное - итерации HALT
            begin : wd
                forever begin
                    @(ev_m1);
                    if (m1_num >= 56) disable wd;
                end
            end
            m1log_en = 0;
        end
    endtask

    // ================================================================ главный сценарий
    integer cost, nb, m;
    initial begin
        $timeformat(-9, 2, " ns", 10);
        $display("tb_cpu: мастер %0.3f МГц, T = 16 мастер-тактов", 1000.0/17.647);

        test_qflag();

        $display("");
        $display("=== ТЕСТ 2: стоимость приёма прерывания (от спада M1 обработчика назад до конца опорной команды) ===");
        test_int("IM1/NOP-slide", 0, 0, 0, 0, cost, nb);
        test_int("IM1/HALT",      0, 1, 0, 0, cost, nb);
        test_int("IM2/NOP-slide", 1, 0, 0, 0, cost, nb);
        test_int("IM2/HALT",      1, 1, 0, 0, cost, nb);
        test_int("NMI/NOP-slide", 0, 0, 1, 0, cost, nb);
        test_int("NMI/HALT",      0, 1, 1, 0, cost, nb);

        $display("");
        $display("=== ТЕСТ 2б: фаза выборки INT. Опорный NOP по $0014: спад M1 на posedge #0 (pe, начало T1);");
        $display("    posedge #16=pe T2, #32=pe T3, #48=pe T4, #64=pe конца T4 (=T1 следующей). Линия опускается на negedge после posedge #off.");
        $display("    Результат 'M1 между'=0 -> принято ПО ЭТОМУ NOP; 1 -> по следующему.");
        for (m = 44; m <= 66; m = m + 1) begin
            if (m == 44 || m == 47 || m == 48 || m == 55 || m == 56 || m == 60 || m == 62 || m == 63 || m == 64 || m == 65 || m == 66)
                test_int("IM1 phase", 0, 0, 0, m, cost, nb);
        end
        $display("    То же для NMI:");
        for (m = 60; m <= 66; m = m + 1) begin
            if (m == 60 || m == 62 || m == 63 || m == 64 || m == 65 || m == 66)
                test_int("NMI phase", 0, 0, 1, m, cost, nb);
        end

        test_bus();
        test_dur();

        $display("");
        $display("tb_cpu: готово");
        $finish;
    end
endmodule
