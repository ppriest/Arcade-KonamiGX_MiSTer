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
// Sound: the sound board (gx_sound): the 68000 running the game's sound
// program, two K054539s and the TMS57002, behind the K056800 mailbox.
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
// DDR3 has two masters: the ROM loader while a game loads, the rotator
// after. They never overlap -- the core is in reset with no picture while
// the load runs -- so the mux is on ldr_busy (at the bottom of this file).
// MISTER_FB is defined in both .qsf revisions for the rotator; its forced
// blank is unused.
assign FB_FORCE_BLANK = 0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// the sound board's output (gx_sound): signed, stereo
wire [15:0] snd_aud_l, snd_aud_r;
assign AUDIO_S = 1;
assign AUDIO_L = snd_aud_l;
assign AUDIO_R = snd_aud_r;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = rot_sel != 2'd0;
wire       rotate_ccw = rot_sel == 2'd2;
wire       flip_180   = status[65];

// 288 x 224 visible, on a 4:3 screen -- 3:4 when it is turned on its side
wire [11:0] base_arx = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary = rotate_en ? 12'd4 : 12'd3;
assign VIDEO_ARX = (!ar) ? base_arx : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? base_ary : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	// SS: four save-state slots of 1 MB in DDR3 from 0x3C000000 (rtl/gx_ss_ddr.sv)
	"KonamiGX;SS3C000000:100000;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	// HDMI only: the analog output keeps the native raster either way. Every
	// GX set is horizontal, so there is no per-set default to follow -- this
	// is for a rotated monitor, not for the game.
	"O[64:63],Rotation,Off,CW,CCW;",
	"O[65],Flip 180,Off,On;",
	// analog 15 kHz (rtl/video/gx_crt_chain.sv); HDMI follows it while On.
	// H2: the settings, shown while CRT Adjust is On
	"O[75],CRT Adjust,Off,On;",
	"H2O[82:76],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[88:83],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[93:89],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[97:94],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[98],CRT V-Size Mode,PVM,Cabinet;",
	// le2's guns (H1: shown for the gun sets): MAME's crosshair where each
	// gun points; the left stick per player -- Auto moves a pushed-full axis
	// as the d-pad does (arcade sticks on gamepad encoders), Aim is always
	// absolute (light guns), D-pad moves on any deflection; the mouse aims
	// for one player (rtl/gx_guns.sv)
	"H1O[68],Crosshair,Off,On;",
	"H1O[70:69],P1 stick,Auto,Aim,D-pad;",
	"H1O[72:71],P2 stick,Auto,Aim,D-pad;",
	"H1O[74:73],Mouse aims,P1,P2,Off;",
	"-;",
	// save states (docs/SAVESTATES.md): the slot, and save/restore it
	"O[100:99],Save state slot,1,2,3,4;",
	"R[101],Save state;",
	"R[102],Restore state;",
	"-;",
	"DIP;",
	"-;",
	"R[0],Reset and close OSD;",
	// positional: bit 4 + i (Arcade-Seta_MiSTer's layout, LESSONS_LEARNED);
	// the .mra's <buttons> lists the same
	// le2: button 1 is the trigger, button 2 a reload (a shot off the screen)
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,Start,Coin,Pause,Service;",
	"jn,A,B,X,-,-,-,Start,Select,L,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [21:0] gamma_bus;

wire [31:0] joystick_0, joystick_1;
wire [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire [24:0] ps2_mouse;
wire [31:0] gun_h, gun_v;               // gx_guns, below
wire  [1:0] gun_trig;
wire        guns;                       // the set has le2's guns (gx_board_cfg)

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire        ioctl_upload;
wire [15:0] ee_rd_data;                 // the NVRAM save (below, with the EEPROM load)
wire        ee_written;
reg         nv_dirty = 1'b0, nv_save = 1'b0, osd_d = 1'b0;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({ 13'd0, ~status[75], ~guns, 1'b0 }),   // H1: the gun options; H2: CRT Adjust's

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	// the .mra's <nvram index="4">: the EEPROM, uploaded when nv_save rises
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_addr[0] ? ee_rd_data[7:0] : ee_rd_data[15:8]),
	.ioctl_rd(),

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
// and then while gx_snd_clear zeroes the sound board's RAMs (below)
wire clr_busy;
wire rst_vid = |rst_sr | clr_busy;

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
wire [23:0] tile_size4, obj_size4, snd_pcm;

