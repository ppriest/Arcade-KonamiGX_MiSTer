// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami GX type 2 main board: the 68EC020 (TG68K.C), MAME's gx_type2_map,
// work RAM, palette, the video (gx_video), the ESC (gx_esc), the EEPROM, the
// I/O ports and the interrupt logic. The sound side is a port: the K056800
// mailbox, which the bench answers until the sound CPU exists (Phase 3).
//
// Reference for everything here is konamigx.cpp; each block names the MAME
// function it follows.
//
// ---- CPU and bus
// TG68KdotC_Kernel directly, with the generics and the ready handshake the
// Phase 0 bench proved against MAME's boot trace (sim/gx_boot_tb): a level
// `ready`, held until the kernel takes the access on a clock-enabled cycle.
// The kernel runs on its own clk_cpu, 24 MHz, since Phase 0 measured its
// standalone Fmax at 49 MHz (docs/ROADMAP.md). clk_cpu is clk / 2 from the
// same PLL at phase 0, so every clk_cpu edge is a clk edge and the paths
// between the two are timed like any other. What the unit needs to know is
// which clk cycles end at a kernel edge: cpu_cen, from a toggle in the
// kernel's domain seen in this one. The benches drive clk_cpu as a second
// clock with coincident edges.
//
// The ROM is behind gx_romcache, the 68EC020's instruction cache sized up:
// a hit is one wait state, the bench's ROM model; the external port is a
// granule of the packed SDRAM image (rtl/memory/gx_sdram_top.sv).
//
// One access unit serves two masters: the CPU, and the ESC while the CPU's
// write that started it is held unacknowledged. Every internal RAM is a
// registered-read gx_sdpram or jtframe RAM: data a clock after the address
// (VRAM: two). The ROM is external, req/ok.
//
// An interrupt acknowledge (FC = 111) is answered at once; TG68K auto-
// vectors (IPL_autovector = 1) but still runs the cycle, at 0xFFFFFFF0 |
// level << 1, which is how HOLD_LINE-style interrupts are cleared here.
//
// ---- interrupts (konamigx.cpp)
//   level 1  vblank: raised at the K053252's INT1 edge if wrport1_1 has
//            0x81 then (or syncen bit 0), and held until the acknowledge
//            cycle or the game's acknowledge through K053252 register 0x0e
//            (MAME: HOLD_LINE, vblank_irq_ack_w's CLEAR_LINE). INT1 rises
//            only after that acknowledge, which is MAME's syncen bit 5.
//            An INT1 that came while the level was disabled is not
//            delivered when it is enabled: it was, once, and Crazy Cross
//            took the interrupt between enabling it (91) and enabling the
//            object DMA's (95); the handler wrote back 90, IRQ 3 never came,
//            and the game stopped with a black screen.
//            syncen bit 0, set by any write of wrport1_1 with bit 7 and bit
//            0, lets the next INT1 through once even if the enable has been
//            cleared since: tbyahhoo writes 91, d1, then 90 and waits for
//            the vblank handler, which writes 91 back.
//   level 2  the K053252's INT2, gated by 0x82 (ack: register 0x0f), with
//            syncen bit 1 as bit 0 for level 1.
//   level 3  object DMA end: MAME's dmastart/dmaend -- at vblank start the
//            DMA busy bit (rdport1_3 bit 1) rises; 384 us later (288 us at
//            8 MHz dots) it falls and, if wrport1_1 has 0x84 or syncen bit 2,
//            IRQ 3 is raised and rdport1_3 bit 7 cleared. Held until
//            acknowledged, as HOLD_LINE.
//   level 4  ESC done, if wrport1_1 bit 4: rdport1_3 bit 3 cleared, held
//            until acknowledged.
//
// ---- not here yet: the K056832/K055673 ROM readback windows (0xd00000,
// 0xd4a000), control_w's reset lines, the watchdog, coin counters.

module gx_main (
    input             rst,
    input             clk,                  // 48 MHz
    input             clk_cpu,              // 24 MHz, clk / 2, phase 0

    // program/data ROM, 0x000000-0x7fffff, one word per request
    output            rom_cs,               // a granule of the packed image (gx_romcache)
    output     [19:0] rom_addr,
    input             rom_ok,
    input      [63:0] rom_data,

    // graphics ROMs
    output     [23:0] tile_rom_addr,
    output            tile_rom_cs,
    input             tile_rom_ok,
    input      [63:0] tile_rom_data,     // the row's bytes, byte 0 in [63:56]
    output     [22:0] obj_rom_addr,
    output            obj_rom_cs,
    output     [22:0] obj_pf_addr,           // the row the sprite scan will draw next
    output            obj_pf_cs,
    input             obj_rom_ok,
    input      [63:0] obj_rom_data,      // the half-row's bytes, byte 0 in [63:56]

    // K056800 mailbox (0xd52000, register n = byte 2n): the bench answers
    output reg        snd_wr,
    output reg        snd_rd,
    output reg [ 3:0] snd_addr,
    output reg [ 7:0] snd_dout,
    input      [ 7:0] snd_din,               // valid the clock after snd_rd

    // board inputs, active low as MAME's ports
    input      [31:0] inputs,               // 0xd5c000: P1 31-24 .. P4 7-0
    input      [ 7:0] coins,                // 0xd5a002: coins/services
    input      [15:0] dsw,                  // 0xd5a000: DSW1, DSW2
    input      [ 7:0] service,              // 0xd5e000 bits 31-24

    // EEPROM image load
    input             ee_blank,             // sweep the 93C46 to all ones (gx_eeprom93c46)
    input             ee_load_we,
    input      [ 5:0] ee_load_addr,
    input      [15:0] ee_load_data,
    input      [ 5:0] ee_rd_addr,           // the NVRAM save reads the 93C46 back
    output     [15:0] ee_rd_data,
    output            ee_written,           // the game changed it (a save is due)

    // per-game K056832 layer offsets
    input  signed [7:0] offs_x [4],
    input  signed [7:0] offs_y [4],
    input      [ 3:0] primode,              // konamigx_mixer_primode for the set
    input      [ 1:0] tile_bpp,             // K056832 depth: 0 5 bpp, 1 6 bpp, 2 8 bpp
    input      [ 1:0] obj_layout,           // K055673 layout: 0 GX, 1 RNG, 2 GX6, 3 LE2
    input      [ 1:0] obj_pri_raw,          // 1 dragoonj's, 2 salmndr2's sprite priority callback
    input      [ 9:0] vis_x0,               // the visible window (gx_board_cfg)
    input      [ 8:0] vis_w,
    input      [ 9:0] obj_hadj,             // the set's K055673 dx - (-26), signed
    input             esc_gen,              // the set's ESC callback generates sprites
    input      [23:0] esc_src,              // from this list
    input      [ 8:0] esc_count,            // of this many entries
    input             esc_copy,             // the callback copies the list (konamigx_esc_alert mode 0)
    input             esc_sal2,             // ... builds it from the object records (mode 1)
    input             prot4,                // 0xcc0000-0xcc0007 is the type 4 Xilinx protection, not the ESC
    input             fj_dma,               // 0xdb0000-0xdb001f is fantjour's DMA (gameDefs special 9)
    input      [ 4:0] rom_uncached,         // clocks an instruction fetch takes while CACR's cache is off
    input             tile_rb66,            // the K056832 window is k_6bpp_rom_long_r (six-byte rows)
    input             guns,                 // le2: the light guns at 0xd44000, P2's trigger at 0xd5e002
    input      [31:0] gun_h,                // le2_gun_H_r
    input      [31:0] gun_v,                // le2_gun_V_r
    input             gun_trig2,            // player 2's trigger
    input             orient_fy,            // ORIENTATION_FLIP_Y sets (gx_video)

    // video out
    output     [23:0] rgb,
    output            vid_lhbl, vid_lvbl, vid_hs, vid_vs,
    output            pxl_cen_o,            // the dot clock enable, for the video output
    output     [ 3:0] pxl_div_o,            // clk a pixel: 8, 6, 4 or 3 (CRT Adjust)
    output            unsupported,

    // observation for the bench
    output     [23:0] dbg_addr,
    output            dbg_access,           // one clock per completed CPU access
    output            dbg_we,
    output     [ 1:0] dbg_be,
    output     [15:0] dbg_data,
    output     [63:0] dbg_ee,               // the 93C46's state (gx_eeprom93c46 dbg)
    output     [15:0] dbg_rom_hits,
    output     [15:0] dbg_rom_misses,
    output     [63:0] dbg_irq,               // interrupt acks per level, the enable byte, the lines
    output     [ 1:0] dbg_esc,               // { the CPU is held on its ESC write, the ESC is busy }
    output     [95:0] dbg_esc_st,            // { count2, SR high byte, ESC completions, gx_esc dbg[63:0] }
    output     [95:0] dbg_obj,               // sprite DMA starts, vblanks, OBJSET1, short lines (probe J)
    output reg [63:0] dbg_k338,              // the last write to K054338 register 14's high byte (probe O)
    output    [135:0] dbg_shd,               // gx_obj's shadow-code-1 tile probe (probe O)
    output    [111:0] dbg_mix,               // the mixer's registers (probe L)
    output    [131:0] dbg_line,              // line time, tilemap and sprites (probe T)
    input             tm_blank_skip,         // gx_tilemap's blank-row skip on
    output     [83:0] dbg_rom,               // the last granule the CPU cache fetched (probe M)
    input             peek_t,                // JTAG: read one granule of the packed image
    input      [19:0] peek_addr,
    // JTAG: read four words of anything the CPU can read (scripts/memdump.py)
    input             pause_cpu,           // hold the 68020 where it is (the Pause button)
    output            snd_run,             // control_w bit 22: the sound CPU runs
    input      [25:0] rom_top,             // SDRAM bytes the packed CPU image occupies
    // the graphics regions, and the port the ROM readback windows read them
    // back through
    input      [25:0] tile_base,
    input      [25:0] obj_base,
    output reg        gfx_cs,
    output reg [22:0] gfx_addr,
    input             gfx_ok,
    input      [63:0] gfx_data,
    input             mem_t,
    input      [23:1] mem_addr,
    output     [87:0] dbg_mem                // { addr, done, the four words }
);

