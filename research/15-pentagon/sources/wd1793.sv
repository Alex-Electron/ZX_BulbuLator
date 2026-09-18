// ====================================================================
// НАШ ЭКЗЕМПЛЯР (BulbuLator, B0075). Отличие от cores/zx-mister/rtl/wd1793.sv - ДВЕ строки:
// объявления `buff_wr` и `spt_addr` вынесены из generate-блоков в область модуля. В оригинале они
// объявлены внутри `generate if(RWMODE)` / `if(EDSK)`, а используются СНАРУЖИ: Quartus такое
// терпит, Vivado - нет (Synth 8-36 buff_wr is not declared). Поведение не меняется.
// Параметры у нас: RWMODE=1 (сектора подаёт хост), EDSK=0 - поддержка .EDSK стоит 4 плитки BRAM
// из 1.5 свободных (замер OOC: EDSK=1 -> 834 LUT / 4.5 плитки, EDSK=0 -> 524 LUT / 0.5 плитки),
// а для TRD/SCL она не нужна.
// ====================================================================

// ====================================================================
//
//  WD1793, WD1772, WD1773 replica (with write capability)
//
//  Copyright (C) 2007,2008 Viacheslav Slavinsky
//  Copyright (C) 2016 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module wd1793 #(parameter RWMODE=0, EDSK=1)
(
	input        clk_sys,     // sys clock
	input        ce,          // ce at CPU clock rate
	input        reset,	     // async reset
	input        io_en,
	input        rd,          // i/o read
	input        wr,          // i/o write
	input  [1:0] addr,        // i/o port addr
	input  [7:0] din,         // i/o data in
	output [7:0] dout,        // i/o data out
	output       drq,         // DMA request
	output       intrq,
	output       busy,

	input        wp,          // write protect

	input  [2:0] size_code,
	input        layout,      // 0 = Track-Side-Sector, 1 - Side-Track-Sector
	input        side,
	input        hlt,         // external head-load timing input from Beta Disk system register
	input        slow_disk,     // B0098: 1 = «как настоящий» темп байта (32 мкс), 0 = быстрый (4.6 мкс)
	input        ra_trk_to_sec, // B0095: класть байт дорожки в регистр сектора после Read Address.
	                            // Штатное поведение чипа и нужно загрузчику Elysium, НО на дорожке 0
	                            // делает регистр сектора нулём, а в смещении стоит `сектор - 1`.
	input        ready,

	// SD access (RWMODE == 1)
	input        img_mounted, // signaling that new image has been mounted
	input [19:0] img_size,    // size of image in bytes. 1MB MAX!
	output       prepare,
	// B0090: наружу то, что нужно для разбора ЗАПИСИ. Номер состояния сознательно не берём (enum,
	// лишний риск) - `data_length` отвечает на вопрос прямее: если он равен размеру сектора и
	// убывает, цикл байтов идёт; если ноль, команда закончилась после первого байта.
	output [15:0] dbg_io,
	output  [7:0] dbg_wrenb,   // B0092: сколько раз сработал wren_b с начала команды
	output [12:0] dbg_addr,    // B0093: {sd_block[1:0], byte_addr[10:0]} - КУДА пишет процессор
	output        cpu_wr_b,    // B0094: НАСТОЯЩИЙ сигнал записи процессора в буфер (не копия)
	output  [8:0] cpu_wr_a,    // B0094: адрес этой записи
	output  [7:0] cpu_wr_d,    // B0094: данные этой записи   // {data_length[10:0], s_drq, s_busy, s_lostdata, s_wrfault, 0}
	output[31:0] sd_lba,
	output reg   sd_rd,
	output reg   sd_wr,
	input        sd_ack,
	input  [8:0] sd_buff_addr,
	input  [7:0] sd_buff_dout,
	output [7:0] sd_buff_din,
	input        sd_buff_wr,

	// RAM access (RWMODE == 0)
	input        input_active,
	input [19:0] input_addr,
	input  [7:0] input_data,
	input        input_wr,
	output[19:0] buff_addr,	  // buffer RAM address
	output       buff_read,	  // buffer RAM read enable
	input  [7:0] buff_din     // buffer RAM data input
);

// Possible track configs:
// 0: 26 x 128  = 3.3KB
// 1: 16 x 256  = 4.0KB
// 2:  9 x 512  = 4.5KB
// 3:  5 x 1024 = 5.0KB
// 4: 10 x 512  = 5.0KB

