// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami System GX for MiSTer: the top. The board is rtl/gx_main.sv; this
// file is the MiSTer side of it -- clocks, the SDRAM image and its download,
// inputs, the OSD and the video output.
//
// Clocks (rtl/pll): clk_sys 96 MHz for the SDRAM controller, clk_vid 48 MHz
// for the board (the dot clock is 6 MHz, eight clocks a pixel) and clk_cpu
// 24 MHz for the 68EC020, all at phase 0 from one PLL, so the crossings
// between them are ordinary timed paths (gx_main.sv, gx_rom_port.sv).
//
// Sound: none yet (Phase 3). The K056800 mailbox is gx_snd_stub.sv.
//
// Not yet: EEPROM persistence (the 93C46 starts blank and the game
// initialises it).
//
// The instrumented revision (KonamiGX_stp, DEBUG_ISSP) carries one ISSP
// probe, read by scripts/read_issp.py: the layout is in the instance below
// and in scripts/read_issp.tcl, kept in step by hand.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign DDRAM_CLK = clk_sys;           // the fast ROM load's (gx_rom_loader, ddram_phy)

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// 288 x 224 visible
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"KonamiGX;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"-;",
	"R[0],Reset and close OSD;",
	// positional: bit 4 + i (Arcade-Seta_MiSTer's layout, LESSONS_LEARNED);
	// the .mra's <buttons> lists the same
	"J1,Button 1,Button 2,Button 3,-,-,-,Start,Coin,Pause,Service;",
	"jn,A,B,X,-,-,-,Start,Select,L,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [21:0] gamma_bus;

wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key()
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram_shifted, clk_vid, clk_cpu, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_vid),
	.outclk_3(clk_cpu),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The board waits for a ROM: index 0 streamed through ioctl and the download
// over, or the fast load's copy from DDR3 finished (gx_rom_loader).
// dl_index0_seen is the index-0 download starting, streamed or not: it ends
// the 93C46's blanking, which must stop before index 2 loads its image.
wire ldr_busy;
reg  rom_loaded = 1'b0, dl_index0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_busy_d = 1'b0;
reg  dl_active_d = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
wire dl_index0 = ioctl_download && ioctl_index == 16'd0;
always @(posedge clk_sys) begin
	ldr_busy_d  <= ldr_busy;
	dl_active_d <= dl_index0;
	ldr_start   <= 1'b0;
	if (dl_index0) dl_index0_seen <= 1'b1;
	if (dl_index0 && !dl_active_d)  begin dl_seen_wr <= 1'b0; ldr_done <= 1'b0; end
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;          // streamed: no copy
	if (dl_seen_wr && !ioctl_download) rom_loaded <= 1'b1;
	if (ldr_busy_d && !ldr_busy)       rom_loaded <= 1'b1;
	// Seta.sv's handshake: the copy starts on the reset release after an
	// index-0 download that streamed nothing, once
	if (reset) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_busy) begin
		ldr_pending <= 1'b0;
		if (dl_index0_seen && !dl_seen_wr && !ldr_done) begin ldr_start <= 1'b1; ldr_done <= 1'b1; end
	end
end

wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_busy;
wire mem_reset  = reset & ~ioctl_download;

// the .mra mod byte: which set (rtl/gx_board_cfg.sv)
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1) mod_byte <= ioctl_dout;

// reset into the board's clock, held long
reg [3:0] rst_sr = 4'hf;
always @(posedge clk_vid) rst_sr <= { rst_sr[2:0], core_reset };
wire rst_vid = |rst_sr;

// which ROM-load path ran, and how long the DDR3 copy took (probe K)
reg [25:0] ldr_cycles = 0;       // clk_sys cycles while copying
reg [25:0] dl_cycles  = 0;       // clk_sys cycles of the index-0 download
always @(posedge clk_sys) begin
	if (ldr_start) ldr_cycles <= 0;
	else if (ldr_busy) ldr_cycles <= ldr_cycles + 1'd1;
	if (dl_index0 && !dl_active_d) dl_cycles <= 0;
	else if (dl_index0) dl_cycles <= dl_cycles + 1'd1;
end

///////////////////////   MEMORY   ///////////////////////////////

wire [25:0] tile_base, obj_base;
wire [23:0] tile_size4, obj_size4;

// the fast load: DDR3 (0x30000000) to the download port as a byte stream
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid, ldr_wr, mem_wait;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire [26:0] ldr_addr;
wire  [7:0] ldr_dout;
ddram_phy u_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY,
	.DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
