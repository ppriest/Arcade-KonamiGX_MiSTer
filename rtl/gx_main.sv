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
//   level 1  vblank: the K053252's INT1 flip-flop, gated by wrport1_1 0x81.
//            The game acknowledges through K053252 register 0x0e (MAME:
//            vblank_irq_ack_w). MAME models this as HOLD_LINE plus a
//            "syncen" latch; the flip-flop is the chip's own behaviour.
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
    input      [39:0] tile_rom_data,
    output     [22:0] obj_rom_addr,
    output            obj_rom_cs,
    output     [22:0] obj_pf_addr,           // the row the sprite scan will draw next
    output            obj_pf_cs,
    input             obj_rom_ok,
    input      [39:0] obj_rom_data,

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

    // per-game K056832 layer offsets
    input  signed [7:0] offs_x [4],
    input  signed [7:0] offs_y [4],
    input      [ 3:0] primode,              // konamigx_mixer_primode for the set
    input      [ 9:0] obj_hadj,             // the set's K055673 dx - (-26), signed
    input             esc_gen,              // the set's ESC callback generates sprites
    input      [23:0] esc_src,              // from this list
    input      [ 8:0] esc_count,            // of this many entries

    // video out
    output     [23:0] rgb,
    output            vid_lhbl, vid_lvbl, vid_hs, vid_vs,
    output            pxl_cen_o,            // the dot clock enable, for the video output
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
    output    [111:0] dbg_mix,               // the mixer's registers (probe L)
    output     [83:0] dbg_rom,               // the last granule the CPU cache fetched (probe M)
    input             peek_t,                // JTAG: read one granule of the packed image
    input      [19:0] peek_addr,
    // JTAG: read four words of anything the CPU can read (scripts/memdump.py)
    input      [25:0] rom_top,             // SDRAM bytes the packed CPU image occupies
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
reg  [15:0] cpu_din;
reg  [15:0] u_din;                          // the access unit's read data
reg         ready;
reg  [ 2:0] ipl_n;                          // active low, as the kernel expects
wire        mem_needed = busstate != 2'b01;
wire        fast_rdy;                       // the unit's ack, straight to the kernel
wire        cpu_clkena = !mem_needed || ready || fast_rdy;

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
    .clr_berr(), .skipFetch(), .regin_out(), .CACR_out(), .VBR_out(), .FlagsSR_out(cpu_sr)
);

// ------------------------------------------------------------ registers
reg  [7:0] wrport1_0, wrport1_1, rdport1_3, syncen;
reg  [7:0] vram_bank;                       // K056832 m_regs[0x19], low byte
reg [15:0] esc_hi;

// ------------------------------------------------------------ memories
// work RAM, 0xc00000-0xc1ffff: two byte lanes of 64K
reg         wr_we_h, wr_we_l;
reg  [15:0] wr_a;
reg  [15:0] wr_d;
wire [ 7:0] wr_qh, wr_ql;
gx_sdpram #(.AW(16), .DW(8)) u_wram_h ( .clk, .we(wr_we_h), .wa(wr_a), .d(wr_d[15:8]), .ra(wr_a), .q(wr_qh) );
gx_sdpram #(.AW(16), .DW(8)) u_wram_l ( .clk, .we(wr_we_l), .wa(wr_a), .d(wr_d[ 7:0]), .ra(wr_a), .q(wr_ql) );

// palette, 0xd90000-0xd97fff: the CPU's copy, 8K x 32 in four byte lanes
// (the x byte is RAM too, and the RAM test checks it); colour bytes are
// forwarded to gx_mixer's palette as they are written
reg  [3:0]  pl_we;                          // { x, R, G, B }
reg  [12:0] pl_a;
reg  [15:0] pl_d;
wire [7:0]  pl_q [4];
genvar gl;
generate for( gl=0; gl<4; gl=gl+1 ) begin : g_pal
    gx_sdpram #(.AW(13), .DW(8)) u_lane ( .clk, .we(pl_we[gl]), .wa(pl_a),
        .d( gl[0] ? pl_d[15:8] : pl_d[7:0] ), .ra(pl_a), .q(pl_q[gl]) );   // x, G: high byte
end endgenerate

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
reg  [ 2:0] pal_fwd_we;
wire [15:0] vram_dout, spr_ram_dout;
wire        int1, int2, obj_dma_busy, obj_ln_short;
reg         obj_dma_trig;      // start the sprite DMA (below: the ESC has finished)
wire        esc_busy, esc_irq, esc_req, esc_we, esc_ack;

gx_video u_video (
    .rst, .clk, .pxl_cen, .pxl2_cen,
    .crtc_cs, .crtc_addr, .crtc_din, .crtc_dout(), .int1, .int2,
    .tm_reg_we, .tm_reg_addr(tm_addr), .tm_reg_din(bus_d16), .tm_reg_be(tm_be),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd, .vram_addr, .vram_din(bus_d16), .vram_be, .vram_dout,
    .offs_x, .offs_y,
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .spr_ram_cs, .spr_ram_we, .spr_ram_addr, .spr_ram_din(bus_d16), .spr_ram_dout,
    .k46_cs, .k46_we(k46_cs), .k46_addr, .k46_din(bus_d16), .k46_dsn,
    .k47_we, .k47_addr, .k47_din(bus_d16), .wrport2, .primode, .obj_hadj,
    .obj_dma_trig(obj_dma_trig), .obj_dma_hold(esc_busy), .dbg_mix,
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr, .obj_pf_cs,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din(bus_d16),
    .bg_grad(wrport1_0[5]),
    .pal_we(pal_fwd_we), .pal_addr(pl_a), .pal_din({ pl_d[7:0], pl_d }),
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .unsupported, .obj_dma_busy, .obj_ln_short
);