assign dout      = q;
assign drq       = s_drq;
assign busy      = s_busy;
assign intrq     = s_intrq;
assign sd_lba    = scan_active ? scan_addr[19:9] : buff_a[19:9] + sd_block;
assign prepare   = EDSK ? scan_active : img_mounted;
assign buff_addr = {buff_a[19:9], 9'd0} + byte_addr;
assign buff_read = ((addr == A_DATA) && buff_rd);

reg   [7:0] sectors_per_track, edsk_spt = 0;
wire [10:0] sector_size = 11'd128 << wd_size_code;
reg  [10:0] byte_addr;
reg  [19:0] buff_a;
reg   [1:0] wd_size_code;

wire  [7:0] buff_dout;
reg   [1:0] sd_block = 0;
reg         format;
generate
	if(RWMODE) begin
		wd1793_dpram sbuf
		(
			.clock(clk_sys),

			.address_a({sd_block, sd_buff_addr}),
			.data_a(sd_buff_dout),
			.wren_a(sd_buff_wr & sd_ack),
			.q_a(sd_buff_din),

			.address_b(scan_active ? {2'b00, scan_addr[8:0]} : byte_addr),
			.data_b(format ? 8'd0 : din),
			.wren_b(wren_b_real),   // B0094: тот же провод, что уходит наружу - копий больше нет
			.q_b(buff_dout)
		);
	end else begin
		assign buff_dout   = 0;
		assign sd_buff_din = 0;
	end
endgenerate

reg         var_size  = 0;
reg  [19:0] disk_size;
reg         layout_r;
wire [19:0] hs  = (layout_r & side) ? disk_size >> 1 : 20'd0;
wire  [7:0] dts = {disk_track[6:0], side} >> layout_r;
always @(posedge clk_sys) begin
	case({var_size,size_code})
				0: buff_a <= hs + {{1'b0, dts, 4'b0000} + {dts, 3'b000} + {dts, 1'b0} + wdreg_sector - 1'd1,  7'd0};
				1: buff_a <= hs + {{dts, 4'b0000}                                     + wdreg_sector - 1'd1,  8'd0};
				2: buff_a <= hs + {{dts, 3'b000}  + dts                               + wdreg_sector - 1'd1,  9'd0};
				3: buff_a <= hs + {{dts, 2'b00}   + dts                               + wdreg_sector - 1'd1, 10'd0};
				4: buff_a <= hs + {{dts, 3'b000}  +{dts, 1'b0}                        + wdreg_sector - 1'd1,  9'd0};
		default: buff_a <= edsk_offset;
	endcase
	case({var_size,size_code})
				0: sectors_per_track <= 26;
				1: sectors_per_track <= 16;
				2: sectors_per_track <= 9;
				3: sectors_per_track <= 5;
				4: sectors_per_track <= 10;
		default: sectors_per_track <= edsk_spt;
	endcase
	case({var_size,size_code})
				0: wd_size_code <= 0;
				1: wd_size_code <= 1;
				2: wd_size_code <= 2;
				3: wd_size_code <= 3;
				4: wd_size_code <= 2;
		default: wd_size_code <= edsk_sizecode;
	endcase
end

reg   [1:0] blk_size;
always @* begin
	case(wd_size_code)
		0: blk_size = 0;
		1: blk_size = 0;
		2: blk_size = buff_a[8:0] ? 2'd1 : 2'd0;
		3: blk_size = buff_a[8:0] ? 2'd2 : 2'd1;
	endcase
end


// Register addresses
localparam A_COMMAND         = 0;
localparam A_STATUS          = 0;
localparam A_TRACK           = 1;
localparam A_SECTOR          = 2;
localparam A_DATA            = 3;

// States
typedef enum 
{
	STATE_IDLE,

	STATE_SEARCH,
	STATE_SEARCH_1,

	STATE_WAIT_READ,
	STATE_WAIT_READ_1,
	STATE_WAIT_READ_2,

	STATE_READ,
	STATE_READ_1,
	STATE_READ_2,
	STATE_READ_3,

	STATE_WAIT_WRITE,
	STATE_WAIT_WRITE_1,
	STATE_WAIT_WRITE_2,

	STATE_WRITE,
	STATE_WRITE_1,
	STATE_WRITE_2,

	STATE_RT_NEXT,          // B0111: следующее поле дорожки для READ TRACK
	STATE_ABORT,
	STATE_WAIT,
	STATE_WAIT_2,
	STATE_ENDCOMMAND
} io_state_t;


// common status bits
reg         buff_wr;      // ПРАВКА: было внутри generate if(RWMODE), а используется снаружи
reg  [7:0]  spt_addr;     // ПРАВКА: было внутри generate if(EDSK)
wire        s_readonly = (wp | !RWMODE);
reg			s_crcerr;
reg			s_headloaded, s_seekerr, s_index;  // mode 1
reg			s_lostdata, s_wrfault; 			     // mode 2,3

// Command mode 0/1 for status register
reg 			cmd_mode;

// allow write protect flag
reg 			s_wpe;

// DRQ/BUSY are always going together
reg	[1:0]	s_drq_busy;
wire			s_drq  = s_drq_busy[1];
wire			s_busy = s_drq_busy[0];
reg         s_intrq;

reg   [7:0] wdreg_track;
reg   [7:0] wdreg_sector;
reg   [7:0] wdreg_data;
wire  [7:0] wdreg_status = cmd_mode == 0 ?
	{~ready, s_readonly & s_wpe, s_headloaded, s_seekerr | ~ready, s_crcerr, !disk_track, s_index, s_busy}:
	{~ready, s_readonly & s_wpe, s_wrfault,    s_seekerr | ~ready, s_crcerr, s_lostdata,  s_drq,   s_busy};

reg   [7:0] read_addr[6];
/* B0111 READ TRACK (команда 0xE). Раньше её не было в диспетчере вовсе: контроллер не становился
   занятым и данных не отдавал, поэтому быстрый загрузчик Z-Player честно печатал UNKNOWN DISK
   FORMAT. Отдать дорожку через буфер нельзя - он 2 КБ, а дорожка MFM около 6250 байт, и счётчик
   `data_length` всего 11 бит. Поэтому дорожка СИНТЕЗИРУЕТСЯ ПОФАЗНО: промежуток, синхро, метки,
   поля адреса с CRC, снова синхро, метка данных, 256 байт ИЗ БУФЕРА (их подаёт ARM штатной
   выборкой сектора) и CRC данных. Каждое поле считается своим `data_length`, поэтому 11 бит
   хватает с запасом, а механизм DRQ и сторожевого таймера остаётся прежним. */
reg         rt_active = 1'b0;   // идёт READ TRACK
reg   [3:0] rt_phase;           // какое поле дорожки отдаём
reg   [7:0] rt_sec;             // текущий сектор
reg   [7:0] rt_val;             // байт-константа текущего поля
reg         rt_const = 1'b0;    // источник байта - константа, а не буфер и не поля адреса
reg  [15:0] rt_crc;             // бегущий CRC поля данных
localparam [3:0] RT_GAP1=0, RT_SYNC1=1, RT_A1ID=2, RT_FE=3, RT_ID=4,
                 RT_GAP2=5, RT_SYNC2=6, RT_A1DA=7, RT_FB=8, RT_DATA=9,
                 RT_CRC=10, RT_GAP3=11, RT_TAIL=12;
reg   [7:0] q;
always @* begin
	case (addr)
		A_STATUS: q = wdreg_status;
		A_TRACK:  q = wdreg_track;
		A_SECTOR: q = wdreg_sector;
		A_DATA:   q = (state == STATE_IDLE) ? wdreg_data :
		              rt_const                ? rt_val :
		              buff_rd                 ? (RWMODE ? buff_dout : buff_din) :
		                                        read_addr[byte_addr[2:0]];
	endcase
end

reg         buff_rd;
// WD1793 READ ADDRESS has a register side effect in addition to returning the
// six-byte ID field: after the transfer, the ID track byte is copied into the
// Sector Register.  Elysium State's custom trackloader relies on this.
reg         read_address_active;
reg         step_direction; // last step direction
reg  [15:0] read_address_crc;

// CRC-16/CCITT used by the WD1793 for an ID field. The three missing A1 sync
// bytes and the FE address mark are part of the CRC stream, followed by C/H/R/N.
function automatic [15:0] crc16_byte;
	input [15:0] crc_in;
	input [7:0] data_in;
	integer ci;
	reg [15:0] crc;
	begin
		crc = crc_in ^ {data_in, 8'h00};
		for(ci = 0; ci < 8; ci = ci + 1)
			crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
		crc16_byte = crc;
	end
endfunction

function automatic [15:0] id_crc;
	input [7:0] c;
	input [7:0] h;
	input [7:0] r;
	input [7:0] n;
	reg [15:0] crc;
	begin
		crc = 16'hFFFF;
		crc = crc16_byte(crc, 8'hA1);
		crc = crc16_byte(crc, 8'hA1);
		crc = crc16_byte(crc, 8'hA1);
		crc = crc16_byte(crc, 8'hFE);
		crc = crc16_byte(crc, c);
		crc = crc16_byte(crc, h);
		crc = crc16_byte(crc, r);
		crc = crc16_byte(crc, n);
		id_crc = crc;
	end
endfunction

reg   [7:0] disk_track;		 // "real" heads position
reg  [10:0]	data_length;	 // this many bytes to transfer during read/write ops
// B0090: наружу для кольца BDI. Только сигналы УРОВНЯ МОДУЛЯ: write_data / read_data / sd_busy
// объявлены ВНУТРИ always-блока и снаружи не видны - та же причина, по которой buff_wr и
// spt_addr в этом файле пришлось выносить из блоков (см. шапку). data_length + DRQ/BUSY/lost/
// fault отвечают на главный вопрос: идёт ли цикл байтов и не сработал ли lost data.
assign dbg_io = {data_length, s_drq, s_busy, s_lostdata, s_wrfault, buff_wr};

// B0092: факт вместо рассуждения - считаем СРАБАТЫВАНИЯ записи процессора в буфер.
// Обнуляем на записи команды, чтобы число относилось к текущей операции.
wire wren_b_real  = wre & buff_wr & (addr == A_DATA) & ~scan_active;
wire wren_b_probe = wren_b_real;
assign cpu_wr_b = wren_b_real;
assign cpu_wr_a = byte_addr[8:0];
assign cpu_wr_d = format ? 8'd0 : din;
reg  [7:0] wrenb_cnt = 8'd0;
reg        wren_b_d  = 1'b0;
reg        wre_probe_d = 1'b0;
always @(posedge clk_sys) begin
	wren_b_d <= wren_b_probe;
	wre_probe_d <= wre;
	if(!wre_probe_d && wre && (addr == A_COMMAND)) wrenb_cnt <= 8'd0;
	else if(wren_b_probe && !wren_b_d && (wrenb_cnt != 8'hFF)) wrenb_cnt <= wrenb_cnt + 8'd1;
end
assign dbg_wrenb = wrenb_cnt;
assign dbg_addr  = {sd_block, byte_addr};   // B0093: адрес процессора и добавка порта хоста
io_state_t  state = STATE_IDLE;

// A 5.25" DD disk rotates at 300 rpm: one revolution is 200 ms. A TR-DOS track
// has 16 ID fields, hence the next ID marker arrives every 12.5 ms. Index and
// ID events come from this one phase model; the previous independent 10 ms
// index timer described a physically impossible disk.
// B0098: было 43750 такта CE = 200 мс на оборот (физически верно для 300 об/мин), но софт,
// ждущий индексные импульсы, из-за этого шёл в 20 раз медленнее эталона MiSTer, и CAT выглядел
// зависшим. Секторы у нас подаёт ARM из файла - физика оборота нам не нужна. 2187 такта = 10 мс,
// как в эталоне.
localparam [18:0] ROT_ID_PERIOD_CE = 19'd2187;  // 10 мс на оборот (эталон MiSTer)
localparam [11:0] INDEX_WIDTH_CE   = 12'd3500;  // 1 ms active index pulse
reg [18:0] rot_id_timer = ROT_ID_PERIOD_CE - 1'b1;
reg  [7:0] rot_id_sector = 8'd1;
reg  [7:0] rot_sec_shadow = 8'd0;   // B0095: слежение за регистром сектора процессора
reg [11:0] index_timer = 12'd0;
wire       rot_id_pulse = ce && ready && (rot_id_timer == 0);

always @* begin
	read_address_crc = id_crc(disk_track, {7'b0, side}, rot_id_sector,
	                          {6'b0, wd_size_code});
end

always @(posedge clk_sys) begin
	if(reset || !ready) begin
		rot_id_timer  <= ROT_ID_PERIOD_CE - 1'b1;
		rot_id_sector <= 8'd1;
		rot_sec_shadow <= 8'd0;
		index_timer   <= 12'd0;
		s_index       <= 1'b0;
	end else if(ce) begin
		// B0095 КАК В ЭТАЛОНЕ: процессор записью регистра сектора задаёт номер, который
		// вернётся в ответе на Read Address. Дальше номер вращается, как и раньше.
		// Один драйвер: предустановка живёт в ЭТОМ же блоке (в блоке портов был бы второй).
		if(wdreg_sector != rot_sec_shadow) begin
			rot_sec_shadow <= wdreg_sector;
			rot_id_sector  <= wdreg_sector;
			rot_id_timer   <= ROT_ID_PERIOD_CE - 1'b1;
		end else
		if(index_timer != 0) begin
			index_timer <= index_timer - 1'b1;
			s_index <= 1'b1;
		end else begin
			s_index <= 1'b0;
		end
		if(rot_id_timer == 0) begin
			rot_id_timer <= ROT_ID_PERIOD_CE - 1'b1;
			if(rot_id_sector >= sectors_per_track) begin
				rot_id_sector <= 8'd1;
				index_timer <= INDEX_WIDTH_CE;
			end else begin
				rot_id_sector <= rot_id_sector + 1'b1;
			end
		end else begin
			rot_id_timer <= rot_id_timer - 1'b1;
		end
	end
end

// Reusable expressions
wire  [7:0] next_track  = (din[6] ? din[5] : step_direction) ? disk_track - 1'd1 : disk_track + 1'd1;
wire [10:0]	next_length = data_length - 1'b1;

// Watchdog
reg         watchdog_set;
wire        watchdog_bark = (wd_timer == 0);
reg  [15:0] wd_timer;
always @(posedge clk_sys) begin
	if(ce) begin
		// ~8 ms lost-data window. The old 4096 clocks (~1.17 ms) was too short for
		// RAM-resident trackloaders that poll #FF between effect frames.
		if(watchdog_set) wd_timer <= 16'd28000;
			else if(wd_timer != 0) wd_timer <= wd_timer - 1'b1;
	end
end

wire        rde = rd & io_en;
wire        wre = wr & io_en;
always @(posedge clk_sys) begin
	reg old_wr, old_rd;

	reg [2:0] cur_addr;
	reg       read_data;
	reg       write_data;
	reg       rw_type;
	integer   wait_time;
	reg [7:0] read_timer;
	reg [9:0] seektimer;
	reg       multisector;
	reg       write;
	reg [5:0] ack;
	reg       sd_busy;
	reg       old_mounted;
	reg [3:0] scan_state;
	reg [1:0] scan_cnt;
	reg [1:0] blk_max;

	if(RWMODE) begin
		old_mounted <= img_mounted;
		if(old_mounted && ~img_mounted) begin
			if(EDSK) begin
				scan_active<= 1;
				scan_addr  <= 0;
				scan_state <= 0;
				scan_wr    <= 0;
				sd_block   <= 0;
			end
			disk_size <= img_size[19:0];
			layout_r  <= layout;
		end
	end else begin
		scan_active <= input_active;
		scan_addr   <= input_addr;
		scan_wr     <= input_wr;
		if(scan_active & ~input_active) begin
			disk_size <= input_addr + 1'd1;
			layout_r  <= layout;
		end
	end

	if(reset & ~scan_active) begin
		read_data <= 0;
		write_data <= 0;
		multisector <= 0;
		step_direction <= 0;
		disk_track <= 0;
		wdreg_track <= 0;
		wdreg_sector <= 0;
		wdreg_data <= 0;
		data_length <= 0;
		byte_addr <=0;
		buff_rd <= 0;
		read_address_active <= 0;
		if(RWMODE) buff_wr <= 0;
		rt_active <= 1'b0; rt_const <= 1'b0;     // B0111
		state <= STATE_IDLE;
		cmd_mode <= 0;
		s_wpe <= 1;
		{s_headloaded, s_seekerr, s_crcerr, s_intrq} <= 0;
		{s_wrfault, s_lostdata} <= 0;
		s_drq_busy <= 0;
		watchdog_set <= 0;
		seektimer <= 'h3FF;
		{ack, sd_wr, sd_rd, sd_busy} <= 0;
	end else if(ce) begin

		// HLT is the board head-load timing input. Raise head-loaded when HLT is
		// high; do not force it low every clock or Type-I command H bits are lost.
		if (hlt)
			s_headloaded <= 1'b1;

		ack <= {ack[4:0], sd_ack};
		if(ack[5:4] == 'b01) {sd_rd,sd_wr} <= 0;
		if(ack[5:4] == 'b10) sd_busy <= 0;

		if(RWMODE & scan_active) begin
			if(scan_addr >= img_size) scan_active <= 0;
			else begin
				case(scan_state)
					0:	begin
							sd_rd   <= 1;
							sd_busy <= 1;
							scan_wr <= 0;
							scan_state <= 1;
						end
					1: if(!sd_busy) begin
							scan_wr    <= 1;
							scan_cnt   <= 1;
							scan_state <= 2;
						end
					2: begin
							scan_cnt <= scan_cnt + 1'd1;
							if(!scan_cnt) begin
								scan_wr <= ~scan_wr;
								if(scan_wr) begin
									scan_addr <= scan_addr + 1'b1;
									if(&scan_addr[8:0]) begin
										scan_active <= var_size;
										scan_state  <= 0;
									end
								end
							end
						end
				endcase
			end
		end

		old_wr <=wre;
		old_rd <=rde;

		if((!old_rd && rde) || (!old_wr && wre)) cur_addr <= addr;

		//Register read operations
		if(old_rd && !rde && (cur_addr == A_STATUS)) s_intrq <= 0;

		//end of data reading
		if(old_rd && !rde && (cur_addr == A_DATA)) read_data <=1;

		//end of data writing
		if(old_wr && !wre && (cur_addr == A_DATA)) write_data <=1;

		case (state)
			/* Idle state or buffer to host transfer */
			STATE_IDLE:; // do nothing

			STATE_SEARCH:
				begin
					if(!ready) begin
						s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end else if(read_address_active && !var_size) begin
						// READ ADDRESS does not search for Sector Register.  It
						// waits for the next physical ID field under the head.
						if(rot_id_pulse) begin
							read_addr[0] <= disk_track;
							read_addr[1] <= {7'b0, side};
							read_addr[2] <= rot_id_sector;
							read_addr[3] <= wd_size_code;
							read_addr[4] <= read_address_crc[15:8];
							read_addr[5] <= read_address_crc[7:0];
							byte_addr    <= 0;
							data_length  <= 6;
							state        <= STATE_READ;
						end
					end else begin
						seektimer <= seektimer - 1'b1;
						if(!seektimer) begin
							byte_addr <= 0;
							if(var_size) begin
								if(~format) edsk_addr <= edsk_start;
								if(EDSK) spt_addr  <= (side ? spt_size>>1 : 8'd0) + disk_track;
								state     <= STATE_SEARCH_1;
							end else begin
								if(!wdreg_sector || (wdreg_sector > sectors_per_track)) begin
									if(~format) s_seekerr <= 1;
									state <= STATE_ENDCOMMAND;
								end else begin
									state <= rw_type ? STATE_WAIT_READ : STATE_READ;
								end
							end
						end
					end
				end
			STATE_SEARCH_1:
				begin
					if(rw_type & (edsk_track == disk_track) &
									 (edsk_side == side) &
									 (format | (edsk_sector == wdreg_sector))) begin
						state <= STATE_WAIT_READ;
					end
					else
					if(~rw_type & (edsk_track == disk_track) &
									  (edsk_side == side)) begin
						read_addr[0] <= edsk_trackf;
						read_addr[1] <= edsk_sidef;
						read_addr[2] <= edsk_sector;
						read_addr[3] <= edsk_sizecode;
						state        <= STATE_READ;
					end
					else
					if(edsk_next == edsk_start) begin
						if(~format) s_seekerr <= 1;
						state <= STATE_ENDCOMMAND;
					end
					else
					begin
						edsk_addr <= edsk_next;
					end
				end
			// read before write in case if sector not aligned or smaller than 512b
			STATE_WAIT_READ:
				begin
					data_length <= sector_size;
					byte_addr   <= buff_a[8:0];
					blk_max     <= blk_size;
					sd_block    <= 0;
					state       <= RWMODE ? STATE_WAIT_READ_1 : write ? STATE_WRITE : STATE_READ;
				end
			STATE_WAIT_READ_1:
				begin
					sd_busy <= 1;
					sd_rd   <= 1;
					state   <= STATE_WAIT_READ_2;
				end
			STATE_WAIT_READ_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						state <= write ? STATE_WRITE : STATE_READ;
						if(sd_block < blk_max) state <= STATE_WAIT_READ_1;
					end
				end

			STATE_READ:
				begin
					watchdog_set <= 1;
					// B0098: быстро по умолчанию (эталон MiSTer ~15), «как настоящий» - по опции.
					// Медленный темп когда-то поставили из-за трек-загрузчиков в ОЗУ, которые
					// теряли байты; опция сохраняет эту возможность, не замедляя всё остальное.
					read_timer <= slow_disk ? 8'd112 : 8'd16;
					state <= STATE_READ_1;
				end
			STATE_READ_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						read_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_READ_2;
					end
				end
			STATE_READ_2:
				begin
					if(watchdog_bark | (read_data & s_drq)) begin
						// reset drq until next byte is read, nothing is lost
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						/* B0111: CRC поля данных считаем по мере отдачи байтов */
						if(rt_active && rt_phase == RT_DATA)
							rt_crc <= crc16_byte(rt_crc, RWMODE ? buff_dout : buff_din);
						if(next_length == 0 && rt_active) begin
							if(rt_phase == RT_GAP3) begin
								if(rt_sec >= sectors_per_track) begin
									rt_phase <= RT_TAIL; state <= STATE_RT_NEXT;
								end else begin
									rt_sec <= rt_sec + 8'd1; rt_phase <= RT_GAP1; state <= STATE_RT_NEXT;
								end
							end else if(rt_phase == RT_TAIL) begin
								rt_active <= 0; rt_const <= 0; state <= STATE_ENDCOMMAND;
							end else begin
								rt_phase <= rt_phase + 4'd1; state <= STATE_RT_NEXT;
							end
						end else if(next_length == 0) begin
							// READ ADDRESS completion: the real WD1793 writes the
							// track address from the ID field into Sector Register.
							// The imported MiSTer model omitted this side effect,
							// leaving a stale sector number and making custom
							// trackloaders fail intermittently.
							if(read_address_active) begin
								if(ra_trk_to_sec) wdreg_sector <= read_addr[0];   // B0095: по опции
								read_address_active <= 0;
							end
							// either read the next sector, or stop if this is track end
							if(multisector) begin
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end else begin
							byte_addr <= byte_addr + 1'd1;
							data_length <= next_length;
							state <= STATE_READ;
						end
					end
				end

			STATE_WAIT_WRITE:
				begin
					if(!ready) begin
						s_wrfault <= 1;
						state <= STATE_ENDCOMMAND;
					end else begin
						sd_block <= 0;
						state <= STATE_WAIT_WRITE_1;
					end
				end
			STATE_WAIT_WRITE_1:
				begin
					sd_busy <= 1;
					sd_wr   <= 1;
					state   <= STATE_WAIT_WRITE_2;
				end
			STATE_WAIT_WRITE_2:
				begin
					if(!sd_busy) begin
						sd_block <= sd_block + 1'd1;
						if(sd_block < blk_max) state <= STATE_WAIT_WRITE_1;
						else begin
							if(format && var_size && !edsk_next) begin
								state <= STATE_ENDCOMMAND;
							end else if(multisector) begin
								edsk_addr <= edsk_next;
								wdreg_sector <= wdreg_sector + 1'b1;
								state <= STATE_SEARCH;
							end else begin
								state <= STATE_ENDCOMMAND;
							end
						end
					end
				end
			STATE_WRITE:
				begin
					watchdog_set <= 1;
					read_timer <= slow_disk ? 8'd112 : 8'd16;   // B0098: см. STATE_READ
					state <= STATE_WRITE_1;
				end
			STATE_WRITE_1:
				begin
					read_timer <= read_timer - 1'b1;
					if(!read_timer) begin
						write_data <= 0;
						watchdog_set <= 0;
						s_lostdata <= 0;
						s_drq_busy <= 2'b11;
						state <= STATE_WRITE_2;
					end
				end
			STATE_WRITE_2:
				begin
					if(watchdog_bark | (write_data & s_drq)) begin
						s_drq_busy <= 2'b01;
						s_lostdata <= watchdog_bark;

						if(!next_length) state <= STATE_WAIT_WRITE;
						else begin
							byte_addr <= byte_addr + 1'd1;
							data_length <= next_length;
							state <= STATE_WRITE;
						end
					end
				end

			// Abort current operation ($D0)
			/* B0111: подготовить следующее поле дорожки. Поля адреса кладём в тот же массив
			   read_addr, который уже обслуживает READ ADDRESS: путь чтения у него готов. */
			STATE_RT_NEXT:
				begin
					byte_addr <= 0;
					rt_const  <= 1;
					buff_rd   <= 0;
					case (rt_phase)
						RT_GAP1:  begin rt_val <= 8'h4E; data_length <= 12; state <= STATE_READ; end
						RT_SYNC1: begin rt_val <= 8'h00; data_length <= 12; state <= STATE_READ; end
						RT_A1ID:  begin rt_val <= 8'hA1; data_length <= 3;  state <= STATE_READ; end
						RT_FE:    begin rt_val <= 8'hFE; data_length <= 1;  state <= STATE_READ; end
						RT_ID:
							begin
								rt_const     <= 0;
								read_addr[0] <= disk_track;
								read_addr[1] <= {7'b0, side};
								read_addr[2] <= rt_sec;
								read_addr[3] <= wd_size_code;
								read_addr[4] <= id_crc(disk_track, {7'b0, side}, rt_sec, wd_size_code) >> 8;
								read_addr[5] <= id_crc(disk_track, {7'b0, side}, rt_sec, wd_size_code);
								data_length  <= 6;
								state        <= STATE_READ;
							end
						RT_GAP2:  begin rt_val <= 8'h4E; data_length <= 12; state <= STATE_READ; end
						RT_SYNC2: begin rt_val <= 8'h00; data_length <= 12; state <= STATE_READ; end
						RT_A1DA:  begin rt_val <= 8'hA1; data_length <= 3;  state <= STATE_READ; end
						RT_FB:
							begin
								rt_val <= 8'hFB; data_length <= 1;
								rt_crc <= crc16_byte(crc16_byte(crc16_byte(crc16_byte(16'hFFFF,
											8'hA1), 8'hA1), 8'hA1), 8'hFB);
								state  <= STATE_READ;
							end
						RT_DATA:
							begin
								/* данные сектора берёт штатная выборка: она наполнит буфер и сама
								   выставит data_length и byte_addr */
								rt_const     <= 0;
								buff_rd      <= 1;          /* байты идут ИЗ БУФЕРА сектора */
								wdreg_sector <= rt_sec;
								state        <= STATE_SEARCH;
							end
						RT_CRC:
							begin
								read_addr[0] <= rt_crc[15:8];
								read_addr[1] <= rt_crc[7:0];
								rt_const     <= 0;
								buff_rd      <= 0;
								data_length  <= 2;
								state        <= STATE_READ;
							end
						RT_GAP3:  begin rt_val <= 8'h4E; data_length <= 12; state <= STATE_READ; end
						default:  begin rt_val <= 8'h4E; data_length <= 16; state <= STATE_READ; end
					endcase
				end

			STATE_ABORT:
				begin
					{sd_rd, sd_wr, sd_busy} <= 0;   // B0098: см. STATE_ENDCOMMAND
					data_length <= 0;
					{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
					state <= STATE_ENDCOMMAND;
				end

			STATE_WAIT:
				begin
					wait_time <= 4000;
					state <= STATE_WAIT_2;
				end
			STATE_WAIT_2:
				begin
					if(wait_time) wait_time <= wait_time - 1;
						else state <= STATE_ENDCOMMAND;
				end

			// End any command.
			STATE_ENDCOMMAND:
				begin
					// 🥇 B0098: снять запросы к хосту и занятость. Без этого «фантомный» sd_wr
					// переживает конец команды (Force Interrupt от TR-DOS принимается в ЛЮБОМ
					// состоянии), а sd_lba берётся живым - и запись уходит по ЧУЖОМУ адресу.
					{sd_rd, sd_wr, sd_busy} <= 0;
					read_address_active <= 0;
					format  <= 0;
					buff_rd <= 0;
					if(RWMODE) buff_wr <=0;
					state <= STATE_IDLE;
					s_drq_busy <= 2'b00;
					seektimer <= 'h3FF;
					s_intrq <= 1;
				end
		endcase

		/* Register write operations */
		if (!old_wr & wre) begin
			case (addr)
				A_COMMAND:
					begin
						s_intrq <= 0;
						if((state == STATE_IDLE) | (din[7:4] == 'hD)) begin
							read_address_active <= 0;
							cmd_mode <= din[7];
							s_wpe    <= ~din[7];
							case (din[7:4])
							'h0: 	// RESTORE
								begin
									// head load as specified, index, track0
									s_headloaded <= din[3] | hlt;
									wdreg_track <= 0;
									disk_track <= 0;

									// some programs like it when FDC gets busy for a while
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h1:	// SEEK
								begin
									// set real track to datareg
									disk_track <= wdreg_data;
									s_headloaded <= din[3] | hlt;

									// get busy
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h2,	// STEP
							'h3,	// STEP & UPDATE
							'h4,	// STEP-IN
							'h5,	// STEP-IN & UPDATE
							'h6,	// STEP-OUT
							'h7:	// STEP-OUT & UPDATE
								begin
									// if direction is specified, store it for the next time
									if (din[6] == 1) step_direction <= din[5]; // 0: forward/in

									// perform step
									disk_track <= next_track;

									// update TRACK register too if asked to
									if (din[4]) wdreg_track <= next_track;

									s_headloaded <= din[3] | hlt;

									// some programs like it when FDC gets busy for a while
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							'h8, 'h9, // READ SECTORS
							'hA, 'hB: // WRITE SECTORS
								begin
									// seek data
									// 5: 0: read, 1: write
									// 4: m: 0: one sector, 1: until the track ends
									// 3: S: SIDE
									// 2: E: some 15ms delay
									// 1: C: check side matching?
									// 0: 0

									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= din[5] ? 2'b10 : 2'b01;
									if(RWMODE) buff_wr <= din[5];

									if(din[6]) wdreg_sector <= 1;

									format      <= din[6];
									multisector <= din[4];
									rw_type     <= 1;
									write_data  <= 0;
									read_data   <= 0;
									edsk_start  <= 0;
									edsk_addr   <= 0;
									state       <= STATE_SEARCH;
									s_wpe       <= din[5];

									if(s_readonly & din[5]) begin
										s_wrfault <= 1;
										state <= STATE_WAIT;
									end
								end
							'hC:	// READ ADDRESS
								begin
									// track, side, sector, sector size code, 2-byte checksum (crc?)
									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= 0;
									if(RWMODE) buff_wr <=0;

									format      <= 0;
									multisector <= 0;
									rw_type     <= 0;
									read_data   <= 0;
									edsk_start  <= edsk_next;
									data_length <= 6;
									read_address_active <= 1;

									state <= STATE_SEARCH;
								end
							'hE:	// READ TRACK (B0111)
								begin
									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;
									{write,buff_rd} <= 2'b00;
									if(RWMODE) buff_wr <= 0;
									format      <= 0;
									multisector <= 0;
									rw_type     <= 1;
									read_data   <= 0;
									read_address_active <= 0;
									rt_active   <= 1;
									rt_sec      <= 1;
									rt_phase    <= RT_GAP1;
									state       <= STATE_RT_NEXT;
								end
							'hD:	// interrupt
								begin
									cmd_mode <= 0;
									// B0099: бит I3 = «прервать НЕМЕДЛЕННО» обязан поднять INTRQ.
									// Без этого TR-DOS 5.03 на повторном CAT ждёт INTRQ вечно: запись
									// команды его снимает, а простаивающий контроллер не поднимает.
									// Найдено кольцом BDI на живой машине (команда 0xDF, PC=0x3D9C).
									if(din[3]) s_intrq <= 1;
									if(state != STATE_IDLE) state <= STATE_ABORT;
										else {s_wrfault,s_seekerr,s_crcerr,s_lostdata, s_drq_busy} <= 0;
								end
							'hF:  // WRITE TRACK = ФОРМАТИРОВАНИЕ ДОРОЖКИ (B0149)
								begin
									// 🥇 Было заглушкой (как и в живом апстриме MiSTer): команда только
									// поднимала состояние, данных не писала. TR-DOS обнуляет каталог
									// именно этой командой, поэтому FORMAT менял лишь метку в служебном
									// секторе - жалоба владельца 21.08.
									// Ниже - тот же путь, что у записи секторов, с флагом `format`:
									// в буфер идут НУЛИ вместо потока формата (в образе TRD промежутки
									// и метки не хранятся), сектор начинается с первого, идентификатор
									// принимается любой, а `multisector` ведёт до конца дорожки.
									s_drq_busy <= 2'b01;
									{s_wrfault,s_seekerr,s_crcerr,s_lostdata} <= 0;

									{write,buff_rd} <= 2'b10;      // как у записи: буфер отдаём машине
									if(RWMODE) buff_wr <= 1'b1;

									wdreg_sector <= 1;             // дорожка пишется с первого сектора
									format       <= 1'b1;          // нули вместо байтов процессора
									multisector  <= 1'b1;          // до конца дорожки
									rw_type      <= 1;
									write_data   <= 0;
									read_data    <= 0;
									edsk_start   <= 0;
									edsk_addr    <= 0;
									state        <= STATE_SEARCH;
									s_wpe        <= din[5];

									if(s_readonly) begin           // защита записи - отказ, а не тишина
										s_wrfault <= 1;
										state <= STATE_WAIT;
									end
								end
							'hE:	// READ TRACK
								begin
									{s_wrfault,s_crcerr,s_lostdata} <= 0;
									s_seekerr  <= 1;
									s_drq_busy <= 2'b01;
									state <= STATE_WAIT;
								end
							endcase
						end
					end

				A_TRACK:  if (!s_busy) wdreg_track <= din;
				A_SECTOR: if (!s_busy) wdreg_sector <= din;
				A_DATA:   wdreg_data <= din;
			endcase
		end
	end
end

reg        scan_active = 0;
reg [19:0] scan_addr;
reg        scan_wr;

reg  [1:0] edsk_sizecode = 0;      // sector size: 0=128K, 1=256K, 2=512K, 3=1024K
reg        edsk_side = 0;          // Side number (0 or 1)
reg  [6:0] edsk_track = 0;         // Track number
reg  [7:0] edsk_sector = 0;        // Sector number 0..15
reg [19:0] edsk_offset = 0;
reg  [7:0] edsk_trackf = 0, edsk_sidef = 0;

reg [10:0] edsk_addr, edsk_start;

reg [10:0] edsk_size = 0;
wire[10:0] edsk_next = ((edsk_addr + 1'd1) >= edsk_size) ? 11'd0 : edsk_addr + 1'd1;

reg  [7:0] spt_size = 0;

generate
	if(EDSK) begin
		wire [7:0] scan_data = RWMODE ? buff_dout : input_data;
		reg [53:0] edsk[1992];
		reg  [7:0] spt[166];

		always @(posedge clk_sys) begin
			{edsk_track,edsk_side,edsk_trackf,edsk_sidef,edsk_sector,edsk_sizecode,edsk_offset} <= edsk[edsk_addr];
			edsk_spt <= spt[spt_addr];
		end

		reg  [7:0] tpos;
		reg  [7:0] tsize;
		reg  [7:0] tsizes[166];
		always @(posedge clk_sys) tsize <= tsizes[tpos];

		wire[127:0] edsk_sig = "EXTENDED CPC DSK";
		wire[127:0] sig_pos  = edsk_sig >> (8'd120-(scan_addr[7:0]<<3));

		always @(posedge clk_sys) begin
			reg old_active, old_wr;
			reg [13:0] hdr_pos, bcnt;
			reg  [7:0] idStatus;
			reg  [6:0] track;
			reg        side;
			reg  [7:0] sector;
			reg  [1:0] sizecode;
			reg  [7:0] crc1;
			reg  [7:0] crc2;
			reg  [7:0] sectors;
			reg [15:0] track_size, track_pos;
			reg [19:0] offset, offset1;
			reg  [7:0] size_lo;
			reg [10:0] secpos;
			reg  [7:0] trackf, sidef;

			old_active <= scan_active;
			if(scan_active & ~old_active) begin
				edsk_size <=0;
				spt_size  <=0;
				track_pos <=0;
				var_size  <=1;
			end

			old_wr <= scan_wr;
			if(scan_wr & ~old_wr & scan_active) begin
				if((scan_addr[19:0] < 16) & (sig_pos[7:0] != scan_data)) var_size <= 0;
				if(var_size) begin
					if( scan_addr == 48) spt_size <= scan_data; else
					if((scan_addr == 49) & (scan_data == 2)) spt_size <= spt_size << 1; else
					if( scan_addr == 52) begin
						track_size <= {scan_data, 8'd0};
						track_pos  <= 0;
						tpos <= 1;
					end else
					if((scan_addr  > 52) & (scan_addr < 218)) begin
						tsizes[scan_addr - 52] <= scan_data;
						spt[scan_addr - 52] <= 0;
					end else
					if((scan_addr >= 256) && track_size) begin
						track_pos <= track_pos + 1'd1;
						case(track_pos)
							00: offset  <= scan_addr + 9'd256;
							16: track   <= scan_data[6:0];
							17: side    <= scan_data[0];
							21: sectors <= scan_data;
							22: spt[(side ? (spt_size >> 1) : 8'd0) + track] <= sectors;
							default:
								if((track_pos >= 24) && sectors) begin
									case(track_pos[2:0])
										0: begin
												trackf  <= scan_data;
												secpos  <= edsk_size;
												offset1 <= offset;
											end
										1: sidef   <= scan_data;
										2: sector  <= scan_data;
										3: sizecode<= scan_data[1:0];
										6: size_lo <= scan_data;
										7: begin
												if({scan_data, size_lo}) begin
													edsk[secpos] <= {track,side,trackf,sidef,sector,sizecode,offset1};
													edsk_size <= edsk_size + 1'd1;
													offset <= offset + {scan_data, size_lo};
												end
												sectors <= sectors - 1'd1;
											end
										default:;
									endcase
								end
						endcase
						if(track_pos >= (track_size - 1'd1)) begin
							track_size <= {tsize, 8'd0};
							track_pos  <= 0;
							tpos <= tpos + 1'd1;
						end
					end
				end
			end
		end
	end
endgenerate

endmodule

module wd1793_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=11)
(
	input	                     clock,

	input	     [ADDRWIDTH-1:0] address_a,
	input	     [DATAWIDTH-1:0] data_a,
	input	                     wren_a,
	output reg [DATAWIDTH-1:0] q_a,

	input	     [ADDRWIDTH-1:0] address_b,
	input	     [DATAWIDTH-1:0] data_b,
	input	                     wren_b,
	output reg [DATAWIDTH-1:0] q_b
);

logic [DATAWIDTH-1:0] ram[0:(1<<ADDRWIDTH)-1];

always_ff@(posedge clock) begin
	if(wren_a) begin
		ram[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram[address_a];
	end
end

always_ff@(posedge clock) begin
	if(wren_b) begin
		ram[address_b] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram[address_b];
	end
end

endmodule
