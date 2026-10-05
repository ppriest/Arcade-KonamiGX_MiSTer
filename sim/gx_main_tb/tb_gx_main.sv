// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GX main board (rtl/gx_main.sv) running daiskiss from reset, traced the
// way scripts/mame/systrace.lua traces MAME: every write (CPU and ESC), every
// read in 0xd00000-0xdfffff, and "# frame N" at each vblank. Compared with
// MAME's trace by scripts/check_gx_main.py. Run from the repository root:
//
//     python scripts/mame_sys_trace.py daiskiss 400
//     python scripts/check_gx_main.py daiskiss 400
//
// Given: the program ROM image (build_rom_image.py maincpu), the two graphics
// ROM images the video benches use, the EEPROM image pinned in
// debug/<set>-nvram, MAME's input port values, and MAME's own replies from
// the sound CPU through the K056800 -- replayed in order per register, the
// way the sound side stands in until it exists (Phase 3).
//
// Runs on Verilator (TG68K.C as GHDL's Verilog conversion, scripts/tg68k_verilog.sh)
// or ModelSim (the VHDL itself): check_gx_main.py --sim.
//
// Under Verilator the clock comes from sim/gx_main_tb/main.cpp (GX_CPP_CLOCK):
// A --timing build cannot be saved, and main.cpp saves
// (+SAVE=file +SAVE_AT=frame) and restores (+RESTORE=file) one. After a
// restore, `reopen` is high for the first clock: the trace is reopened for
// appending and the run's plusargs are read again -- everything else,
// including the ROM images and the sound replies, comes from the snapshot.

`timescale 1ns/1ps

// clk_cpu is the kernel's 24 MHz, clk / 2 with COINCIDENT rising edges, as
// the PLL gives it: both are blocking-assigned in the same time step (or set
// together before one eval in main.cpp), so every process samples pre-edge
// values, as on the board.
// INSTANCE does nothing but name the build: scripts/check_gx_main.py
// --instance N builds into obj_verilator/gx_main_tb_GINSTANCE_N_, so a second
// run can start while another is simulating (they share only the input
// files, which each reads at its start)
`ifdef GX_CPP_CLOCK
module tb_gx_main #(parameter INSTANCE = 0) (
    input             clk,
    input             clk_cpu,
    input             reopen,
    output     [31:0] frame_o
);
`else
module tb_gx_main #(parameter INSTANCE = 0);
reg clk = 0, clk_cpu = 0, reopen = 0;
always #10.417 clk = ~clk;
always #20.834 clk_cpu = ~clk_cpu;
`endif

localparam string TD = "debug/gx_tilemap_tb/";
localparam string OD = "debug/gx_obj_tb/";
localparam string SD = "debug/gx_main_tb/";   // the inputs check_gx_main.py writes (snd.hex)
string            od = SD;                    // +OUT=<dir/>: this run's trace and pictures
string            set_name = "daiskiss";      // +SET=<name>: its ROM image, EEPROM image and trace name

reg rst = 1;
// +SPR_MIX=0: gx_mixer's spr_mix_on off -- no sprite blended, as MAME draws
int spr_mix_sel = 1;
initial void'($value$plusargs("SPR_MIX=%d", spr_mix_sel));