// ------------------------------------------------------------ EEPROM
wire ee_do;
gx_eeprom93c46 u_ee (
    .rst, .clk, .blank(ee_blank), .cs(wrport1_0[1]), .sk(wrport1_0[2]), .di(wrport1_0[0]), .dout(ee_do), .dbg(dbg_ee),
    .load_we(ee_load_we), .load_addr(ee_load_addr), .load_data(ee_load_data)
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
    .rst, .clk, .start(esc_start), .data(esc_data), .busy(esc_busy), .irq(esc_irq), .dbg(esc_dbg),
    .gen_en(esc_gen), .gen_src(esc_src), .gen_count(esc_count),
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
localparam [2:0] U_IDLE = 0, U_WAIT = 1, U_ROM = 2, U_TB2 = 3, U_SND = 4;
reg  [2:0]  ust;
reg  [2:0]  ucnt;
reg         u_ack, u_esc, u_md;             // whose access is in progress
reg  [23:1] ua_r;                           // the request, held for the access
reg  [ 1:0] ube_r;
reg         uwe_r;
reg  [15:0] ud_r;
reg  [ 3:0] usrc;                           // where the read data comes from

localparam [3:0] R_ZERO=0, R_WRAM=1, R_PAL=2, R_VRAM=3, R_SPR=4, R_IO=5, R_SND=6;
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

always @(posedge clk) begin
    u_ack <= 0;
    { tm_reg_we, tbank_we, vram_we, vram_rd, spr_ram_cs, k46_cs, k55_we, crtc_cs } <= 0;
    k47_we <= 0; k338_we <= 0;
    { wr_we_h, wr_we_l } <= 0;
    pl_we <= 0; pal_fwd_we <= 0;
    snd_wr <= 0; snd_rd <= 0;
    spr_ram_we <= 0;
    if( rst ) begin
        ust <= U_IDLE; cr_cs <= 0;
        wrport1_0 <= 0; wrport1_1 <= 0; wrport2 <= 0; vram_bank <= 0;
        esc_start <= 0; esc_started <= 0;
    end else case( ust )
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
            end else if( ub < 24'h800000 ) begin
                if( rom_backed ) begin
                    cr_addr <= ua[22:1]; cr_cs <= 1; ust <= U_ROM;
                end else usrc <= R_ZERO;
            end else if( ub >= 24'hc00000 && ub < 24'hc20000 ) begin
                wr_a <= ua[16:1]; wr_d <= ud;
                if( uwe ) begin wr_we_h <= ube[1]; wr_we_l <= ube[0]; end
                usrc <= R_WRAM; ucnt <= 3'd2;
            end else if( ub >= 24'hcc0000 && ub < 24'hcc0004 ) begin
                // esc_w: the 32-bit write arrives as two words; the second starts it
                if( uwe && !ub[1] ) esc_hi <= ud;
                if( uwe &&  ub[1] ) begin esc_data <= { esc_hi[7:0], ud }; esc_start <= 1; esc_started <= 1; end
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
                io_q <= ub[1] ? 16'h0000 : { service, 8'h00 };
                usrc <= R_IO;
            end else if( ub >= 24'hd80000 && ub < 24'hd80020 ) begin
                if( uwe ) begin k338_we <= ube; k338_addr <= ua[4:1]; end
            end else if( ub >= 24'hd90000 && ub < 24'hd98000 ) begin
                pl_a <= ua[14:2]; pl_d <= ud;
                if( uwe ) begin
                    // word 0 of the entry: x (UDS), R (LDS); word 1: G, B
                    pl_we      <= ua[1] ? { 2'b00, ube } : { ube, 2'b00 };
                    pal_fwd_we <= ua[1] ? { 1'b0, ube } : { ube[0], 2'b00 };
                end
                usrc <= R_PAL; ucnt <= 3'd2;
            end else if( ub >= 24'hda0000 && ub < 24'hda4000 ) begin
                // the window shows the page K056832 m_regs[0x19] selects
                // (change_rambank); 0xda2000 is the same page again
                vram_addr <= { (vram_bank[4:1] & 4'b1100) | { 2'b00, vram_bank[1:0] }, ua[12:1] };
                vram_be   <= ube;
                if( uwe ) vram_we <= 1; else vram_rd <= 1;
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
    U_ROM: if( cr_ok ) begin
        cr_cs <= 0; u_din <= cr_data; u_ack <= 1; ust <= U_IDLE;
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
            else if( cpu_cen ) cst <= C_IDLE;      // taken this clock (fast_rdy)
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
        C_READY: if( cpu_cen ) begin ready <= 0; cst <= C_IDLE; end
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
        // MAME's vblank/hblank callbacks: a set syncen bit passes this one
        // interrupt and is consumed
        if( int1 && !int1_l && syncen[0] ) begin syncen[0] <= 0; pend1 <= 1; end
        if( int2 && !int2_l && syncen[1] ) begin syncen[1] <= 0; pend2 <= 1; end
        if( iack && iack_lvl == 3'd1 ) pend1 <= 0;
        if( iack && iack_lvl == 3'd2 ) pend2 <= 0;
        if( iack && iack_lvl == 3'd3 ) irq3 <= 0;
        if( iack && iack_lvl == 3'd4 ) irq4 <= 0;
    end
end

wire irq1 = int1 && ((wrport1_1[7] && wrport1_1[0]) || pend1);
wire irq2 = int2 && ((wrport1_1[7] && wrport1_1[1]) || pend2);
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

assign dbg_access = u_ack;                // CPU and ESC: MAME's write tap sees both
assign dbg_addr   = { ua_r, 1'b0 };
assign dbg_we     = uwe_r;
assign dbg_be     = ube_r;
assign dbg_data   = uwe_r ? ud_r : u_din;

endmodule
