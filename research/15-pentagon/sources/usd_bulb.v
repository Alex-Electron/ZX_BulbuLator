//-------------------------------------------------------------------------------------------------
// usd_bulb.v - порт SPI-карты машины: DivMMC (#E7/#EB) И Z-Controller (#77/#57) на ОДНОМ движке.
//
// B0143: Переключаемый SPI-движок:
//        turbo = 1: Turbo 28.33 МГц (spclk 56.667 МГц, 282 нс на байт - мгновенный обмен без WAIT).
//        turbo = 0: Standard 3.5 МГц (ne7M0).
//        Порт #57 (Z-Controller) считывает результат текущей команды сразу.
//        Порт #EB (DivMMC) сохраняет конвейерную задержку (md) для esxDOS.
//        Порт #77 на чтение отдает признак карты в Active-Low полярности ({7b0, ~sd_cd}).
//-------------------------------------------------------------------------------------------------
module usd_bulb
(
	input  wire      clock,
	input  wire      cep,
	input  wire      cen,
	input  wire      turbo,     // 1 = Turbo 28.33 MHz, 0 = Standard 3.5 MHz (cen)

	input  wire      en_dm,     // DivMMC включён: живут порты #E7/#EB
	input  wire      en_zc,     // Z-Controller включён: живут порты #77/#57
	input  wire      sd_cd,     // 1 = карта вставлена (для чтения #77)

	input  wire      iorq,
	input  wire      wr,
	input  wire      rd,
	input  wire[7:0] d,
	output wire[7:0] q,
	input  wire[7:0] a,

	output reg       cs,
	output wire      ck,
	input  wire      miso,
	output wire      mosi,
	output wire      zc_sel
);

wire p_e7 = en_dm && (a == 8'hE7);
wire p_eb = en_dm && (a == 8'hEB);
wire p_77 = en_zc && (a == 8'h77);
wire p_57 = en_zc && (a == 8'h57);

// Выбор карты. У DivMMC он прямой (бит0), у Z-Controller - составной (cs <= d[1] | ~d[0]).
initial cs = 1'b1;
always @(posedge clock) begin
	if(!iorq && !wr && p_e7) cs <= d[0];
	if(!iorq && !wr && p_77) cs <= d[1] | ~d[0];
end

wire iotx = !iorq && !wr && (p_eb || p_57);
wire iorx = !iorq && !rd && (p_eb || p_57);

reg tx, dtx;
reg rx, drx;

/* 🥇 СТАРТОВЫЙ ИМПУЛЬС ЖИВЁТ РОВНО ОДИН ПЕРИОД РАЗРЕШЕНИЯ, А НЕ ОДИН ТАКТ spclk.
   B0142 снял с этого блока гейт `if(cep)`, а блок сдвига остался под `cen` (B0143 вернул ему
   `if(spi_tick)`). В стандартном режиме 3.5 МГц `cen` приходит раз в восемь тактов, поэтому
   однотактовый `tx` в разрешающий такт просто не попадал: движок не выдавал НИ ОДНОГО фронта `ck`
   (проверено симуляцией - ckedges = 0), то есть опция «Standard SPI» была мёртвой с B0142.
   Возвращаем импульсу медленный гейт: в turbo он остаётся однотактовым (spi_tick = 1), в
   стандартном режиме держится от `cep` до следующего `cep` и гарантированно захватывается
   блоком сдвига на промежуточном `cen`. */
wire spi_tick = turbo ? 1'b1 : cen;
wire spi_arm  = turbo ? 1'b1 : cep;

always @(posedge clock) if(spi_arm) begin
	tx <= 1'b0;
	dtx <= iotx;
	if(iotx && !dtx) tx <= 1'b1;

	rx <= 1'b0;
	drx <= iorx;
	if(iorx && !drx) rx <= 1'b1;
end

reg [7:0] md = 8'hFF;
reg [7:0] sd = 8'hFF;
reg [4:0] count = 5'b10000;

always @(posedge clock) if(spi_tick) begin
	if(count[4]) begin
		if(tx || rx) begin
			md    <= sd;
			sd    <= tx ? d : 8'hFF;
			count <= 5'd0;
		end
	end else begin
		if(count[0]) sd <= { sd[6:0], miso };
		count <= count + 5'd1;
	end
end

assign ck = count[0];
assign mosi = sd[7];

// Признак активности шины для Z-Controller (#77 и #57)
assign zc_sel = !iorq && !rd && (p_77 || p_57);

// Для DivMMC (#EB) отдаем md (конвейер с задержкой на 1 байт).
// Для Z-Controller (#57) отдаем sd, если передача завершена, иначе md.
// Для Z-Controller (#77) отдаем статус карты (0 = вставлена).
assign q = p_eb ? md :
           p_77 ? {7'b0000000, ~sd_cd} :
           p_57 ? (count[4] ? sd : md) :
           8'hFF;

endmodule
