`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// fb_line_disp.v  -  Phase 1a: line-buffered DDR display (replaces fb_loader + the whole-frame BRAM
// in fb_display). Per-source-line AXI-HP0 read into a small LUTRAM buffer, scanned out at 720p50.
// ZX output BYTE-IDENTICAL to fb_display.v; frees ~11 BRAM36. Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// v2 = code-review (workflow ws1b0mjym, FIX-THEN-GO) fixes applied:
//   B1: frame_base/fk_d reset + `base_valid` gate -> NO AR until disp_base pinned by first frame_kick
//       (else a boot burst reads garbage DDR and falsely asserts live -> bad cap_en re-source).
//   B2: need_row clk_pixel->fclk100 uses a SETTLED multi-bit cross (use nr_s2 only when nr_s2==nr_s3),
//       not a bare binary 2-FF (which can present a bogus intermediate at a multi-bit row boundary and
//       make the eviction logic drop a resident line).
//   F3: clear buf_row tag (=ROW_NONE) at invalidate so a mid-fill buffer can never tag-match.
//   F4: pixel select parameterized by SRC_BPP (psel=nib<<LBPP, px=rd[psel +: SRC_BPP]) -> the palette is
//       the only per-core stage. (ZX 4bpp output byte-identical.)
//   F5: MAXOUT param; LBW = FBURSTS*BEATS single source; widened word-address; named burst granule.
//   F6: lb read forced to 0 when !have_line (no X); dead code removed.
//
// CORE-INDEPENDENT scaler (machine-backend contract): geometry/scale/crop/bpp are PARAMETERS (ZX
// defaults). Buffering = TWO tag-addressed line buffers (buf_row + valid); the fclk100 reader keeps
// {need_row, need_row+1} resident; the scanout reads whichever buffer is tagged with the current rd_sy.
// Frame-top prime is automatic (in the top pillarbox need_row=SY0 -> SY0/SY0+1 load before the picture).
//-------------------------------------------------------------------------------------------------
module fb_line_disp #(
    parameter integer SRC_W   = 360,
    parameter integer SRC_H   = 302,      // capture writes 302 rows (vc 8..309, clean visible frame)
    parameter integer SRC_BPP = 4,
    parameter integer STRIDE  = 360,
    parameter integer SX0     = 0,        // show cols 0..356 = FULL left border, right edge = last good col 356
    parameter integer SY0     = 0,        // (white rgb/blank-skew garbage at 357-358 and black pad 359 excluded).
    parameter integer CROP_W  = 357,      // User choice: keep the WHOLE border, don't trim left; left 53 / right 48
    parameter integer CROP_H  = 302,      // show 302 rows (vc 8..309): rainbow top + active + rainbow + 1 black bottom
    parameter integer HMARGIN = 283,      // center 357*2=714 px in the 1280-wide active raster ((1280-714)/2)
    parameter integer VMARGIN = 58,       // center 302*2=604 lines in the 720-line active raster ((720-604)/2)
    parameter integer XSH     = 1,        // horizontal upscale shift
    parameter integer YSH     = 1,        // vertical upscale shift
    parameter integer WSH     = 4,        // log2(px per 64-bit word) = log2(64/SRC_BPP)
    parameter integer LBPP    = 2,        // log2(SRC_BPP) (4bpp->2)
    parameter integer FBURSTS = 3,        // 16-beat bursts per line fetch
    parameter integer MAXOUT  = 6,        // outstanding read bursts (<=8 HP cap)
    parameter integer WA      = 21        // word-address width (covers big frames)
)(
    // ==== CE29/B0066: ПАЛИТРА СТАЛА ПЕР-КОРНОЙ И ПРОГРАММИРУЕМОЙ (задача C очереди) ====
    // Было: у 8bpp вшита таблица NES 2C02 на 64 записи прямо в этом файле, ОБЩЕМ с ZX, а у 4bpp
    // палитры не было вовсе - там стояла формула RGBI. Из-за этого третья машина упиралась не в
    // кристалл, а в один этот `generate`: C64 (16 цветов VIC-II) выразить нечем, Atari (128 цветов)
    // тем более. Теперь таблица одна, инициализируется под ширину пикселя и переписывается с ARM
    // одним 32-битным словом {адрес, R, G, B} - то есть машина приносит свои цвета с собой.
    // Вывод при СТАРОЙ инициализации бит-в-бит прежний: у 4bpp значения ровно те, что давала формула.
    input  wire        pal_wclk,      // такт домена записи (у оболочки это aclk)
    input  wire        pal_we,        // строб записи (домен aclk у оболочки)
    input  wire [7:0]  pal_addr,
    input  wire [23:0] pal_rgb,
    // ---- fclk100 (= S_AXI_HP0 ACLK) ----
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] disp_base,
    input  wire        frame_kick,
    output reg  [31:0] ar_addr,
    output wire [5:0]  ar_id,
    output wire [3:0]  ar_len,
    output wire [2:0]  ar_size,
    output wire [1:0]  ar_burst,
    output wire [3:0]  ar_cache,
    output wire [2:0]  ar_prot,
    output wire [1:0]  ar_lock,
    output wire [3:0]  ar_qos,
    output reg         ar_valid,
    input  wire        ar_ready,
    input  wire [63:0] r_data,
    input  wire        r_last,
    input  wire        r_valid,
    output wire        r_ready,
    // ---- clk_pixel (HDMI 720p50) ----
    input  wire        rd_clk,
    input  wire [10:0] cx,
    input  wire [10:0] cy,
    input  wire [11:0] hmargin_a,   // Step 15: LIVE whole-frame HDMI position (else HMARGIN default). aclk-ish -> settle-latched to rd_clk below.
    input  wire [11:0] vmargin_a,   // Step 15: LIVE whole-frame HDMI vertical position (else VMARGIN default).
    input  wire [11:0] sx0_a,       // Step 15: LIVE crop origin X (first source column shown) - trims left border
    input  wire [11:0] sy0_a,       // Step 15: LIVE crop origin Y (first source row shown)    - trims top border
    input  wire [11:0] cropw_a,     // Step 15: LIVE crop width  (source columns shown)         - trims right border
    input  wire [11:0] croph_a,     // Step 15: LIVE crop height (source rows shown)            - trims bottom border
    input  wire [3:0]  xmul_a,      // CE21: LIVE integer upscale X (1..8). 0 = keep the compile-time XSH default.
    input  wire [3:0]  ymul_a,      // CE21: LIVE integer upscale Y (1..8). 0 = keep the compile-time YSH default.
                                    //   Was a PARAMETER (shift), so the scale could not be an owner-visible per-machine
                                    //   setting and non-power-of-2 was impossible: NES needs x3 vertical to fill 720p.
    output reg  [23:0] rgb,
    // ---- status ----
    output reg         live,
    output reg  [15:0] underrun_cnt,   // домен rd_clk, НАСЫЩАЕТСЯ: пиксель внутри картинки, а строки в буфере нет
    output reg  [15:0] stale_base_cnt, // домен clk,    НАСЫЩАЕТСЯ: пуск отложен - снимок адреса от ПРОШЛОГО кадра
    input  wire        quiesce_i,   // v158 QUIESCE: stop starting NEW line fetches - safe PL reload
    output wire        idle_o       // 1 = reader idle (no AR in flight)
);
    localparam integer BEATS   = 16;              // 16-beat = 128B INCR bursts
    localparam integer LBW     = FBURSTS*BEATS;   // line-buffer depth (words)
    localparam [8:0]   ROW_NONE= 9'h1FF;          // "no row" tag
    localparam integer MAXR    = (1<<($clog2(2*LBW)));

    assign ar_id=6'd0; assign ar_len=BEATS-1; assign ar_size=3'b011; assign ar_burst=2'b01;
    assign ar_cache=4'b0011; assign ar_prot=3'b000; assign ar_lock=2'b00; assign ar_qos=4'b0000;
    assign r_ready = 1'b1;

    // ---- Step 15: LIVE margins, settle-latched into rd_clk (the osd_pos idiom: 3-FF + accept only a
    // value seen twice in a row) so a multi-bit change from the ARM can never present a bogus in-between
    // to the window/address logic. Defaults = the HMARGIN/VMARGIN params (ZX/unchanged behaviour). ----
    reg [11:0] hm_s1, hm_s2, hm_s3, hm_q = HMARGIN[11:0];
    reg [11:0] vm_s1, vm_s2, vm_s3, vm_q = VMARGIN[11:0];
    reg [11:0] sx_s1, sx_s2, sx_s3, sx_q = SX0[11:0];
    reg [11:0] sy_s1, sy_s2, sy_s3, sy_q = SY0[11:0];
    reg [11:0] cw_s1, cw_s2, cw_s3, cw_q = CROP_W[11:0];
    reg [11:0] ch_s1, ch_s2, ch_s3, ch_q = CROP_H[11:0];
    localparam [3:0] XDEF = 4'd1 << XSH;                // compile-time default as a MULTIPLIER (XSH=1 -> x2)
    localparam [3:0] YDEF = 4'd1 << YSH;
    reg [3:0]  xm_s1, xm_s2, xm_s3, xm_q = 4'd1 << XSH;
    reg [3:0]  ym_s1, ym_s2, ym_s3, ym_q = 4'd1 << YSH;
    always @(posedge rd_clk) begin
        hm_s1<=hmargin_a; hm_s2<=hm_s1; hm_s3<=hm_s2; if (hm_s2==hm_s3) hm_q<=hm_s2;
        vm_s1<=vmargin_a; vm_s2<=vm_s1; vm_s3<=vm_s2; if (vm_s2==vm_s3) vm_q<=vm_s2;
        sx_s1<=sx0_a;     sx_s2<=sx_s1; sx_s3<=sx_s2; if (sx_s2==sx_s3) sx_q<=sx_s2;
        sy_s1<=sy0_a;     sy_s2<=sy_s1; sy_s3<=sy_s2; if (sy_s2==sy_s3) sy_q<=sy_s2;
        cw_s1<=cropw_a;   cw_s2<=cw_s1; cw_s3<=cw_s2; if (cw_s2==cw_s3) cw_q<=cw_s2;
        ch_s1<=croph_a;   ch_s2<=ch_s1; ch_s3<=ch_s2; if (ch_s2==ch_s3) ch_q<=ch_s2;
        xm_s1<=xmul_a;    xm_s2<=xm_s1; xm_s3<=xm_s2; if (xm_s2==xm_s3) xm_q<=(xm_s2==4'd0) ? XDEF : xm_s2;
        ym_s1<=ymul_a;    ym_s2<=ym_s1; ym_s3<=ym_s2; if (ym_s2==ym_s3) ym_q<=(ym_s2==4'd0) ? YDEF : ym_s2;
    end

    // ---- CE21: integer scale as a LIVE value. Division by a runtime factor is done by reciprocal
    // multiply with a 14-bit fraction; verified EXACT (== floor(d/m)) for m=1..8 over d=0..1439, i.e.
    // the whole 720p raster. Two of these (X and Y) cost ~2 DSP of the 73 free. ----
    function [11:0] divm;
        input [11:0] d;
        input [3:0]  m;
        reg   [14:0] r;
        reg   [26:0] pr;
        begin
            case (m)
                4'd1: r = 15'd16384; 4'd2: r = 15'd8192;  4'd3: r = 15'd5462;  4'd4: r = 15'd4096;
                4'd5: r = 15'd3277;  4'd6: r = 15'd2731;  4'd7: r = 15'd2341;  4'd8: r = 15'd2048;
                default: r = 15'd8192;                  // 0 / >8 -> behave as x2 (never divide by zero)
            endcase
            pr   = d * r;
            divm = pr[25:14];
        end
    endfunction

    // pic_w/pic_h REGISTERED: they change only when a settle-latch above updates (i.e. when the owner
    // touches a menu), so keeping the multiply combinational put it in the per-pixel cone for nothing.
    reg [15:0] pic_w = CROP_W[15:0] * (16'd1 << XSH);
    reg [15:0] pic_h = CROP_H[15:0] * (16'd1 << YSH);
    always @(posedge rd_clk) begin pic_w <= cw_q * xm_q; pic_h <= ch_q * ym_q; end
    wire [11:0] dx    = cx - hm_q;
    wire [11:0] dy    = cy - vm_q;
    wire        h_in  = (cx >= hm_q) && ({4'd0,dx} < pic_w);
    wire        v_in  = (cy >= vm_q) && ({4'd0,dy} < pic_h);

    //=============================================================================================
    // B0063/CE26 PIXEL-PATH ADDRESS GENERATION, INCREMENTAL. This is the fix for the ONLY setup
    // violation this design has ever had: the ZX build failed clk_pix_raw (74.25 MHz) with WNS
    // -1.728 ns on 64 endpoints - 128 endpoints before the shell was re-housed - and every failing
    // path was the same one: hdmi cy -> divm() reciprocal multiply (DSP48E1) -> * STRIDE -> LUTRAM
    // (RAMD64E) -> rd_q, sixteen logic levels inside one 13.468 ns pixel period. The comment further
    // down this file already blamed a long combinational cone for the project's lifelong dot/stripe
    // artefacts; CE21's live scale made that cone worse by adding the divider.
    //
    // A nearest-neighbour scaler does not need division at all: the source coordinate advances by one
    // every xm output pixels. So:
    //   * HORIZONTAL - a counter driven from cx+1 (one pixel of LOOKAHEAD), so the registered value is
    //     already correct when the pixel is fetched. No shift, bit-identical addresses to the divide.
    //   * VERTICAL - the row is constant for a whole line, so compute the NEXT line's row all through
    //     the current line (cy+1, stable) and latch it at the line boundary. Same for the row base
    //     address rd_sy*STRIDE. Both leave the per-pixel path entirely.
    // Result: the LUTRAM address comes from registers through an adder, not from a DSP through a
    // multiplier. divm() survives only for the next-line computation, where it has a full line to
    // settle instead of one pixel.
    //=============================================================================================
    wire [11:0] cxn  = cx + 12'd1;                       // next output pixel
    wire [11:0] dxn  = cxn - {1'b0, hm_q[11:0]};
    wire        h_in_n = (cxn >= {1'b0, hm_q[11:0]}) && ({4'd0,dxn} < pic_w);
    reg  [8:0]  rd_sx_r = 9'd0;
    reg  [3:0]  xcnt    = 4'd0;
    // B0064/CE27 ИСПРАВЛЕНИЕ (владелец: "когда screen x = 0, развёртка куда-то бежит").
    // Сброс горизонтального счётчика по условию cxn <= hm_q при hm_q == 0 НЕ НАСТУПАЕТ НИКОГДА:
    // cxn = cx+1 пробегает 1..H_TOTAL и нулю не равен. Счётчик не переинициализировался на новой
    // строке и продолжал расти -> адрес источника уезжал, картинка «бежала». Теперь сбрасываем и
    // за правым краем картинки: эта область покрывает весь гасящий интервал при ЛЮБОМ hm_q,
    // включая ноль. Проверено перебором hm 0..400 x xm 1..3 x sx0 x cw: расхождений с делением нет.
    wire [15:0] xend_n = {4'd0, hm_q[11:0]} + pic_w;      // на один пиксель правее последнего видимого
    always @(posedge rd_clk) begin
        if ((cxn <= {1'b0, hm_q[11:0]}) || ({4'd0, cxn} >= xend_n)) begin   // вне картинки = держим начало строки
            rd_sx_r <= sx_q[8:0];
            xcnt    <= 4'd0;
        end else if (h_in_n) begin
            if (xcnt + 4'd1 >= xm_q) begin xcnt <= 4'd0;          rd_sx_r <= rd_sx_r + 9'd1; end
            else                          xcnt <= xcnt + 4'd1;
        end
    end

    wire [11:0] dyn = (cy + 12'd1) - {1'b0, vm_q[11:0]};
    wire        v_in_n = ((cy + 12'd1) >= {1'b0, vm_q[11:0]}) && ({4'd0,dyn} < pic_h);
    reg  [8:0]     rd_sy_n = 9'd0, rd_sy_r = 9'd0;
    reg  [WA-1:0]  lin_base_n = {WA{1'b0}}, lin_base = {WA{1'b0}};
    reg  [11:0]    cy_d = 12'd0;
    always @(posedge rd_clk) begin
        rd_sy_n    <= v_in_n ? (sy_q[8:0] + divm(dyn, ym_q)) : sy_q[8:0];   // whole line to settle
        lin_base_n <= rd_sy_n * STRIDE;
        cy_d       <= cy;
        if (cy != cy_d) begin                            // line boundary: adopt the prepared row
            rd_sy_r  <= rd_sy_n;
            lin_base <= lin_base_n;
        end
    end

    //=============================================================================================
    // clk_pixel: which SOURCE ROW does the scanout need now (= need_row)?  In the top pillarbox we
    // point at SY0 so the reader primes SY0/SY0+1 before the picture; in-picture it tracks the row.
    //=============================================================================================
    wire        in_v   = v_in;
    wire [8:0]  row_in = rd_sy_r;        // B0063: уже посчитано конвейером выше (без делителя в пути)
    reg  [8:0]  need_row;
    always @(posedge rd_clk) need_row <= in_v ? row_in : sy_q[8:0];

    //=============================================================================================
    // disp_base pinned ONCE per frame; reader keeps {want0,want1} resident in 2 tagged buffers.
    //=============================================================================================
    (* ram_style="distributed" *) reg [63:0] lb [0:2*LBW-1];
    reg  [8:0]    buf_row [0:1];
    reg  [WA-1:0] buf_base[0:1];
    reg  [1:0]    buf_valid;

    // need_row clk_pixel->fclk100, SETTLED (use nr_s2 only when it equals nr_s3) -> no bogus multi-bit
    reg [8:0] nr_s1, nr_s2, nr_s3, nr_stable;
    always @(posedge clk) begin
        nr_s1 <= need_row; nr_s2 <= nr_s1; nr_s3 <= nr_s2;
        if (nr_s2 == nr_s3) nr_stable <= nr_s2;
    end
    wire [8:0] want0 = nr_stable;
    wire [8:0] want1 = (nr_stable + 9'd1 < SRC_H[8:0]) ? nr_stable + 9'd1 : nr_stable;

    // disp_base pin (latched the cycle after frame_kick) + base_valid (set once a frame has been pinned)
    reg        fk_d, base_valid;
    reg [31:0] frame_base;
    /* 🥇 B0194 МЕТКА КАДРА У СТРОК ЧИТАТЕЛЯ. Жалоба владельца 17.09: на мерцающих демках верхние
       ~4 строки кадра идут «с неоднородностью», и кропом это не лечится. Причина: строки в двух
       буферах читателя помечены ТОЛЬКО номером (`buf_row`), без привязки к кадру. Картинка кончается
       около cy=626, гашение HDMI (и смена `disp_base`) наступает на cy=720, а между ними читатель уже
       сидит в нижнем поле, где `need_row = sy0`, и ПОДКАЧИВАЕТ первые строки следующего кадра - из
       ЕЩЁ СТАРОГО буфера. После смены базы номера совпадают, тег считается годным, и верх нового кадра
       показывается из прошлого. Два буфера строк при масштабе 2 дают ровно 4 экранные строки.
       Метка однобитная намеренно: сравнение попадает в конус `have0/have1` -> RD_IDLE -> `ar_addr`,
       у которого в B0124 уже была история с таймингом, и 32-битное сравнение баз туда класть нельзя. */
    reg        base_epoch = 1'b0;
    always @(posedge clk) begin
        if (!resetn) begin fk_d<=1'b0; frame_base<=disp_base; base_valid<=1'b0; base_epoch<=1'b0; end
        else begin
            fk_d <= frame_kick;
            if (fk_d) begin frame_base <= disp_base; base_valid <= 1'b1; base_epoch <= ~base_epoch; end
        end
    end

    reg  [1:0] buf_epoch = 2'b00;      // B0194: из какого кадра принесена строка
    wire b0_ok  = buf_valid[0] && (buf_epoch[0]==base_epoch);
    wire b1_ok  = buf_valid[1] && (buf_epoch[1]==base_epoch);
    wire b0_is0 = b0_ok && (buf_row[0]==want0);
    wire b0_is1 = b0_ok && (buf_row[0]==want1);
    wire b1_is0 = b1_ok && (buf_row[1]==want0);
    wire b1_is1 = b1_ok && (buf_row[1]==want1);
    wire have0    = b0_is0 | b1_is0;
    wire have1    = b0_is1 | b1_is1;
    wire b0_spare = !(b0_is0 | b0_is1);
    wire b1_spare = !(b1_is0 | b1_is1);

    localparam RD_IDLE=1'b0, RD_AR=1'b1;
    reg        rstate;
    reg        tgt;
    reg        tgt_epoch;             // B0194: метка кадра, из которого берётся эта строка
    reg [8:0]  tgt_row;
    reg [WA-1:0] tgt_base;
    reg [8:0]  ar_issued;
    reg [8:0]  words_rcvd;
    reg [2:0]  outstanding;

    wire ar_hs = ar_valid & ar_ready;
    wire r_hs  = r_valid & r_ready;

    function [WA-1:0] base_word_f(input [8:0] r); base_word_f = (r*STRIDE) >> WSH; endfunction
    function [WA-1:0] align_f   (input [8:0] r); align_f     = ((r*STRIDE) >> WSH) & ~{{(WA-4){1'b0}},4'd15}; endfunction

    // 🥇 B0124 АДРЕС СТРОКИ - В РЕГИСТР, ВМЕСТЕ С ТЕГОМ СТРОКИ.
    // Приём дословно повторяет osd_ddr_rd.v:118-125 (B0114), где он живёт восемь сборок и уже
    // подтверждён синтезом. Здесь в комбинационном пути RD_IDLE стояли ДВА ПОСЛЕДОВАТЕЛЬНЫХ
    // сумматора: align_f (r*STRIDE>>WSH, то есть r*24) и frame_base + (...<<3). Это и есть отчётные
    // CARRY4=5 у нарушенного пути ddrdisp/nr_stable_reg[3] -> ddrdisp/ar_addr_reg[18] (12 уровней
    // логики). Замер на этом конусе: три четверти задержки - ТРАССИРОВКА, поэтому директивами
    // размещения и полировки он не лечится в принципе (проверено: четыре директивы и переразводка
    // не сдвинули -0.219 нс ни на пикосекунду). Лечится только сокращением числа уровней.
    // Когерентность держит ТЕГ: пуск разрешён лишь когда снимок относится к той строке, которую
    // хотят сейчас. Только-что изменившийся want не может подсунуть протухший адрес под свежий
    // номер строки - в худшем случае один такт простоя на смену строки.
    reg [31:0]   addr0_q = 32'd0,      addr1_q = 32'd0;
    reg [WA-1:0] base0_q = {WA{1'b0}}, base1_q = {WA{1'b0}};
    reg [8:0]    row0_q  = 9'h1FF,     row1_q  = 9'h1FF;
    /* 🥇 B0196 СНИМОК АДРЕСА ОБЯЗАН ЗНАТЬ, ИЗ КАКОГО КАДРА ВЗЯТА ЕГО БАЗА.
       Остаток верхней кромки после B0194/B0195 (владелец: «полоса шириной в один спектрумовский
       пиксель, видно только на мерцающих демках»). Механизм, такт за такт на `clk`:
         K+2  `fk_d`=1: `frame_base` и `base_epoch` ещё СТАРЫЕ, и именно из старой базы считается
              `addr0_q`/`addr1_q` (блок ниже работает каждый такт, без разрешения);
         K+3  `frame_base` и `base_epoch` уже НОВЫЕ, а `addr0_q` лежит посчитанный по СТАРОЙ базе.
       На K+3 обе строки негодны по метке (`!have0`), читатель стоит в `RD_IDLE` - в гашении ему
       делать нечего - и срабатывает В ТОТ ЖЕ ТАКТ: берёт `ar_addr <= addr0_q`, то есть адрес в
       буфере ПРОШЛОГО кадра, а помечает строку `tgt_epoch <= base_epoch`, то есть НОВОЙ меткой.
       Сторож `row0_q == want0` проверял свежесть НОМЕРА СТРОКИ, но не свежесть базы кадра.
       Итог: первая исходная строка картинки приезжает из прошлого кадра с честной меткой «свежая»,
       поэтому проверка метки на пиксельной стороне (B0195) пропустить её не могла в принципе.
       Сходится всё: только сверху (перезакачка по смене метки достаётся первой строке, остальные
       читаются много позже), только на мерцающих демках (иначе `disp_base` от кадра к кадру не
       меняется и подмены не видно), кропом не лечится, и в снимке кадра отсутствует.
       Лечение: метку кадра, из базы которого посчитан снимок, положить РЯДОМ со снимком и пускать
       чтение только на совпадении. Цена - один такт простоя раз в кадр, внутри гашения.
       Метка однобитная намеренно: в конус `RD_IDLE` -> `ar_addr` нельзя класть 32-битное сравнение
       баз (у этого пути в B0124 уже была история с таймингом). */
    reg          fbe_q   = 1'b0;
    always @(posedge clk) begin
        fbe_q   <= base_epoch;
        row0_q  <= want0;
        base0_q <= align_f(want0);
        addr0_q <= frame_base + ({{(32-WA-3){1'b0}}, align_f(want0), 3'b000});
        row1_q  <= want1;
        base1_q <= align_f(want1);
        addr1_q <= frame_base + ({{(32-WA-3){1'b0}}, align_f(want1), 3'b000});
    end

    wire base_fresh = (fbe_q == base_epoch);   // B0196: снимок адреса относится к ТЕКУЩЕЙ базе кадра

    always @(posedge clk) begin
        if (!resetn) begin
            rstate<=RD_IDLE; ar_valid<=1'b0; ar_addr<=32'd0; ar_issued<=9'd0; words_rcvd<=9'd0;
            outstanding<=3'd0; buf_valid<=2'b00; buf_epoch<=2'b00; tgt<=1'b0; tgt_epoch<=1'b0; live<=1'b0;
            buf_row[0]<=ROW_NONE; buf_row[1]<=ROW_NONE; buf_base[0]<={WA{1'b0}}; buf_base[1]<={WA{1'b0}};
        end else begin
            case (rstate)
            RD_IDLE: begin
                ar_valid<=1'b0; outstanding<=3'd0; ar_issued<=9'd0; words_rcvd<=9'd0;
                // B0124: адрес, база и тег берутся ИЗ ОДНОГО снимка (см. блок выше), а условие
                // row*_q == want* и есть проверка, что снимок свежий. Арифметика бит-в-бит прежняя.
                if (!quiesce_i && base_valid && base_fresh && !have0 && (b0_spare || b1_spare) && (row0_q == want0)) begin
                    tgt       <= b0_spare ? 1'b0 : 1'b1;
                    tgt_epoch <= base_epoch;
                    tgt_row  <= row0_q;
                    tgt_base <= base0_q;
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr  <= addr0_q;
                    rstate   <= RD_AR;
                end else if (!quiesce_i && base_valid && base_fresh && !have1 && (b0_spare || b1_spare) && (row1_q == want1)) begin
                    tgt       <= b0_spare ? 1'b0 : 1'b1;
                    tgt_epoch <= base_epoch;
                    tgt_row  <= row1_q;
                    tgt_base <= base1_q;
                    if (b0_spare) begin buf_valid[0]<=1'b0; buf_row[0]<=ROW_NONE; end
                    else          begin buf_valid[1]<=1'b0; buf_row[1]<=ROW_NONE; end
                    ar_addr  <= addr1_q;
                    rstate   <= RD_AR;
                end
            end
            RD_AR: begin
                if (!ar_valid && (ar_issued < FBURSTS) && (outstanding < MAXOUT[2:0]))
                    ar_valid <= 1'b1;
                if (ar_hs) begin
                    ar_valid  <= 1'b0;
                    ar_addr   <= ar_addr + 32'd128;
                    ar_issued <= ar_issued + 9'd1;
                end
                if (r_hs) begin
                    lb[(tgt?LBW:0) + words_rcvd] <= r_data;
                    words_rcvd <= words_rcvd + 9'd1;
                end
                case ({ar_hs,(r_hs & r_last)})
                    2'b10: outstanding<=outstanding+3'd1;
                    2'b01: outstanding<=outstanding-3'd1;
                    default:;
                endcase
                if (words_rcvd==LBW-1 && r_hs) begin
                    buf_row [tgt] <= tgt_row;
                    buf_base[tgt] <= tgt_base;
                    buf_epoch[tgt]<= tgt_epoch;      // B0194
                    buf_valid[tgt]<= 1'b1;
                    live          <= 1'b1;
                    rstate        <= RD_IDLE;
                end
            end
            endcase
        end
    end

    //=============================================================================================
    // clk_pixel scanout (crop/upscale/palette LIFTED from fb_display.v; mem[rd_word] -> line buffer).
    //=============================================================================================
    wire in_pic = h_in && v_in;
    wire [8:0]  rd_sx = rd_sx_r;         // B0063: регистр счётчика вместо реципрок-деления
    // rd_sy COMBINATIONAL from cy (byte-identical to fb_display.v) -- NOT the registered need_row
    // (which exists only for the reader-CDC). Using need_row here added an extra register stage on the
    // vertical path vs the in_pic gate -> a 1-line data/gate skew visible as ~1px clipped at the top.
    wire [8:0]  rd_sy = rd_sy_r;         // B0063: защёлкнуто на границе строки
    wire [WA-1:0] lin     = lin_base + rd_sx;   // B0063: умножение на STRIDE ушло из пиксельного пути
    wire [WA-1:0] lin_word= lin >> WSH;
    wire [3:0]  lin_nib   = lin[WSH-1:0];

    /* 🥇 B0195 МЕТКА КАДРА НУЖНА И ПИКСЕЛЬНОЙ СТОРОНЕ, А НЕ ТОЛЬКО ЧИТАТЕЛЮ.
       B0194 добавил метку в условия попадания читателя - артефакт на верхней кромке уменьшился
       ровно вдвое (владелец: было ~4 строки, стало ~2), и это само указало на вторую половину.
       Почему половина: после смены кадра ОБЕ строки становятся негодными по метке, и читатель берёт
       под перезакачку СВОБОДНЫЙ буфер - при обеих негодных `b0_spare` истинен, значит обновляется
       буфер 0, а буфер 1 продолжает лежать со старой строкой и поднятым `buf_valid`. Пиксельная
       сторона метку не проверяла вовсе и спокойно отдавала эту строку: `sy0` шла свежая, `sy0+1` -
       из прошлого кадра. Одна исходная строка при масштабе 2 = 2 экранные строки.
       `buf_epoch` и `base_epoch` заводим теми же двумя ступенями, что и `buf_valid`, чтобы признак
       и метка приходили на пиксельную сторону согласованно. Если строка не годна, `have_line` = 0 -
       это окно живёт только внутри гашения, где ничего не выводится. */
    reg [1:0] v_s1, v_s2, e_s1, e_s2;
    reg       be_s1, be_s2;
    always @(posedge rd_clk) begin
        v_s1<=buf_valid;  v_s2<=v_s1;
        e_s1<=buf_epoch;  e_s2<=e_s1;
        be_s1<=base_epoch; be_s2<=be_s1;
    end
    wire sel0 = v_s2[0] && (e_s2[0]==be_s2) && (buf_row[0]==rd_sy);
    wire sel1 = v_s2[1] && (e_s2[1]==be_s2) && (buf_row[1]==rd_sy);
    wire        have_line = sel0 | sel1;
    wire [WA-1:0] sbase   = sel0 ? buf_base[0] : buf_base[1];
    wire [WA-1:0] bufidx  = lin_word - sbase;                 // 0..LBW-1 when have_line
    wire [63:0] word      = have_line ? lb[(sel0 ? 0 : LBW) + bufidx[$clog2(LBW)-1:0]] : 64'd0;

    reg [63:0] rd_q; reg [3:0] nib_q; reg in_pic_q; reg have_q;
    always @(posedge rd_clk) begin
        rd_q<=word; nib_q<=lin_nib; in_pic_q<=in_pic; have_q<=have_line;
    end
    wire [9:0] psel = nib_q << LBPP;
    wire [SRC_BPP-1:0] px = rd_q[psel +: SRC_BPP];            // pixel, SRC_BPP-wide (4=ZX RGBI, 8=NES index)
    // ---- палитра: одна таблица на любой SRC_BPP, с записью из ARM ----
    localparam integer PAL_N  = (SRC_BPP >= 8) ? 256 : 16;
    localparam integer PAL_AW = (SRC_BPP >= 8) ? 8   : 4;
    (* ram_style = "distributed" *) reg [23:0] pal [0:PAL_N-1];
    integer pi;
    initial begin
        if (SRC_BPP >= 8) begin
            // NES 2C02, как было (индексы 64..255 - зеркала, чтобы промах индекса не давал мусор)
            pal[  0]=24'h666666; pal[  1]=24'h002A88; pal[  2]=24'h1412A7; pal[  3]=24'h3B00A4;
            pal[  4]=24'h5C007E; pal[  5]=24'h6E0040; pal[  6]=24'h6C0600; pal[  7]=24'h561D00;
            pal[  8]=24'h333500; pal[  9]=24'h0B4800; pal[ 10]=24'h005200; pal[ 11]=24'h004F08;
            pal[ 12]=24'h00404D; pal[ 13]=24'h000000; pal[ 14]=24'h000000; pal[ 15]=24'h000000;
            pal[ 16]=24'hADADAD; pal[ 17]=24'h155FD9; pal[ 18]=24'h4240FF; pal[ 19]=24'h7527FE;
            pal[ 20]=24'hA01ACC; pal[ 21]=24'hB71E7B; pal[ 22]=24'hB53120; pal[ 23]=24'h994E00;
            pal[ 24]=24'h6B6D00; pal[ 25]=24'h388700; pal[ 26]=24'h0C9300; pal[ 27]=24'h008F32;
            pal[ 28]=24'h007C8D; pal[ 29]=24'h000000; pal[ 30]=24'h000000; pal[ 31]=24'h000000;
            pal[ 32]=24'hFFFEFF; pal[ 33]=24'h64B0FF; pal[ 34]=24'h9290FF; pal[ 35]=24'hC676FF;
            pal[ 36]=24'hF36AFF; pal[ 37]=24'hFE6ECC; pal[ 38]=24'hFE8170; pal[ 39]=24'hEA9E22;
            pal[ 40]=24'hBCBE00; pal[ 41]=24'h88D800; pal[ 42]=24'h5CE430; pal[ 43]=24'h45E082;
            pal[ 44]=24'h48CDDE; pal[ 45]=24'h4F4F4F; pal[ 46]=24'h000000; pal[ 47]=24'h000000;
            pal[ 48]=24'hFFFEFF; pal[ 49]=24'hC0DFFF; pal[ 50]=24'hD3D2FF; pal[ 51]=24'hE8C8FF;
            pal[ 52]=24'hFBC2FF; pal[ 53]=24'hFEC4EA; pal[ 54]=24'hFECCC5; pal[ 55]=24'hF7D8A5;
            pal[ 56]=24'hE4E594; pal[ 57]=24'hCFEF96; pal[ 58]=24'hBDF4AB; pal[ 59]=24'hB3F3CC;
            pal[ 60]=24'hB5EBF2; pal[ 61]=24'hB8B8B8; pal[ 62]=24'h000000; pal[ 63]=24'h000000;
            for (pi = 64; pi < PAL_N; pi = pi + 1) pal[pi] = 24'h000000;
        end else begin
            // ZX RGBI - ровно то, что давала формула `bri ? 8'hFF : 8'hD7`, бит-в-бит
            for (pi = 0; pi < 16; pi = pi + 1)
                pal[pi] = { pi[2] ? (pi[3] ? 8'hFF : 8'hD7) : 8'h00,
                            pi[1] ? (pi[3] ? 8'hFF : 8'hD7) : 8'h00,
                            pi[0] ? (pi[3] ? 8'hFF : 8'hD7) : 8'h00 };
        end
    end
    // запись из ARM. Домен aclk против rd_clk: переносим тогглом, данные к моменту импульса стоят.
    (* ASYNC_REG="TRUE" *) reg [2:0] palw_s = 3'd0;
    reg palw_tog_a = 1'b0;
    always @(posedge pal_wclk) if (pal_we) palw_tog_a <= ~palw_tog_a;
    always @(posedge rd_clk) palw_s <= {palw_s[1:0], palw_tog_a};
    wire palw_pulse = palw_s[2] ^ palw_s[1];
    always @(posedge rd_clk) if (palw_pulse) pal[pal_addr[PAL_AW-1:0]] <= pal_rgb;

    always @(posedge rd_clk)
        rgb <= (in_pic_q && have_q) ? pal[px[PAL_AW-1:0]] : 24'h505050;


    // ---- приборы читателя, одним словом в регистре 0x1C8 = {stale_base_cnt, underrun_cnt} ----
    // Оба счётчика НАСЫЩАЮТСЯ на 0xFFFF: важно «растёт или нет», а не точное число. Домены разные
    // (rd_clk и clk), поэтому слово читать двумя чтениями и смотреть дельту, а не мгновенное значение.
    //   underrun_cnt   растёт -> читатель НЕ УСПЕВАЕТ донести строку к пикселю (нечем выводить);
    //   stale_base_cnt растёт -> сторож B0196 отложил пуск, то есть дефект подмены кадра ЛОВИТСЯ
    //                            (на 50 Гц ожидаем порядка 50-100 в секунду; ноль = сторож не нужен).
    always @(posedge rd_clk) begin
        if (!resetn)                                                       underrun_cnt <= 16'd0;
        else if (in_pic && !have_line && underrun_cnt != 16'hFFFF)         underrun_cnt <= underrun_cnt + 16'd1;
    end
    always @(posedge clk) begin
        if (!resetn)                                                       stale_base_cnt <= 16'd0;
        else if (base_valid && !base_fresh && !have0 && (b0_spare || b1_spare)
                 && stale_base_cnt != 16'hFFFF)                            stale_base_cnt <= stale_base_cnt + 16'd1;
    end
    assign idle_o = (rstate==RD_IDLE);   // v158: in IDLE ar_valid=0 and outstanding=0 by construction
endmodule
//-------------------------------------------------------------------------------------------------