// ------------------------------------------------------------ clocks
// cpu_cen: this clk cycle ends at a clk_cpu edge. cpu_t toggles at each
// kernel edge; cpu_t_d follows a clk later; they agree in the second of the
// two clk cycles of a kernel period, the one the kernel samples at the end of.
reg  cpu_t = 0, cpu_t_d = 0;
always @(posedge clk_cpu) cpu_t <= ~cpu_t;
always @(posedge clk)     cpu_t_d <= cpu_t;
wire cpu_cen = cpu_t == cpu_t_d;
reg  [3:0] pdiv = 0;
reg  pxl_cen = 0, pxl2_cen = 0;
reg  [7:0] wrport2;
wire [3:0] pdiv_n = wrport2[1:0] == 2'd0 ? 4'd8 :    // 6 MHz
                    wrport2[1:0] == 2'd1 ? 4'd6 :    // 8 MHz
                    wrport2[1:0] == 2'd2 ? 4'd4 : 4'd3;
assign pxl_cen_o = pxl_cen;
assign pxl_div_o = pdiv_n;
// control_w (0xd58000) bits 23:16 are wrport2; bit 22 releases the sound CPU
// and DSP from reset (konamigx.cpp control_w)
assign snd_run = wrport2[6];

always @(posedge clk) begin
    pdiv     <= pdiv + 4'd1 >= pdiv_n ? 4'd0 : pdiv + 4'd1;
    pxl_cen  <= pdiv == 0;
    pxl2_cen <= pdiv == 0 || pdiv == { 1'b0, pdiv_n[3:1] };
end

// ------------------------------------------------------------ CPU
wire [31:0] a32;
wire [15:0] cpu_dout;
wire [ 1:0] busstate;
wire [ 7:0] cpu_sr;                          // T.S.0III (TG68K FlagsSR)
wire        nWr, nUDS, nLDS;
wire [ 2:0] fc;
wire [ 3:0] cacr;                           // the 68EC020's CACR (EI is bit 0)
reg  [15:0] cpu_din;
reg  [15:0] u_din;                          // the access unit's read data
reg         ready;
reg  [ 2:0] ipl_n;                          // active low, as the kernel expects
wire        mem_needed = busstate != 2'b01;
wire        fast_rdy;                       // the unit's ack, straight to the kernel
// Pause holds the kernel's clock enable low, which is a wait state as far as
// it is concerned: it stops between instructions or mid-access, and resumes
// exactly where it was. Everything else keeps running -- the video, so the
// picture stays up, and the sprite DMA, which re-reads the same list.
//
// The handshake has to be held with it. An access that completes while
// paused is acknowledged to a kernel that is not listening, so the two
// places that retire an ack on a kernel edge wait for the pause to lift as
// well; otherwise the ack is lost and the kernel repeats the access when it
// wakes -- the fault the ESC's release had (LESSONS_LEARNED).
wire        cpu_clkena = (!mem_needed || ready || fast_rdy) && !pause_cpu;
wire        cpu_take   = cpu_cen && !pause_cpu;

TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
    .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
    .BarrelShifter(0), .MUL_Hardware(1)
) u_cpu (
    .clk(clk_cpu), .nReset(~rst), .clkena_in(cpu_clkena),
    .data_in(fast_rdy ? u_din : cpu_din), .IPL(ipl_n), .IPL_autovector(1'b1), .berr(1'b0),
    .CPU(2'b11),
    .addr_out(a32), .data_write(cpu_dout),
    .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
    .busstate(busstate), .longword(), .nResetOut(), .FC(fc),
    .clr_berr(), .skipFetch(), .regin_out(), .CACR_out(cacr), .VBR_out(), .FlagsSR_out(cpu_sr)
);

// ------------------------------------------------------------ registers
reg  [7:0] wrport1_0, wrport1_1, rdport1_3, syncen;
reg  [7:0] vram_bank;                       // K056832 m_regs[0x19], low byte
reg [15:0] esc_hi;
reg [15:0] p4_op;                           // type4_prot_w: the command word
reg        p4_op_v, p4_clk;                 // m_last_prot_op != -1, m_last_prot_clk
reg        esc_p4;
reg        esc_fj;
reg [15:0] fjw [0:15];                      // fantjour_dma_w's eight dwords, as words
reg [ 7:0] fj_mode, fj_sz2;
reg [23:0] fj_sa, fj_da;
reg [15:0] fj_db;
reg [31:0] fj_x;

// ------------------------------------------------------------ memories
// work RAM, 0xc00000-0xc1ffff: two byte lanes of 64K
reg         wr_we_h, wr_we_l;
reg  [15:0] wr_a;
reg  [15:0] wr_d;
wire [ 7:0] wr_qh, wr_ql;
gx_sdpram #(.AW(16), .DW(8)) u_wram_h ( .clk, .we(wr_we_h), .wa(wr_a), .d(wr_d[15:8]), .ra(wr_a), .q(wr_qh) );
gx_sdpram #(.AW(16), .DW(8)) u_wram_l ( .clk, .we(wr_we_l), .wa(wr_a), .d(wr_d[ 7:0]), .ra(wr_a), .q(wr_ql) );

// palette, 0xd90000-0xd97fff: 8K x 32 in four byte lanes. The colour bytes
// live in gx_mixer's palette, which the CPU writes and reads back through
// gx_video (pal_q); the x byte is RAM too (the RAM test checks it) and is
// kept here.
reg  [3:0]  pl_we;                          // { x, R, G, B }
reg  [12:0] pl_a;
reg  [15:0] pl_d;
wire [7:0]  pl_q [4];
wire [23:0] pal_q;
gx_sdpram #(.AW(13), .DW(8)) u_pal_x ( .clk, .we(pl_we[3]), .wa(pl_a),
    .d(pl_d[15:8]), .ra(pl_a), .q(pl_q[3]) );                           // x: high byte
