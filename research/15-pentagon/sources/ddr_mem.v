//-------------------------------------------------------------------------------------------------
// ddr_mem.v - БАЙТОВАЯ ПАМЯТЬ МАШИНЫ В PS DDR через свободный порт S_AXI_HP2.
//-------------------------------------------------------------------------------------------------
// Зачем: 54 % коллекции владельца (14 880 ромов из 27 325) не влезает в BRAM по объёму, а Пентагону
// нужен настоящий мегабайт - в кристалле его нет физически (270 КБ BRAM всего, свободно ~43 КБ).
// Обе задачи закрывает ОДИН мастер: расширенные банки ZX и большие картриджи NES.
//
// ПОЧЕМУ ЭТО РАБОТАЕТ (наши собственные замеры, ddr_probe на этом же порту, 31.07):
//   первое слово чтения    181-206 нс (макс. 460)
//   окно чтения Z80 3.5 МГц  ~571 нс   -> запас почти трёхкратный
//   дедлайн PPU у NES         186 нс   -> там без кеша нельзя, отсюда порядок: сперва ZX
// И главное: видеотракт основную память НЕ трогает (экран зеркалится в отдельную BRAM `scr`),
// поэтому на этом пути нет жёсткого реального времени.
//
// КАК ОСТАНАВЛИВАЕМ ПРОЦЕССОР. Не клок-гейтом! В ядре уже есть штатный механизм: контеншен ULA
// останавливает CPU, не трогая ULA и видео (`main.v: cpu_ten = pe3M5 & contend`). Латентность DDR
// ложится туда же одним термом `& ~mwait`. Гасить `pe3M5_core` в топе НЕЛЬЗЯ - он морозит ядро
// целиком вместе с ULA, и растр поедет (так работает пауза, и это другое).
//
// Байтовый доступ на 64-битной шине: одна транзакция в один такт данных, нужный байт выбирается
// адресом [2:0], запись - через WSTRB. Никакого кеша в первой версии сознательно: сначала
// правильность, потом скорость. Строчный кеш на 8 байт добавляется позже одним блоком и виден
// в этом же интерфейсе как уменьшение mwait.
//
// Домены: машинная сторона на своём такте (у ZX это spclk), AXI на fclk100. Запрос и ответ
// переносятся тогглом + 3 триггера, как во всей оболочке (см. inject_cdc / kbd_tx).
//-------------------------------------------------------------------------------------------------
`default_nettype none

module ddr_mem #(
    parameter [31:0]  BASE   = 32'h0F400000,   // окно в PS DDR (ниже мейлбокса 0x0F700000)
    parameter integer ADDR_W = 20              // 20 бит = 1 МБ (Пентагон 1024)
)(
    // ---------------- AXI-HP2 (домен aclk) ----------------
    input  wire        aclk,
    input  wire        aresetn,
    // запись
    output reg  [31:0] aw_addr,
    output wire [3:0]  aw_len,
    output wire [2:0]  aw_size,
    output wire [1:0]  aw_burst,
    output wire [3:0]  aw_cache,
    output wire [2:0]  aw_prot,
    output wire [1:0]  aw_lock,
    output wire [3:0]  aw_qos,
    output reg         aw_valid,
    input  wire        aw_ready,
    output reg  [63:0] w_data,
    output reg  [7:0]  w_strb,
    output wire        w_last,
    output reg         w_valid,
    input  wire        w_ready,
    input  wire        b_valid,
    output wire        b_ready,
    // чтение
    output reg  [31:0] ar_addr,
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

    // ---------------- сторона машины (домен mclk) ----------------
    input  wire                mclk,
    input  wire [ADDR_W-1:0]   maddr,
    input  wire [7:0]          mwdata,
    input  wire                mrd,      // однотактовый запрос чтения
    input  wire                mwr,      // однотактовый запрос записи
    output reg  [7:0]          mrdata,
    // ЯВНЫЙ начальный ноль обязателен: от mwait теперь зависит разрешение такта процессора,
    // и подняться после конфигурации в единице означало бы намертво стоящую машину.
    output reg                 mwait = 1'b0,

    // ---------------- сторона ARM (домен aclk, БЕЗ пересечения домена) ----------------
    // Оплачено первым же испытанием: сперва запросы от ARM подавались на машинный вход, а он живёт
    // в такте машины (у ZX spclk 56.7 МГц). Однотактовый импульс из fclk100 через границу домена
    // ТЕРЯЛСЯ - из 64 запросов до мастера дошли 42. У ARM своя сторона, и ей CDC не нужен вовсе:
    // AXI-часть модуля и так тактируется fclk100.
    input  wire                arm_req,     // 1 такт aclk
    input  wire                arm_iswr,
    input  wire [ADDR_W-1:0]   arm_addr,
    input  wire [7:0]          arm_wdata,
    output reg  [7:0]          arm_rdata,
    output reg                 arm_busy,
    output reg  [15:0]         arm_drop,    // запросов отброшено (пришли, пока мастер занят)

    // ---------------- QUIESCE и телеметрия ----------------
    input  wire        quiesce_i,        // 1 = новых транзакций не начинать
    output wire        idle_o,           // 1 = ни одной транзакции в полёте
    output reg  [15:0] wait_cnt,         // сколько тактов машина простояла (для приборной проверки)
    output reg  [15:0] xact_cnt          // сколько транзакций выполнено
);
    // постоянные поля AXI: один такт данных, 8 байт, INCR, некешируемо
    assign aw_len = 4'd0;  assign aw_size = 3'b011;  assign aw_burst = 2'b01;
    assign aw_cache = 4'b0000; assign aw_prot = 3'b000; assign aw_lock = 2'b00; assign aw_qos = 4'b0000;
    assign ar_len = 4'd0;  assign ar_size = 3'b011;  assign ar_burst = 2'b01;
    assign ar_cache = 4'b0000; assign ar_prot = 3'b000; assign ar_lock = 2'b00; assign ar_qos = 4'b0000;
    assign w_last  = 1'b1;
    assign b_ready = 1'b1;
    assign r_ready = 1'b1;

    // ---- запрос: mclk -> aclk (тоггл + 3 триггера) ----
    // ВСЯ машинная сторона живёт в ОДНОМ always: mwait ставится по запросу и снимается по
    // подтверждению, и если разнести это по двум блокам - получается два драйвера одной цепи
    // (синтез ловит как multi-driven net; ровно на этом я уже спотыкался со стробом палитры).
    reg req_tog_m = 1'b0;
    reg req_pend_m = 1'b0;              // B0074: запрос выдаётся ТАКТОМ ПОЗЖЕ адреса/данных
    reg [ADDR_W-1:0] req_addr_m = {ADDR_W{1'b0}};
    reg [7:0] req_wdata_m = 8'd0;
    reg       req_iswr_m  = 1'b0;
    (* ASYNC_REG="TRUE" *) reg [2:0] req_s = 3'd0;
    always @(posedge aclk) req_s <= {req_s[1:0], req_tog_m};
    wire req_pulse = req_s[2] ^ req_s[1];
    (* ASYNC_REG="TRUE" *) reg [ADDR_W-1:0] a_addr_s0 = {ADDR_W{1'b0}}, a_addr_s1 = {ADDR_W{1'b0}};
    (* ASYNC_REG="TRUE" *) reg [7:0] a_wd_s0 = 8'd0, a_wd_s1 = 8'd0;
    (* ASYNC_REG="TRUE" *) reg [1:0] a_iswr_s = 2'd0;
    always @(posedge aclk) begin
        a_addr_s0 <= req_addr_m;  a_addr_s1 <= a_addr_s0;
        a_wd_s0   <= req_wdata_m; a_wd_s1   <= a_wd_s0;
        a_iswr_s  <= {a_iswr_s[0], req_iswr_m};
    end

    // ---- автомат AXI ----
    localparam S_IDLE = 3'd0, S_AR = 3'd1, S_R = 3'd2, S_AW = 3'd3, S_B = 3'd5, S_START = 3'd6;
    localparam S_RDLY = 3'd4, S_RACK = 3'd7;   // B0074: данные вперёд флага (см. S_R)
    reg [2:0] st = S_IDLE;
    reg [2:0] byte_sel = 3'd0;
    reg [ADDR_W-1:0] cur_addr = {ADDR_W{1'b0}};
    reg [7:0] cur_wd = 8'd0;
    reg       cur_iswr = 1'b0;
    reg       src_arm  = 1'b0;
    reg [7:0] rd_byte = 8'd0;
    reg       ack_tog_a = 1'b0;
    // B0074: запрос машины ЗАЩЁЛКИВАЕТСЯ, а не обслуживается «на лету». `req_pulse` живёт один такт
    // aclk и обслуживался ТОЛЬКО в S_IDLE: если он приходил, пока мастер занят (стенд ARM через
    // регистр 0x148 работает при живой машине), импульс терялся безвозвратно, а `mwait` снимается
    // ИСКЛЮЧИТЕЛЬНО по подтверждению - процессор замерзал насмерть до перезагрузки ядра.
    reg       req_pend_a = 1'b0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            st <= S_IDLE; ar_valid <= 1'b0; aw_valid <= 1'b0; w_valid <= 1'b0;
            xact_cnt <= 16'd0; arm_busy <= 1'b0; arm_drop <= 16'd0; req_pend_a <= 1'b0;
        end else begin
        if (req_pulse) req_pend_a <= 1'b1;      // защёлкнуть; снимается при входе в транзакцию
        case (st)
        S_IDLE: begin
                    // приоритет у МАШИНЫ: её запрос синхронен её такту и ждать не может
                    if ((req_pend_a || arm_req) && !quiesce_i) begin
                        // источник: машина (через CDC) или ARM (напрямую)
                        if (req_pend_a) begin
                            req_pend_a <= 1'b0;
                            src_arm  <= 1'b0;
                            byte_sel <= a_addr_s1[2:0];
                            cur_addr <= a_addr_s1;
                            cur_wd   <= a_wd_s1;
                            cur_iswr <= a_iswr_s[1];
                        end else begin
                            src_arm  <= 1'b1;
                            byte_sel <= arm_addr[2:0];
                            cur_addr <= arm_addr;
                            cur_wd   <= arm_wdata;
                            cur_iswr <= arm_iswr;
                            arm_busy <= 1'b1;
                        end
                        st <= S_START;
                    end else if (quiesce_i) begin
                        // Под QUIESCE новых транзакций не начинаем. Но запрос МАШИНЫ - это
                        // производный фронт: не обслужил - он потерян, а mwait остался бы стоять
                        // навсегда, то есть процессор заморожен без надежды ожить. Отвечаем пустым
                        // подтверждением: байт будет мусорным (машину всё равно вот-вот сменят
                        // перезагрузкой ядра), зато нет вечной заморозки, если QUIESCE снимут.
                        if (req_pend_a) begin ack_tog_a <= ~ack_tog_a; req_pend_a <= 1'b0; end
                        if (arm_req)   arm_drop  <= arm_drop + 16'd1;
                    end
                end
        S_START: begin
                    if (cur_iswr) begin
                        aw_addr  <= BASE + {{(32-ADDR_W){1'b0}}, {cur_addr[ADDR_W-1:3], 3'b000}};
                        aw_valid <= 1'b1;
                        w_data   <= {8{cur_wd}};                       // байт во все позиции
                        w_strb   <= (8'd1 << byte_sel);                // валиден только нужный
                        w_valid  <= 1'b1;
                        st       <= S_AW;
                    end else begin
                        ar_addr  <= BASE + {{(32-ADDR_W){1'b0}}, {cur_addr[ADDR_W-1:3], 3'b000}};
                        ar_valid <= 1'b1;
                        st       <= S_AR;
                    end
                end
        S_AR:   if (ar_ready) begin ar_valid <= 1'b0; st <= S_R; end
        S_R:    if (r_valid) begin
                    // B0074: байт МАШИНЫ пишем ТОЛЬКО в машинной ветке. Раньше `rd_byte` обновлялся
                    // на любой транзакции, включая ARM-овскую: чтение со стенда, попавшее между
                    // ответом машине и его приёмом (~50 нс), подменяло машине байт.
                    if (src_arm) begin arm_rdata <= r_data[{byte_sel, 3'b000} +: 8]; arm_busy <= 1'b0;
                                       xact_cnt <= xact_cnt + 16'd1; st <= S_IDLE; end
                    // B0074: ПОДТВЕРЖДЕНИЕ МАШИНЕ - НЕ В ЭТОМ ТАКТЕ, а через два (S_RDLY -> S_RACK).
                    // Иначе `rd_byte` и `ack_tog_a` меняются ОДНОВРЕМЕННО, а на стороне машины флаг
                    // идёт через 3 триггера, данные - через 2: если фронт mclk попадает в окно смены,
                    // флаг может «обогнать» данные на такт, и процессор получит байт ПРЕДЫДУЩЕЙ
                    // транзакции. Приборно: 5-10 % чтений расширенных банков возвращали предыдущий
                    // байт, сбойные смещения плавали с шагом ~17 доступов (биение 100/56.667 МГц).
                    // С форсажем данных обе краевые ситуации безопасны: если mclk совпал со сменой
                    // ДАННЫХ - флаг ещё не менялся и импульс придёт позже; если совпал со сменой
                    // ФЛАГА - данные стоят уже 20 нс и оба триггера возьмут новое значение.
                    else begin rd_byte <= r_data[{byte_sel, 3'b000} +: 8]; st <= S_RDLY; end
                end
        S_RDLY: st <= S_RACK;                       // такт форсажа для данных
        S_RACK: begin
                    ack_tog_a <= ~ack_tog_a;
                    xact_cnt  <= xact_cnt + 16'd1;
                    st        <= S_IDLE;
                end
        S_AW:   begin
                    if (aw_ready) aw_valid <= 1'b0;
                    if (w_ready)  w_valid  <= 1'b0;
                    if ((aw_ready || !aw_valid) && (w_ready || !w_valid)) st <= S_B;
                end
        S_B:    if (b_valid) begin
                    if (src_arm) arm_busy  <= 1'b0;
                    else         ack_tog_a <= ~ack_tog_a;
                    xact_cnt  <= xact_cnt + 16'd1;
                    st        <= S_IDLE;
                end
        default: st <= S_IDLE;
        endcase
        end
    end
    assign idle_o = (st == S_IDLE);

    // ---- ответ: aclk -> mclk, и вся машинная сторона одним блоком ----
    (* ASYNC_REG="TRUE" *) reg [2:0] ack_s = 3'd0;
    (* ASYNC_REG="TRUE" *) reg [7:0] rb_s0 = 8'd0, rb_s1 = 8'd0;
    wire ack_pulse = ack_s[2] ^ ack_s[1];
    always @(posedge mclk) begin
        ack_s <= {ack_s[1:0], ack_tog_a};
        rb_s0 <= rd_byte;  rb_s1 <= rb_s0;      // данные стоят задолго до импульса подтверждения
        if (mrd | mwr) begin                    // запрос имеет приоритет над подтверждением
            req_addr_m  <= maddr;
            req_wdata_m <= mwdata;
            req_iswr_m  <= mwr;
            req_pend_m  <= 1'b1;                // B0074: САМ запрос - следующим тактом (см. ниже)
            mwait       <= 1'b1;                // держим процессор с того же такта, что и запрос
        end else if (req_pend_m) begin
            // Та же болезнь, что была на пути ответа, только в обратную сторону: адрес/данные и
            // тоггл запроса менялись ОДНОВРЕМЕННО, а на стороне aclk тоггл идёт через 3 триггера,
            // адрес/данные - через 2. Совпадение фронтов дало бы запись по ПРЕДЫДУЩЕМУ адресу или
            // предыдущим байтом. Отдаём тоггл на такт позже: к моменту его обнаружения адрес и
            // данные стоят неподвижно уже 17.6 нс.
            req_tog_m  <= ~req_tog_m;
            req_pend_m <= 1'b0;
        end else if (ack_pulse) begin
            // B0074: берём rd_byte НАПРЯМУЮ, а не с конца собственного конвейера rb_s0/rb_s1.
            // Так сделано в проверенном временем inject_cdc.v: полезная нагрузка ДЕРЖИТСЯ
            // неподвижно, а синхронизируется только флаг. Конвейер данных добавлял им задержку,
            // из-за которой у флага оставался всего один такт запаса - его и съедало совпадение
            // фронтов. Здесь rd_byte стоит уже ~3 такта mclk (два такта форсажа + путь флага).
            mrdata <= rd_byte;
            mwait  <= 1'b0;
        end
        if (mwait) wait_cnt <= wait_cnt + 16'd1;   // приборный счётчик простоя процессора
    end
endmodule
`default_nettype wire