gx_rom_loader u_ldr (
	.clk(clk_sys), .reset(reset),
	// the stream ends where the sprite region's does: obj_base + 5/4 of its four-byte part
	.length({ 2'd0, obj_base + { 2'd0, obj_size4 } + { 4'd0, obj_size4[23:2] } }),
	.start(ldr_start), .busy(ldr_busy),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.wr(ldr_wr), .addr(ldr_addr), .dout(ldr_dout), .wait_in(mem_wait)
);
wire        m_download = ioctl_download | ldr_busy;
wire [15:0] m_index    = ldr_busy ? 16'd0    : ioctl_index;
wire        m_wr       = ldr_busy ? ldr_wr   : ioctl_wr;
wire [26:0] m_addr     = ldr_busy ? ldr_addr : ioctl_addr;
wire  [7:0] m_dout     = ldr_busy ? ldr_dout : ioctl_dout;
assign ioctl_wait = mem_wait;
wire signed [7:0] offs_x [4], offs_y [4];
wire  [3:0] primode;
wire        esc_gen;
wire  [9:0] obj_hadj;
wire [23:0] esc_src;
wire  [8:0] esc_count;
gx_board_cfg u_cfg ( .game(mod_byte), .tile_base, .obj_base, .tile_size4, .obj_size4, .offs_x, .offs_y, .primode,
                     .obj_hadj, .esc_gen, .esc_src, .esc_count );

wire        rom_cs, rom_ok, tile_rom_cs, tile_rom_ok, obj_rom_cs, obj_rom_ok;
wire [19:0] rom_addr;
wire [63:0] rom_data;
wire [23:0] tile_rom_addr;
wire [22:0] obj_rom_addr;
wire [39:0] tile_rom_data, obj_rom_data;

gx_sdram_top u_mem (
	.clk(clk_vid), .clk_mem(clk_sys), .reset(mem_reset), .init(~pll_locked),
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
	.SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK(),
	.ioctl_download(m_download), .ioctl_index(m_index), .ioctl_wr(m_wr), .ioctl_addr(m_addr),
	.ioctl_dout(m_dout), .ioctl_wait(mem_wait),
	.tile_base, .obj_base, .tile_size4, .obj_size4,
	.cpu_cs(rom_cs), .cpu_addr(rom_addr), .cpu_ok(rom_ok), .cpu_data(rom_data),
	// gx_tilemap's rom_addr is a row index and gx_obj's a half-row index (the
	// video benches' ROM models); each is one granule
	.tile_cs(tile_rom_cs), .tile_addr(tile_rom_addr[20:0]), .tile_ok(tile_rom_ok), .tile_data(tile_rom_data),
	.obj_cs(obj_rom_cs), .obj_addr(obj_rom_addr[19:0]), .obj_ok(obj_rom_ok), .obj_data(obj_rom_data)
);

///////////////////////   INPUTS   ///////////////////////////////
// konamigx.cpp INPUT_PORTS common, active low: a player's byte is
// left, right, up, down, B1, B2, B3, start from bit 0; P1 at 31:24, P2 at
// 23:16. joystick_N: right, left, down, up, then the J1 buttons at bit 4+i:
// B1 B2 B3 at 4-6, Start 10, Coin 11, Pause 12, Service 13.

function [7:0] player( input [31:0] j );
	player = ~{ j[10], j[6], j[5], j[4], j[3], j[2], j[0], j[1] };   // start, B3, B2, B1, down, up, right, left
endfunction

wire [31:0] inputs  = { player(joystick_0), player(joystick_1), 16'hffff };
// 0xd5a002: coins and service switches, active low, except bit 7: the gokuparo
// port set every set here uses declares SYSTEM_DSW bit 15 active HIGH, so it
// reads 0 (MAME reads 0xFEFF7FF7 idle; the bench gives the same). With it
// high Twin Bee Yahhoo! failed its EEPROM check on the board.
wire  [7:0] coins   = { 1'b0, ~{ 1'b0, 2'b00, 2'b00, joystick_1[11], joystick_0[11] } };  // bit 0 coin 1, bit 1 coin 2
wire  [7:0] service = ~{ 4'b0000, joystick_0[13] | joystick_1[13], 3'b000 };          // bit 3: the service switch

// The 93C46: blank (swept to all ones) from configuration until the ROM
// download starts, then the set's default image (ioctl index 2, the .mra's
// <rom index="2">: MAME's "eeprom" region, big-endian words, which most sets
// ship "to prevent game booting with error") loaded a word at a time. The
// board is in reset throughout. A later reset does not blank it, so the
// contents survive an OSD reset. ioctl_wr is a clk_sys pulse; the write
// enable is held two clk_sys cycles so the 48 MHz part sees it.
reg  [1:0] ee_we_s = 0;
reg  [5:0] ee_a;
reg  [7:0] ee_hi;
reg [15:0] ee_d;
always @(posedge clk_sys) begin
	ee_we_s <= { ee_we_s[0], 1'b0 };
	if (ioctl_wr && ioctl_index == 16'd2 && !ioctl_addr[24:7]) begin
		if (!ioctl_addr[0]) ee_hi <= ioctl_dout;
		else begin ee_we_s <= 2'b11; ee_a <= ioctl_addr[6:1]; ee_d <= { ee_hi, ioctl_dout }; end
	end
end
wire ee_we = |ee_we_s;
wire ee_blank = rst_vid & ~dl_index0_seen;

// <switches> (ioctl index 254): byte 0 = SW1 (0xd5a000), byte 1 = SW2
// (0xd5a001), as build_mra.py writes them from the driver's SYSTEM_DSW port
reg [7:0] sw[2];
initial begin sw[0] = 8'hfe; sw[1] = 8'hff; end       // common's defaults, until the .mra's arrive
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:1]) sw[ioctl_addr[0]] <= ioctl_dout;
wire [15:0] dsw = { sw[0], sw[1] };

///////////////////////   THE BOARD   ////////////////////////////

wire        snd_wr, snd_rd;
wire  [3:0] snd_addr;
wire  [7:0] snd_dout, snd_din;

wire [23:0] rgb, dbg_addr;
wire        vid_lhbl, vid_lvbl, vid_hs, vid_vs, pxl_cen, unsupported, dbg_access;
reg         lvbl_q = 1;
always @(posedge clk_vid) lvbl_q <= vid_lvbl;
gx_snd_stub u_snd ( .clk(clk_vid), .rst(rst_vid), .frame(lvbl_q & ~vid_lvbl),
                    .wr(snd_wr), .rd(snd_rd), .addr(snd_addr), .din(snd_dout), .dout(snd_din) );
wire [15:0] dbg_rom_hits, dbg_rom_misses;
wire [63:0] dbg_ee, dbg_irq;
wire [95:0] dbg_esc_st;
wire [95:0] dbg_obj;
wire [111:0] dbg_mix;
wire [ 1:0] dbg_esc;

gx_main u_board (
	.rst(rst_vid), .clk(clk_vid), .clk_cpu(clk_cpu),
	.rom_cs, .rom_addr, .rom_ok, .rom_data,
	.tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
	.obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data,
	.snd_wr, .snd_rd, .snd_addr, .snd_dout, .snd_din,
	.inputs, .coins, .dsw, .service,
	.ee_blank(ee_blank), .ee_load_we(ee_we), .ee_load_addr(ee_a), .ee_load_data(ee_d),
	.offs_x, .offs_y, .primode, .obj_hadj, .esc_gen, .esc_src, .esc_count,
	.rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .pxl_cen_o(pxl_cen), .unsupported,
	.dbg_addr(dbg_addr), .dbg_access(dbg_access), .dbg_we(), .dbg_be(), .dbg_data(),
	.dbg_ee(dbg_ee), .dbg_rom_hits(dbg_rom_hits), .dbg_rom_misses(dbg_rom_misses), .dbg_irq(dbg_irq), .dbg_esc(dbg_esc), .dbg_esc_st(dbg_esc_st), .dbg_obj(dbg_obj), .dbg_mix(dbg_mix)
);

///////////////////////   PROBES   ///////////////////////////////
// Instance F, 128 bits (scripts/read_issp.tcl decodes): counters of what the
// board is doing, cleared by source bit 0 and not by reset, so a rate can be
// taken after a clear.
`ifdef DEBUG_ISSP
wire [7:0] issp_src;
reg [15:0] c_frames = 0, c_access = 0, c_tile = 0, c_obj = 0;
reg [23:0] last_addr = 0;
reg        lvbl_d = 1;
always @(posedge clk_vid) begin
	lvbl_d <= vid_lvbl;
	if (issp_src[0]) begin
		c_frames <= 0; c_access <= 0; c_tile <= 0; c_obj <= 0;
	end else begin
		if (!vid_lvbl && lvbl_d) c_frames <= c_frames + 1'd1;
		if (dbg_access)          c_access <= c_access + 1'd1;
		if (tile_rom_ok)         c_tile   <= c_tile + 1'd1;
		if (obj_rom_ok)          c_obj    <= c_obj + 1'd1;
	end
	if (dbg_access) last_addr <= dbg_addr;
end
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp (
	.clk(clk_vid),
	.probe({ dbg_esc, ioctl_download, vid_lvbl, unsupported, rst_vid, rom_loaded, pll_locked,
	         c_obj, c_tile, dbg_rom_misses, dbg_rom_hits, last_addr, c_access, c_frames }),
	.source(issp_src)
);
// Instance G, 64 bits: the 93C46 -- [2:0] state, [3] locked, [9:4] sweep,
// [31:16] word 0, [47:32] word 1, [63:48] word 63 (gx_eeprom93c46 dbg;
// read_issp.tcl's fields_G)
issp_probe #(.INSTANCE_ID("G"), .PROBE_W(64), .SOURCE_W(8)) u_issp_ee (
	.clk(clk_vid), .probe(dbg_ee), .source()
);
// Instance H, 64 bits: the interrupts -- [11:0] [23:12] [35:24] [47:36] acks
// at levels 1-4, [55:48] wrport1_1, [58:56] ipl_n, [59] int1, [60] int2,
// [61] irq3, [62] irq4, [63] iack (gx_main dbg_irq; read_issp.tcl's fields_H)
issp_probe #(.INSTANCE_ID("H"), .PROBE_W(64), .SOURCE_W(8)) u_issp_irq (
	.clk(clk_vid), .probe(dbg_irq), .source()
);
// Instance I, 96 bits: the ESC -- [5:0] state, [28:6] m_addr[23:1], [52:29]
// set, [61:53] entry e, [62] busy, [63] m_req, [71:64] completions, [79:72]
// the CPU's SR high byte, [95:80] count2 (gx_main dbg_esc_st; fields_I)
// Instance J, 64 bits: the sprite DMA -- [11:0] DMA starts, [23:12] vblanks,
// [35:24] vblanks with DMAEN set, [47:40] OBJSET1 now, [55:48] at the last
// vblank, [63:56] at the last DMA start (gx_main dbg_obj; fields_J)
// [75:64] short lines (the sprite scan had not finished when the next
// line began), [87:76] short lines in the last whole frame, [95:88] sprite
// DMA starts while the ESC was busy
// Instance K, 64 bits: the ROM load -- [25:0] clk_sys cycles of the DDR3
// copy, [51:26] cycles of the index-0 download, [52] the download streamed
// bytes (the byte path ran), [53] the copy ran (fields_K)
// Instance L, 96 bits: what the game programs into the mixer -- [15:0]
// K055555 VINMIX, [31:16] VMIXON, [47:32] INPUT_ENABLES, [63:48] K054338
// alpha 1, [79:64] alpha 2, [95:80] control, [111:96] K056832 0x0a (fields_L)
issp_probe #(.INSTANCE_ID("L"), .PROBE_W(112), .SOURCE_W(8)) u_issp_mix (
	.clk(clk_vid), .probe(dbg_mix), .source()
);
issp_probe #(.INSTANCE_ID("K"), .PROBE_W(64), .SOURCE_W(8)) u_issp_ldr (
	.clk(clk_sys), .probe({ 10'd0, ldr_done, dl_seen_wr, dl_cycles, ldr_cycles }), .source()
);
issp_probe #(.INSTANCE_ID("J"), .PROBE_W(96), .SOURCE_W(8)) u_issp_obj (
	.clk(clk_vid), .probe(dbg_obj), .source()
);
issp_probe #(.INSTANCE_ID("I"), .PROBE_W(96), .SOURCE_W(8)) u_issp_esc (
	.clk(clk_vid), .probe(dbg_esc_st), .source()
);
`endif

///////////////////////   VIDEO   ////////////////////////////////

arcade_video #(.WIDTH(288), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_vid),
	.ce_pix(pxl_cen),
	.RGB_in(rgb),
	.HBlank(~vid_lhbl),
	.VBlank(~vid_lvbl),
	.HSync(vid_hs),
	.VSync(vid_vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),
	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

endmodule