assign pl_q[2] = pal_q[23:16];
assign pl_q[1] = pal_q[15:8];
assign pl_q[0] = pal_q[7:0];

// ------------------------------------------------------------ video
reg         tm_reg_we, tbank_we, vram_we, vram_rd, spr_ram_cs, k46_cs, k55_we, crtc_cs;
reg  [ 1:0] k47_we, k338_we;                // byte lanes: the game writes some of these bytes alone
reg  [ 1:0] spr_ram_we, tm_be, vram_be, k46_dsn;
reg  [ 4:0] tm_addr;
reg  [15:0] bus_d16;
reg  [ 2:0] tbank_addr, k47_addr;
reg  [ 7:0] tbank_din, k55_din, crtc_din;
reg  [15:0] vram_addr;
reg  [13:1] spr_ram_addr;
reg  [ 3:0] k46_addr, k338_addr, crtc_addr;
reg  [ 5:0] k55_addr;
wire [15:0] vram_dout, spr_ram_dout;
wire        int1, int2, obj_dma_busy, obj_ln_short;
reg         obj_dma_trig;      // start the sprite DMA (below: the ESC has finished)
wire        esc_busy, esc_irq, esc_req, esc_we, esc_ack;

// the tile ROM readback's address and bank (declared before gx_video, which
// drives them; used by the readback windows below)
wire [22:1] rmrd_addr;
wire [31:0] tile_gfx_bank;
gx_video u_video (
    .rst, .clk, .pxl_cen, .pxl2_cen, .obj_vmirror(orient_fy),
    .crtc_cs, .crtc_addr, .crtc_din, .crtc_dout(), .int1, .int2,
    .tm_reg_we, .tm_reg_addr(tm_addr), .tm_reg_din(bus_d16), .tm_reg_be(tm_be),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd, .vram_addr, .vram_din(bus_d16), .vram_be, .vram_dout,
    .offs_x, .offs_y,
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .spr_ram_cs, .spr_ram_we, .spr_ram_addr, .spr_ram_din(bus_d16), .spr_ram_dout,
    .k46_cs, .k46_we(k46_cs), .k46_addr, .k46_din(bus_d16), .k46_dsn,
    .k47_we, .k47_addr, .k47_din(bus_d16), .wrport2, .primode, .tile_bpp, .obj_layout, .obj_pri_raw, .vis_x0, .vis_w, .obj_hadj,
    .obj_dma_trig(obj_dma_trig), .obj_dma_hold(esc_busy), .dbg_mix, .dbg_shd, .dbg_line, .tm_blank_skip,
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr, .obj_pf_cs,
    .rmrd_addr, .tile_gfx_bank,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din(bus_d16),
    .bg_grad(wrport1_0[5]),
    .pal_we(pl_we[2:0]), .pal_addr(pl_a), .pal_din({ pl_d[7:0], pl_d }), .pal_q,
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .unsupported, .obj_dma_busy, .obj_ln_short
);

// ------------------------------------------------------------ EEPROM
wire ee_do;
gx_eeprom93c46 u_ee (
    .rst, .clk, .blank(ee_blank), .cs(wrport1_0[1]), .sk(wrport1_0[2]), .di(wrport1_0[0]), .dout(ee_do), .dbg(dbg_ee),
    .load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data),
    .rd_addr(ee_rd_addr), .rd_data(ee_rd_data), .written(ee_written)
);

// ------------------------------------------------------------ ESC
reg         esc_start;
reg  [23:0] esc_data;
wire [79:0] esc_dbg;
reg  [ 7:0] esc_done = 0;                    // completions (free-running)
always @(posedge clk) if( esc_irq ) esc_done <= esc_done + 1'd1;
assign dbg_esc_st = { esc_dbg[79:64], cpu_sr, esc_done, esc_dbg[63:0] };
wire [23:1] esc_addr;
wire [ 1:0] esc_be;
wire [15:0] esc_dout;

gx_esc u_escm (
    .rst, .clk, .start(esc_start), .data(esc_data), .p4(esc_p4), .fj(esc_fj), .fj_mode, .fj_sz2, .fj_sa, .fj_da, .fj_db, .fj_x, .busy(esc_busy), .irq(esc_irq), .dbg(esc_dbg),
    .gen_en(esc_gen), .gen_src(esc_src), .gen_count(esc_count), .gen_copy(esc_copy), .gen_sal2(esc_sal2),
    .m_req(esc_req), .m_we(esc_we), .m_addr(esc_addr), .m_be(esc_be), .m_dout(esc_dout),
    .m_din(u_din), .m_ack(esc_ack)
);

// ------------------------------------------------------------ JTAG reads
// A third bus master, below the ESC and the CPU: on a toggle of mem_t it
// reads the four words at mem_addr and holds them on the probe. It is how
// the board's own memory is read out (scripts/memdump.py) -- the benches
// reproduce MAME from a capture, and this is the same capture taken from
// the board instead. It steals four bus cycles, far fewer than the ESC
// takes, so a game keeps running while it is read.
// mem_t and mem_addr come from the probe's clock, not this one. The toggle
// goes through two flops before it is believed, which leaves the address
// stable for two clocks before it is sampled: taken directly, a group could
// be read at the address of the group before (the read stalled every few
// dozen groups until this was added).
reg         md_t1, md_t2;
always @(posedge clk) begin md_t1 <= mem_t; md_t2 <= md_t1; end

reg         md_s, md_busy, md_req;
reg  [ 1:0] md_w;                            // which of the four words
reg  [23:1] md_addr;
reg  [63:0] md_data;
wire        md_ack;

