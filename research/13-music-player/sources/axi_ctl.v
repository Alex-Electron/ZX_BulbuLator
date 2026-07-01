`timescale 1ns/1ps
//-------------------------------------------------------------------------------------------------
// axi_ctl.v  -  BulbuLator Stage-1 control plane (AXI3 slave on Zynq-7010 M_AXI_GP0).
// Contact: lavrinovich.alex@gmail.com
//-------------------------------------------------------------------------------------------------
// The ARM (PS) reaches the Spectrum (PL) through this register file: HALT the Z80, write RAM,
// inject Z80 registers (T80 DIR vector) and machine ports (7FFD / border) -> load .sna/.z80.
//
// Register map (base = M_AXI_GP0 0x4000_0000), AXI3, 32-bit, single-beat:
//   0x00 VERSION   R   0xB01B0013
//   0x04 CONTROL   RW  bit0 HALT (1 = freeze the Z80; ARM owns the memory bus)
//   0x08 STATUS    R   bit0 HALT_ACK, bit1 RAM_BUSY
//   0x0C COUNTER   R   free-running aclk counter (liveness)
//   0x10 RAM_ADDR  RW  17-bit Spectrum RAM byte address; auto-increments after each RAM_DATA write
//   0x14 RAM_DATA  W   byte -> RAM[RAM_ADDR], RAM_ADDR++
//   0x18 SCRATCH   RW  spare
//   0x20..0x38 DIR0..DIR6  RW  the 212-bit T80 register-injection vector (7 words; DIR6 = top 20b)
//   0x3C PORT_7FFD RW  bits[5:0] = 128K paging port value
//   0x40 PORT_FE   RW  bits[2:0] = border
//   0x44 COMMIT    W   bit0 = PORT_COMMIT (apply 7FFD+border), bit1 = DIR_COMMIT (pulse DIRSet)
//   0x48 OSD_CTRL  RW  bit0 = OSD_ENABLE (show the toast overlay)
//   0x4C OSD_ADDR  RW  9-bit OSD-buffer word pointer; auto-increments after each OSD_DATA write
//   0x50 OSD_DATA  W   32 packed 1-bpp OSD pixels -> osd_buf[OSD_ADDR], OSD_ADDR++ (LUTRAM, no halt)
//   0x54 KBD_DATA  R   keyboard scancode FIFO head; [9]=release_flag (1=this byte is a break/release)
//                      [8]=empty [7:0]=code.
//                      A READ also POPS the FIFO (one entry per read). The ARM owns all hotkey/OSD
//                      policy -> no function key is decoded in fabric (portable across cores).
//   0x58 KBD_STAT  R   bit0 = FIFO empty (non-popping poll)
//   0x5C KBD_HB    W   any write = deadman heartbeat (keeps the keyboard gate open while ARM lives)
//   0x60 MACHINE_ID R  loaded-core identity for the ARM (here ZX 128K); lets one ARM image serve
//                      many machines: [15:0] machine code, [23:16] variant.
//   0x64 VGEOM     R   captured video geometry probe {frame_lines, vis_last, vis_first} (diagnostic)
//   0x68 OSD_BG    RW  OSD panel background colour (24-bit RGB)
//   0x6C OSD_OP    RW  OSD panel opacity alpha 0..255
//   0x70 OSD_POS   RW  OSD panel position {Y0[26:16], X0[10:0]}
//   0x74 VOL       W   HDMI output volume gain 0..255 (PCM * vol / 256; 255 ~= unity)
//   0x78 AUDIO_CTRL W  bit0 = player active (mux ARM PCM -> HDMI, mute the fabric audio)
//   0x7C AUDIO_FIFO W  push one signed-16 stereo sample {R[31:16], L[15:0]} into the audio FIFO
//   0x80 AUDIO_STAT R  bit0 = FIFO empty, bit1 = FIFO full
//   0x84 BANNER_CTRL W bit0 = independent status-banner overlay enable
//   0x88 BANNER_ADDR W banner LUTRAM word pointer; auto-increments after each BANNER_DATA write
//   0x8C BANNER_DATA W 32 packed 1-bpp banner pixels -> ban_buf[ptr], ptr++
//   0x90 BANNER_POS W  banner window position {Y0[26:16], X0[10:0]}
//
// Purely aclk (FCLK0). The crossing into the Spectrum clock (HALT level, RAM write strobe, the
// DIRSet pulse, the port-force pulses) lives in inject_cdc.v. The scancode FIFO crossing lives in
// the top (async_fifo, spclk write / aclk read).
//-------------------------------------------------------------------------------------------------
module axi_ctl #(
    parameter [31:0] VERSION    = 32'hB01B0013,
    parameter [31:0] MACHINE_ID = 32'h00805A58   // 'ZX' (0x5A58) + variant 0x80 (128K)
)(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [11:0] s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire        s_awvalid,
    output reg         s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output reg         s_wready,
    output reg  [11:0] s_bid,
    output reg  [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [11:0] s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [11:0] s_rid,
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ---- control-plane interface (aclk domain) ----
    output reg         ctl_halt,
    output reg         ctl_ram_we,        // 1-aclk pulse
    output reg  [16:0] ctl_ram_addr,      // running pointer (post-inc; for readback)
    output reg  [16:0] ctl_ram_waddr,     // this write's address (pre-inc; what the CDC latches)
    output reg  [7:0]  ctl_ram_data,
    output reg  [211:0] ctl_dir,          // Z80 register-injection vector
    output reg  [5:0]  ctl_7ffd,
    output reg  [2:0]  ctl_border,
    output reg         ctl_dir_commit,    // 1-aclk pulse
    output reg         ctl_port_commit,   // 1-aclk pulse
    output reg         ctl_reset,         // 1-aclk pulse: machine RESET+wipe (CONTROL bit2) - cold reset Z80 + all peripherals
    // ---- OSD overlay write port (aclk) ----
    output reg         ctl_osd_enable,
    output reg         ctl_osd_we,        // 1-aclk pulse
    output reg  [9:0]  ctl_osd_waddr,     // OSD buffer word address (1024 words; 256x128/32)
    output reg  [31:0] ctl_osd_wdata,
    output reg  [23:0] ctl_osd_bg,        // user-chosen OSD panel background colour (0x68)
    output reg  [7:0]  ctl_osd_op,        // OSD panel opacity alpha 0..255 (0x6C)
    output reg  [31:0] ctl_osd_pos,       // OSD panel position {Y0[26:16],X0[10:0]} (0x70)
    // ---- independent BANNER overlay write port (aclk) ----
    output reg         ctl_ban_enable,
    output reg         ctl_ban_we,        // 1-aclk pulse
    output reg  [8:0]  ctl_ban_waddr,     // banner buffer word address (512 words; 256x64/32)
    output reg  [31:0] ctl_ban_wdata,
    output reg  [31:0] ctl_ban_pos,       // banner position {Y0[26:16],X0[10:0]} (0x90)
    output reg  [7:0]  ctl_vol,           // HDMI volume gain 0..255 (PCM sample * vol / 256); 0x74
    output reg         ctl_player_en,     // 0x78 bit0: ARM audio player active (mux player PCM -> HDMI)
    output reg         ctl_audio_we,      // 1-aclk pulse: push ctl_audio_data into the audio FIFO (0x7C)
    output reg  [31:0] ctl_audio_data,    // {R[31:16], L[15:0]} signed-16 stereo sample
    input  wire        aud_full,          // audio FIFO status (read at 0x80)
    input  wire        aud_empty,
    input  wire [7:0]  aud_rdcount,
    // ---- keyboard scancode FIFO (control-plane tap; machine-agnostic) ----
    input  wire [8:0]  kbd_fifo_dout,     // {make, code[7:0]} FWFT head
    input  wire        kbd_fifo_empty,
    output reg         kbd_fifo_rd,       // 1-aclk pop pulse (on a completed KBD_DATA read)
    output reg         kbd_deadman_kick,  // 1-aclk pulse (on a KBD_HB write)
    input  wire        halt_ack,
    input  wire        ram_busy,
    input  wire        reset_busy,        // machine reset/wipe in progress (STATUS bit2; from inject_cdc)
    input  wire [31:0] cap_geom          // frame-geometry probe (read-only, 0x64)
);
    localparam IDX_VERSION = 6'h00, IDX_CONTROL = 6'h01, IDX_STATUS = 6'h02,
               IDX_COUNTER = 6'h03, IDX_RAMADDR = 6'h04, IDX_RAMDATA = 6'h05,
               IDX_SCRATCH = 6'h06,
               IDX_DIR0    = 6'h08, // 0x20..0x38 = DIR0..DIR6
               IDX_P7FFD   = 6'h0F, // 0x3C
               IDX_PFE     = 6'h10, // 0x40
               IDX_COMMIT  = 6'h11, // 0x44
               IDX_OSDCTRL = 6'h12, IDX_OSDADDR = 6'h13, IDX_OSDDATA = 6'h14, // 0x48/0x4C/0x50
               IDX_KBDDATA = 6'h15, IDX_KBDSTAT = 6'h16, IDX_KBDHB   = 6'h17, // 0x54/0x58/0x5C
               IDX_MACHID  = 6'h18,                                          // 0x60
               IDX_VGEOM   = 6'h19,                                          // 0x64 (frame geometry)
               IDX_OSDBG   = 6'h1A,                                          // 0x68 (OSD bg colour RGB)
               IDX_OSDOP   = 6'h1B,                                          // 0x6C (OSD opacity alpha)
               IDX_OSDPOS  = 6'h1C,                                          // 0x70 (OSD panel X0/Y0)
               IDX_VOL     = 6'h1D,                                          // 0x74 (HDMI volume gain 0..255)
               IDX_ACTL    = 6'h1E,                                          // 0x78 AUDIO_CTRL (bit0 player_en)
               IDX_AFIFO   = 6'h1F,                                          // 0x7C AUDIO_FIFO (W: push {R,L})
               IDX_ASTAT   = 6'h20,                                          // 0x80 AUDIO_STAT (R: full/empty/count)
               IDX_BANCTRL = 6'h21,                                          // 0x84 BANNER_CTRL (bit0 BANNER_ENABLE)
               IDX_BANADDR = 6'h22,                                          // 0x88 BANNER_ADDR (9-bit word ptr, auto-inc)
               IDX_BANDATA = 6'h23,                                          // 0x8C BANNER_DATA (W: 32 packed px)
               IDX_BANPOS  = 6'h24;                                          // 0x90 BANNER_POS ({Y0[26:16],X0[10:0]})

    reg [31:0] counter;
    reg [31:0] reg_scratch;
    reg [9:0]  osd_ptr;                 // running OSD-buffer word pointer (auto-inc, 1024 words)
    reg [8:0]  ban_ptr;                 // running banner-buffer word pointer (auto-inc, 512 words)
    always @(posedge aclk) counter <= aresetn ? counter + 32'd1 : 32'd0;

    //---------------------------------------------------------------------------------------------
    // Write channel.
    //---------------------------------------------------------------------------------------------
    localparam W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;
    reg [1:0]  wstate;
    reg [11:0] awid_q;
    reg [5:0]  awidx_q;

    always @(posedge aclk) begin
        ctl_ram_we       <= 1'b0;       // default: one-cycle pulses
        ctl_dir_commit   <= 1'b0;
        ctl_port_commit  <= 1'b0;
        ctl_reset        <= 1'b0;
        ctl_osd_we       <= 1'b0;
        ctl_ban_we       <= 1'b0;
        ctl_audio_we     <= 1'b0;
        kbd_deadman_kick <= 1'b0;
        if (!aresetn) begin
            wstate <= W_IDLE; s_awready <= 1'b0; s_wready <= 1'b0; s_bvalid <= 1'b0;
            s_bresp <= 2'b00; s_bid <= 12'd0;
            ctl_halt <= 1'b0; ctl_ram_addr <= 17'd0; ctl_ram_waddr <= 17'd0; ctl_ram_data <= 8'd0;
            ctl_dir <= 212'd0; ctl_7ffd <= 6'd0; ctl_border <= 3'd0; reg_scratch <= 32'd0;
            ctl_osd_enable <= 1'b0; osd_ptr <= 10'd0; ctl_osd_waddr <= 10'd0; ctl_osd_wdata <= 32'd0;
            ctl_osd_bg <= 24'h101840;   // default panel bg: dark blue (readable with cream ink)
            ctl_osd_op <= 8'd204;       // default opacity alpha ~80% (more dim/opaque)
            ctl_osd_pos <= 32'h00B00200;// default {Y0=176, X0=512}: upper-third centre
            ctl_ban_enable <= 1'b0; ban_ptr <= 9'd0; ctl_ban_waddr <= 9'd0; ctl_ban_wdata <= 32'd0;
            ctl_ban_pos <= 32'h02800200;// default {Y0=640, X0=512}: bottom-centre strip, clear of the OSD
            ctl_vol <= 8'd255;          // default full volume (unity gain)
            ctl_player_en <= 1'b0; ctl_audio_data <= 32'd0;
            kbd_deadman_kick <= 1'b0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    s_bvalid <= 1'b0; s_awready <= 1'b1;
                    if (s_awvalid && s_awready) begin
                        awid_q <= s_awid; awidx_q <= s_awaddr[7:2];
                        s_awready <= 1'b0; s_wready <= 1'b1; wstate <= W_DATA;
                    end
                end
                W_DATA: if (s_wvalid && s_wready) begin
                    case (awidx_q)
                        IDX_CONTROL: begin ctl_halt <= s_wdata[0]; ctl_reset <= s_wdata[2]; end  // bit2 = machine RESET+wipe pulse
                        IDX_RAMADDR: ctl_ram_addr <= s_wdata[16:0];
                        IDX_RAMDATA: begin
                            ctl_ram_data  <= s_wdata[7:0];
                            ctl_ram_we    <= 1'b1;
                            ctl_ram_waddr <= ctl_ram_addr;
                            ctl_ram_addr  <= ctl_ram_addr + 17'd1;
                        end
                        IDX_SCRATCH: reg_scratch <= s_wdata;
                        6'h08: ctl_dir[ 31:  0] <= s_wdata;          // DIR0
                        6'h09: ctl_dir[ 63: 32] <= s_wdata;          // DIR1
                        6'h0A: ctl_dir[ 95: 64] <= s_wdata;          // DIR2
                        6'h0B: ctl_dir[127: 96] <= s_wdata;          // DIR3
                        6'h0C: ctl_dir[159:128] <= s_wdata;          // DIR4
                        6'h0D: ctl_dir[191:160] <= s_wdata;          // DIR5
                        6'h0E: ctl_dir[211:192] <= s_wdata[19:0];    // DIR6 (top 20 bits)
                        IDX_P7FFD: ctl_7ffd   <= s_wdata[5:0];
                        IDX_PFE:   ctl_border <= s_wdata[2:0];
                        IDX_COMMIT: begin
                            ctl_port_commit <= s_wdata[0];
                            ctl_dir_commit  <= s_wdata[1];
                        end
                        IDX_OSDCTRL: ctl_osd_enable <= s_wdata[0];
                        IDX_OSDBG:   ctl_osd_bg     <= s_wdata[23:0];
                        IDX_OSDOP:   ctl_osd_op     <= s_wdata[7:0];
                        IDX_OSDPOS:  ctl_osd_pos    <= s_wdata;
                        IDX_VOL:     ctl_vol        <= s_wdata[7:0];
                        IDX_ACTL:    ctl_player_en  <= s_wdata[0];
                        IDX_AFIFO:   begin ctl_audio_data <= s_wdata; ctl_audio_we <= 1'b1; end
                        IDX_OSDADDR: osd_ptr        <= s_wdata[9:0];
                        IDX_OSDDATA: begin
                            ctl_osd_wdata <= s_wdata;
                            ctl_osd_we    <= 1'b1;
                            ctl_osd_waddr <= osd_ptr;
                            osd_ptr       <= osd_ptr + 10'd1;
                        end
                        IDX_BANCTRL: ctl_ban_enable <= s_wdata[0];
                        IDX_BANPOS:  ctl_ban_pos    <= s_wdata;
                        IDX_BANADDR: ban_ptr        <= s_wdata[8:0];
                        IDX_BANDATA: begin
                            ctl_ban_wdata <= s_wdata;
                            ctl_ban_we    <= 1'b1;
                            ctl_ban_waddr <= ban_ptr;
                            ban_ptr       <= ban_ptr + 9'd1;
                        end
                        IDX_KBDHB: kbd_deadman_kick <= 1'b1;   // heartbeat: keep the gate open
                        default: ;
                    endcase
                    if (s_wlast) begin
                        s_wready <= 1'b0; s_bid <= awid_q; s_bresp <= 2'b00;
                        s_bvalid <= 1'b1; wstate <= W_RESP;
                    end
                end
                W_RESP: if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; wstate <= W_IDLE; end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    //---------------------------------------------------------------------------------------------
    // Read channel.
    //---------------------------------------------------------------------------------------------
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;
    reg        rstate;
    reg [11:0] arid_q;
    reg [5:0]  aridx_q;

    always @(posedge aclk) begin
        kbd_fifo_rd <= 1'b0;           // default: one-cycle pop pulse (set on a completed KBD_DATA read)
        if (!aresetn) begin
            rstate <= R_IDLE; s_arready <= 1'b0; s_rvalid <= 1'b0;
            s_rresp <= 2'b00; s_rlast <= 1'b0; s_rdata <= 32'd0; s_rid <= 12'd0;
            kbd_fifo_rd <= 1'b0;
        end else case (rstate)
            R_IDLE: begin
                s_rvalid <= 1'b0; s_arready <= 1'b1;
                if (s_arvalid && s_arready) begin
                    arid_q <= s_arid; aridx_q <= s_araddr[7:2];
                    s_arready <= 1'b0; rstate <= R_DATA;
                end
            end
            R_DATA: begin
                s_rid <= arid_q; s_rresp <= 2'b00; s_rlast <= 1'b1;
                case (aridx_q)
                    IDX_VERSION: s_rdata <= VERSION;
                    IDX_CONTROL: s_rdata <= {31'd0, ctl_halt};
                    IDX_STATUS:  s_rdata <= {29'd0, reset_busy, ram_busy, halt_ack};  // bit2 reset_busy, bit1 ram_busy, bit0 halt_ack
                    IDX_COUNTER: s_rdata <= counter;
                    IDX_RAMADDR: s_rdata <= {15'd0, ctl_ram_addr};
                    IDX_SCRATCH: s_rdata <= reg_scratch;
                    IDX_OSDCTRL: s_rdata <= {31'd0, ctl_osd_enable};
                    IDX_OSDBG:   s_rdata <= {8'd0, ctl_osd_bg};
                    IDX_OSDOP:   s_rdata <= {24'd0, ctl_osd_op};
                    IDX_OSDPOS:  s_rdata <= ctl_osd_pos;
                    IDX_BANCTRL: s_rdata <= {31'd0, ctl_ban_enable};
                    IDX_BANPOS:  s_rdata <= ctl_ban_pos;
                    IDX_BANADDR: s_rdata <= {23'd0, ban_ptr};
                    IDX_VOL:     s_rdata <= {24'd0, ctl_vol};
                    IDX_ASTAT:   s_rdata <= {22'd0, aud_rdcount, aud_full, aud_empty};
                    IDX_OSDADDR: s_rdata <= {22'd0, osd_ptr};
                    IDX_KBDDATA: s_rdata <= {22'd0, kbd_fifo_dout[8], kbd_fifo_empty, kbd_fifo_dout[7:0]};
                    IDX_KBDSTAT: s_rdata <= {31'd0, kbd_fifo_empty};
                    IDX_MACHID:  s_rdata <= MACHINE_ID;
                    IDX_VGEOM:   s_rdata <= cap_geom;
                    default:     s_rdata <= 32'hDEADBEEF;
                endcase
                s_rvalid <= 1'b1;
                if (s_rvalid && s_rready) begin
                    s_rvalid <= 1'b0; s_rlast <= 1'b0; rstate <= R_IDLE;
                    if (aridx_q == IDX_KBDDATA) kbd_fifo_rd <= 1'b1;   // pop AFTER the ARM latched the head
                end
            end
            default: rstate <= R_IDLE;
        endcase
    end
endmodule
//-------------------------------------------------------------------------------------------------