// ----------------------------------------------------------- program ROM
// gx_main asks for granules of the packed SDRAM image (gx_sdram_top.sv):
// granule g is CPU bytes 8g.. below 0x20000 and 8g + 0x1e0000 above, byte k
// at bits [8k +: 8]. Answered +ROM_WAIT clocks after rom_cs (default 10,
// about what the SDRAM path takes); the cache in gx_main makes a hit one
// wait state. rom_cs drops the clock after rom_ok; !rom_ok keeps that clock
// from answering twice.
localparam int ROM_BYTES = 8 * 1024 * 1024;
byte unsigned rom [0:ROM_BYTES-1];
wire [19:0] rom_addr;
wire        rom_cs;
reg         rom_ok = 0;
reg  [63:0] rom_data;
wire [22:0] rom_byte = rom_addr < 20'h4000 ? { rom_addr, 3'b000 } : { rom_addr, 3'b000 } + 23'h1e0000;
// +ROM_WAIT=n clocks a fetch, plus one on every other fetch unless
// +ROM_JITTER=0: the board's SDRAM answers in an odd number of clocks as
// often as an even one, and a fixed even latency hid a lost-ack fault in the
// ESC's release of the CPU (LESSONS_LEARNED).
int         rom_wait = 10, rom_jitter = 1, rlat = 0;
reg  [7:0]  rom_lfsr = 8'h5a;
always @(posedge clk) begin
    rom_ok <= 0;
    if (!rom_cs) rlat <= 0;
    else if (rlat < rom_wait + (rom_jitter != 0 ? int'(rom_lfsr[0]) : 0)) rlat <= rlat + 1;
    else if (!rom_ok) begin
        rom_ok   <= 1;
        rom_lfsr <= { rom_lfsr[6:0], rom_lfsr[7] ^ rom_lfsr[5] ^ rom_lfsr[4] ^ rom_lfsr[3] };
        for (int k = 0; k < 8; k++) rom_data[8*k +: 8] <= rom[rom_byte + k];
    end
end

// ----------------------------------------------------------- graphics ROMs
reg [63:0] trom_v [1 << 21];   // crzcross's tile region is 2M rows; rows of 5, 6 or 8 bytes, byte 0 in [63:56]
reg [63:0] orom_v [1 << 22];   // half-rows, byte 0 in [63:56]
int        tntiles, ontiles, ROM_LAT = 6;
wire [23:0] tile_rom_addr;  wire tile_rom_cs;  reg tile_rom_ok = 0; reg [63:0] tile_rom_data;
wire [22:0] obj_rom_addr;   wire obj_rom_cs;   reg obj_rom_ok = 0;  reg [63:0] obj_rom_data;
reg [23:0] tlast; int tlat;
always @(posedge clk) begin
    tile_rom_ok <= 1'b0;
    if (!tile_rom_cs) tlat <= 0;
    else if (tlat == 0 || tile_rom_addr != tlast) begin tlast <= tile_rom_addr; tlat <= 1; end
    else if (tlat < ROM_LAT) tlat <= tlat + 1;
    else begin
        tile_rom_ok   <= 1'b1;
        tile_rom_data <= trom_v[((tile_rom_addr >> 3) % tntiles) * 8 + tile_rom_addr[2:0]];
    end
end
// One ok per fetch, as gx_rom_port gives it: a fetch is a new address or cs
// raised again. The model used to repeat ok on every clock once the latency
// had passed, which hid a lost-ok deadlock in the sprite drawer that the
// board showed (gx_obj.v). +OBJ_OK_LEVEL=1 restores the repeat.
reg [22:0] olast; int olat; reg odone = 0; int obj_ok_level = 0;
initial void'($value$plusargs("OBJ_OK_LEVEL=%d", obj_ok_level));
always @(posedge clk) begin
    obj_rom_ok <= 1'b0;
    if (!obj_rom_cs) begin olat <= 0; odone <= 0; end
    else if (olat == 0 || obj_rom_addr != olast) begin olast <= obj_rom_addr; olat <= 1; odone <= 0; end
    else if (olat < ROM_LAT) olat <= olat + 1;
    else if (!odone || obj_ok_level != 0) begin
        odone <= 1;
        obj_rom_ok   <= 1'b1;
        obj_rom_data <= orom_v[(((obj_rom_addr >> 5) % ontiles) << 5) | obj_rom_addr[4:0]];
    end
end

// ----------------------------------------------------------- K056800 replay
// snd.hex: one line per MAME read, "reg value frame", in MAME's order.
// Replayed in order per register -- which holds through the boot -- and from
// RTL frame +SND_TIME_FROM by time: a read in RTL frame f gets the replies
// MAME's CPU got in its frame f + +SND_OFFSET, in order, the last of them
// repeated if the RTL reads more often. The game polls sound status a
// number of times that depends on CPU speed, so order alone drifts.
localparam int MAXR = 1 << 20;
reg  [ 3:0] rp_reg [MAXR];
reg  [ 7:0] rp_val [MAXR];
int         rp_fr  [MAXR];
int         rp_n = 0, snd_time_from = -1, snd_offset = 0;
int         rp_next [16];         // per register: index of the next reply
reg  [ 7:0] rp_last [16];
wire        snd_wr, snd_rd;
wire [ 3:0] snd_addr;
wire [ 7:0] snd_dout;
reg  [ 7:0] snd_din;
int         snd_miss = 0;

// +SND_STUB=1: the core's gx_snd_stub answers instead of MAME's replies
int         snd_stub = 0;
wire [7:0]  stub_dout;
reg         lvbl_st = 1;
always @(posedge clk) lvbl_st <= vid_lvbl;
gx_snd_stub u_stub ( .clk, .rst, .frame(lvbl_st & ~vid_lvbl), .wr(snd_wr), .rd(snd_rd && snd_stub != 0),
                     .addr(snd_addr), .din(snd_dout), .dout(stub_dout) );
// +SND_REAL=1: the K056800 with the sound board behind it (Phase 3a), the
// sound 68000 running the real sound program out of +SND_ROM, so the main
// CPU is answered the way the hardware answers it rather than with MAME's
// replies replayed by time. The sound board's SDRAM is modelled here: the
// program at 0, the samples at 0x40000, the K054539s' RAM at 0x440000,
// the TMS57002's at 0x450000 (gx_sound's offsets from snd_base, which is 0
// in this model).
int         snd_real = 0;
wire [7:0]  k8_host;
wire        k8_wr, k8_rd, k8_irq;
wire [2:0]  k8_addr;
wire [7:0]  k8_din, k8_dout;
// save states: the engine's wires (its instance is after the DUT's)
int ss_save_at = -1, ss_load_at = -1;
string ss_save_f, ss_load_f;
wire        e_m_req, e_m_go, e_m_held, e_m_done, e_m_bwe, e_s_req, e_s_go, e_s_held, e_s_done, e_s_bwe;
wire [ 4:0] e_m_bidx, e_s_bidx;
wire [31:0] e_m_bd, e_m_bq, e_s_bd, e_s_bq;
wire        e_mb_req, e_mb_we, e_mb_ack, e_sb_req, e_sb_we, e_sb_ack, e_sd_req, e_sd_we, e_sd_ack;
wire [23:1] e_mb_addr, e_sb_addr;
wire [ 1:0] e_mb_be;
wire [15:0] e_mb_wd, e_mb_rd, e_sb_wd, e_sb_rd, e_sd_wd, e_sd_rd;
wire [17:0] e_sd_addr;
wire        e_snap, e_commit, e_freeze, e_ssen, e_sswe, e_step;
wire [ 3:0] e_sssel;
wire [11:0] e_ssaddr;
wire [15:0] e_sswd, e_ssrd_main, e_ssrd_snd, e_ssrd_k8;
wire [ 8:0] e_vpos, e_hpos;
wire        e_esc_busy, e_dma_busy, e_busy, e_err;
wire        sl_start, sl_save, sl_wv, sl_end, sl_rtake;
wire [15:0] sl_wd;
wire [31:0] sl_words;
reg         e_save = 0, e_load = 0;

gx_k056800 u_k056800 (
    .clk, .rst,
    .h_wr(snd_wr && snd_real != 0), .h_rd(snd_rd && snd_real != 0), .h_addr(snd_addr[2:0]),
    .h_din(snd_dout), .h_dout(k8_host),
    .s_wr(k8_wr), .s_rd(k8_rd), .s_addr(k8_addr), .s_din(k8_din), .s_dout(k8_dout), .irq(k8_irq),
    .ss_snap(e_snap), .ss_commit(e_commit), .ss_sel(e_ssen && e_sssel == 4'd2), .ss_addr(e_ssaddr),
    .ss_we(e_sswe), .ss_wd(e_sswd), .ss_rd(e_ssrd_k8)
);

localparam int SMEM = 'h490000 / 8;
reg  [63:0] smem [0:SMEM-1];
wire        sm_cs, sm_inval, sm_wreq;
wire [22:0] sm_addr;
reg         sm_ok = 0, sm_wbusy = 0;
reg  [63:0] sm_data;
wire [25:0] sm_waddr;
wire [15:0] sm_wdata;
wire        sm_we16;
reg  [ 3:0] sm_wcnt = 0;
wire        dx_cs, dx_inval;
wire [14:0] dx_addr;
reg         dx_ok = 0;
reg  [63:0] dx_data;
always @(posedge clk) begin
    sm_ok <= 1'b0;
    if (sm_cs && !sm_ok) begin
        sm_data <= (int'(sm_addr) < SMEM) ? smem[sm_addr] : 64'd0;
        sm_ok   <= 1'b1;
    end
    // a write is taken (busy) and finishes a few clocks later, as the arbiter's
    if (sm_wreq && !sm_wbusy && sm_wcnt == 0) begin
        if (int'(sm_waddr >> 3) < SMEM) begin
            if (sm_we16) smem[sm_waddr >> 3][8 * sm_waddr[2:0] +: 16] <= sm_wdata;
            else         smem[sm_waddr >> 3][8 * sm_waddr[2:0] +: 8]  <= sm_wdata[7:0];
        end
        sm_wbusy <= 1'b1; sm_wcnt <= 4'd6;
    end else if (sm_wcnt != 0) begin
        sm_wcnt <= sm_wcnt - 4'd1;
        if (sm_wcnt == 4'd1) sm_wbusy <= 1'b0;
    end
end

// the voices' sample port, as the DSP's: a granule a few clocks later
wire        sp_cs;
wire [20:0] sp_addr;
reg         sp_ok = 0;
reg  [63:0] sp_data;
reg  [3:0]  sp_cnt = 0;
always @(posedge clk) begin
    sp_ok <= 1'b0;
    if (!sp_cs || sp_ok) sp_cnt <= 0;
    else if (sp_cnt == 4'd8) begin
        sp_data <= smem[('h40000 >> 3) + int'(sp_addr)];
        sp_ok   <= 1'b1;
        sp_cnt  <= 0;
    end else sp_cnt <= sp_cnt + 4'd1;
end

reg  [3:0] dx_cnt = 0;
always @(posedge clk) begin
    dx_ok <= 1'b0;
    if (!dx_cs || dx_ok) dx_cnt <= 0;
    else if (dx_cnt == 4'd8) begin
        dx_data <= smem[('h450000 >> 3) + int'(dx_addr)];
        dx_ok   <= 1'b1;
        dx_cnt  <= 0;
    end else dx_cnt <= dx_cnt + 4'd1;
end

wire        snd_run, snd_tr_valid;
wire [63:0] snd_dbg, snd_tr_data, dsp_dbg;
// +DSP_LOG=1: the DSP's state once a frame (gx_tms57002 dbg)
int dsp_log = 0;
initial void'($value$plusargs("DSP_LOG=%d", dsp_log));
// hostf edges, the first 40
int dsp_hn = 0; reg dsp_hl = 0;
always @(posedge clk) if (dsp_log != 0) begin
    dsp_hl <= dsp_dbg[19];
    if (dsp_dbg[19] != dsp_hl && dsp_hn < 40) begin
        $display("DSPHOST t%0t f%0d hostf %0d pc %02x h_rd %0d h_ctrl_wr %0d rst %0d", $time, frame, dsp_dbg[19],
                 dsp_dbg[7:0], u_sound.d_rd, u_sound.d_ctrl_wr, u_sound.rst);
        dsp_hn++;
    end
    if (u_sound.d_rd && dsp_hn < 40) begin
        $display("DSPRD t%0t f%0d hostf %0d", $time, frame, dsp_dbg[19]); dsp_hn++;
    end
end
// a shadow of the DSP's RAM from its own writes, checked on its reads
reg [7:0] dsp_shadow [0:'h3ffff];
reg       dsp_shv    [0:'h3ffff];
int dsp_bad = 0, dsp_wn = 0, dsp_rn = 0;
initial for (int q = 0; q < 'h40000; q++) dsp_shv[q] = 0;
always @(posedge clk) if (dsp_log != 0) begin
    if (u_sound.dx_req && u_sound.dx_we && u_sound.dx_wack) begin
        for (int k = 0; k < 8; k++) if (u_sound.dx_wmask[k]) begin
            dsp_shadow[{u_sound.dx_addr, 3'(k)}] = u_sound.dx_wdata[8*k +: 8];
            dsp_shv[{u_sound.dx_addr, 3'(k)}] = 1;
        end
        dsp_wn++;
    end
    if (u_sound.dx_req && !u_sound.dx_we && dx_ok) begin
        dsp_rn++;
        for (int k = 0; k < 8; k++)
            if (!dsp_shv[{u_sound.dx_addr, 3'(k)}] && dx_data[8*k +: 8] != 0 && dsp_bad < 20) begin
                $display("DSPMEM f%0d addr %05x byte %0d never written, reads %02x", frame,
                         {u_sound.dx_addr, 3'(k)}, k, dx_data[8*k +: 8]);
                dsp_bad++;
            end else if (dsp_shv[{u_sound.dx_addr, 3'(k)}] && dsp_shadow[{u_sound.dx_addr, 3'(k)}] !== dx_data[8*k +: 8] && dsp_bad < 20) begin
                $display("DSPMEM f%0d addr %05x byte %0d read %02x wrote %02x (writes %0d reads %0d)", frame,
                         {u_sound.dx_addr, 3'(k)}, k, dx_data[8*k +: 8], dsp_shadow[{u_sound.dx_addr, 3'(k)}], dsp_wn, dsp_rn);
                dsp_bad++;
            end
    end
end
// +DSP_XLOG=n: the DSP's first n external-memory transactions
int dsp_xlog = 0;
initial void'($value$plusargs("DSP_XLOG=%d", dsp_xlog));
always @(posedge clk) if (dsp_xlog > 0) begin
    if (u_sound.dx_req && u_sound.dx_we && u_sound.dx_wack) begin
        $display("XLOG W %05x %02x %016x", {u_sound.dx_addr, 3'd0}, u_sound.dx_wmask, u_sound.dx_wdata); dsp_xlog--;
    end
    if (u_sound.dx_req && !u_sound.dx_we && dx_ok) begin
        $display("XLOG R %05x %016x", {u_sound.dx_addr, 3'd0}, dx_data); dsp_xlog--;
    end
end
longint frame_clk = 0;
always @(posedge clk) frame_clk++;
// +ESC_LOG=n: how long each of the first n ESC commands holds the CPU
int esc_log = 0; longint esc_t0 = 0; reg esc_bl = 0; int esc_fr_clk = 0, esc_fr_n = 0;
int esc_nw = 0, esc_nrom = 0, esc_nram = 0;
int esc_af = 0; string esc_afn;
initial if ($value$plusargs("ESC_ADDRS=%s", esc_afn)) esc_af = $fopen(esc_afn, "w");
initial void'($value$plusargs("ESC_LOG=%d", esc_log));
always @(posedge clk) begin
    esc_bl <= dut.esc_busy;
    if (dut.esc_busy && !esc_bl) esc_t0 = frame_clk;
    if (dut.esc_busy) esc_fr_clk++;
    // the ESC's own accesses, by kind: reads of ROM, reads of RAM, writes
    // +ESC_ADDRS=file: every ROM read of the ESC, its clock, while ESC_LOG counts
    if (dut.esc_ack && !dut.esc_we && esc_af != 0 && esc_log > 0 && { dut.esc_addr, 1'b0 } < 24'h800000)
        $fwrite(esc_af, "%0d %06x\n", frame_clk - esc_t0, { dut.esc_addr, 1'b0 });
    if (dut.esc_ack) begin
        if (dut.esc_we) esc_nw++;
        else if ({ dut.esc_addr, 1'b0 } < 24'h800000) esc_nrom++;
        else esc_nram++;
    end
    if (dut.esc_busy && !esc_bl) begin esc_nw = 0; esc_nrom = 0; esc_nram = 0; end
    if (!dut.esc_busy && esc_bl) begin
        esc_fr_n++;
        if (esc_log > 0) begin
            $display("ESCLOG f%0d busy %0d clocks: %0d ROM reads, %0d RAM reads, %0d writes",
                     frame, frame_clk - esc_t0, esc_nrom, esc_nram, esc_nw);
            esc_log--;
        end
    end
    if (!vid_lvbl && lvbl_st && (esc_fr_n != 0 || esc_fr_clk != 0) && esc_log != 0) begin
        $display("ESCFRAME f%0d commands %0d busy %0d clocks", frame, esc_fr_n, esc_fr_clk);
    end
    if (!vid_lvbl && lvbl_st) begin esc_fr_clk = 0; esc_fr_n = 0; end
end
int dsp_qlog = 0; reg dsp_ql = 0;
initial void'($value$plusargs("DSP_QLOG=%d", dsp_qlog));
always @(posedge clk) if (dsp_qlog > 0) begin
    dsp_ql <= u_sound.dx_req;
    if (u_sound.dx_req && (!dsp_ql || (u_sound.dx_wack || dx_ok)))
        ;
    if (u_sound.dx_req && (u_sound.dx_wack || dx_ok)) begin
        $display("QLOG ack %s by %s addr %05x mask %02x ust %0d pc %02x t%0t", u_sound.dx_we ? "W" : "R",
                 u_sound.dx_wack ? (dx_ok ? "both" : "wack") : "x_ok", {u_sound.dx_addr, 3'd0}, u_sound.dx_wmask,
                 u_sound.ust, dsp_dbg[7:0], $time);
        dsp_qlog--;
    end
end
reg dsp_xr_l = 0;
always @(posedge clk) if (dsp_qlog > 0) begin
    dsp_xr_l <= u_sound.dx_req;
    if (u_sound.d_ctrl_wr)
        $display("QLOG ctrl %02x pc %02x st %0d x_req %0d we %0d idle %0d t%0t", u_sound.d_din, dsp_dbg[7:0],
                 dsp_dbg[25:24], u_sound.dx_req, u_sound.dx_we, dsp_dbg[20], $time);
    if (u_sound.dx_req && !dsp_xr_l)
        $display("QLOG req %s addr %05x mask %02x pc %02x t%0t", u_sound.dx_we ? "W" : "R",
                 {u_sound.dx_addr, 3'd0}, u_sound.dx_wmask, dsp_dbg[7:0], $time);
    if (!u_sound.dx_req && dsp_xr_l)
        $display("QLOG drop pc %02x t%0t", dsp_dbg[7:0], $time);
end
int dsp_xclk = 0, dsp_xn = 0, dsp_run = 0, dsp_wclk = 0;
reg dsp_xl = 0;
always @(posedge clk) begin
    dsp_xl <= dsp_dbg[16];
    if (dsp_dbg[16]) dsp_xclk++;
    if (dsp_dbg[16] && !dsp_xl) dsp_xn++;
    if (dsp_dbg[25:24] != 0) dsp_run++;
    if (u_sound.dx_req && u_sound.dx_we) dsp_wclk++;
    if (dsp_log != 0 && !vid_lvbl && lvbl_st) begin
        $display("DSPLOG f%0d pc %02x st %0d pload %0d cload %0d in_rst %0d idle %0d hostf %0d x_req %0d ovr %0d smps %0d xreqs %0d xclk %0d wclk %0d run %0d ust %0d",
                 frame, dsp_dbg[7:0], dsp_dbg[25:24], dsp_dbg[23], dsp_dbg[22], dsp_dbg[21], dsp_dbg[20],
                 dsp_dbg[19], dsp_dbg[16], dsp_dbg[49:38], dsp_dbg[63:50], dsp_xn, dsp_xclk, dsp_wclk, dsp_run, u_sound.ust);
        dsp_xclk = 0; dsp_xn = 0; dsp_run = 0; dsp_wclk = 0;
    end
end
// +SND_TRACE=path: the sound 68000's bus cycles, one a line
string  snd_trace_f;
integer snd_tf = 0;
initial if ($value$plusargs("SND_TRACE=%s", snd_trace_f)) snd_tf = $fopen(snd_trace_f, "w");
always @(posedge clk) if (snd_tf != 0 && snd_tr_valid)
    $fwrite(snd_tf, "%0d %0d %s %0d%0d %0d%0d %06x %04x\n", snd_tr_data[63:48], snd_tr_data[47:45],
            snd_tr_data[44] ? "R" : "W", snd_tr_data[43], snd_tr_data[42], snd_tr_data[41], snd_tr_data[40],
            snd_tr_data[39:16], snd_tr_data[15:0]);
gx_sound u_sound (
    .clk, .clk_cpu, .rst(rst || !snd_run || snd_real == 0), .rst_chip(rst || snd_real == 0),
    .snd_base(26'd0), .snd_pcm(24'h400000),   // this model's layout: RAMs at 0x440000 and 0x450000
    .dsp_dbg_clr(1'b0),
    .m_cs(sm_cs), .m_addr(sm_addr), .m_ok(sm_ok), .m_data(sm_data), .m_inval(sm_inval),
    .w_req(sm_wreq), .w_addr(sm_waddr), .w_data(sm_wdata), .w_we16(sm_we16), .w_busy(sm_wbusy),
    .x_cs(dx_cs), .x_addr(dx_addr), .x_ok(dx_ok), .x_data(dx_data), .x_inval(dx_inval),
    .p_cs(sp_cs), .p_addr(sp_addr), .p_ok(sp_ok), .p_data(sp_data), .p_inval(),
    .aud_l(), .aud_r(),
    .k8_wr, .k8_rd, .k8_addr, .k8_din, .k8_dout, .k8_irq,
    .dbg(snd_dbg), .dsp_dbg(dsp_dbg),
    .tr_valid(snd_tr_valid), .tr_data(snd_tr_data),
    .ss_s_req(e_s_req), .ss_s_go(e_s_go), .ss_s_held(e_s_held), .ss_s_done(e_s_done),
    .ss_s_bidx(e_s_bidx), .ss_s_bwe(e_s_bwe), .ss_s_bd(e_s_bd), .ss_s_bq(e_s_bq),
    .ss_sb_req(e_sb_req), .ss_sb_we(e_sb_we), .ss_sb_addr(e_sb_addr), .ss_sb_wd(e_sb_wd),
    .ss_sb_ack(e_sb_ack), .ss_sb_rd(e_sb_rd),
    .ss_sd_req(e_sd_req), .ss_sd_we(e_sd_we), .ss_sd_addr(e_sd_addr), .ss_sd_wd(e_sd_wd),
    .ss_sd_ack(e_sd_ack), .ss_sd_rd(e_sd_rd),
    .ss_freeze(e_freeze), .ss_snap(e_snap), .ss_commit(e_commit), .ss_step(e_step),
    .ss_sel(e_sssel), .ss_en(e_ssen), .ss_addr(e_ssaddr), .ss_we(e_sswe), .ss_wd(e_sswd), .ss_rd(e_ssrd_snd)
);
initial begin
    string f;
    void'($value$plusargs("SND_REAL=%d", snd_real));
    if (snd_real != 0) begin
        if (!$value$plusargs("SND_ROM=%s", f)) $fatal(1, "+SND_REAL needs +SND_ROM");
        $readmemh(f, smem);
    end
end

// +AUDIO=file: a line a sample (48 kHz) -- each chip's left and right (8
// bits of fraction), the board's output -- and, for scripts/k054539_model.py,
// every write to either K054539, and read of its 0x22d port, between them:
//   S l0 r0 l1 r1 L R
//   W chip reg data
//   R chip 22d
string  aud_f;
integer aud_fd = 0;
initial if ($value$plusargs("AUDIO=%s", aud_f)) aud_fd = $fopen(aud_f, "w");
// after a restore the saved descriptor is not this process's: this run's own file
always @(posedge clk) if (reopen) begin
    aud_fd = 0;
    if ($value$plusargs("AUDIO=%s", aud_f)) aud_fd = $fopen(aud_f, "w");
end
always @(posedge clk) if (aud_fd != 0) begin
    if (u_sound.smp_cnt == 10'd999 && !u_sound.rst)
        $fwrite(aud_fd, "S %0d %0d %0d %0d %0d %0d\n", u_sound.kl0, u_sound.kr0, u_sound.kl1, u_sound.kr1,
                u_sound.mix_l >>> 8, u_sound.mix_r >>> 8);
    if (u_sound.kc_we && (u_sound.kc_cs0 || u_sound.kc_cs1))
        $fwrite(aud_fd, "W %0d %03x %02x\n", u_sound.kc_cs1, u_sound.kc_addr, u_sound.kc_din);
    // a read of the RAM/ROM port moves its pointer
    if (!u_sound.kc_we && (u_sound.kc_cs0 || u_sound.kc_cs1) && u_sound.kc_addr == 11'h22d)
        $fwrite(aud_fd, "R %0d 22d\n", u_sound.kc_cs1);
end
final if (aud_fd != 0) $fclose(aud_fd);

// +COIN_AT=f / +START_AT=f: coin 1, then player 1's start, held for eight
// RTL frames from that frame (active low, as KonamiGX.sv's ports), to reach
// the screens after coin-up
// +B1_AT=f: player 1's button 1 the same way (a service-menu choice)
int coin_at = -1, start_at = -1, b1_at = -1;
initial begin
    void'($value$plusargs("COIN_AT=%d", coin_at));
    void'($value$plusargs("START_AT=%d", start_at));
    void'($value$plusargs("B1_AT=%d", b1_at));
end
wire        coin_on  = coin_at  >= 0 && frame >= coin_at  && frame < coin_at + 8;
wire        start_on = start_at >= 0 && frame >= start_at && frame < start_at + 8;
wire        b1_on    = b1_at    >= 0 && frame >= b1_at    && frame < b1_at + 8;
wire [31:0] tb_inputs = { !start_on, 2'b11, !b1_on, 28'hFFF_FFFF };
wire [ 7:0] tb_coins  = { 7'h3F, !coin_on };

wire [7:0]  snd_din_mux = snd_real != 0 ? k8_host : snd_stub != 0 ? stub_dout : snd_din;

// +SND_LOG=n: the first n mailbox events of the real sound board -- what
// the main CPU sends (H>S) and what the sound CPU answers (S>H) -- with the
// frame, and a line each frame the sound CPU's address and access count, so
// the exchange can be read directly instead of inferred from the main CPU's
// writes
int snd_log = 0;
initial void'($value$plusargs("SND_LOG=%d", snd_log));
reg [15:0] snd_acc_l = 0;
always @(posedge clk) if (snd_real != 0 && snd_log > 0) begin
    // host registers 4-6 are the volume and mute (the main CPU ramps the volume
    // with hundreds of 0x35 writes); only the command registers are logged
    if (snd_wr && snd_addr[3] == 1'b0 && (snd_addr[2:0] < 3'd4 || snd_addr[2:0] == 3'd7)) begin
        $display("SNDLOG f%0d H>S reg %0d = %02x", frame, snd_addr[2:0], snd_dout); snd_log--;
    end
    if (k8_wr) begin
        $display("SNDLOG f%0d S>H reg %0d = %02x", frame, k8_addr, k8_din); snd_log--;
    end
end
// gx_sound dbg: { 9'd0, accesses[15:0], irq2, IRQ 1, rst, 4'd0, sctrl, address }
always @(posedge clk) if (snd_real != 0 && snd_log > 0 && !vid_lvbl && lvbl_st) begin
    $display("SNDLOG f%0d sound CPU at %06x, %0d accesses, irq2 %0d, irq1 %0d, in reset %0d, sctrl %02x",
             frame, snd_dbg[23:0], snd_dbg[54:39], snd_dbg[38], snd_dbg[37], snd_dbg[36], snd_dbg[31:24]);
end

always @(posedge clk) if (snd_rd && snd_stub == 0 && snd_real == 0) begin
    int k, target;
    k = rp_next[snd_addr];
    if (snd_time_from >= 0 && frame >= snd_time_from) begin
        target = frame + snd_offset;
        while (k < rp_n && (rp_reg[k] != snd_addr || rp_fr[k] < target)) k++;
        if (k < rp_n && rp_fr[k] == target) begin
            snd_din <= rp_val[k];
            rp_last[snd_addr] <= rp_val[k];
            rp_next[snd_addr] = k + 1;
        end else begin
            snd_din <= rp_last[snd_addr];   // no more replies in that frame
            rp_next[snd_addr] = k;
        end
    end else begin
    while (k < rp_n && rp_reg[k] != snd_addr) k++;
    if (k < rp_n) begin
        snd_din <= rp_val[k];
        rp_last[snd_addr] <= rp_val[k];
        rp_next[snd_addr] = k + 1;
    end else begin
        snd_din <= rp_last[snd_addr];     // MAME's trace ran out: repeat the last reply
        snd_miss++;
    end
    end
end

// ----------------------------------------------------------- DUT
reg        ee_we = 0;
reg  [5:0] ee_a;
reg [15:0] ee_d;
// the set's constants from the core's own table (+GAME: its mod byte,
// scripts/build_mra.py SETS order), so the bench cannot drift from the core
int         game = 0;
initial void'($value$plusargs("GAME=%d", game));
wire signed [7:0] offs_x [4], offs_y [4];
wire [ 3:0] cfg_primode;
wire [ 1:0] cfg_tile_bpp, cfg_obj_layout;
wire [ 1:0] cfg_obj_pri_raw;
wire [ 9:0] cfg_vis_x0;
wire [ 8:0] cfg_vis_w;
wire [ 9:0] cfg_obj_hadj;
// +ROM_UNCACHED=n: gx_main's clocks for an instruction fetch with the cache off
int rom_uncached = 6;          // as KonamiGX.sv
initial void'($value$plusargs("ROM_UNCACHED=%d", rom_uncached));
wire        cfg_esc_gen, cfg_esc_copy, cfg_prot4, cfg_esc_sal2, cfg_tile_rb66, cfg_guns, cfg_orient_fy, cfg_fj_dma;
wire [23:0] cfg_esc_src;
wire [ 8:0] cfg_esc_count;
// the 056734 (rtl/esc/k056734.sv); +ESC_CHIP=0 runs gx_esc's copy of MAME's C instead
wire        cfg_esc_chip;
wire [15:0] cfg_esc_s10;
wire [ 3:0] cfg_esc_s11n;
wire [31:0] cfg_esc_xor;
wire [63:0] cfg_esc_lanes;
int esc_chip_on = 1;
initial void'($value$plusargs("ESC_CHIP=%d", esc_chip_on));
gx_board_cfg u_cfg ( .clk, .game(8'(game)), .tile_base(), .obj_base(), .tile_size4(), .obj_size4(), .snd_pcm(),
                     .offs_x, .offs_y, .primode(cfg_primode), .tile_bpp(cfg_tile_bpp), .obj_layout(cfg_obj_layout),
                     .obj_pri_raw(cfg_obj_pri_raw), .vis_x0(cfg_vis_x0), .vis_w(cfg_vis_w),
                     .obj_hadj(cfg_obj_hadj), .esc_gen(cfg_esc_gen), .esc_src(cfg_esc_src),
                     .esc_count(cfg_esc_count), .esc_copy(cfg_esc_copy), .prot4(cfg_prot4),
                     .esc_sal2(cfg_esc_sal2), .tile_rb66(cfg_tile_rb66), .guns(cfg_guns), .orient_fy(cfg_orient_fy), .fj_dma(cfg_fj_dma),
                     .esc_chip(cfg_esc_chip), .esc_s10(cfg_esc_s10), .esc_s11n(cfg_esc_s11n), .esc_xor(cfg_esc_xor), .esc_lanes(cfg_esc_lanes) );
wire [23:0] rgb, dbg_addr;
wire        vid_lhbl, vid_lvbl, vid_hs, vid_vs, unsupported, dbg_access, dbg_we;
wire [ 1:0] dbg_be;
wire [15:0] dbg_data;

wire [15:0] dbg_rom_hits, dbg_rom_misses;
// ----------------------------------------------------------- hiscore.v
// As KonamiGX.sv has it, with the HPS played here. +HS_CFG=file: the .mra's
// <rom index="3"> bytes (hex, whitespace between), downloaded before rst
// falls; +HS_DUMP=file: the hiscore part of the <nvram> file, sent after
// the EEPROM's 128 (zero) bytes as index 4. +HS_OSD_AT=f: the OSD opens at
// frame f (autosave on); an upload the module then asks for is printed as
// HS_UPLOAD lines. +HS_PEEK_AT=f: each entry's bytes in work RAM at frame f,
// as HS_RAM lines.
wire [16:0] hs_addr;
wire  [7:0] hs_wd, hs_q, hs_to_hps;
wire        hs_we, hs_rd, hs_wi, hs_pause, hs_configured, hs_upload_req;
reg         hs_dl = 0, hs_ul = 0, hs_wr = 0, hs_osd = 0;
reg  [7:0]  hs_index = 0, hs_dout = 0;
reg  [24:0] hs_ioaddr = 0;
wire        hs_nv = hs_index == 8'd4;
hiscore #(.HS_ADDRESSWIDTH(17), .HS_SCOREWIDTH(9), .CFG_ADDRESSWIDTH(2), .CFG_LENGTHWIDTH(2)) u_hiscore (
    .clk, .paused(pause_cpu | hs_pause), .reset(rst), .autosave(1'b1),
    .ioctl_upload(hs_ul), .ioctl_upload_req(hs_upload_req), .ioctl_download(hs_dl), .ioctl_wr(hs_wr),
    .ioctl_addr(hs_nv ? hs_ioaddr - 25'd128 : hs_ioaddr),
    .ioctl_index(hs_nv && hs_ioaddr < 25'd128 ? 8'hfe : hs_index),
    .OSD_STATUS(hs_osd), .data_from_hps(hs_dout), .data_from_ram(hs_q), .ram_address(hs_addr),
    .data_to_hps(hs_to_hps), .data_to_ram(hs_wd), .ram_write(hs_we), .ram_intent_read(hs_rd),
    .ram_intent_write(hs_wi), .pause_cpu(hs_pause), .configured(hs_configured)
);
byte unsigned hs_cfg [0:255];
byte unsigned hs_dump[0:1023];
int  hs_cfg_n = 0, hs_dump_n = 0, hs_osd_at = -1, hs_peek_at = -1;
byte unsigned hs_tmp [0:1023];
function automatic int hs_read(string plus);
    string f; int fd, v, n = 0;
    if (!$value$plusargs(plus, f)) return 0;
    fd = $fopen(f, "r");
    if (fd == 0) $fatal(1, "%s: cannot open %s", plus, f);
    while ($fscanf(fd, "%h", v) == 1) begin hs_tmp[n] = 8'(v); n++; end
    $fclose(fd);
    return n;
endfunction
initial begin
    hs_cfg_n = hs_read("HS_CFG=%s");  for (int i = 0; i < hs_cfg_n; i++) hs_cfg[i] = hs_tmp[i];
    hs_dump_n = hs_read("HS_DUMP=%s"); for (int i = 0; i < hs_dump_n; i++) hs_dump[i] = hs_tmp[i];
    void'($value$plusargs("HS_OSD_AT=%d", hs_osd_at));
    void'($value$plusargs("HS_PEEK_AT=%d", hs_peek_at));
end
// the HPS: config, then <nvram>, a byte every 4 clocks; later the upload
int  hs_ph = 0, hs_i = 0, hs_c = 0, hs_ul_n = 0;
wire hs_dl_busy = hs_cfg_n != 0 && hs_ph < 3;
always @(posedge clk) begin
    hs_wr <= 0;
    hs_c  <= hs_c + 1;
    case (hs_ph)
    0: if (hs_cfg_n != 0) begin hs_ph <= 1; hs_i <= 0; hs_c <= 0; hs_index <= 8'd3; hs_dl <= 1; end
    1, 2: if (hs_c == 3) begin
        hs_c <= 0;
        if (hs_i == (hs_ph == 1 ? hs_cfg_n : 128 + hs_dump_n)) begin
            hs_dl <= 0; hs_i <= 0;
            if (hs_ph == 1 && hs_dump_n != 0) begin hs_ph <= 2; hs_index <= 8'd4; end
            else hs_ph <= 3;
        end else begin
            if (hs_i == 0 && hs_ph == 2) hs_dl <= 1;
            hs_ioaddr <= 25'(hs_i);
            hs_dout   <= hs_ph == 1 ? hs_cfg[hs_i] : hs_i < 128 ? 8'd0 : hs_dump[hs_i - 128];
            hs_wr     <= 1;
            hs_i      <= hs_i + 1;
        end
    end
    3: if (hs_upload_req) begin hs_ph <= 4; hs_index <= 8'd4; hs_ul <= 1; hs_i <= 0; hs_c <= 0; hs_ioaddr <= 0; end
    4: if (hs_c == 6) begin
        hs_c <= 0;
        if (hs_i >= 128) $display("HS_UPLOAD %0d %02x", hs_i - 128, hs_to_hps);
        if (hs_i + 1 == 128 + hs_ul_n) begin hs_ul <= 0; hs_ph <= 3; end
        else begin hs_i <= hs_i + 1; hs_ioaddr <= 25'(hs_i + 1); end
    end
    endcase
end
// the upload's length: the entries' lengths in the config
always @* begin
    hs_ul_n = 0;
    for (int e = 16; e + 8 <= hs_cfg_n; e += 8) hs_ul_n += { hs_cfg[e+4], hs_cfg[e+5] };
end

gx_main dut (
    .rst, .clk, .clk_cpu,
    .rom_addr, .rom_cs, .rom_ok, .rom_data,
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr(), .obj_pf_cs(),
    // the ROM readback windows: the bench answers with zero, which is what
    // the board did before they existed
    .tile_base(26'(tile_base)), .obj_base(26'(obj_base)),
    .gfx_cs, .gfx_addr, .gfx_ok, .gfx_data,
    .snd_wr, .snd_rd, .snd_addr, .snd_dout, .snd_din(snd_din_mux),
    .inputs(tb_inputs), .coins(tb_coins), .dsw(16'hFEFF), .service(8'hFF),
    .ee_blank(rst), .ee_load_we(ee_we), .ee_load_addr(ee_a), .ee_load_data(ee_d),
    .offs_x, .offs_y, .primode(cfg_primode), .tile_bpp(cfg_tile_bpp), .obj_layout(cfg_obj_layout),
    .obj_pri_raw(cfg_obj_pri_raw), .vis_x0(cfg_vis_x0), .vis_w(cfg_vis_w),
    .obj_hadj(cfg_obj_hadj), .esc_gen(cfg_esc_gen), .esc_src(cfg_esc_src), .esc_count(cfg_esc_count),
    .esc_copy(cfg_esc_copy), .prot4(cfg_prot4), .esc_sal2(cfg_esc_sal2), .tile_rb66(cfg_tile_rb66),
    // MAME's guns at rest (LIGHT*_X/Y default 0x80): X 165, Y 112
    .guns(cfg_guns), .gun_h({ 16'd165, 16'd165 }), .gun_v({ 16'd112, 16'd112 }), .gun_trig2(1'b0), .orient_fy(cfg_orient_fy), .fj_dma(cfg_fj_dma), .rom_uncached(5'(rom_uncached)),
    .esc_chip(cfg_esc_chip && esc_chip_on != 0), .esc_s10(cfg_esc_s10), .esc_s11n(cfg_esc_s11n), .esc_xor(cfg_esc_xor), .esc_lanes(cfg_esc_lanes),
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .pxl_cen_o(), .unsupported,
    .dbg_addr, .dbg_access, .dbg_we, .dbg_be, .dbg_data, .dbg_ee(), .dbg_rom_hits, .dbg_rom_misses, .dbg_irq(), .dbg_esc(), .dbg_esc_st(), .dbg_obj(), .dbg_mix(), .dbg_line(), .tm_blank_skip(1'b1), .spr_mix_on(spr_mix_sel != 0), .dbg_rom(), .peek_t(1'b0), .peek_addr(20'd0),
    // the SDRAM layout's tile_base: where the packed CPU image ends. +ROM_TOP
    // sets it larger to get the behaviour before gx_main bounded it, when a
    // read above the image's length returned what follows it in SDRAM --
    // with +ROM_JUNK_FROM, what the board did.
    .rom_top(26'(rom_top)), .pause_cpu(pause_cpu | hs_pause), .snd_run,
    .mem_t(md_t), .mem_addr(23'(md_a)), .dbg_mem(dbg_mem),
    .ss_m_req(e_m_req), .ss_m_go(e_m_go), .ss_m_held(e_m_held), .ss_m_done(e_m_done),
    .ss_m_bidx(e_m_bidx), .ss_m_bwe(e_m_bwe), .ss_m_bd(e_m_bd), .ss_m_bq(e_m_bq),
    .ss_mb_req(e_mb_req), .ss_mb_we(e_mb_we), .ss_mb_addr(e_mb_addr), .ss_mb_be(e_mb_be),
    .ss_mb_wd(e_mb_wd), .ss_mb_ack(e_mb_ack), .ss_mb_rd(e_mb_rd),
    .ss_snap(e_snap), .ss_commit(e_commit), .ss_freeze(e_freeze),
    .ss_sel(e_sssel), .ss_en(e_ssen), .ss_addr(e_ssaddr), .ss_we(e_sswe), .ss_wd(e_sswd), .ss_rd(e_ssrd_main),
    .ss_vpos(e_vpos), .ss_hpos(e_hpos), .ss_esc_busy(e_esc_busy), .ss_dma_busy(e_dma_busy),
    .cheat_code(tb_cheat), .cheat_clr(tb_cheat_clr),
    .hs_hold(hs_pause), .hs_on(hs_rd | hs_wi), .hs_addr(hs_addr), .hs_we(hs_we), .hs_wd(hs_wd), .hs_q(hs_q)
);

// +CHEATS=file: cheat codes as the .mra gives them (32 hex digits a line:
// flags, address, compare, data), loaded at frame 2 the way KonamiGX.sv
// loads Main_MiSTer's: cleared, then each code with its strobe
reg [128:0] tb_cheat = 129'd0;
reg         tb_cheat_clr = 1'b0;
logic [127:0] tb_codes [0:15];
int  tb_ncodes = 0, tb_ci = 0, tb_cph = 0;
string tb_cheat_f;
initial if ($value$plusargs("CHEATS=%s", tb_cheat_f)) begin
    int fd; string ln;
    fd = $fopen(tb_cheat_f, "r");
    while (fd != 0 && !$feof(fd) && tb_ncodes < 16) begin
        if ($fgets(ln, fd) > 0 && ln.len() >= 32) begin
            void'($sscanf(ln, "%h", tb_codes[tb_ncodes]));
            tb_ncodes++;
        end
    end
    if (fd != 0) $fclose(fd);
    $display("CHEATS %0d codes from %s", tb_ncodes, tb_cheat_f);
end
always @(posedge clk) if (tb_ncodes != 0 && frame >= 2 && tb_ci <= tb_ncodes) begin
    tb_cph <= tb_cph + 1;
    if (tb_ci == 0) begin
        tb_cheat_clr <= tb_cph < 8;
        if (tb_cph == 16) begin tb_ci <= 1; tb_cph <= 0; end
    end else begin
        if (tb_cph == 0) tb_cheat <= { 1'b0, tb_codes[tb_ci - 1] };
        if (tb_cph == 4) tb_cheat[128] <= 1'b1;
        if (tb_cph == 12) begin tb_cheat[128] <= 1'b0; tb_ci <= tb_ci + 1; tb_cph <= 0; end
    end
end

// ----------------------------------------------------------- save states
// rtl/gx_savestate.sv with a slot in memory (docs/SAVESTATES.md):
//   +SS_SAVE_AT=<frame> +SS_SAVE=<file>   save at that frame into a .ss file:
//                                         Main_MiSTer's format (the slot's
//                                         control word, then the data)
//   +SS_LOAD_AT=<frame> +SS_LOAD=<file>   load one at that frame

gx_savestate u_ssg (
    .clk, .rst,
    .save_req(e_save), .load_req(e_load), .set_id(8'(game)), .busy(e_busy), .err(e_err),
    .esc_busy(e_esc_busy), .dma_busy(e_dma_busy), .vpos(e_vpos), .hpos({ 1'b0, e_hpos }),
    .m_req(e_m_req), .m_go(e_m_go), .m_held(e_m_held), .m_done(e_m_done),
    .m_bidx(e_m_bidx), .m_bwe(e_m_bwe), .m_bd(e_m_bd), .m_bq(e_m_bq),
    .s_req(e_s_req), .s_go(e_s_go), .s_held(e_s_held), .s_done(e_s_done),
    .s_bidx(e_s_bidx), .s_bwe(e_s_bwe), .s_bd(e_s_bd), .s_bq(e_s_bq),
    .ss_snap(e_snap), .ss_commit(e_commit), .snd_freeze(e_freeze),
    .ss_sel(e_sssel), .ss_en(e_ssen), .ss_addr(e_ssaddr), .ss_we(e_sswe), .ss_step(e_step), .ss_wd(e_sswd),
    .ss_rd(e_ssrd_main | e_ssrd_snd | e_ssrd_k8),
    .mb_req(e_mb_req), .mb_we(e_mb_we), .mb_addr(e_mb_addr), .mb_be(e_mb_be), .mb_wd(e_mb_wd),
    .mb_ack(e_mb_ack), .mb_rd(e_mb_rd),
    .sb_req(e_sb_req), .sb_we(e_sb_we), .sb_addr(e_sb_addr), .sb_wd(e_sb_wd), .sb_ack(e_sb_ack), .sb_rd(e_sb_rd),
    .sd_req(e_sd_req), .sd_we(e_sd_we), .sd_addr(e_sd_addr), .sd_wd(e_sd_wd), .sd_ack(e_sd_ack), .sd_rd(e_sd_rd),
    .sl_start, .sl_save, .sl_wv, .sl_wd, .sl_wready, .sl_end, .sl_words, .sl_idle,
    .sl_rv, .sl_rd, .sl_rtake
);

// the slot in DDR3, as on the board: gx_ss_ddr against a model of the port
// (BUSY for a clock in three, reads answered five clocks later), slot 0 at
// 0x3C000000. A .ss file is the slot's bytes, as Main_MiSTer writes them.
wire        sl_wready, sl_idle, sl_rv, ss_own;
wire [15:0] sl_rd;
wire  [7:0] sd_bc, sd_be;
wire [28:0] sd_a;
wire [63:0] sd_din;
wire        sd_rd, sd_we;
reg  [63:0] sd_dout = 0;
reg         sd_rdy = 0;
reg  [ 1:0] sd_ph = 0;
wire        sd_busy = sd_ph == 2'd2;
localparam int SS_DW = 1 << 17;                  // one slot, 1 MB
logic [63:0] ss_ddr [0:SS_DW-1];
localparam [28:0] SS_W0 = 29'h07800000;            // 0x3C000000 / 8
reg  [ 2:0] sd_lat = 0;
reg  [16:0] sd_ra;
gx_ss_ddr u_ss_ddr (
    .clk, .rst, .slot(2'd0), .active(e_busy),
    .sl_start, .sl_save, .sl_wv, .sl_wd, .sl_wready, .sl_end, .sl_words, .sl_idle,
    .sl_rv, .sl_rd, .sl_rtake, .own(ss_own),
    .DDRAM_BUSY(sd_busy), .DDRAM_BURSTCNT(sd_bc), .DDRAM_ADDR(sd_a), .DDRAM_DOUT(sd_dout),
    .DDRAM_DOUT_READY(sd_rdy), .DDRAM_RD(sd_rd), .DDRAM_DIN(sd_din), .DDRAM_BE(sd_be), .DDRAM_WE(sd_we)
);
always @(posedge clk) begin
    sd_ph  <= sd_ph == 2'd2 ? 2'd0 : sd_ph + 2'd1;
    sd_rdy <= 0;
    if (sd_we && !sd_busy) begin
        if (sd_a - SS_W0 >= SS_DW) $fatal(1, "slot write outside slot 0: %h", sd_a);
        for (int k = 0; k < 8; k++)
            if (sd_be[k]) ss_ddr[17'(sd_a - SS_W0)][8*k +: 8] <= sd_din[8*k +: 8];
    end
    if (sd_rd && !sd_busy) begin sd_ra <= 17'(sd_a - SS_W0); sd_lat <= 3'd5; end
    else if (sd_lat != 0) begin
        sd_lat <= sd_lat - 3'd1;
        if (sd_lat == 3'd1) begin sd_dout <= ss_ddr[sd_ra]; sd_rdy <= 1; end
    end
end

reg          e_busy_l = 0, e_saving = 0;
longint      ss_t0 = 0;
always @(posedge clk) begin
    e_save <= 0; e_load <= 0;
    e_busy_l <= e_busy;
    if (!vid_lvbl && lvbl_st) begin
        if (frame == ss_save_at) begin e_save <= 1; e_saving <= 1; ss_t0 = $time; end
        if (frame == ss_load_at) begin e_load <= 1; e_saving <= 0; ss_t0 = $time; end
    end
    if (e_busy_l && !e_busy) begin
        $display("SS %s done at frame %0d: raster %0d/%0d, err %0d, %0d us", e_saving ? "save" : "load",
                 frame, u_ssg.r_v, u_ssg.r_h, e_err, ($time - ss_t0) / 1000000);
        if (e_saving) ss_write();
    end
end

// the slot as Main_MiSTer saves it: the control word, then size * 4 bytes
task automatic ss_write();
    int fd, n;
    logic [63:0] w;
    fd = $fopen(ss_save_f, "wb");
    n = int'(ss_ddr[0][63:32]);
    for (int k = 0; k < 1 + (n + 1) / 2; k++) begin
        w = ss_ddr[k];
        for (int b = 0; b < 8; b++) if (k == 0 || 8 * (k - 1) + b < 4 * n) $fwrite(fd, "%c", w[8*b +: 8]);
    end
    $fclose(fd);
    $display("SS saved %0d 32-bit words (counter %0d) to %s", n, ss_ddr[0][31:0], ss_save_f);
endtask

// read at time 0, and again in a run restored from a snapshot (+RESTORE),
// whose variables are the saved run's
task automatic ss_args();
    void'($value$plusargs("SS_SAVE_AT=%d", ss_save_at));
    void'($value$plusargs("SS_LOAD_AT=%d", ss_load_at));
    void'($value$plusargs("SS_SAVE=%s", ss_save_f));
    if ($value$plusargs("SS_LOAD=%s", ss_load_f)) begin
        int fd, c, k;
        fd = $fopen(ss_load_f, "rb");
        if (fd == 0) $fatal(1, "cannot open %s", ss_load_f);
        k = 0;
        while (k < 8 * SS_DW) begin
            c = $fgetc(fd);
            if (c < 0) break;
            ss_ddr[k / 8][8 * (k % 8) +: 8] = c[7:0];
            k++;
        end
        $fclose(fd);
        $display("SS read %0d bytes from %s into slot 0", k, ss_load_f);
    end
endtask
initial ss_args();
always @(posedge clk) if (reopen) ss_args();

// +PROBE_PIX=x,y,f: at bitmap pixel (x, y) of frame f, what each tilemap
// layer gives the mixer -- { colour[5:0], pixel[7:0] } -- with the K055555's
// display mask and mix enables and the K054338's blend words, a line each
int pp_x = -1, pp_y = -1, pp_f = -1;
initial begin
    string ps;
    if ($value$plusargs("PROBE_PIX=%s", ps)) void'($sscanf(ps, "%d,%d,%d", pp_x, pp_y, pp_f));
end
always @(posedge clk)
    if (frame == pp_f && dut.u_video.u_mix.pxl_cen && dut.u_video.u_mix.bx == 10'(pp_x) && dut.u_video.u_mix.by == 10'(pp_y))
        $display("PROBE_PIX f%0d (%0d,%0d) A %04x B %04x C %04x D %04x spr %0d/%04x disp %02x vinmix %02x vmixon %02x r13 %04x r14 %04x k55_bg %02x %02x grad %0d",
                 frame, pp_x, pp_y, dut.u_video.u_mix.lyr_a, dut.u_video.u_mix.lyr_b, dut.u_video.u_mix.lyr_c, dut.u_video.u_mix.lyr_d,
                 dut.u_video.u_mix.spr_valid, dut.u_video.u_mix.spr_pen,
                 dut.u_video.u_mix.k55[45], dut.u_video.u_mix.k55[33], dut.u_video.u_mix.k55[34],
                 dut.u_video.u_mix.k338[13], dut.u_video.u_mix.k338[14], dut.u_video.u_mix.k55[0], dut.u_video.u_mix.k55[1],
                 dut.u_video.u_mix.bg_grad);
always @(posedge clk)
    if (frame == pp_f && dut.u_video.u_mix.pxl_cen && dut.u_video.u_mix.bx == 10'(pp_x) && dut.u_video.u_mix.by == 10'(pp_y))
        $display("PROBE_OBJ opset %04x coregshift %0d coreg %04x oinprion %02x ocblk %02x",
                 dut.u_video.u_obj.opset, dut.u_video.u_obj.coregshift, dut.u_video.u_obj.coreg,
                 dut.u_video.u_obj.oinprion, dut.u_video.u_obj.ocblk);

// +EE_LOG=file: the 93C46's pins, a line per change of CS/SK/DI or DO:
// "frame clk cs sk di do". +PC_HIT=hex: a line each time the main CPU
// fetches an opcode there (+PC_HIT2: a second address).
int ee_fd = 0;
longint ee_clk = 0;
reg [3:0] ee_pins_l = 4'hf;
wire [3:0] ee_pins = { dut.u_ee.cs, dut.u_ee.sk, dut.u_ee.di, dut.u_ee.dout };
initial begin
    string f;
    if ($value$plusargs("EE_LOG=%s", f)) ee_fd = $fopen(f, "w");
end
always @(posedge clk) begin
    ee_clk <= ee_clk + 1;
    ee_pins_l <= ee_pins;
    if (ee_fd != 0 && ee_pins != ee_pins_l)
        $fwrite(ee_fd, "%0d %0d %b %b %b %b\n", frame, ee_clk, ee_pins[3], ee_pins[2], ee_pins[1], ee_pins[0]);
end
final if (ee_fd != 0) $fclose(ee_fd);

reg [31:0] pc_hit = 32'hffffffff, pc_hit2 = 32'hffffffff;
initial begin
    void'($value$plusargs("PC_HIT=%h", pc_hit));
    void'($value$plusargs("PC_HIT2=%h", pc_hit2));
end
always @(posedge clk)
    if (dut.cpu_cen && dut.busstate == 2'b00 && dut.cpu_clkena && (dut.a32 == pc_hit || dut.a32 == pc_hit2))
        $display("PC_HIT %06x frame %0d clk %0d", dut.a32, frame, ee_clk);

// ----------------------------------------------------------- trace
// The last column is the CPU's interrupt mask (SR bits 8-10), as MAME's
// trace has it: check_gx_main.py compares each level as its own stream.
// It is read from GHDL's conversion under Verilator; ModelSim cannot see into the
// VHDL and writes 0.
`ifdef VERILATOR
wire [2:0] ipl_mask = dut.u_cpu.flagssr[2:0];
`else
wire [2:0] ipl_mask = 3'd0;
`endif
int junk_from = 0;

// The graphics ROM readback port (0xd00000, 0xd4a000), answered from the
// same rows the drawing ports read, in the SDRAM image's layout: one row per
// granule, the region's bytes at 0-4. The set's own layout comes in as
// +TILE_BASE/+OBJ_BASE (build_mra.rtl_arm); answering zero here is why no
// bench could see Crazy Cross's ROM check fail.
int tile_base = 'h200000, obj_base = 'ha00000;
initial begin
    void'($value$plusargs("TILE_BASE=%h", tile_base));
    void'($value$plusargs("OBJ_BASE=%h", obj_base));
end
wire        gfx_cs;
wire [22:0] gfx_addr;
reg         gfx_ok = 0;
reg  [63:0] gfx_data = 0;
always @(posedge clk) begin
    gfx_ok <= 1'b0;
    if (gfx_cs && !gfx_ok) begin
        int a; reg [63:0] row;
        a = int'(gfx_addr) << 3;
        if (a >= obj_base)       row = orom_v[(a - obj_base) >> 3];
        else if (a >= tile_base) row = trom_v[(a - tile_base) >> 3];
        else                     row = 64'd0;
        // granule byte k is the row's byte k
        for (int k = 0; k < 8; k++) gfx_data[8*k +: 8] <= row[63 - 8*k -: 8];
        gfx_ok   <= 1'b1;
    end
end
int rom_top = 'h200000;
// +PAUSE_AT=<frame>: hold the CPU from that frame on, as the Pause button
// does, so what the video path keeps doing without it can be looked at
int pause_at = 0, pause_for = 10;
// +MEMDUMP=<hex byte address>: read four words there the way
// scripts/memdump.py does on the board, and print them. The board reads the
// third word of every group with its high byte zero; this is the same
// request through the same logic, against the bench's own ROM.
int  md_from = 0;
reg  md_t = 0;
reg [22:0] md_a = 0;
wire [87:0] dbg_mem;
initial void'($value$plusargs("MEMDUMP=%h", md_from));

// the same four-word groups scripts/memdump.py asks the board for, through
// the same logic, once the game is up
reg [2:0] md_st = 0;
reg [2:0] md_g  = 0;
reg [7:0] md_wait = 0;
always @(posedge clk) if (md_from != 0) case (md_st)
    3'd0: if (frame == 4) begin md_a <= 23'(md_from >> 1); md_g <= 0; md_st <= 3'd1; end
    3'd1: begin md_t <= ~md_t; md_wait <= 0; md_st <= 3'd2; end
    3'd2: begin
        md_wait <= md_wait + 8'd1;
        if (md_wait > 8'd4 && dbg_mem[64] && dbg_mem[87:65] == md_a + 23'd3) begin
            $display("MEMDUMP %06x  %04x %04x %04x %04x", { md_a, 1'b0 },
                     dbg_mem[15:0], dbg_mem[31:16], dbg_mem[47:32], dbg_mem[63:48]);
            if (md_g == 3'd3) md_st <= 3'd3;
            else begin md_g <= md_g + 3'd1; md_a <= md_a + 23'd4; md_st <= 3'd1; end
        end
    end
    default: ;
endcase
reg pause_cpu = 0;
initial begin
    void'($value$plusargs("PAUSE_AT=%d", pause_at));
    void'($value$plusargs("PAUSE_FOR=%d", pause_for));
end
initial void'($value$plusargs("ROM_TOP=%h", rom_top));

integer ft, seq = 0, frame = 0, frames = 60;
reg     lvbl_l = 1;
`ifdef GX_CPP_CLOCK
assign frame_o = frame;
`endif

always @(posedge clk) if (!rst) begin
    lvbl_l <= vid_lvbl;
    if (dbg_access && (dbg_we || (dbg_addr >= 24'hd00000 && dbg_addr < 24'he00000))) begin
        seq++;
        $fdisplay(ft, "%0d\t%s\t%06X\t%08X\t%08X\t%0d", seq, dbg_we ? "w" : "r",
                  { dbg_addr[23:2], 2'b00 },
                  dbg_addr[1] ? { 16'h0, {8{dbg_be[1]}}, {8{dbg_be[0]}} } : { {8{dbg_be[1]}}, {8{dbg_be[0]}}, 16'h0 },
                  dbg_addr[1] ? { 16'h0, dbg_data } : { dbg_data, 16'h0 }, ipl_mask);
    end
    if (!vid_lvbl && lvbl_l) begin
        frame++;
        hs_osd <= hs_osd_at >= 0 && frame >= hs_osd_at && frame < hs_osd_at + 2;
        if (frame == hs_peek_at)
            for (int e = 16; e + 8 <= hs_cfg_n; e += 8) begin
                int a, n;                           // assigned, not initialised: these are static
                a = { hs_cfg[e+1], hs_cfg[e+2], hs_cfg[e+3] } - 24'hc00000;
                n = { hs_cfg[e+4], hs_cfg[e+5] };
                for (int i = 0; i < n; i++)
                    $display("HS_RAM %06x %02x", 24'hc00000 + a + i,
                             (a + i) % 2 ? dut.u_wram_l.mem[(a + i) / 2] : dut.u_wram_h.mem[(a + i) / 2]);
            end
        // paused for +PAUSE_FOR frames (10 by default), then released: the
        // writes either side must still be MAME's, in MAME's order, or an
        // ack was dropped over the pause
        if (pause_at != 0)
            pause_cpu <= frame >= pause_at && frame < pause_at + pause_for;
        $fdisplay(ft, "# frame %0d", frame);
        $fflush(ft);                    // a snapshot taken here keeps the trace whole
        if (frame % 20 == 0) $display("frame %0d  seq %0d  %t", frame, seq, $time);
        if (frame >= frames) begin
            $fdisplay(ft, "# %0d accesses logged", seq);
            $fclose(ft);
            $display("SND replies exhausted %0d times", snd_miss);
            $display("ROM cache: %0d hits, %0d misses (16-bit counters)", dbg_rom_hits, dbg_rom_misses);
            $display("GX_MAIN_DONE");
            $finish;
        end
    end
end

// ----------------------------------------------------------- pictures
// The visible pixels of each frame shown after marker n, one hex RGB per
// line, to shot_<n>.hex: for n in +SHOT_FROM..+SHOT_TO, and for each n
// listed (hex, one a line) in <out>/shot_frames.hex if it exists.
integer fs, shot_from = -1, shot_to = -1, shot_px = 0, shot_n;
reg     shooting = 0, lvbl_s = 1;
reg     shot_want [0:16383];
task automatic read_shot_list;
    int fl;
    reg [13:0] fr_list [0:1023];
    for (int i = 0; i < 16384; i++) shot_want[i] = 0;
    for (int i = 0; i < 1024; i++) fr_list[i] = 0;
    fl = $fopen({od, "shot_frames.hex"}, "r");
    if (fl != 0) begin
        $fclose(fl);
        $readmemh({od, "shot_frames.hex"}, fr_list);
        for (int i = 0; i < 1024; i++) if (fr_list[i] != 0) shot_want[fr_list[i]] = 1;
    end
endtask
always @(posedge clk) if (!rst) begin
    lvbl_s <= vid_lvbl;
    if (vid_lvbl && !lvbl_s && ((frame >= shot_from && frame <= shot_to) || (frame < 16384 && shot_want[frame]))) begin
        fs = $fopen($sformatf("%sshot_%0d.hex", od, frame), "w");
        shooting <= 1; shot_px = 0; shot_n = frame;
    end else if (!vid_lvbl && lvbl_s && shooting) begin
        $fclose(fs); shooting <= 0;
        if (shot_px != 64512) $display("SHOT %0d: %0d visible pixels", shot_n, shot_px);
    end else if (shooting && dut.pxl_cen && vid_lhbl && vid_lvbl) begin
        $fwrite(fs, "%06x\n", rgb); shot_px++;
    end
end

// ----------------------------------------------------------- probes
// +PROBE_FROM=a +PROBE_TO=b: per frame, what the sprite path did -- DMA
// runs, sprites started drawing, sprite pixels out of the line buffer.
// Only under Verilator, which can reach inside the design.
`ifdef VERILATOR
integer probe_from = -1, probe_to = -1, p_dma, p_draw, p_px, p_shd, p_rom, p_ok, p_we, p_pen;
reg     p_dma_l, lvbl_p = 1, p_cs_l;
always @(posedge clk) if (!rst) begin
    lvbl_p  <= vid_lvbl;
    p_dma_l <= dut.u_video.u_obj.dma_bsy;
    p_cs_l  <= obj_rom_cs;
    if (!vid_lvbl && lvbl_p) begin
        if (frame >= probe_from && frame <= probe_to)
            $display("PROBE frame %0d: dma %0d, drawn %0d, rom req %0d ok %0d, buf we %0d pen %0d, obj px %0d, shadow px %0d, objset1 %02x",
                     frame, p_dma, p_draw, p_rom, p_ok, p_we, p_pen, p_px, p_shd, dut.u_video.u_obj.objset1);
        p_dma = 0; p_draw = 0; p_px = 0; p_shd = 0; p_rom = 0; p_ok = 0; p_we = 0; p_pen = 0;
    end else begin
        if (dut.u_video.u_obj.dma_bsy && !p_dma_l) p_dma++;
        if (dut.u_video.u_obj.dr_start) p_draw++;
        if (obj_rom_cs && !p_cs_l) p_rom++;
        if (obj_rom_ok) p_ok++;
        if (dut.u_video.u_obj.u_draw.u_draw.buf_we) begin
            p_we++;
            if (dut.u_video.u_obj.u_draw.u_draw.buf_din[4:0] != 0) p_pen++;
        end
        if (dut.pxl_cen && dut.u_video.u_obj.pxl_valid) p_px++;
        if (dut.pxl_cen && dut.u_video.u_obj.shd_valid) p_shd++;
    end
end

// +PROBE_DUMP=n: in frame n, the first DMA reads and sprite ROM answers
integer probe_dump = -1, pd_dma = 0, pd_rom = 0;
reg     pd_dma_l = 0;
reg [13:1] pd_dma_a;
always @(posedge clk) if (!rst && frame == probe_dump) begin
    pd_dma_l <= dut.u_video.u_obj.dma_bsy;
    pd_dma_a <= dut.u_video.u_obj.dma_addr;
    if (pd_dma_l && pd_dma < 48 && pd_dma_a != dut.u_video.u_obj.dma_addr) begin
        $display("DUMP dma  %04x -> %04x", { pd_dma_a, 1'b0 }, dut.u_video.u_obj.dma_data);
        pd_dma++;
    end
    if (obj_rom_ok && pd_rom < 24) begin
        $display("DUMP rom  %06x -> %010x", olast, obj_rom_data);
        pd_rom++;
    end
end
`endif

// ----------------------------------------------------------- setup
task automatic run_args;
    void'($value$plusargs("OUT=%s", od));
    void'($value$plusargs("SET=%s", set_name));
    read_shot_list();
    void'($value$plusargs("FRAMES=%d", frames));
    void'($value$plusargs("ROM_WAIT=%d", rom_wait));
    void'($value$plusargs("ROM_JITTER=%d", rom_jitter));
    void'($value$plusargs("SND_TIME_FROM=%d", snd_time_from));
    void'($value$plusargs("SND_OFFSET=%d", snd_offset));
    void'($value$plusargs("SND_STUB=%d", snd_stub));
    void'($value$plusargs("SHOT_FROM=%d", shot_from));
    void'($value$plusargs("SHOT_TO=%d", shot_to));
`ifdef VERILATOR
    void'($value$plusargs("PROBE_FROM=%d", probe_from));
    void'($value$plusargs("PROBE_TO=%d", probe_to));
    void'($value$plusargs("PROBE_DUMP=%d", probe_dump));
`endif
endtask

always @(posedge clk) if (reopen) begin
    run_args();                         // this run's OUT before the trace is reopened there
    ft = $fopen({od, set_name, "_rtl_sys.trace"}, "a");
    $display("RESTORED at frame %0d, seq %0d; running to frame %0d", frame, seq, frames);
end

// The EEPROM image, then reset: a clocked sequence, so that the bench needs
// no delays and builds without --timing. The image goes in after rst
// falls (the part blanks itself while rst is high); the game does not touch
// the EEPROM for hundreds of frames.
byte unsigned ee [0:127];
int          setup_n = 0;
always @(posedge clk) if (setup_n < 160 && !(setup_n == 79 && hs_dl_busy)) begin
    setup_n <= setup_n + 1;
    if (setup_n == 79) rst <= 0;
    ee_we   <= setup_n >= 84 && setup_n < 148;
    ee_a    <= 6'(setup_n - 84);
    ee_d    <= { ee[2*(setup_n-84)+1], ee[2*(setup_n-84)] };    // MAME stores 16-bit words little-endian
end

string rom_file;
initial begin
    integer fd, got, rg, vl, mf;
    run_args();
    if (!$value$plusargs("TNTILES=%d", tntiles)) $fatal(1, "+TNTILES= missing");
    if (!$value$plusargs("ONTILES=%d", ontiles)) $fatal(1, "+ONTILES= missing");
    // +ROM_FILE=path: another program image in place of the set's (a
    // directed test: a few instructions at the reset address)
    if ($value$plusargs("ROM_FILE=%s", rom_file)) fd = $fopen(rom_file, "rb");
    else fd = $fopen({"debug/", set_name, "-rom/maincpu.bin"}, "rb");
    got = $fread(rom, fd); $fclose(fd);
    if (got != ROM_BYTES) $fatal(1, "maincpu.bin: %0d bytes", got);
    // +ROM_JUNK_FROM=<hex CPU address>: what the board holds where the .mra
    // wrote nothing -- MAME's region reads 0 there, the SDRAM whatever was
    // in it. A BIOS that sums the whole window sees the difference.
    if ($value$plusargs("ROM_JUNK_FROM=%h", junk_from))
        for (int i = junk_from; i < ROM_BYTES; i++) rom[i] = 8'(i * 7 + 8'h5a);
    $readmemh({TD, "rom.hex"}, trom_v);
    $readmemh({OD, "rom.hex"}, orom_v);
    fd = $fopen({SD, "snd.hex"}, "r");
    while (!$feof(fd) && rp_n < MAXR)
        if ($fscanf(fd, "%h %h %d\n", rg, vl, mf) == 3) begin
            rp_reg[rp_n] = rg; rp_val[rp_n] = vl; rp_fr[rp_n] = mf; rp_n++;
        end
    $fclose(fd);
    for (int i = 0; i < 16; i++) begin rp_next[i] = 0; rp_last[i] = 8'h00; end
    fd = $fopen({"debug/", set_name, "-nvram/", set_name, "/eeprom"}, "rb");
    got = $fread(ee, fd); $fclose(fd);
    $display("ROM %0d bytes, %0d sound replies, EEPROM %0d bytes", ROM_BYTES, rp_n, got);

    ft = $fopen({od, set_name, "_rtl_sys.trace"}, "w");
    $fdisplay(ft, "# RTL main board: all writes, reads of 0xd00000-0xdfffff");
end

endmodule