always @(posedge clk) begin
    if( rst ) begin
        md_busy <= 0; md_req <= 0; md_s <= md_t2; md_w <= 0;
    end else if( md_busy ) begin
        if( md_ack ) begin
            md_data[16*md_w +: 16] <= u_din;
            if( md_w == 2'd3 ) begin md_busy <= 0; md_req <= 0; end
            else begin md_w <= md_w + 2'd1; md_addr <= md_addr + 23'd1; end
        end
    end else if( md_s != md_t2 ) begin
        md_s    <= md_t2;
        md_busy <= 1; md_req <= 1; md_w <= 0;
        md_addr <= mem_addr;
    end
end
assign dbg_mem = { md_addr, !md_busy, md_data };

// CPU-side state (the block that drives it is below the unit)
localparam [1:0] C_IDLE = 0, C_BUSY = 1, C_ESC = 2, C_READY = 3;
reg  [1:0] cst;
reg        esc_seen;

// ------------------------------------------------------------ access unit
// A request is { we, addr, be, data }; the unit answers with u_din and a
// one-clock u_ack.
localparam [2:0] U_IDLE = 0, U_WAIT = 1, U_ROM = 2, U_TB2 = 3, U_SND = 4, U_GFX = 5;
reg  [2:0]  ust;
reg  [2:0]  ucnt;
reg         u_ack, u_esc, u_md;             // whose access is in progress
reg  [23:1] ua_r;                           // the request, held for the access
reg  [ 1:0] ube_r;
reg         uwe_r;
reg  [15:0] ud_r;
reg  [ 3:0] usrc;                           // where the read data comes from

localparam [3:0] R_ZERO=0, R_WRAM=1, R_PAL=2, R_VRAM=3, R_SPR=4, R_IO=5, R_SND=6, R_REGS=7;

reg  [15:0] io_q;

wire        cpu_req_now;
// A request is decoded on the clock it is taken, straight from its source,
// so a RAM access answers two clocks after the kernel's address -- in time
// for the next cpu_cen: one wait state, Phase 0's budget (docs/ROADMAP.md).
// ua/ube/uwe/ud are the source while idle and the held request after.
wire        take_esc = ust == U_IDLE && esc_req && !u_ack;
wire        take_md  = ust == U_IDLE && !take_esc && md_req && !u_ack;
wire        take_cpu = ust == U_IDLE && !take_esc && !take_md && cpu_req_now;
wire        take     = take_esc || take_md || take_cpu;
wire [23:1] ua  = ust != U_IDLE ? ua_r  : take_esc ? esc_addr : take_md ? md_addr : a32[23:1];
wire [ 1:0] ube = ust != U_IDLE ? ube_r : take_esc ? esc_be   : take_md ? 2'b11   : { ~nUDS, ~nLDS };
wire        uwe = ust != U_IDLE ? uwe_r : take_esc ? esc_we   : take_md ? 1'b0    : !nWr;
wire [15:0] ud  = ust != U_IDLE ? ud_r  : take_esc ? esc_dout : take_md ? 16'd0   : cpu_dout;
wire [23:0] ub  = { ua, 1'b0 };             // byte address of the word

// ---- the register copy, for a capture from the board
// The video chips' registers are write-only (MAME's gx map has no read
// handler for them), so scripts/mame/capture.lua rebuilds them from a tap
// on the CPU's writes. This keeps the same thing here: every write to
// those ranges, as the chips are given it, in a small RAM that only the
// memory reader (take_md, scripts/memdump.py) reads, at 0xe00000 + 2 *
// word -- nothing the game can reach. scripts/board_capture.py lays it out
// as capture.lua's reg_*.bin files, so the video benches can render the
// board's own state.
//   words 0x00-0x1f  d40000-d4003f  K056832
//         0x20-0x27  d44000-d4400f  tile bank
//         0x28-0x2b  d48000-d48007  K053246
//         0x2c-0x33  d4a010-d4a01f  K055673
//         0x34-0x43  d4c000-d4c01f  K053252
//         0x44-0xc3  d50000-d500ff  K055555
//         0xc4-0xd3  d80000-d8001f  K054338
//         0xd4-0xd5  d56000-d56003  write port 1
//         0xd6-0xd7  d58000-d58003  write port 2
reg  [8:0] rg_wa;
reg        rg_in;
always @* begin
    rg_in = 1'b1;
    if(      ub >= 24'hd40000 && ub < 24'hd40040 ) rg_wa = 9'h000 + 9'(ua[5:1]);
    else if( ub >= 24'hd44000 && ub < 24'hd44010 ) rg_wa = 9'h020 + 9'(ua[3:1]);
    else if( ub >= 24'hd48000 && ub < 24'hd48008 ) rg_wa = 9'h028 + 9'(ua[2:1]);
    else if( ub >= 24'hd4a010 && ub < 24'hd4a020 ) rg_wa = 9'h02c + 9'(ua[3:1]);
    else if( ub >= 24'hd4c000 && ub < 24'hd4c020 ) rg_wa = 9'h034 + 9'(ua[4:1]);
    else if( ub >= 24'hd50000 && ub < 24'hd50100 ) rg_wa = 9'h044 + 9'(ua[7:1]);
    else if( ub >= 24'hd80000 && ub < 24'hd80020 ) rg_wa = 9'h0c4 + 9'(ua[4:1]);
    else if( ub >= 24'hd56000 && ub < 24'hd56004 ) rg_wa = 9'h0d4 + 9'(ua[1]);
    else if( ub >= 24'hd58000 && ub < 24'hd58004 ) rg_wa = 9'h0d6 + 9'(ua[1]);
    else begin rg_wa = 9'd0; rg_in = 1'b0; end
end
wire        rg_we = take && uwe && rg_in && !take_md;
reg  [8:0]  rg_ra;
wire [7:0]  rg_qh, rg_ql;
gx_sdpram #(.AW(9), .DW(8)) u_rgh ( .clk, .we(rg_we && ube[1]), .wa(rg_wa), .d(ud[15:8]), .ra(rg_ra), .q(rg_qh) );
gx_sdpram #(.AW(9), .DW(8)) u_rgl ( .clk, .we(rg_we && ube[0]), .wa(rg_wa), .d(ud[ 7:0]), .ra(rg_ra), .q(rg_ql) );
assign esc_ack = u_ack && u_esc;
assign md_ack  = u_ack && u_md;

// The CPU addresses the packed image actually backs: the BIOS, and 0x200000
// up to the image's length. konamigx.cpp maps the whole region and leaves
// what no ROM loads as zero; here the tile graphics follow the CPU image in
// SDRAM, so a read outside these windows came back as graphics.
//
// It is not a corner: daiskiss's ESC takes a sprite's piece list from
// 0x4f0080, which is zero in MAME and tile data here, so it read a count of
// 32,497 pieces and walked them, holding the bus for frames at a time. The
// sprite list was left half written -- the stray graphics in the top-left
// corner on the board (docs/ROADMAP.md).
wire [23:0] cpu_end    = 24'h200000 + ( rom_top[23:0] - 24'h020000 );
wire        rom_backed = ub < 24'h020000 || ( ub >= 24'h200000 && ub < cpu_end );

function [7:0] gfx_byte( input [2:0] k );
    gfx_byte = gfx_data[8*k +: 8];
endfunction