// the fast load: DDR3 (0x30000000) to the download port as a byte stream
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid, ldr_wr, mem_wait;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire [26:0] ldr_addr;
wire  [7:0] ldr_dout;
// its side of the DDR3 mux at the bottom of this file
wire  [7:0] ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire [63:0] ldr_DDRAM_DIN;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
ddram_phy u_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
gx_rom_loader u_ldr (
	.clk(clk_sys), .reset(reset),
	// the stream ends after the sound board's ROMs: snd_base (where the
	// sprite spread ends) + the sound program's 0x40000 + the samples'
	// 0x400000 (build_mra's SND_CPU and SND_PCM)
	.length({ 2'd0, obj_base + { 1'b0, obj_size4, 1'b0 } + 26'h040000 + { 2'd0, snd_pcm } }),
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
wire  [1:0] tile_bpp, obj_layout;
wire  [1:0] obj_pri_raw;
wire  [9:0] vis_x0;
wire  [8:0] vis_w;
wire        esc_gen, esc_copy, prot4, esc_sal2, tile_rb66, orient_fy, fj_dma;
wire  [9:0] obj_hadj;
wire [23:0] esc_src;
wire  [8:0] esc_count;
gx_board_cfg u_cfg ( .clk(clk_sys), .game(mod_byte), .tile_base, .obj_base, .tile_size4, .obj_size4, .snd_pcm, .offs_x, .offs_y, .primode, .tile_bpp, .obj_layout, .obj_pri_raw, .vis_x0, .vis_w,
                     .obj_hadj, .esc_gen, .esc_src, .esc_count, .esc_copy, .prot4, .esc_sal2, .tile_rb66, .guns, .orient_fy, .fj_dma );

wire        rom_cs, rom_ok, tile_rom_cs, tile_rom_ok, obj_rom_cs, obj_rom_ok;
wire [19:0] rom_addr;
wire [63:0] rom_data;
wire [23:0] tile_rom_addr;
wire [22:0] obj_rom_addr, obj_pf_addr;
// the sound board's SDRAM client (gx_sound, below)
wire        snd_cs, snd_ok, snd_inval, snd_wreq, snd_wbusy;
// gx_sound's own, before gx_snd_clear's are muxed in
wire        s_inval, s_wreq, s_we16, x_inval_s, p_inval_s;
wire [25:0] s_waddr;
wire [15:0] s_wdata;
wire [22:0] snd_maddr;
wire [63:0] snd_mdata;
wire [25:0] snd_waddr;
wire [15:0] snd_wdata;
wire        snd_we16;
// the DSP's RAM (gx_tms57002 through gx_sound)
wire        dsp_cs, dsp_ok, dsp_inval;
// the K054539s' voices' sample reads (gx_sound)
wire        pcm_cs, pcm_ok, pcm_inval;
wire [20:0] pcm_addr;
wire [63:0] pcm_data;
wire [14:0] dsp_addr;
wire [63:0] dsp_data;
wire        gfx_cs, gfx_ok;
wire [22:0] gfx_addr;
wire [63:0] gfx_data;
wire        obj_pf_cs;
wire [63:0] tile_rom_data, obj_rom_data;

gx_sdram_top u_mem (
	.clk(clk_vid), .clk_mem(clk_sys), .reset(mem_reset), .init(~pll_locked),
	.SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
	.SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK(),
	.ioctl_download(m_download), .ioctl_index(m_index), .ioctl_wr(m_wr), .ioctl_addr(m_addr),
	.ioctl_dout(m_dout), .ioctl_wait(mem_wait),
	.tile_base, .obj_base, .tile_size4, .obj_size4, .snd_pcm, .tile_bpp, .obj_layout,
	.cpu_cs(rom_cs), .cpu_addr(rom_addr), .cpu_ok(rom_ok), .cpu_data(rom_data),
	// gx_tilemap's rom_addr is a row index and gx_obj's a half-row index (the
	// video benches' ROM models); each is one granule
	.tile_cs(tile_rom_cs), .tile_addr(tile_rom_addr[20:0]), .tile_ok(tile_rom_ok), .tile_data(tile_rom_data),
	.obj_cs(obj_rom_cs), .obj_addr(obj_rom_addr[21:0]), .obj_ok(obj_rom_ok), .obj_data(obj_rom_data),
	.obj_pf_cs(obj_pf_cs), .obj_pf_addr(obj_pf_addr[21:0]),
	.gfx_cs, .gfx_addr, .gfx_ok, .gfx_data,
	.snd_cs, .snd_addr(snd_maddr), .snd_ok, .snd_data(snd_mdata), .snd_inval,
	.snd_wreq, .snd_waddr, .snd_wdata, .snd_we16, .snd_wbusy,
	.dsp_cs, .dsp_addr, .dsp_ok, .dsp_data, .dsp_inval,
	.pcm_cs, .pcm_addr, .pcm_ok, .pcm_data, .pcm_inval
);

///////////////////////   INPUTS   ///////////////////////////////
// konamigx.cpp INPUT_PORTS common, active low: a player's byte is
// left, right, up, down, B1, B2, B3, start from bit 0; P1 at 31:24, P2 at
// 23:16. joystick_N: right, left, down, up, then the J1 buttons at bit 4+i:
// B1 B2 B3 at 4-6, Start 10, Coin 11, Pause 12, Service 13.

function [7:0] player( input [31:0] j );
	// MAME bit 2 is up and bit 3 down; MiSTer's joystick bit 3 is up and 2
	// down (it had them the other way round: up and down were swapped)
	player = ~{ j[10], j[6], j[5], j[4], j[2], j[3], j[0], j[1] };   // start, B3, B2, B1, down, up, right, left
endfunction

// the low half is players 3 and 4 on the common port; dragoonj puts buttons
// 4-6 there (player 1 at bits 12-14, player 2 at 8-10), from joystick bits
// 7-9. Unpressed they read 1, as the 3/4-player inputs no set here uses.
wire [31:0] inputs  = { player(joystick_0), player(joystick_1),
                        1'b1, ~joystick_0[9], ~joystick_0[8], ~joystick_0[7],
                        1'b1, ~joystick_1[9], ~joystick_1[8], ~joystick_1[7], 8'hff };
// 0xd5a002: coins and service switches, active low, except bit 7: the gokuparo
// port set every set here uses declares SYSTEM_DSW bit 15 active HIGH, so it
// reads 0 (MAME reads 0xFEFF7FF7 idle; the bench gives the same). With it
// high Twin Bee Yahhoo! failed its EEPROM check on the board.
wire  [7:0] coins   = { 1'b0, ~{ 1'b0, 2'b00, 2'b00, joystick_1[11], joystick_0[11] } };  // bit 0 coin 1, bit 1 coin 2
// bit 3: the service switch; bit 2: le2's player 1 trigger (SERVICE 0x04000000)
wire  [7:0] service = ~{ 4'b0000, joystick_0[13] | joystick_1[13], guns & gun_trig[0], 2'b00 };

// The 93C46: blank (swept to all ones) from configuration until the ROM
// download starts, then the set's default image (ioctl index 2, the .mra's
// <rom index="2">: MAME's "eeprom" region, big-endian words, which most sets
// ship "to prevent game booting with error") loaded a word at a time. The
// board is in reset throughout. A later reset does not blank it, so the
// contents survive an OSD reset. The saved EEPROM, the .mra's <nvram
// index="4">, arrives the same way after the ROM and overwrites the default.
// ioctl_wr is a clk_sys pulse; the write enable is held two clk_sys cycles so
// the 48 MHz part sees it.
reg  [1:0] ee_we_s = 0;
reg  [5:0] ee_a;
reg  [7:0] ee_hi;
reg [15:0] ee_d;
always @(posedge clk_sys) begin
	ee_we_s <= { ee_we_s[0], 1'b0 };
	if (ioctl_wr && (ioctl_index == 16'd2 || ioctl_index == 16'd4) && !ioctl_addr[24:7]) begin
		if (!ioctl_addr[0]) ee_hi <= ioctl_dout;
		else begin ee_we_s <= 2'b11; ee_a <= ioctl_addr[6:1]; ee_d <= { ee_hi, ioctl_dout }; end
	end
end
wire ee_we = |ee_we_s;
wire ee_blank = rst_vid & ~dl_index0_seen;

// NVRAM save: the HPS reads the EEPROM back into the .mra's <nvram> file
// (config/nvram) when asked, which is when the OSD opens after the game has
// written it -- Arcade-JalecoMS32_MiSTer's shape. The upload reads
// ioctl_addr's byte, big-endian words as the load. ee_written is a clk_vid
// pulse, two clk_sys cycles.
always @(posedge clk_sys) begin
	osd_d   <= OSD_STATUS;
	nv_save <= 1'b0;
	if (ee_written) nv_dirty <= 1'b1;
	if (OSD_STATUS && !osd_d && nv_dirty) begin
		nv_save  <= 1'b1;
		nv_dirty <= 1'b0;
	end
end

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
wire  [3:0] pxl_div;
// The sound board: the K056800 with the sound CPU behind it running the
// real program, held in reset until the main CPU releases it.
wire        snd_run;
wire  [7:0] k8_host;
assign snd_din = k8_host;

wire        k8_wr, k8_rd, k8_irq;
wire  [2:0] k8_addr;
wire  [7:0] k8_din, k8_dout;
gx_k056800 u_k056800 (
	.clk(clk_vid), .rst(rst_vid),
	.h_wr(snd_wr), .h_rd(snd_rd), .h_addr(snd_addr[2:0]),
	.h_din(snd_dout), .h_dout(k8_host),
	.s_wr(k8_wr), .s_rd(k8_rd), .s_addr(k8_addr), .s_din(k8_din), .s_dout(k8_dout),
	.irq(k8_irq), .dbg(k8_dbg),
	.ss_snap, .ss_commit, .ss_sel(ss_en && ss_sel == 4'd2), .ss_addr, .ss_we, .ss_wd, .ss_rd(ss_rd_k8)
);

wire [63:0] snd_dbg, dsp_dbg;

// save states: the engine's wires (gx_savestate below gx_main)
wire        ss_busy, ss_own, ss_snap, ss_commit, ss_freeze, ss_en, ss_we, ss_step;
wire [ 3:0] ss_sel;
wire [11:0] ss_addr;
wire [15:0] ss_wd, ss_rd_main, ss_rd_snd, ss_rd_k8;
wire        ss_m_req, ss_m_go, ss_m_held, ss_m_done, ss_m_bwe;
wire        ss_s_req, ss_s_go, ss_s_held, ss_s_done, ss_s_bwe;
wire [ 4:0] ss_m_bidx, ss_s_bidx;
wire [31:0] ss_m_bd, ss_m_bq, ss_s_bd, ss_s_bq;
wire        ss_mb_req, ss_mb_we, ss_mb_ack, ss_sb_req, ss_sb_we, ss_sb_ack, ss_sd_req, ss_sd_we, ss_sd_ack;
wire [23:1] ss_mb_addr, ss_sb_addr;
wire [ 1:0] ss_mb_be;
wire [15:0] ss_mb_wd, ss_mb_rd, ss_sb_wd, ss_sb_rd, ss_sd_wd, ss_sd_rd;
wire [17:0] ss_sd_addr;
wire [ 8:0] ss_vpos, ss_hpos;
wire        ss_esc_busy, ss_dma_busy;
wire        sl_start, sl_save, sl_wv, sl_wready, sl_end, sl_idle, sl_rv, sl_rtake;
wire [15:0] sl_wd, sl_rd;
wire [31:0] sl_words;
wire  [7:0] ss_DDRAM_BURSTCNT, ss_DDRAM_BE;
wire [28:0] ss_DDRAM_ADDR;
wire [63:0] ss_DDRAM_DIN;
wire        ss_DDRAM_RD, ss_DDRAM_WE;
wire [31:0] snd_ovr;
wire [49:0] k8_dbg;
// the sound board's RAMs zeroed after each reset, gx_sound held meanwhile
wire        clr_inval, clr_wreq;
wire [25:0] clr_waddr;
gx_snd_clear u_snd_clear (
	.clk(clk_vid), .hold(|rst_sr),
	.snd_base(obj_base + { 1'b0, obj_size4, 1'b0 }), .snd_pcm,
	.busy(clr_busy), .inval(clr_inval),
	.w_req(clr_wreq), .w_addr(clr_waddr), .w_busy(snd_wbusy)
);
assign snd_wreq  = clr_busy ? clr_wreq  : s_wreq;
assign snd_waddr = clr_busy ? clr_waddr : s_waddr;
assign snd_wdata = clr_busy ? 16'd0     : s_wdata;
assign snd_we16  = clr_busy ? 1'b1      : s_we16;
assign snd_inval = s_inval   | clr_inval;
assign dsp_inval = x_inval_s | clr_inval;
assign pcm_inval = p_inval_s | clr_inval;

`ifdef DEBUG_ISSP
wire  [7:0] dsp_src;                    // probe D: [0] restarts the DSP's overrun counts
`else
wire  [7:0] dsp_src = 8'd0;
`endif
gx_sound u_sound (
	.clk(clk_vid), .clk_cpu(clk_cpu), .rst(rst_vid || !snd_run), .rst_chip(rst_vid),
	// where the sprite region's spread ends (gx_sdram_top's snd_base)
	.snd_base(obj_base + { 1'b0, obj_size4, 1'b0 }), .snd_pcm,
	.m_cs(snd_cs), .m_addr(snd_maddr), .m_ok(snd_ok), .m_data(snd_mdata), .m_inval(s_inval),
	.w_req(s_wreq), .w_addr(s_waddr), .w_data(s_wdata), .w_we16(s_we16), .w_busy(snd_wbusy),
	.x_cs(dsp_cs), .x_addr(dsp_addr), .x_ok(dsp_ok), .x_data(dsp_data), .x_inval(x_inval_s),
	.p_cs(pcm_cs), .p_addr(pcm_addr), .p_ok(pcm_ok), .p_data(pcm_data), .p_inval(p_inval_s),
	.aud_l(snd_aud_l), .aud_r(snd_aud_r),
	.k8_wr, .k8_rd, .k8_addr, .k8_din, .k8_dout, .k8_irq,
	.dbg(snd_dbg), .dsp_dbg, .ovr_dbg(snd_ovr), .dsp_dbg_clr(dsp_src[0]),
	.tr_valid(), .tr_data(),
	.ss_s_req, .ss_s_go, .ss_s_held, .ss_s_done, .ss_s_bidx, .ss_s_bwe, .ss_s_bd, .ss_s_bq,
	.ss_sb_req, .ss_sb_we, .ss_sb_addr, .ss_sb_wd, .ss_sb_ack, .ss_sb_rd,
	.ss_sd_req, .ss_sd_we, .ss_sd_addr, .ss_sd_wd, .ss_sd_ack, .ss_sd_rd,
	.ss_freeze, .ss_snap, .ss_commit, .ss_step, .ss_sel, .ss_en, .ss_addr, .ss_we, .ss_wd, .ss_rd(ss_rd_snd)
);
wire [15:0] dbg_rom_hits, dbg_rom_misses;
wire [63:0] dbg_ee, dbg_irq;
wire [95:0] dbg_esc_st;
wire [95:0] dbg_obj;
wire [63:0] dbg_k338;
wire [135:0] dbg_shd;
wire [111:0] dbg_mix;
wire [131:0] dbg_line;
wire [83:0] dbg_rom;
wire [ 1:0] dbg_esc;

// The sources the ISSP probes below drive, and the probe the JTAG memory
// read answers on. They are used by the instance above, which is in both
// revisions, so they are declared here and tied off when the probes are
// compiled out.
`ifdef DEBUG_ISSP
wire [31:0] peek_src;
wire [31:0] mem_src;
wire  [7:0] line_src;                   // probe T: [0] turns gx_tilemap's blank-row skip off
`else
wire [31:0] peek_src = 32'd0;
wire [31:0] mem_src  = 32'd0;
wire  [7:0] line_src = 8'd0;
`endif
wire [87:0] dbg_mem;

// Pause: joystick bit 12, the position the conf string's button list and the
// .mra's <buttons> give Pause (bit 4 + its index). It toggles, either pad,
// and holds the 68020 where it is; the video keeps running, so the picture
// stays up.
wire pause_btn = joystick_0[12] | joystick_1[12];
reg  pause_btn_d = 1'b0, pause_cpu = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_cpu <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_cpu <= ~pause_cpu;
end

gx_main u_board (
	.rst(rst_vid), .clk(clk_vid), .clk_cpu(clk_cpu),
	.rom_cs, .rom_addr, .rom_ok, .rom_data,
	.tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
	.obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr, .obj_pf_cs,
	.snd_wr, .snd_rd, .snd_addr, .snd_dout, .snd_din,
	.inputs, .coins, .dsw, .service,
	.ee_blank(ee_blank), .ee_load_we(ee_we), .ee_load_addr(ee_a), .ee_load_data(ee_d),
	.ee_rd_addr(ioctl_addr[6:1]), .ee_rd_data(ee_rd_data), .ee_written(ee_written),
	.offs_x, .offs_y, .primode, .tile_bpp, .obj_layout, .obj_pri_raw, .vis_x0, .vis_w, .obj_hadj, .esc_gen, .esc_src, .esc_count, .esc_copy, .prot4, .esc_sal2, .tile_rb66,
	.guns, .gun_h, .gun_v, .gun_trig2(guns & gun_trig[1]), .orient_fy, .fj_dma, .rom_uncached(5'd6),
	.rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .pxl_cen_o(pxl_cen), .pxl_div_o(pxl_div), .unsupported,
	.dbg_addr(dbg_addr), .dbg_access(dbg_access), .dbg_we(), .dbg_be(), .dbg_data(),
	.dbg_ee(dbg_ee), .dbg_rom_hits(dbg_rom_hits), .dbg_rom_misses(dbg_rom_misses), .dbg_irq(dbg_irq), .dbg_esc(dbg_esc), .dbg_esc_st(dbg_esc_st), .dbg_obj(dbg_obj), .dbg_k338(dbg_k338), .dbg_shd(dbg_shd), .dbg_mix(dbg_mix), .dbg_line(dbg_line), .tm_blank_skip(!line_src[0]), .dbg_rom(dbg_rom),
	.peek_t(peek_src[0]), .peek_addr(peek_src[31:12]),
	.rom_top(tile_base), .pause_cpu(pause_cpu), .snd_run,
	.tile_base, .obj_base, .gfx_cs, .gfx_addr, .gfx_ok, .gfx_data,
	.mem_t(mem_src[0]), .mem_addr(mem_src[31:9]), .dbg_mem(dbg_mem),
	.ss_m_req, .ss_m_go, .ss_m_held, .ss_m_done, .ss_m_bidx, .ss_m_bwe, .ss_m_bd, .ss_m_bq,
	.ss_mb_req, .ss_mb_we, .ss_mb_addr, .ss_mb_be, .ss_mb_wd, .ss_mb_ack, .ss_mb_rd,
	.ss_snap, .ss_commit, .ss_sel, .ss_en, .ss_addr, .ss_we, .ss_wd, .ss_rd(ss_rd_main),
	.ss_vpos, .ss_hpos, .ss_esc_busy, .ss_dma_busy
);

///////////////////////   SAVE STATES   //////////////////////////
// docs/SAVESTATES.md. The OSD's Save/Restore (status 101/102, held while
// the OSD shows them) start gx_savestate on clk_vid; it takes the CPUs,
// walks rtl/gx_ss_layout.svh through the board's channels, and moves the
// image to or from the selected slot in DDR3 (gx_ss_ddr), where
// Main_MiSTer keeps the four slots' files. Not while the sound CPU is in
// reset or the Pause button holds the 68020: neither CPU could be taken.
reg  [2:0] ss_sv_s = 0, ss_ld_s = 0;
reg        ss_save = 0, ss_load = 0;
always @(posedge clk_vid) begin
	ss_sv_s <= { ss_sv_s[1:0], status[101] };
	ss_ld_s <= { ss_ld_s[1:0], status[102] };
	ss_save <= ss_sv_s[2:1] == 2'b01 && snd_run && !pause_cpu && !rst_vid;
	ss_load <= ss_ld_s[2:1] == 2'b01 && snd_run && !pause_cpu && !rst_vid;
end
wire [1:0] ss_slot = status[100:99];

gx_savestate u_ss (
	.clk(clk_vid), .rst(rst_vid),
	.save_req(ss_save), .load_req(ss_load), .set_id(mod_byte), .busy(ss_busy), .err(),
	.esc_busy(ss_esc_busy), .dma_busy(ss_dma_busy), .vpos(ss_vpos), .hpos({ 1'b0, ss_hpos }),
	.m_req(ss_m_req), .m_go(ss_m_go), .m_held(ss_m_held), .m_done(ss_m_done),
	.m_bidx(ss_m_bidx), .m_bwe(ss_m_bwe), .m_bd(ss_m_bd), .m_bq(ss_m_bq),
	.s_req(ss_s_req), .s_go(ss_s_go), .s_held(ss_s_held), .s_done(ss_s_done),
	.s_bidx(ss_s_bidx), .s_bwe(ss_s_bwe), .s_bd(ss_s_bd), .s_bq(ss_s_bq),
	.ss_snap, .ss_commit, .snd_freeze(ss_freeze),
	.ss_sel, .ss_en, .ss_addr, .ss_we, .ss_step, .ss_wd, .ss_rd(ss_rd_main | ss_rd_snd | ss_rd_k8),
	.mb_req(ss_mb_req), .mb_we(ss_mb_we), .mb_addr(ss_mb_addr), .mb_be(ss_mb_be), .mb_wd(ss_mb_wd),
	.mb_ack(ss_mb_ack), .mb_rd(ss_mb_rd),
	.sb_req(ss_sb_req), .sb_we(ss_sb_we), .sb_addr(ss_sb_addr), .sb_wd(ss_sb_wd), .sb_ack(ss_sb_ack), .sb_rd(ss_sb_rd),
	.sd_req(ss_sd_req), .sd_we(ss_sd_we), .sd_addr(ss_sd_addr), .sd_wd(ss_sd_wd), .sd_ack(ss_sd_ack), .sd_rd(ss_sd_rd),
	.sl_start, .sl_save, .sl_wv, .sl_wd, .sl_wready, .sl_end, .sl_words, .sl_idle,
	.sl_rv, .sl_rd, .sl_rtake
);

gx_ss_ddr u_ss_ddr (
	.clk(clk_vid), .rst(rst_vid), .slot(ss_slot), .active(ss_busy),
	.sl_start, .sl_save, .sl_wv, .sl_wd, .sl_wready, .sl_end, .sl_words, .sl_idle,
	.sl_rv, .sl_rd, .sl_rtake,
	.own(ss_own),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ss_DDRAM_BURSTCNT), .DDRAM_ADDR(ss_DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ss_DDRAM_RD),
	.DDRAM_DIN(ss_DDRAM_DIN), .DDRAM_BE(ss_DDRAM_BE), .DDRAM_WE(ss_DDRAM_WE)
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
// Instance M, 84 bits: the last granule the CPU's ROM cache fetched from
// SDRAM -- [63:0] the bytes, [83:64] its granule address in the packed
// image (fields_M). At a halt it is the fetch that fed the CPU.
// its source asks for a granule: [0] toggles to read, [31:12] the address
issp_probe #(.INSTANCE_ID("M"), .PROBE_W(84), .SOURCE_W(32)) u_issp_rom (
	.clk(clk_vid), .probe(dbg_rom), .source(peek_src)
);
// Instance N, 88 bits: four words of anything the CPU can read, at the
// address its source asks for -- [0] toggles the read, [31:9] the word
// address. The probe is { addr, done, word 0..3 } (fields_N). This is how a
// capture is taken from the board instead of from MAME (scripts/memdump.py).
issp_probe #(.INSTANCE_ID("N"), .PROBE_W(88), .SOURCE_W(32)) u_issp_mem (
	.clk(clk_vid), .probe(dbg_mem), .source(mem_src)
);
// Instance S, 116 bits: the sound board -- whether the 68000 is released
// (bit 115, formerly "selected", is 1), where it is, how many accesses it
// has made, its interrupts, and the K056800's six registers (fields_S).
issp_probe #(.INSTANCE_ID("S"), .PROBE_W(148), .SOURCE_W(8)) u_issp_snd (
	.clk(clk_vid), .probe({ snd_ovr, 1'b1, snd_run, k8_dbg, snd_dbg }), .source()
);
// Instance D, 64 bits: the TMS57002 (fields_D) -- whether a sample's
// program fits its 1000 clocks with SDRAM behind it
// source bit 0 restarts the DSP's longest-sample and overrun counts
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(64), .SOURCE_W(8)) u_issp_dsp (
	.clk(clk_vid), .probe(dsp_dbg), .source(dsp_src)
);
issp_probe #(.INSTANCE_ID("L"), .PROBE_W(112), .SOURCE_W(8)) u_issp_mix (
	.clk(clk_vid), .probe(dbg_mix), .source()
);
issp_probe #(.INSTANCE_ID("K"), .PROBE_W(64), .SOURCE_W(8)) u_issp_ldr (
	.clk(clk_sys), .probe({ 10'd0, ldr_done, dl_seen_wr, dl_cycles, ldr_cycles }), .source()
);
// Instance O, 136 bits: the first tile each frame of a sprite with shadow
// code 1, from the scan to its data (gx_obj dbg_shd; read_issp.tcl's fields_O)
issp_probe #(.INSTANCE_ID("O"), .PROBE_W(136), .SOURCE_W(8)) u_issp_shd (
	.clk(clk_vid), .probe(dbg_shd), .source()
);
issp_probe #(.INSTANCE_ID("J"), .PROBE_W(96), .SOURCE_W(8)) u_issp_obj (
	.clk(clk_vid), .probe(dbg_obj), .source()
);
issp_probe #(.INSTANCE_ID("I"), .PROBE_W(96), .SOURCE_W(8)) u_issp_esc (
	.clk(clk_vid), .probe(dbg_esc_st), .source()
);
// Instance T, 132 bits: line time per frame (gx_video dbg_line; fields_T).
// Source bit 0 turns the blank-row skip off, to compare the same scene.
issp_probe #(.INSTANCE_ID("T"), .PROBE_W(132), .SOURCE_W(8)) u_issp_line (
	.clk(clk_vid), .probe(dbg_line), .source(line_src)
);
`endif

///////////////////////   VIDEO   ////////////////////////////////

wire [23:0] rgb_x;
gx_guns u_guns (
	.clk(clk_vid), .rst(rst_vid), .joy0(joystick_0), .joy1(joystick_1),
	.ana0(joystick_l_analog_0), .ana1(joystick_l_analog_1), .mouse(ps2_mouse),
	.mode0(status[70:69]), .mode1(status[72:71]), .ms_who(status[74:73]),
	.yrev(orient_fy), .gun_h, .gun_v, .trig(gun_trig),
	.show(guns & status[68]), .pxl_cen, .lhbl(vid_lhbl), .lvbl(vid_lvbl), .vis_w,
	.rgb_in(rgb), .rgb_out(rgb_x)
);

// ---------------------------------------------------------- CRT Adjust
// rmonic79's CRT Adjust and CRT V-Size, glued as in Arcade-Psikyo_MiSTer
// (rtl/video/gx_crt_chain.sv says where GX differs). The OSD stores list
// indices: H-Position's 97 entries wrap at 97, V-Size's 15 at 15, V-Shift
// and H-Size are plain two's complement. H-Size and V-Size are held at 0
// while the scandoubler or its effects are on.
wire              crt_on      = status[75];
wire              crt_scale   = ~(forced_scandoubler | |status[46:44]);
wire        [6:0] crt_hpos_ix = status[82:76];
wire signed [8:0] crt_hoffset = crt_hpos_ix <= 7'd48 ? $signed({ 2'b00, crt_hpos_ix })
                                                     : $signed({ 2'b00, crt_hpos_ix }) - 9'sd97;
wire        [3:0] crt_vsz_ix  = status[97:94];
wire signed [3:0] crt_vsz     = crt_vsz_ix <= 4'd7 ? $signed(crt_vsz_ix) : $signed(crt_vsz_ix - 4'd15);

wire       crt_ce, crt_hs, crt_vs, crt_hb, crt_vb;
wire [7:0] crt_r, crt_g, crt_b;

gx_crt_chain u_crt (
	.clk(clk_vid), .ce_pix(pxl_cen), .pxl_div,
	.active(crt_on), .scale_en(crt_scale),
	.hoffset(crt_hoffset), .voffset($signed(status[88:83])), .hsize($signed(status[93:89])),
	.vsize_step(crt_vsz), .vsize_cabinet(status[98]),
	.r_in(rgb_x[23:16]), .g_in(rgb_x[15:8]), .b_in(rgb_x[7:0]),
	.hs_in(vid_hs), .vs_in(vid_vs), .hb_in(~vid_lhbl), .vb_in(~vid_lvbl),
	.ce_out(crt_ce), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_vid),
	.ce_pix(crt_ce),
	.RGB_in({ crt_r, crt_g, crt_b }),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),
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

// ---------------------------------------------------------- HDMI rotation
// screen_rotate_two taps the video output into DDR3 for the HPS
// framebuffer, which the scaler then reads turned or flipped; the analog
// output is untouched and keeps the native raster. This is a display
// option, not the game's own flip-screen bit (gx_tilemap flags that on
// `unsupported`, and no set has set it in anything run so far).
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire  [7:0] rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;

screen_rotate_two u_rotate (
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(flip_180),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	// held off the bus while the ROM loader or the save states have it
	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_busy | ss_own),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

assign DDRAM_CLK      = ldr_busy ? clk_sys            : rot_DDRAM_CLK;
// after the load the port is the rotator's, on its clock (clk_vid), except
// while gx_ss_ddr owns it (the same clock)
assign DDRAM_BURSTCNT = ldr_busy ? ldr_DDRAM_BURSTCNT : ss_own ? ss_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_busy ? ldr_DDRAM_ADDR     : ss_own ? ss_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_busy ? ldr_DDRAM_DIN      : ss_own ? ss_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_busy ? ldr_DDRAM_BE       : ss_own ? ss_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_busy ? ldr_DDRAM_WE       : ss_own ? ss_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_busy ? ldr_DDRAM_RD       : ss_own ? ss_DDRAM_RD       : rot_DDRAM_RD;

endmodule
