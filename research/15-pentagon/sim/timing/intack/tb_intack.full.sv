// tb_intack (клон прибора Потапова для НАШЕГО T80pa через cpu.v):
// сколько тактов от спада /INT до записи в порт первой командой обработчика (OUT (FE),A),
// в четырёх режимах ожидания (IM1/IM2 x слайд NOP / HALT) и по восьми фазам подачи /INT.
// Без ULA и контеншена: WAIT_n=1, память комбинационная. Настоящий Z80: IM1 13 T, IM2 19 T,
// HALT ничего не меняет; разброс по фазам 0..3 T, IM2-IM1 = 6.
module tb_intack;
  reg clk = 0; always #10 clk = ~clk;      // такт T = 2 мастер-такта (pe, ne)
  reg ph = 0;  always @(posedge clk) ph <= ~ph;
  wire pe = ~ph, ne = ph;
  reg reset_n = 0, irq_n = 1;
  wire rfsh, mreq, iorq, m1, rd, wr; wire [7:0] q; wire [15:0] a; reg [7:0] d;
  cpu dut(.clock(clk), .pe(pe), .ne(ne), .reset(reset_n), .rfsh(rfsh), .mreq(mreq), .iorq(iorq),
          .nmi(1'b1), .irq(irq_n), .m1(m1), .rd(rd), .wr(wr), .d(d), .q(q), .a(a),
          .dirset(1'b0), .dir(212'd0), .reg_out());
  reg [7:0] mem [0:65535];
  always @* d = mem[a];
  always @(posedge clk) if (!mreq && !wr) mem[a] <= q;
  wire io_write = ~iorq & ~wr;
  integer tcnt = 0; reg counting = 0;
  always @(posedge clk) if (counting && pe) tcnt = tcnt + 1;   // считаем T-состояния
  integer k;
  task build(input im2, input halted);
    begin
      for (k=0;k<65536;k=k+1) mem[k]=8'h00;
      mem[0]=8'hF3; mem[1]=8'h31; mem[2]=8'h00; mem[3]=8'hC0;   // DI; LD SP,C000
      mem[4]=8'h3E; mem[5]=8'h81; mem[6]=8'hED; mem[7]=8'h47;   // LD A,81; LD I,A
      mem[8]=8'hED; mem[9]= im2 ? 8'h5E : 8'h56;                // IM2 / IM1
      mem[10]=8'hFB;                                            // EI
      if (halted) mem[11]=8'h76;                                // HALT (иначе слайд NOP)
      for (k=16'h8100;k<=16'h8201;k=k+1) mem[k]=8'h81;          // вектор IM2 -> 8181
      mem[16'h0038]=8'hD3; mem[16'h0039]=8'hFE;                 // IM1: OUT (FE),A
      mem[16'h8181]=8'hD3; mem[16'h8182]=8'hFE;                 // IM2: OUT (FE),A
    end
  endtask
  integer res;
  task measure(input im2, input halted, input integer phase);
    begin
      build(im2, halted);
      reset_n=0; irq_n=1; counting=0; tcnt=0;
      repeat(16) @(posedge clk); reset_n=1;
      repeat(400) @(posedge clk);                 // дойти до EI и HALT/слайда
      repeat(phase*2) @(posedge clk);             // фаза подачи /INT: по 1 T
      @(posedge clk); counting=1; irq_n=0;
      fork
        begin repeat(140) @(posedge clk); irq_n=1; end
        begin @(posedge io_write); counting=0; res=tcnt; end
      join
    end
  endtask
  // ДИАГНОСТИКА: первые выборки команд и любые циклы ввода-вывода
  reg m1d=1; integer nm1=0;
  always @(posedge clk) begin
    m1d <= m1;
    if (!m1 && m1d && nm1 < 40) begin nm1=nm1+1; $display("    M1 #%0d a=%04h d=%02h irq_n=%b iff?", nm1, a, d, irq_n); end
    if (!iorq && !wr) $display("    IO WRITE a=%04h q=%02h at %0t", a, q, $time);
  end
  integer p; integer r[0:3];
  initial begin
    $display("ПРИЁМ ПРЕРЫВАНИЯ, тактов от спада /INT до OUT (FE),A обработчика");
    $display("фаза : IM1 слайд | IM1 HALT | IM2 слайд | IM2 HALT");
    for (p=0;p<8;p=p+1) begin
      measure(0,0,p); r[0]=res; measure(0,1,p); r[1]=res;
      measure(1,0,p); r[2]=res; measure(1,1,p); r[3]=res;
      $display("  %0d  :    %2d     |    %2d    |    %2d     |    %2d", p, r[0], r[1], r[2], r[3]);
    end
    $display("Z80: IM1 13+OUT, IM2 19+OUT; разброс по фазам ровно 0..3; IM2-IM1 = 6; HALT = слайд");
    $finish;
  end
  initial begin #20_000_000; $display("ТАЙМАУТ"); $finish; end
endmodule