// ------------------------------------------------------ ROM readback windows
// The game checksums its own graphics ROMs by reading them back through the
// chips: 0xd00000 the K056832's, 0xd4a000 the K055673's. Without them every
// ROM test reports BAD, and Crazy Cross will not go in-game.
//
// Both windows name a byte of a region whose rows are five bytes, which the
// SDRAM image holds as eight (four, then the fifth at offset 4). MAME's
// k056832 rom_read_b computes base = (o/4)*5 + (o%4)*2 and reads base, then
// base+1 on the next read of the same address -- m_rom_half, which a VRAM
// read clears. Dividing that by five to find the row is avoidable: with
// q = o/4 and r = o%4 the row and the byte within it fall out of r alone.
reg         rom_half;
reg  [ 2:0] gfx_sel;                         // byte within the granule
reg         gfx_five;                        // the fifth-bit part (one byte)
reg         gfx_word;                        // a 16-bit word, not a byte

// ub is the word address; the window is read a byte at a time, so which byte
// comes from the strobe -- UDS the even one, LDS the odd. Taking ub alone
// gave the even byte for both lanes, so every other byte of the checksum was
// a repeat and the test read the ROM as something it is not.
wire [23:0] tr_ba   = ub + ( ube[1] ? 24'd0 : 24'd1 );
wire [24:0] tr_o    = 25'(tr_ba - 24'hd00000) + { tile_gfx_bank[11:0], 13'd0 };
wire [22:0] tr_q    = tr_o[24:2];
wire [ 1:0] tr_r    = tr_o[1:0];
// { row offset from q, byte within the row } for each r, and again for the
// second half (base+1)
reg  [22:0] tr_row;
reg  [ 2:0] tr_bir;
always @* begin
    // k_6bpp_rom_long_r: base = (o/4)*6 + (o%4)*2, rows of six
    if( tile_rb66 ) begin
        tr_row = tr_r == 2'd3 ? tr_q + 23'd1 : tr_q;
        tr_bir = tr_r == 2'd3 ? { 2'd0, rom_half } : { tr_r[1:0], rom_half };
    end else
    case( { rom_half, tr_r } )
        3'b000: begin tr_row = tr_q;            tr_bir = 3'd0; end
        3'b001: begin tr_row = tr_q;            tr_bir = 3'd2; end
        3'b010: begin tr_row = tr_q;            tr_bir = 3'd4; end
        3'b011: begin tr_row = tr_q + 23'd1;    tr_bir = 3'd1; end
        3'b100: begin tr_row = tr_q;            tr_bir = 3'd1; end
        3'b101: begin tr_row = tr_q;            tr_bir = 3'd3; end
        3'b110: begin tr_row = tr_q + 23'd1;    tr_bir = 3'd0; end
        3'b111: begin tr_row = tr_q + 23'd1;    tr_bir = 3'd2; end
    endcase
end
// the fifth byte of a row sits at offset 4 of its granule, the other four at 0-3
wire [25:0] tr_byte = tile_base + { tr_row, 3'b000 } + { 23'd0, tr_bir };

