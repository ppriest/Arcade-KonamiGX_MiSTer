// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Type 1 terrain (docs/TYPE1.md): the K053936 drawing two tilemaps from
// one map RAM, height (HROM) and colour (CROM), and the 056540 ("PSAC4")
// raising them into a height field. Written from MAME's type1_draw_terrain
// (konamigx_v.cpp, which calls itself an approximation) and the K053936's
// line mode; scripts/t1_psac4_model.py is the same, and sim/gx_t1_psac4_tb
// checks this against it.
//
// MAME draws the frame at vblank start from the state then; the game writes
// that state late in the frame before (lines 248-272 after vblank start,
// scripts/mame/t1_sweep.lua). Here the frame is drawn from vblank start into
// a DDR3 frame store over the frame that follows, and shown the frame after:
// one frame later than MAME (docs/HACKS.md). The LRAM, line control and map
// RAM are read as the frame is drawn; the registers, lookup bank and y
// origin are taken at its start.
//
// Per LRAM line l = 1..255 (near to far; golf 1..480), for each of the 384
// visible columns: the colour c and height h of K053936 row l + 14 at that
// column, and, where c's pixel is not 0, the column is filled from
//   top = max(ground - level * scale / 64, 0),   ground = 256 + yorigin - l - s8(e)
// (golf: / 256, and lines past 224 take the second y origin) down to what
// nearer lines left uncovered (the limit), or, with scale 0, the one pixel
// at ground.
//
// The frame store holds, per pixel, the drawing line's parameter (the
// priority) and c (16 bits; 0 is nothing, as c is never 0 where drawn). The
// parameter's lookup nibble is kept in a table per buffer and applied as the
// pixel is shown.
module gx_t1_psac4 #(
    parameter [6:0] MEM_BASE = 7'b0010011      // DDR3 0x26000000
) (
    input             clk,                  // 48 MHz
    input             rst,
    input             golf,                 // opengolf, ggreats2 (gx_board_cfg t1g)
    input      [ 9:0] vis_x0,               // the window's first bitmap column (the store's column 0)
    input      [ 4:0] vis_y0,               // and row

    // the raster (gx_video): vblank, and the bitmap row being shown
    input             lvbl,
    input      [ 8:0] by,
    input      [ 9:0] rd_x,                 // bitmap column
    output reg        t_valid,              // two cycles after rd_x
    output reg [11:0] t_pen,                // CROM colour | lookup << 8
    output reg [ 7:0] t_pri,                // the LRAM parameter

    // the CPU's state (gx_main)
    input      [15:0] ctrl0, ctrl1, ctrl6, ctrl7,   // K053936 registers 0, 1, 6, 7
    input      [15:0] ctrl14,               // and 14: golf's y-origin phase (bit 7)
    input      [15:0] p4_hi, p4_lo,         // 056540 register 0, a long's halves
    input      [ 3:0] brk,                  // the lookup bank (type1_bank_w bits 15-12)
    output reg [10:0] lr_addr,              // LRAM, words (registered read)
    input      [15:0] lr_q,
    output reg [11:0] lc_addr,              // line control, words (registered read)
    input      [15:0] lc_q,
    output reg [10:0] lk_addr,              // lookup SRAM (registered read)
    input      [ 7:0] lk_q,

    // SDRAM (gx_rom_port clients): the map RAM's entries, CROM and HROM
    output reg        m_cs,
    output reg [13:0] m_addr,
    input             m_ok,
    input      [63:0] m_data,               // bytes little-endian, as the CPU wrote them
    output reg        c_cs,
    output reg [19:0] c_addr,
    input             c_ok,
    input      [63:0] c_data,
    output reg        h_cs,
    output reg [19:0] h_addr,
    input             h_ok,
    input      [63:0] h_data,

    // the frame store
    input             DDRAM_BUSY,
    output     [ 7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    output     [63:0] DDRAM_DIN,
    output     [ 7:0] DDRAM_BE,
    output            DDRAM_WE,
    output            DDRAM_RD,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY,

    // { the last frame's clocks / 32, its misses }; 0xffff: it did not finish
    output     [31:0] dbg
);

localparam int W = 384;
// the last bitmap row shown: Racin' Force shows 255 from 0, golf 224 from 16
wire [8:0] maxy = golf ? 9'd239 : 9'd254;

// word address: buffer b, row y, word w (four pixels)
function automatic [28:0] waddr( input b, input [7:0] y, input [6:0] w );
    waddr = { MEM_BASE, 6'd0, b, y, w };
endfunction

// ------------------------------------------------------------ frame control
reg        lvbl_l = 1'b1;
// latched at vblank end (type1_vblank_w): golf keeps two, by K053936
// register 14's bit 7 then ("Open Golf alternates near/far table ranges")
reg [15:0] yorigin_l [0:1];
reg  [1:0] yvalid_l = 2'b00;
reg        fb = 1'b0;                       // the buffer being drawn; ~fb is shown
reg        go = 1'b0;
reg  [1:0] warm = 2'd0;                     // frames drawn since reset (the store starts as junk)
always @(posedge clk) begin
    lvbl_l <= lvbl;
    go <= 1'b0;
    if( rst ) begin
        yvalid_l <= 2'b00; fb <= 1'b0; warm <= 2'd0;
    end else begin
        if( !lvbl_l && lvbl ) begin
            yorigin_l[golf && ctrl14[7]] <= { p4_hi[7:0], p4_lo[15:8] };
            yvalid_l[golf && ctrl14[7]]  <= 1'b1;
        end
        if( lvbl_l && !lvbl ) begin
            fb <= ~fb;
            go <= 1'b1;
            if( warm != 2'd3 ) warm <= warm + 2'd1;
        end
    end
end

// taken at a frame's start
reg  [15:0] k0, k1, k6, yorg0, yorg1;
reg  [ 1:0] kyv;
reg  [ 3:0] kbrk;
reg         kgolf;
reg  [ 9:0] kvx0;
reg  [ 8:0] kmaxy;

// ------------------------------------------------------------ line tables
// per buffer, a parameter's lookup nibble
reg  [ 3:0] ltab [0:511];
reg  [ 3:0] ltab_q;
reg         lt_we;
reg  [ 7:0] lt_par;
reg  [ 3:0] lt_d;
always @(posedge clk) if( lt_we ) ltab[{ fb, lt_par }] <= lt_d;

// ------------------------------------------------------------ the pipeline's state
localparam [3:0] D_IDLE = 0, D_CLR = 1, D_LR0 = 2, D_LR1 = 3, D_LR2 = 4, D_LK = 5, D_LC0 = 6,
                 D_LC1 = 7, D_LC2 = 8, D_LC3 = 9, D_LC4 = 10, D_COLS = 11, D_DRAIN = 12, D_DONE = 13;
reg  [ 3:0] ds = D_IDLE;
reg  [ 8:0] line;
reg  [15:0] le_hi;                          // the LRAM entry's scale
reg  [15:0] lc0, lc1, lc2;
reg  signed [17:0] ground;
reg  [15:0] scale;
reg  [ 7:0] par;
reg  [31:0] ax, ay, dx, dy;
reg  [ 8:0] xi;                             // the next column to issue
reg  [ 8:0] clr_n;
reg  [20:0] fclk;
reg  [15:0] misses, dbg_clk = 16'hffff, dbg_miss = 16'd0;
assign dbg = { dbg_clk, dbg_miss };

// P0 issues a column (the map and limit reads), P1 has the map entry, P2
// the CROM and HROM granules, P3 decides. A stage waits only for its own
// misses, and the map and texture fetches run at once.
reg         v1 = 1'b0, v2 = 1'b0, v3 = 1'b0;
reg  [ 8:0] x1, x2, x3;
reg  [10:0] tx1, ty1;                       // P1: the texel
reg  [ 1:0] pl2;                            // P2: the colour's PL bits
reg  [ 7:0] hb2;                            //     the tile's height byte
reg  [ 2:0] cs2, hs2;                       //     the group's first byte in its granule
reg  [19:0] cg2, hg2;                       //     the group's first granule
reg  [ 1:0] ck2, hk2;                       //     the pixel in the group
reg  [ 8:0] lim2, lim3;
reg  [ 7:0] c3;
reg         op3;
reg  [23:0] prod3;

// ------------------------------------------------------------ the limits
reg  [ 8:0] lim [0:511];
reg  [ 8:0] lim_q;
reg         lim_we;
reg  [ 8:0] lim_wa, lim_d;
wire [ 8:0] lim_ra;
always @(posedge clk) begin
    if( lim_we ) lim[lim_wa] <= lim_d;
    lim_q <= lim[lim_ra];
end

// ------------------------------------------------------------ the caches
// the map: 256 entries, direct-mapped on the tile index; emptied each frame,
// as the map is RAM (a write during the frame is seen only if its entry was
// not already held)
reg  [63:0] mc_d [0:255];
reg  [ 6:0] mc_t [0:255];                   // { valid, tile index[13:8] }
reg  [63:0] mc_q;
reg  [ 6:0] mc_tq;
reg         mc_we;
reg  [ 7:0] mc_wa;
reg  [63:0] mc_wd;
reg  [ 6:0] mc_wt;
wire [ 7:0] mc_ra;
always @(posedge clk) begin
    if( mc_we ) begin mc_d[mc_wa] <= mc_wd; mc_t[mc_wa] <= mc_wt; end
    mc_q <= mc_d[mc_ra]; mc_tq <= mc_t[mc_ra];
end
// CROM and HROM: granules in two banks by parity, 256 each, so that both
// granules a three-byte group can straddle are read in one cycle. Tags
// { valid, granule[19:9] }; valid only from reset (the ROMs do not change).
localparam int TW = 12;
reg  [63:0] cce [0:255], cco [0:255], hce [0:255], hco [0:255];
reg  [TW-1:0] cte [0:255], cto [0:255], hte [0:255], hto [0:255];
reg  [63:0] cce_q, cco_q, hce_q, hco_q;
reg  [TW-1:0] cte_q, cto_q, hte_q, hto_q;
wire [ 7:0] ce_ra, co_ra, he_ra, ho_ra;
reg         cc_we, hc_we;
reg  [19:0] cc_wg, hc_wg;
reg  [63:0] cc_wd, hc_wd;
reg         tclr = 1'b1;                    // emptying the tags after reset
reg  [ 7:0] tclr_n = 8'd0;
always @(posedge clk) begin
    if( tclr ) begin
        cte[tclr_n] <= '0; cto[tclr_n] <= '0; hte[tclr_n] <= '0; hto[tclr_n] <= '0;
    end else begin
        if( cc_we && !cc_wg[0] ) begin cce[cc_wg[8:1]] <= cc_wd; cte[cc_wg[8:1]] <= { 1'b1, cc_wg[19:9] }; end
        if( cc_we &&  cc_wg[0] ) begin cco[cc_wg[8:1]] <= cc_wd; cto[cc_wg[8:1]] <= { 1'b1, cc_wg[19:9] }; end
        if( hc_we && !hc_wg[0] ) begin hce[hc_wg[8:1]] <= hc_wd; hte[hc_wg[8:1]] <= { 1'b1, hc_wg[19:9] }; end
        if( hc_we &&  hc_wg[0] ) begin hco[hc_wg[8:1]] <= hc_wd; hto[hc_wg[8:1]] <= { 1'b1, hc_wg[19:9] }; end
    end
    cce_q <= cce[ce_ra]; cte_q <= cte[ce_ra];
    cco_q <= cco[co_ra]; cto_q <= cto[co_ra];
    hce_q <= hce[he_ra]; hte_q <= hte[he_ra];
    hco_q <= hco[ho_ra]; hto_q <= hto[ho_ra];
end
always @(posedge clk) begin
    if( rst ) begin tclr <= 1'b1; tclr_n <= 8'd0; end
    else if( tclr ) begin tclr_n <= tclr_n + 8'd1; if( tclr_n == 8'hff ) tclr <= 1'b0; end
end

// ------------------------------------------------------------ P1: the map entry
// A fetched granule is also kept in a bypass register, so the stage that
// waited for it goes on the next cycle rather than when the cache's read
// port has it.
reg         mb_v;
reg  [13:0] mb_ti;
reg  [63:0] mb_d;
wire [13:0] ti1   = { ty1[10:4], tx1[10:4] };
wire        mb_hit = mb_v && mb_ti == ti1;
wire        m_hit = mb_hit || (mc_tq[6] && mc_tq[5:0] == ti1[13:8]);
wire [63:0] me = mb_hit ? mb_d : mc_q;
wire [31:0] ea = { me[ 7: 0], me[15: 8], me[23:16], me[31:24] };  // long 0: height tile
wire [31:0] eb = { me[39:32], me[47:40], me[55:48], me[63:56] };  // long 1: colour tile, flips
wire [ 3:0] cpx = eb[21] ? ~tx1[3:0] : tx1[3:0];
wire [ 3:0] cpy = eb[20] ? ~ty1[3:0] : ty1[3:0];
wire [ 3:0] hpx = eb[23] ? ~tx1[3:0] : tx1[3:0];
wire [ 3:0] hpy = eb[22] ? ~ty1[3:0] : ty1[3:0];
// t1_charlayout6: code * 192 + row * 12 + group * 3
function automatic [22:0] goff( input [14:0] code, input [3:0] row, input [1:0] grp );
    goff = { code, 7'd0 } + { 1'b0, code, 6'd0 } + { 15'd0, row, 3'd0 } + { 16'd0, row, 2'd0 }
         + { 20'd0, grp, 1'b0 } + { 21'd0, grp };
endfunction
// t1_charlayout8 (golf's CROM): code * 256 + row * 16 + group * 4
wire [22:0] coff8 = { eb[14:0], 8'd0 } + { 15'd0, cpy, 4'd0 } + { 17'd0, cpx[3:2], 2'd0 };
wire [22:0] coff = kgolf ? coff8 : goff( eb[14:0], cpy, cpx[3:2] );
wire [22:0] hoff = goff( ea[14:0], hpy, hpx[3:2] );

// ------------------------------------------------------------ P2: the pixels
// two bypass registers a stream (a group can need two granules)
reg  [ 1:0] cb_v, hb_v;
reg  [19:0] cb_g [0:1], hb_g [0:1];
reg  [63:0] cb_d [0:1], hb_d [0:1];
reg         cb_p, hb_p;                     // the one to replace next
// a three-byte group straddles two granules from byte 6 (golf's four-byte
// CROM groups start at 0 or 4, and never do)
wire        c_st = cs2 >= 3'd6, h_st = hs2 >= 3'd6;
wire [19:0] cg2n = cg2 + 20'd1, hg2n = hg2 + 20'd1;
function automatic tag_hit( input [19:0] g, input [TW-1:0] te, input [TW-1:0] to );
    tag_hit = (g[0] ? to : te) == { 1'b1, g[19:9] };
endfunction
// granule g, { held, data }: from a bypass register, else the bank its parity names
function automatic [64:0] look( input [19:0] g, input [TW-1:0] te, input [TW-1:0] to,
                                input [63:0] de, input [63:0] dO,
                                input [1:0] bv, input [19:0] bg0, input [19:0] bg1,
                                input [63:0] bd0, input [63:0] bd1 );
    if( bv[0] && bg0 == g )      look = { 1'b1, bd0 };
    else if( bv[1] && bg1 == g ) look = { 1'b1, bd1 };
    else look = { tag_hit( g, te, to ), g[0] ? dO : de };
endfunction
wire [64:0] cl0 = look( cg2,  cte_q, cto_q, cce_q, cco_q, cb_v, cb_g[0], cb_g[1], cb_d[0], cb_d[1] );
wire [64:0] cl1 = look( cg2n, cte_q, cto_q, cce_q, cco_q, cb_v, cb_g[0], cb_g[1], cb_d[0], cb_d[1] );
wire [64:0] hl0 = look( hg2,  hte_q, hto_q, hce_q, hco_q, hb_v, hb_g[0], hb_g[1], hb_d[0], hb_d[1] );
wire [64:0] hl1 = look( hg2n, hte_q, hto_q, hce_q, hco_q, hb_v, hb_g[0], hb_g[1], hb_d[0], hb_d[1] );
wire        c_h0 = cl0[64], c_h1 = !c_st || cl1[64];
wire        h_h0 = hl0[64], h_h1 = !h_st || hl1[64];
wire        t_hit = c_h0 && c_h1 && h_h0 && h_h1;
// the group's three bytes; pixel k is bit k of each nibble, plane 0 (the MSB)
// the third byte's high nibble
function automatic [5:0] pix6( input [127:0] g, input [2:0] st, input [1:0] k );
    reg [7:0] b0, b1, b2;
    b0 = g[{ st, 3'd0 } +: 8]; b1 = g[{ st, 3'd0 } + 8 +: 8]; b2 = g[{ st, 3'd0 } + 16 +: 8];
    pix6 = { b2[3'd4 + k], b2[k], b1[3'd4 + k], b1[k], b0[3'd4 + k], b0[k] };
endfunction
// t1_charlayout8: four bytes, plane 0 the fourth byte's high nibble
function automatic [7:0] pix8( input [63:0] g, input [2:0] st, input [1:0] k );
    reg [7:0] b0, b1, b2, b3;
    b0 = g[{ st, 3'd0 } +: 8]; b1 = g[{ st, 3'd0 } + 8 +: 8];
    b2 = g[{ st, 3'd0 } + 16 +: 8]; b3 = g[{ st, 3'd0 } + 24 +: 8];
    pix8 = { b3[3'd4 + k], b3[k], b2[3'd4 + k], b2[k], b1[3'd4 + k], b1[k], b0[3'd4 + k], b0[k] };
endfunction
wire [ 5:0] cpix = pix6( { cl1[63:0], cl0[63:0] }, cs2, ck2 );
wire [ 7:0] cpix8 = pix8( cl0[63:0], cs2, ck2 );
wire [ 5:0] hpix = pix6( { hl1[63:0], hl0[63:0] }, hs2, hk2 );
wire [ 7:0] level = { 2'b00, hpix } + hb2;

// ------------------------------------------------------------ advance
// each stage moves when it has what it needs and the next has room
wire        sq_full;
wire        cols  = ds == D_COLS;
wire        adv2  = cols && v2 && t_hit && !sq_full;
wire        free2 = !v2 || adv2;
wire        adv1  = cols && v1 && m_hit && free2;
wire        free1 = !v1 || adv1;
wire        issue = cols && xi != 9'(W) && free1;
// the read addresses: a stage's own while it waits, else its next
// occupant's, so the data is there when that arrives
assign mc_ra  = issue ? { ay[20], ax[26:20] } : ti1[7:0];
assign lim_ra = issue ? xi : x1;
reg  [ 7:0] ce_r, co_r, he_r, ho_r;         // P2's
// granule g's bank holds it at g[8:1]; its successor is in the other bank
assign ce_ra = adv1 ? coff[11:4] + { 7'd0, coff[3] } : ce_r;
assign co_ra = adv1 ? coff[11:4] : co_r;
assign he_ra = adv1 ? hoff[11:4] + { 7'd0, hoff[3] } : he_r;
assign ho_ra = adv1 ? hoff[11:4] : ho_r;

// P3's top
// Racin' Force's projection has 6 fractional bits, golf's 8
wire signed [17:0] top_r = ground - $signed(kgolf ? { 3'b000, prod3[23:8] } : { 1'b0, prod3[23:6] });
wire        [ 8:0] top   = top_r < 0 ? 9'd0 : top_r > 18'sd255 ? 9'd255 : top_r[8:0];

// the writer's queue: { point, x[8:0], y0[8:0], y1[8:0], parameter[7:0], c[7:0] }
reg         sq_push;
reg  [43:0] sq_d;
reg         wr_busy;

always @(posedge clk) begin
    lt_we <= 1'b0; lim_we <= 1'b0; mc_we <= 1'b0; cc_we <= 1'b0; hc_we <= 1'b0;
    sq_push <= 1'b0;
    fclk <= fclk + 21'd1;
    if( rst ) begin
        ds <= D_IDLE; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
        m_cs <= 1'b0; c_cs <= 1'b0; h_cs <= 1'b0;
        mb_v <= 1'b0; cb_v <= 2'b00; hb_v <= 2'b00; cb_p <= 1'b0; hb_p <= 1'b0;
    end else if( go ) begin
        if( ds != D_DONE && ds != D_IDLE ) begin dbg_clk <= 16'hffff; dbg_miss <= misses; end
        k0 <= ctrl0; k1 <= ctrl1; k6 <= ctrl6; kbrk <= brk;
        yorg0 <= yorigin_l[0]; yorg1 <= yorigin_l[1]; kyv <= yvalid_l;
        kgolf <= golf; kvx0 <= vis_x0; kmaxy <= maxy;
        fclk <= 21'd0; misses <= 16'd0; clr_n <= 9'd0;
        v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
        m_cs <= 1'b0; c_cs <= 1'b0; h_cs <= 1'b0;
        mb_v <= 1'b0;                       // the map RAM may have changed
        ds <= (ctrl7[5] && yvalid_l != 2'b00) ? D_CLR : D_DONE;
    end else begin
        // ------------------------------------------------ frame and line
        case( ds )
        D_CLR: if( !tclr ) begin
            // the limits to the screen's bottom; the map cache emptied
            lim_we <= 1'b1; lim_wa <= clr_n; lim_d <= kmaxy + 9'd1;
            mc_we <= 1'b1; mc_wa <= clr_n[7:0]; mc_wt <= 7'd0; mc_wd <= 64'd0;
            clr_n <= clr_n + 9'd1;
            if( clr_n == 9'(W - 1) ) begin line <= 9'd1; ds <= D_LR0; end
        end
        // LRAM long `line` is words 2l, 2l + 1
        D_LR0: begin lr_addr <= { 1'b0, line, 1'b0 }; ds <= D_LR1; end
        D_LR1: begin lr_addr <= { 1'b0, line, 1'b1 }; ds <= D_LR2; end
        D_LR2: begin le_hi <= lr_q; ds <= D_LK; end
        D_LK: begin : lk
            reg bank;
            // golf: lines past 224 are the second table range, from its own origin
            bank = kgolf && line > 9'd224;
            par    <= lr_q[15:8];
            scale  <= le_hi;
            ground <= 18'sd256 + $signed({ 2'b00, bank ? yorg1 : yorg0 }) - $signed({ 9'd0, line })
                    - $signed({ {10{lr_q[7]}}, lr_q[7:0] });
            lk_addr <= { 1'b0, kbrk, lr_q[15:9] };
            // K053936 row line + 14 (its line control is 512 rows of four words)
            lc_addr <= { 1'b0, 9'(line + 9'd14), 2'd0 };
            if( lr_q[15:8] == 8'hff || !kyv[bank] ) begin
                line <= line + 9'd1;
                ds <= line == (kgolf ? 9'd480 : 9'd255) ? D_DRAIN : D_LR0;
            end else ds <= D_LC0;
        end
        D_LC0: begin lc_addr <= lc_addr + 12'd1; ds <= D_LC1; end
        D_LC1: begin
            lc_addr <= lc_addr + 12'd1; lc0 <= lc_q;
            // SRAM 22N: PR0 selects the nibble (odd: low), PR1-7 the byte
            lt_we <= 1'b1; lt_par <= par; lt_d <= par[0] ? lk_q[3:0] : lk_q[7:4];
            ds <= D_LC2;
        end
        D_LC2: begin lc_addr <= lc_addr + 12'd1; lc1 <= lc_q; ds <= D_LC3; end
        D_LC3: begin lc2 <= lc_q; ds <= D_LC4; end
        D_LC4: begin : setup
            reg signed [31:0] sx, sy, ixx, ixy;
            sx  = 256 * $signed(16'(lc0 + k0));
            sy  = 256 * $signed(16'(lc1 + k1));
            ixx = $signed(lc2);
            ixy = $signed(lc_q);
            if( k6[15] ) ixx = ixx * 256;
            if( k6[7] )  ixy = ixy * 256;
            // draw_roz's 16.16 accumulators, from the window's first column
            dx <= ixx << 5; dy <= ixy << 5;
            ax <= (sx << 5) + ((ixx * $signed({ 1'b0, kvx0 })) << 5);
            ay <= (sy << 5) + ((ixy * $signed({ 1'b0, kvx0 })) << 5);
            xi <= 9'd0;
            ds <= D_COLS;
        end
        D_COLS: if( xi == 9'(W) && !v1 && !v2 && !v3 ) begin
            line <= line + 9'd1;
            ds <= line == (kgolf ? 9'd480 : 9'd255) ? D_DRAIN : D_LR0;
        end
        D_DRAIN: if( !sq_push && sq_empty && !wr_busy ) begin
            dbg_clk <= fclk[20:5]; dbg_miss <= misses; ds <= D_DONE;
        end
        default: ;
        endcase

        // ------------------------------------------------ the columns
        // P3
        v3 <= adv2;
        if( v3 && op3 ) begin
            if( scale == 16'd0 ) begin
                if( ground >= 0 && ground <= $signed({ 9'd0, kmaxy }) ) begin
                    sq_push <= 1'b1;
                    sq_d <= { 1'b1, x3, ground[8:0], ground[8:0], par, c3 };
                end
            end else if( top < lim3 ) begin
                sq_push <= 1'b1;
                sq_d <= { 1'b0, x3, top, lim3 - 9'd1, par, c3 };
                lim_we <= 1'b1; lim_wa <= x3; lim_d <= top;
            end
        end
        if( adv2 ) begin
            x3 <= x2; lim3 <= lim2;
            // golf drops CROM's PL bits; its transparency is the whole 8-bit pixel
            c3 <= kgolf ? cpix8 : { pl2, cpix };
            op3 <= kgolf ? cpix8 != 8'd0 : cpix != 6'd0;
            prod3 <= level * scale;
        end
        if( free2 ) v2 <= adv1;
        if( adv1 ) begin
            x2 <= x1; lim2 <= lim_q;
            pl2 <= eb[19:18]; hb2 <= ea[23:16];
            cg2 <= coff[22:3]; cs2 <= coff[2:0]; ck2 <= cpx[1:0];
            hg2 <= hoff[22:3]; hs2 <= hoff[2:0]; hk2 <= hpx[1:0];
            ce_r <= ce_ra; co_r <= co_ra; he_r <= he_ra; ho_r <= ho_ra;
        end
        if( free1 ) v1 <= issue;
        if( issue ) begin
            x1 <= xi;
            tx1 <= ax[26:16]; ty1 <= ay[26:16];
            xi <= xi + 9'd1;
            ax <= ax + dx; ay <= ay + dy;
        end

        // ------------------------------------------------ misses
        // the map: P1's entry
        if( m_cs ) begin
            if( m_ok ) begin
                m_cs <= 1'b0;
                mc_we <= 1'b1; mc_wa <= m_addr[7:0]; mc_wd <= m_data; mc_wt <= { 1'b1, m_addr[13:8] };
                mb_v <= 1'b1; mb_ti <= m_addr; mb_d <= m_data;
            end
        end else if( cols && v1 && !m_hit ) begin
            m_cs <= 1'b1; m_addr <= ti1; misses <= misses + 16'd1;
        end
        // CROM and HROM: P2's granules, the first then the second
        if( c_cs ) begin
            if( c_ok ) begin
                c_cs <= 1'b0; cc_we <= 1'b1; cc_wg <= c_addr; cc_wd <= c_data;
                cb_v[cb_p] <= 1'b1; cb_g[cb_p] <= c_addr; cb_d[cb_p] <= c_data; cb_p <= ~cb_p;
            end
        end else if( cols && v2 && !(c_h0 && c_h1) ) begin
            c_cs <= 1'b1; c_addr <= c_h0 ? cg2n : cg2; misses <= misses + 16'd1;
        end
        if( h_cs ) begin
            if( h_ok ) begin
                h_cs <= 1'b0; hc_we <= 1'b1; hc_wg <= h_addr; hc_wd <= h_data;
                hb_v[hb_p] <= 1'b1; hb_g[hb_p] <= h_addr; hb_d[hb_p] <= h_data; hb_p <= ~hb_p;
            end
        end else if( cols && v2 && !(h_h0 && h_h1) ) begin
            h_cs <= 1'b1; h_addr <= h_h0 ? hg2n : hg2;
        end
    end
end

// ------------------------------------------------------------ the writer
// spans and points into the drawn buffer, a pixel a write; abandoned with
// the frame at its next start
localparam int QD = 16;
reg  [43:0] sq [0:QD-1];
reg  [ 3:0] sq_wr = 4'd0, sq_rd = 4'd0;
reg  [ 4:0] sq_n = 5'd0;
wire        sq_empty = sq_n == 5'd0;
assign      sq_full = sq_n >= 5'(QD - 4);
reg  [43:0] wq;
reg  [ 8:0] wy;
reg         w_req = 1'b0;
reg  [28:0] w_addr;
reg  [63:0] w_din;
reg  [ 7:0] w_be;
wire        w_take;
wire        sq_pop = !wr_busy && !sq_empty;
always @(posedge clk) begin
    if( rst || go ) begin
        sq_wr <= 4'd0; sq_rd <= 4'd0; sq_n <= 5'd0; wr_busy <= 1'b0; w_req <= 1'b0;
    end else begin
        if( sq_push ) begin sq[sq_wr] <= sq_d; sq_wr <= sq_wr + 4'd1; end
        sq_n <= sq_n + (sq_push ? 5'd1 : 5'd0) - (sq_pop ? 5'd1 : 5'd0);
        if( w_take ) w_req <= 1'b0;
        if( sq_pop ) begin
            wq <= sq[sq_rd]; wy <= sq[sq_rd][33:25];
            sq_rd <= sq_rd + 4'd1;
            wr_busy <= 1'b1;
        end else if( wr_busy && (!w_req || w_take) ) begin
            // one pixel of column wq[42:34]
            w_req  <= 1'b1;
            w_addr <= waddr( fb, wy[7:0], wq[42:36] );
            w_be   <= 8'b11 << { wq[35:34], 1'b0 };
            w_din  <= { 4{ wq[15:0] } };
            wy <= wy + 9'd1;
            if( wy == wq[24:16] ) wr_busy <= 1'b0;
        end
    end
end

// ------------------------------------------------------------ the display
// row by + 1 is read into a line buffer while row by is shown, and cleared
// in the store as it is read; the window's first row at vblank start. ~fb is
// shown.
reg  [63:0] lb [0:255];                     // two rows of 96 words (four pixels each), by row parity
reg  [63:0] lb_q;
reg  [ 8:0] by_l;
reg  [ 7:0] rr;
reg         rd_go;
always @(posedge clk) begin
    by_l <= by;
    rd_go <= 1'b0;
    if( lvbl_l && !lvbl ) begin rr <= { 3'd0, vis_y0 }; rd_go <= 1'b1; end
    else if( lvbl && by != by_l && by < maxy ) begin rr <= 8'(by + 9'd1); rd_go <= 1'b1; end
end

localparam [1:0] R_IDLE = 0, R_RD = 1, R_GET = 2, R_CLR = 3;
reg  [ 1:0] rs = R_IDLE;
reg  [ 6:0] rgot, rclr;
reg  [ 7:0] rrow;
always @(posedge clk) begin
    if( rst ) rs <= R_IDLE;
    else case( rs )
    R_IDLE: if( rd_go ) begin rrow <= rr; rs <= R_RD; end
    R_RD:   if( !DDRAM_BUSY ) begin rgot <= 7'd0; rs <= R_GET; end
    R_GET:  if( DDRAM_DOUT_READY ) begin
                rgot <= rgot + 7'd1;
                if( rgot == 7'd95 ) begin rclr <= 7'd0; rs <= R_CLR; end
            end
    R_CLR:  if( !DDRAM_BUSY ) begin
                rclr <= rclr + 7'd1;
                if( rclr == 7'd95 ) rs <= R_IDLE;
            end
    endcase
end
always @(posedge clk) if( rs == R_GET && DDRAM_DOUT_READY ) lb[{ rrow[0], rgot }] <= DDRAM_DOUT;

// the port: the display's read and clear first, then the writer
assign DDRAM_RD       = rs == R_RD;
assign DDRAM_WE       = rs == R_CLR || (rs == R_IDLE && w_req);
assign DDRAM_BURSTCNT = rs == R_RD || rs == R_CLR ? 8'd96 : 8'd1;
assign DDRAM_ADDR     = rs == R_RD || rs == R_CLR ? waddr( ~fb, rrow, 7'd0 ) : w_addr;
assign DDRAM_DIN      = rs == R_CLR ? 64'd0 : w_din;
assign DDRAM_BE       = rs == R_CLR ? 8'hff : w_be;
assign w_take         = rs == R_IDLE && w_req && !DDRAM_BUSY;

// the shown pixel, two cycles after rd_x: the store's word, then its
// parameter's lookup nibble
wire [9:0] lx = rd_x - vis_x0;
reg  [ 1:0] lx_l;
reg  [15:0] lb_q2;
wire [15:0] lb_px = lb_q[{ lx_l, 4'd0 } +: 16];
always @(posedge clk) begin
    lb_q   <= lb[{ by[0], lx[8:2] }];
    lx_l   <= lx[1:0];
    lb_q2  <= lb_px;
    ltab_q <= ltab[{ ~fb, lb_px[15:8] }];
end
always @(*) begin
    t_valid = lb_q2 != 16'd0 && warm == 2'd3;
    t_pen   = { ltab_q, lb_q2[7:0] };
    t_pri   = lb_q2[15:8];
end

endmodule
