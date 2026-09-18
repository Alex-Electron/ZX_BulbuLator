`timescale 1ns/1ps
//------------------------------------------------------------------------------
// tape_bram_fifo.v -- tape-only dual-clock FIFO backed by true block RAM.
//
// The generic async_fifo uses LUTRAM and asynchronous FWFT reads.  That is an
// excellent small FIFO, but the 1024-descriptor tape FIFO has too little burst
// reserve for quantised MP3 at FAST8.  Here the payload lives in a true dual
// port BRAM: ARM/AXI writes at fclk100; the tape player consumes from a small
// read-domain prefetch queue at spclk.  Only Gray pointers cross clock domains.
//
// `rbin` is deliberately advanced when the player actually consumes a
// descriptor, not when it is prefetched.  Thus the write side can never
// overwrite a descriptor held in the BRAM-read pipeline or the local queue.
//------------------------------------------------------------------------------
module tape_bram_fifo #(
    parameter integer DW = 32,
    // 🥇 B0123 ДВЕ ПЛИТКИ ВМЕСТО ЧЕТЫРЁХ. Блочная память была перебрана РОВНО на полплитки
    // («BRAM overutilized. Used = 121, Available = 120» в логе синтеза), и синтезатор молча выдавил
    // девять буферов оболочки в распределённую память - 2526 LUT, каждый шестой на кристалле.
    // Освобождаем здесь: исторически МАЛО было 1024 дескриптора (шапка файла выше), 2048 - вдвое
    // больше проверенно недостаточного. Приёмка обязательна: матрица MP3/WAV на 8x со счётчиком
    // голодания ДО и ПОСЛЕ, иначе вернуть 12.
    parameter integer AW = 11,       // 2048 descriptors = 8 KiB = two RAMB36
    parameter integer QAW = 2        // four prefetched descriptors in rd_clk domain
)(
    input  wire          wr_clk,
    input  wire          wr_rst_n,
    input  wire          wr_en,
    input  wire [DW-1:0] din,
    output wire          full,

    input  wire          rd_clk,
    input  wire          rd_rst_n,
    input  wire          rd_en,       // consume the current FWFT descriptor
    output wire [DW-1:0] dout,
    output wire          empty
);
    localparam integer QDEPTH = (1 << QAW);

    // Explicit synchronous-read BRAM.  A raw `ram_style=block` replacement for
    // async_fifo would be wrong because BRAM has no asynchronous FWFT port;
    // the four-entry queue below restores FWFT semantics to tape_player.
    (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    // Declared before the write-side synchronizer because `rgray` crosses
    // into that domain.  Keeping this at the module declaration point avoids
    // an implicit-net/late-declaration ambiguity on the 13-bit CDC bus.
    reg [AW:0] rbin = {AW+1{1'b0}}, rgray = {AW+1{1'b0}};
    reg [AW:0] fbin = {AW+1{1'b0}};

    // ---- write domain: standard Cummings full calculation ------------------
    reg [AW:0] wbin = {AW+1{1'b0}}, wgray = {AW+1{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [AW:0] rgray_w1 = {AW+1{1'b0}}, rgray_w2 = {AW+1{1'b0}};
    reg full_r = 1'b0;
    wire wr_do = wr_en & ~full_r;
    wire [AW:0] wbin_next  = wbin + wr_do;
    wire [AW:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire full_next = (wgray_next == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign full = full_r;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin <= {AW+1{1'b0}}; wgray <= {AW+1{1'b0}}; full_r <= 1'b0;
            rgray_w1 <= {AW+1{1'b0}}; rgray_w2 <= {AW+1{1'b0}};
        end else begin
            wbin <= wbin_next; wgray <= wgray_next; full_r <= full_next;
            rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
        end
    end
    always @(posedge wr_clk) if (wr_do) mem[wbin[AW-1:0]] <= din;

    // ---- read domain ---------------------------------------------------------
    // rbin/rgray = descriptors actually handed to tape_player.  fbin is a
    // private look-ahead address and therefore never participates in full.
    (* ASYNC_REG = "TRUE" *) reg [AW:0] wgray_r1 = {AW+1{1'b0}}, wgray_r2 = {AW+1{1'b0}};
    reg [AW:0] wbin_r;
    integer k;
    always @(*) begin
        wbin_r[AW] = wgray_r2[AW];
        for (k=AW-1; k>=0; k=k-1) wbin_r[k] = wbin_r[k+1] ^ wgray_r2[k];
    end

    reg [DW-1:0] qmem [0:QDEPTH-1];
    reg [QAW-1:0] q_w = {QAW{1'b0}}, q_r = {QAW{1'b0}};
    reg [QAW:0]   q_count = {QAW+1{1'b0}};
    // One registered BRAM output is in flight.  `pipe_valid` is accounted for
    // in the queue capacity, so a read may be launched on *every* rd_clk.
    // That preserves a full descriptor/clock throughput rather than creating
    // a bubble every second clock at the shortest possible FAST8 pulses.
    reg [DW-1:0]  pipe_data = {DW{1'b0}};
    reg           pipe_valid = 1'b0;

    wire pop = rd_en & (q_count != {QAW+1{1'b0}});
    // `pipe_valid` transfers into qmem on this edge while a newly issued read
    // becomes valid on the next edge.  `pop` can therefore make room for a new
    // fetch even if the local queue was full at the start of this cycle.
    wire source_avail = (fbin != wbin_r);
    wire fetch_issue = source_avail &&
                       ((q_count + pipe_valid) < (QDEPTH + pop));
    wire [AW:0] rbin_next  = rbin + pop;
    wire [AW:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    assign empty = (q_count == {QAW+1{1'b0}});
    assign dout  = qmem[q_r];

    // qmem has no architectural reset: q_count/pipe_valid guarantee that its
    // contents are never observed before a completed BRAM fetch writes them.
    // Keep it out of the asynchronously-reset pointer process so Vivado does
    // not infer a spurious reset and dissolve this tiny queue into FFs.
    always @(posedge rd_clk) begin
        if (pipe_valid) qmem[q_w] <= pipe_data;
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin <= {AW+1{1'b0}}; rgray <= {AW+1{1'b0}}; fbin <= {AW+1{1'b0}};
            wgray_r1 <= {AW+1{1'b0}}; wgray_r2 <= {AW+1{1'b0}};
            q_w <= {QAW{1'b0}}; q_r <= {QAW{1'b0}}; q_count <= {QAW+1{1'b0}};
            pipe_data <= {DW{1'b0}}; pipe_valid <= 1'b0;
        end else begin
            wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
            rbin <= rbin_next; rgray <= rgray_next;

            if (pipe_valid) q_w <= q_w + 1'b1;
            if (pop) q_r <= q_r + 1'b1;
            case ({pipe_valid, pop})
                2'b10: q_count <= q_count + 1'b1;
                2'b01: q_count <= q_count - 1'b1;
                default: q_count <= q_count;
            endcase

            pipe_valid <= fetch_issue;
            if (fetch_issue) begin
                pipe_data <= mem[fbin[AW-1:0]];
                fbin <= fbin + 1'b1;
            end
        end
    end
endmodule