// the sprite window: eight offsets, four words of the four-byte part and two
// bytes of the fifth-bit part (k055673_5bpp_rom_word_r)
wire [ 2:0] sr_off  = ub[3:1];
wire [22:1] sr_w    = rmrd_addr + ( sr_off == 3'd0 ? 22'd2 :
                                    sr_off == 3'd1 ? 22'd3 :
                                    sr_off == 3'd5 ? 22'd1 : 22'd0 );
// sr_w counts in words, so its value is the byte offset halved: the region
// byte is i = 2*sr_w, and a row's four bytes are the granule's first four
wire [25:0] sr_byte4 = obj_base + { 2'd0, sr_w[22:2], 3'b000 } + { 24'd0, sr_w[1], 1'b0 };
// cases 2,3 and 6,7: romofs/2 is a byte of the fifth-bit part, +1 for 2,3.
// romofs is rmrd_addr's own value, so romofs/2 is it shifted once more.
wire [22:0] sr_five = { 1'b0, rmrd_addr[22:2] } + ( sr_off[2] ? 23'd0 : 23'd1 );
wire [25:0] sr_byte5 = obj_base + { sr_five, 3'b000 } + 26'd4;
wire        sr_is5   = sr_off[1:0] == 2'd2 || sr_off[1:0] == 2'd3;

// ------------------------------------------------------------ ROM cache
reg         cr_cs;
reg  [22:1] cr_addr;
wire        cr_ok;
wire [15:0] cr_data;
gx_romcache u_cache (
    .clk, .rst,
    .a_pre(ua[22:1]), .cs(cr_cs), .addr(cr_addr), .ok(cr_ok), .data(cr_data),
    .p_cs(rom_cs), .p_addr(rom_addr), .p_ok(rom_ok), .p_data(rom_data),
    .dbg_hits(dbg_rom_hits), .dbg_misses(dbg_rom_misses),
    .dbg_addr(dbg_rom[83:64]), .dbg_data(dbg_rom[63:0]), .peek_t, .peek_addr
);
reg  esc_started;                           // the CPU's write started the ESC

// The 68EC020's instruction cache (CACR bit 0, EI). The games run their
// power-on tests with it off -- Twin Bee from frame 244 to 827, Crazy Cross
// to 764, Dragoon Might to 1059, by MAME's CACR -- and on the board every
// instruction fetch then goes to the program ROM. gx_romcache would answer
// most of them in a clock or two, the CPU ran the tests' timeout loops far
// faster than the board, and the loops gave up waiting for the sound CPU
// (MAME underclocks the CPU for twelve seconds instead, init_posthack).
// With the cache off, an instruction fetch (FC program space) takes at
// least rom_uncached clocks from its issue. Twin Bee in the main bench with
// the real sound board: 0 and 4 stop in the sound test as the board did, 6
// and 8 pass it and reach the game; KonamiGX.sv uses 6, the board's SDRAM
// misses only adding to it. Data reads are unchanged: the
// real cache holds instructions only, so this is still faster than the
// board there.
reg  [ 4:0] rom_wc;
reg         rom_slow, rom_got;
reg  [15:0] rom_q;

always @(posedge clk) begin
    u_ack <= 0;
    { tm_reg_we, tbank_we, vram_we, vram_rd, spr_ram_cs, k46_cs, k55_we, crtc_cs } <= 0;
    k47_we <= 0; k338_we <= 0;
    { wr_we_h, wr_we_l } <= 0;
    pl_we <= 0;
    snd_wr <= 0; snd_rd <= 0;
    spr_ram_we <= 0;
    if( rst ) begin
        ust <= U_IDLE; cr_cs <= 0;
        wrport1_0 <= 0; wrport1_1 <= 0; wrport2 <= 0; vram_bank <= 0;
        esc_start <= 0; esc_started <= 0;
        p4_op_v <= 0; p4_clk <= 0; esc_p4 <= 0; esc_fj <= 0;
    end else case( ust )
    // the granule the readback window asked for
    U_GFX: if( gfx_ok ) begin
        gfx_cs <= 0;
        // a word from the sprite window, or the byte in the lane that asked
        u_din  <= gfx_word  ? { gfx_byte(gfx_sel + 3'd1), gfx_byte(gfx_sel) }
                : ube_r[1]  ? { gfx_byte(gfx_sel), 8'd0 }
                            : { 8'd0, gfx_byte(gfx_sel) };
        // the K056832 window alternates halves on repeated reads of the same
        // address; the K055673 window does not
        if( !gfx_five && !gfx_word ) rom_half <= ~rom_half;
        u_ack <= 1;
        ust   <= U_IDLE;
    end
    U_IDLE: begin
        if( cst == C_ESC ) esc_started <= 0;
        // the ESC while it is busy, the CPU otherwise: decode and issue
        if( take ) begin
            u_esc <= take_esc; u_md <= take_md;
            ua_r <= ua; ube_r <= ube; uwe_r <= uwe; ud_r <= ud;
            ust     <= U_WAIT;
            bus_d16 <= ud;
            usrc    <= R_ZERO;
            ucnt    <= 3'd1;                     // default: done next clock
            if( take_cpu && fc == 3'b111 ) begin
                usrc <= R_ZERO;                  // interrupt acknowledge
            end else if( take_md && ub >= 24'he00000 && ub < 24'he00400 ) begin
                rg_ra <= ua[9:1]; usrc <= R_REGS; ucnt <= 3'd2;      // the register copy
            end else if( ub < 24'h800000 ) begin
                if( rom_backed ) begin
                    cr_addr <= ua[22:1]; cr_cs <= 1; ust <= U_ROM;
                    rom_wc <= 5'd0; rom_got <= 1'b0;
                    rom_slow <= take_cpu && fc[1:0] == 2'b10 && !cacr[0];
                end else usrc <= R_ZERO;
            end else if( ub >= 24'hc00000 && ub < 24'hc20000 ) begin
                wr_a <= ua[16:1]; wr_d <= ud;
                if( uwe ) begin wr_we_h <= ube[1]; wr_we_l <= ube[0]; end
                usrc <= R_WRAM; ucnt <= 3'd2;
            end else if( fj_dma && ub >= 24'hdb0000 && ub < 24'hdb0020 ) begin
                // fantjour_dma_w: the registers, and a write to register 0's
                // top byte (the mode) starts the DMA, which holds the CPU
                // until it is done -- MAME runs it on the write, in no time
                if( uwe ) begin
                    if( ube[1] ) fjw[ua[4:1]][15:8] <= ud[15:8];
                    if( ube[0] ) fjw[ua[4:1]][ 7:0] <= ud[ 7:0];
                    if( ua[4:1] == 4'd0 && ube[1] ) begin
                        fj_mode <= ud[15:8];
                        fj_sz2  <= ube[0] ? ud[7:0] : fjw[0][7:0];
                        fj_sa   <= { fjw[2][7:0], fjw[3] };
                        fj_da   <= { fjw[7][7:0], fjw[8] };
                        fj_db   <= fjw[11];
                        fj_x    <= { fjw[12], fjw[13] };
                        esc_fj <= 1; esc_p4 <= 0; esc_start <= 1; esc_started <= 1;
                    end
                end
            end else if( prot4 && ub >= 24'hcc0000 && ub < 24'hcc0008 ) begin
                // type4_prot_w, the high word of each dword (the only writes
                // winspike makes, by a MAME write tap): 0xcc0004 is the
                // command; bit 9 of 0xcc0000 is a clock, and its falling edge
                // runs the command, once
                if( uwe && ub[2:1] == 2'b10 ) begin p4_op <= ud; p4_op_v <= 1; end
                if( uwe && ub[2:1] == 2'b00 ) begin
                    p4_clk <= ud[9];
                    if( p4_clk && !ud[9] && p4_op_v ) begin
                        esc_data <= { 8'd0, p4_op }; esc_p4 <= 1; esc_fj <= 0; esc_start <= 1; esc_started <= 1;
                        p4_op_v <= 0;
                    end
                end
            end else if( ub >= 24'hcc0000 && ub < 24'hcc0004 ) begin
                // esc_w: the 32-bit write arrives as two words; the second starts it
                if( uwe && !ub[1] ) esc_hi <= ud;
                if( uwe &&  ub[1] ) begin esc_data <= { esc_hi[7:0], ud }; esc_p4 <= 0; esc_fj <= 0; esc_start <= 1; esc_started <= 1; end
            end else if( ub >= 24'hd00000 && ub < 24'hd02000 ) begin
                // K056832 ROM readback, a byte at a time
                gfx_cs <= 1; gfx_addr <= tr_byte[25:3]; gfx_sel <= tr_byte[2:0];
                gfx_five <= 1'b0; gfx_word <= 1'b0;
                ust <= U_GFX;
            end else if( ub >= 24'hd4a000 && ub < 24'hd4a010 ) begin
                // K055673 ROM readback: four words of the four-byte part,
                // two bytes of the fifth-bit part
                gfx_cs <= 1;
                gfx_addr <= sr_is5 ? sr_byte5[25:3] : sr_byte4[25:3];
                gfx_sel  <= sr_is5 ? sr_byte5[2:0]  : sr_byte4[2:0];
                gfx_five <= sr_is5; gfx_word <= !sr_is5;
                ust <= U_GFX;
            end else if( ub >= 24'hd20000 && ub < 24'hd24000 ) begin
                spr_ram_cs <= 1; spr_ram_addr <= ua[13:1];
                if( uwe ) spr_ram_we <= ube;
                usrc <= R_SPR; ucnt <= 3'd2;
            end else if( ub >= 24'hd40000 && ub < 24'hd40040 ) begin
                if( uwe ) begin
                    tm_reg_we <= 1; tm_addr <= ua[5:1]; tm_be <= ube;
                    if( ua[5:1] == 5'h19 && ube[0] ) vram_bank <= ud[7:0];
                end
            end else if( ub >= 24'hd44000 && ub < 24'hd44008 ) begin
                if( !uwe && guns ) begin
                    io_q <= ub[2] ? (ub[1] ? gun_v[15:0] : gun_v[31:16])
                                  : (ub[1] ? gun_h[15:0] : gun_h[31:16]);
                    usrc <= R_IO;
                end
                // konamigx_tilebank_w: one byte per lane
                if( uwe && ube[1] ) begin tbank_we <= 1; tbank_addr <= { ua[2:1], 1'b0 }; tbank_din <= ud[15:8]; end
                else if( uwe && ube[0] ) begin tbank_we <= 1; tbank_addr <= { ua[2:1], 1'b1 }; tbank_din <= ud[7:0]; end
                if( uwe && ube == 2'b11 ) ust <= U_TB2;
            end else if( ub >= 24'hd48000 && ub < 24'hd48008 ) begin
                if( uwe ) begin k46_cs <= 1; k46_addr <= { 1'b0, ua[2:1], 1'b0 }; k46_dsn <= ~ube; end
            end else if( ub >= 24'hd4a010 && ub < 24'hd4a020 ) begin
                if( uwe ) begin k47_we <= ube; k47_addr <= ua[3:1]; end
            end else if( ub >= 24'hd4c000 && ub < 24'hd4c020 ) begin
                if( uwe && ube[1] ) begin crtc_cs <= 1; crtc_addr <= ua[4:1]; crtc_din <= ud[15:8]; end
            end else if( ub >= 24'hd50000 && ub < 24'hd50100 ) begin
                if( uwe && ube[1] ) begin k55_we <= 1; k55_addr <= ua[6:1]; k55_din <= ud[15:8]; end
            end else if( ub >= 24'hd52000 && ub < 24'hd52020 ) begin
                snd_addr <= ua[4:1];
                if( uwe && ube[1] ) begin snd_wr <= 1; snd_dout <= ud[15:8]; end
                if( !uwe && ube[1] ) begin snd_rd <= 1; usrc <= R_SND; ucnt <= 3'd2; end
            end else if( ub >= 24'hd56000 && ub < 24'hd56004 ) begin
                if( uwe && !ub[1] ) begin
                    if( ube[1] ) wrport1_0 <= ud[15:8];
                    if( ube[0] ) wrport1_1 <= ud[7:0];
                end
            end else if( ub >= 24'hd58000 && ub < 24'hd58004 ) begin
                if( uwe && !ub[1] && ube[0] ) wrport2 <= ud[7:0];
            end else if( ub >= 24'hd5a000 && ub < 24'hd5a004 ) begin
                io_q <= ub[1] ? { coins, rdport1_3[7:1], ee_do } : dsw;
                usrc <= R_IO;
            end else if( ub >= 24'hd5c000 && ub < 24'hd5c004 ) begin
                io_q <= ub[1] ? inputs[15:0] : inputs[31:16];
                usrc <= R_IO;
            end else if( ub >= 24'hd5e000 && ub < 24'hd5e004 ) begin
                // le2's port: bits 15-8 unknown active low, P2's trigger at bit 10
                io_q <= ub[1] ? (guns ? { 5'b11111, ~gun_trig2, 2'b11, 8'h00 } : 16'h0000)
                              : { service, 8'h00 };
                usrc <= R_IO;
            end else if( ub >= 24'hd80000 && ub < 24'hd80020 ) begin
                if( uwe ) begin k338_we <= ube; k338_addr <= ua[4:1]; end
            end else if( ub >= 24'hd90000 && ub < 24'hd98000 ) begin
                pl_a <= ua[14:2]; pl_d <= ud;
                if( uwe ) begin
                    // word 0 of the entry: x (UDS), R (LDS); word 1: G, B
                    pl_we      <= ua[1] ? { 2'b00, ube } : { ube, 2'b00 };
                end
                usrc <= R_PAL; ucnt <= 3'd2;
            end else if( ub >= 24'hda0000 && ub < 24'hda4000 ) begin
                // the window shows the page K056832 m_regs[0x19] selects
                // (change_rambank); 0xda2000 is the same page again
                vram_addr <= { (vram_bank[4:1] & 4'b1100) | { 2'b00, vram_bank[1:0] }, ua[12:1] };
                vram_be   <= ube;
                if( uwe ) vram_we <= 1; else begin vram_rd <= 1; rom_half <= 1'b0; end
                usrc <= R_VRAM; ucnt <= 3'd3;
            end
        end
    end
    U_WAIT: if( ucnt != 0 ) begin
        esc_start <= 0;
        ucnt <= ucnt - 3'd1;
        if( ucnt == 3'd1 ) begin
            case( usrc )
                R_WRAM: u_din <= { wr_qh, wr_ql };
                R_PAL:  u_din <= ua_r[1] ? { pl_q[1], pl_q[0] } : { pl_q[3], pl_q[2] };
                R_VRAM: u_din <= vram_dout;
                R_SPR:  u_din <= spr_ram_dout;
                R_IO:   u_din <= io_q;
                R_SND:  u_din <= { snd_din, 8'h00 };
                R_REGS: u_din <= { rg_qh, rg_ql };
                default: u_din <= 16'h0000;
            endcase
            u_ack <= 1;
            ust   <= U_IDLE;
        end
    end
    U_TB2: begin                              // the tile bank word's second byte
        tbank_we <= 1; tbank_addr <= { ua_r[2:1], 1'b1 }; tbank_din <= ud_r[7:0];
        ucnt <= 3'd1; ust <= U_WAIT;
    end
    U_ROM: begin
        if( rom_wc != 5'h1f ) rom_wc <= rom_wc + 5'd1;
        if( cr_ok ) begin cr_cs <= 0; rom_q <= cr_data; rom_got <= 1'b1; end
        if( (cr_ok || rom_got) && (!rom_slow || rom_wc >= rom_uncached) ) begin
            u_din <= cr_ok ? cr_data : rom_q; u_ack <= 1; ust <= U_IDLE;
        end
    end
    default: ust <= U_IDLE;
    endcase
end

// ------------------------------------------------------------ the CPU side
// C_IDLE: a new access goes to the unit. On its ack: ready, unless it was
// the ESC's starting write, which waits for the ESC.
assign cpu_req_now = cst == C_IDLE && mem_needed && !ready && !esc_busy;
assign fast_rdy    = cst == C_BUSY && u_ack && !u_esc && !u_md && !esc_started;

always @(posedge clk) begin
    if( rst ) begin
        cst <= C_IDLE; ready <= 0; esc_seen <= 0;
    end else case( cst )
        C_IDLE: if( take_cpu ) cst <= C_BUSY;
        C_BUSY: if( u_ack && !u_esc && !u_md ) begin
            cpu_din <= u_din;
            if( esc_started ) begin cst <= C_ESC; esc_seen <= 0; end
            else if( cpu_take ) cst <= C_IDLE;     // taken this clock (fast_rdy)
            else begin ready <= 1; cst <= C_READY; end
        end
        C_ESC: begin
            // gx_esc raises busy the clock after start, or never if the
            // address is not a command packet
            if( esc_busy ) esc_seen <= 1;
            if( !esc_busy ) begin ready <= 1; cst <= C_READY; end
        end
        // ready is held until a clk cycle that ends at a kernel edge: the kernel
        // samples clkena there and nowhere else. From C_BUSY that is always the
        // next cycle; from C_ESC it is whichever cycle esc_busy dropped in, and
        // on the board, with the SDRAM's odd latencies, half of those were the
        // wrong one -- the ack was lost, the kernel repeated its write, and the
        // ESC ran the same command again, for ever (LESSONS_LEARNED).
        C_READY: if( cpu_take ) begin ready <= 0; cst <= C_IDLE; end
    endcase
end

// The sprite DMA against the ESC: the K053246 starts its copy two lines after
// vblank, and this ESC -- unlike MAME's, which runs in no time -- may still be
// writing the list then. jt053246_dma holds off while esc_busy; this starts it
// as soon as the ESC finishes, so the frame gets a whole list a little late
// rather than half of the last one and half of this.
reg        dma_pend, lvbl_dt, hs_dt;
reg  [1:0] hs_cnt;
always @(posedge clk) begin
    obj_dma_trig <= 0;
    lvbl_dt <= vid_lvbl;
    hs_dt   <= vid_hs;
    if( rst ) begin dma_pend <= 0; hs_cnt <= 0; end
    else begin
        if( !vid_lvbl && lvbl_dt ) hs_cnt <= 0;                       // vblank began
        else if( vid_hs && !hs_dt && hs_cnt != 2'd3 ) begin
            hs_cnt <= hs_cnt + 1'd1;
            if( hs_cnt == 2'd1 && esc_busy ) dma_pend <= 1;           // the copy's moment, held off
        end
        if( dma_pend && !esc_busy ) begin dma_pend <= 0; obj_dma_trig <= 1; end
    end
end

// ------------------------------------------------------------ interrupts
reg  [23:0] dma_t;
reg         lvbl_l, irq3, irq4, dma_run;
reg         int1_l, int2_l, pend1, pend2;     // syncen bits 0/1, taken at an INT edge
wire        iack = cst == C_BUSY && u_ack && !u_esc && !u_md && fc == 3'b111;
wire [ 2:0] iack_lvl = a32[3:1];
wire [23:0] dma_len = wrport2[0] ? 24'd13824 : 24'd18432;   // (256+32) / (342+42) us at 48 MHz

always @(posedge clk) begin
    if( rst ) begin
        rdport1_3 <= 8'hfc; syncen <= 0; irq3 <= 0; irq4 <= 0; dma_run <= 0; lvbl_l <= 1;
        int1_l <= 0; int2_l <= 0; pend1 <= 0; pend2 <= 0;
    end else begin
        lvbl_l <= vid_lvbl;
        int1_l <= int1; int2_l <= int2;
        // eeprom_w: syncen makes each IRQ fire at least once after it is enabled
        if( take && uwe && ub >= 24'hd56000 && ub < 24'hd56004
            && !ub[1] && ube[0] && ud[7] )
            syncen <= syncen | { 3'b000, ud[4:0] };
        // dmastart_callback at vblank, dmaend_callback dma_len later
        if( !vid_lvbl && lvbl_l ) begin
            rdport1_3 <= rdport1_3 | 8'h02;
            dma_run <= 1; dma_t <= dma_len;
        end else if( dma_run ) begin
            if( dma_t == 0 ) begin
                dma_run <= 0;
                rdport1_3 <= rdport1_3 & ~8'h02;
                if( (wrport1_1 & 8'h84) == 8'h84 || syncen[2] ) begin
                    syncen[2] <= 0;
                    rdport1_3 <= rdport1_3 & ~8'h82;
                    irq3 <= 1;
                end
            end else dma_t <= dma_t - 24'd1;
        end
        if( esc_irq && wrport1_1[4] ) begin
            rdport1_3 <= rdport1_3 & ~8'h08;
            irq4 <= 1;
        end
        // MAME's vblank/hblank callbacks, at the INT edge: the level's
        // enable, or a set syncen bit (consumed), raises it
        if( int1 && !int1_l && ((wrport1_1 & 8'h81) == 8'h81 || syncen[0]) ) begin
            syncen[0] <= 0; pend1 <= 1;
        end
        if( int2 && !int2_l && ((wrport1_1 & 8'h82) == 8'h82 || syncen[1]) ) begin
            syncen[1] <= 0; pend2 <= 1;
        end
        // cleared by the acknowledge cycle, or the K053252's (INT falls)
        if( (iack && iack_lvl == 3'd1) || !int1 ) pend1 <= 0;
        if( (iack && iack_lvl == 3'd2) || !int2 ) pend2 <= 0;
        if( iack && iack_lvl == 3'd3 ) irq3 <= 0;
        if( iack && iack_lvl == 3'd4 ) irq4 <= 0;
    end
end

wire irq1 = pend1;
wire irq2 = pend2;
always @* begin
    ipl_n = 3'b111;
    if( irq1 ) ipl_n = ~3'd1;
    if( irq2 ) ipl_n = ~3'd2;
    if( irq3 ) ipl_n = ~3'd3;
    if( irq4 ) ipl_n = ~3'd4;
end

// ------------------------------------------------------------ observation
// Interrupt acknowledges per level (free-running 12-bit counters: read twice
// for a rate), wrport1_1 (the game's IRQ enable byte at 0xd56001) and the
// lines as the kernel sees them.
reg  [11:0] c_iack1, c_iack2, c_iack3, c_iack4;
always @(posedge clk) begin
    if( rst ) begin
        c_iack1 <= 0; c_iack2 <= 0; c_iack3 <= 0; c_iack4 <= 0;
    end else if( iack ) case( iack_lvl )
        3'd1: c_iack1 <= c_iack1 + 1'd1;
        3'd2: c_iack2 <= c_iack2 + 1'd1;
        3'd3: c_iack3 <= c_iack3 + 1'd1;
        3'd4: c_iack4 <= c_iack4 + 1'd1;
        default: ;
    endcase
end
assign dbg_irq = { iack, irq4, irq3, int2, int1, ipl_n, wrport1_1, c_iack4, c_iack3, c_iack2, c_iack1 };
assign dbg_esc = { cst == C_ESC, esc_busy };

// The sprite DMA: starts (obj_dma_busy rising), vblanks, and OBJSET1 (K053246
// register 5, bit 4 DMAEN) as last written and as it stood at the last vblank
// and at the last DMA start, with a count of vblanks that found DMAEN set.
reg  [ 7:0] objset1_m, objset1_vbl, objset1_dma;
reg  [11:0] c_dma, c_vbl, c_vbl_en, c_short, c_short_f, c_short_last;
reg  [ 7:0] c_dma_esc;                       // DMA starts while the ESC is writing the list
reg         dma_busy_l, lvbl_obs;
always @(posedge clk) begin
    dma_busy_l <= obj_dma_busy;
    lvbl_obs   <= vid_lvbl;
    if( k46_cs && k46_addr[2:1] == 2'd2 && !k46_dsn[0] ) objset1_m <= bus_d16[7:0];
    if( obj_dma_busy && !dma_busy_l ) begin
        c_dma <= c_dma + 1'd1; objset1_dma <= objset1_m;
        if( esc_busy ) c_dma_esc <= c_dma_esc + 1'd1;
    end
    if( !vid_lvbl && lvbl_obs ) begin
        c_vbl <= c_vbl + 1'd1; objset1_vbl <= objset1_m;
        if( objset1_m[4] ) c_vbl_en <= c_vbl_en + 1'd1;
        c_short_last <= c_short_f; c_short_f <= 0;
    end
    if( obj_ln_short ) begin
        c_short <= c_short + 1'd1;
        c_short_f <= c_short_f + 1'd1;
    end
end
assign dbg_obj = { c_dma_esc, c_short_last, c_short, objset1_dma, objset1_vbl, objset1_m, 4'd0, c_vbl_en, c_vbl, c_dma };

// The last write to K054338 register 14's high byte (0xd8001c): on the
// board that byte is lost (tkmmpzdm's select screen), while the byte
// writes of the attract's fade arrive as bytes. { who (1 ESC, 2 memory
// reader, 0 CPU), byte lanes, the CPU's interrupt mask, data } in [22:0],
// the address of the CPU's last instruction fetch before it in [46:23], a
// count of such writes in [62:47].
reg [23:0] last_fetch;
always @(posedge clk)
    if( rst ) begin dbg_k338 <= 64'd0; last_fetch <= 24'd0; end
    else begin
        if( take_cpu && fc[1:0] == 2'b10 ) last_fetch <= { ua, 1'b0 };
        if( take && uwe && ub >= 24'hd8001c && ub < 24'hd8001e && ube[1] ) begin
            dbg_k338[22:0]  <= { take_md, take_esc, ube, cpu_sr[2:0], ud };
            dbg_k338[46:23] <= last_fetch;
            dbg_k338[62:47] <= dbg_k338[62:47] + 16'd1;
        end
    end

assign dbg_access = u_ack;                // CPU and ESC: MAME's write tap sees both
assign dbg_addr   = { ua_r, 1'b0 };
assign dbg_we     = uwe_r;
assign dbg_be     = ube_r;
assign dbg_data   = uwe_r ? ud_r : u_din;

endmodule
