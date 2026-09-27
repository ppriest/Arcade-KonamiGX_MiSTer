/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX sprites: K053246 + K055673, as jotego's jt053246 object pipeline.
 *
 * DERIVED FROM jtsimson_obj.v (jotego/jtcores e7958c86, cores/simson/hdl,
 * GPL-3.0-or-later, Jose Tejada Gomez), vendored unmodified beside this in
 * rtl/video/k055673/. What differs from it, and why, is in
 * rtl/video/k055673/PROVENANCE.md, "Local changes". In short:
 *
 *   - jt053246 runs with GX_DMA_ALWAYS=1: the DMA copies the list at every
 *     start whether or not OBJSET1 bit 4 (DMAEN) is set. MAME's GX mixer has
 *     no copy at all -- konamigx_mixer_init(screen, 0) points it at the
 *     K053247 RAM -- so it draws the live list whatever DMAEN says, and
 *     tokkae runs with DMAEN clear (OBJSET1 0x20) and its sprites on screen
 *     (docs/MAME_KLUDGES.md).
 *   - jt053246 runs with GX_ORDER=1: the DMA copies sprites in RAM order,
 *     and which sprite is in front is decided per pixel in the line buffer
 *     on the key {z-code, priority} -- lowest wins, first written wins a tie
 *     (MAME's konamigx_mixer order; docs/MAME_KLUDGES.md).
 *   - pixels of 4, 5, 6 or 8 bits (obj_layout: K055673_LAYOUT_RNG, GX, GX6,
 *     LE2) through jtframe_draw at BPP=8, the planes a layout lacks zero.
 *   - the colour and priority come from GX's type2_sprite_callback, which
 *     routes the attribute through the K055555's OBJ palette and priority
 *     fields; the code gets the K055673's VRC bank bits.
 *   - solid/shadow split as konamigx_mixer does it: a sprite with shadow
 *     code 0 is solid; with a shadow code it is solid except its shadow pen
 *     (31), and that pen is a shadow if the code's shadow set is on, when the
 *     code is not 1 or OBJSET1 bit 5 is set; otherwise every pen is shadow,
 *     if set 0 is on, and the sprite has no solid pixels. Shadow pixels go
 *     to the line buffer's shadow plane with the shadow priority
 *     (SHAD1_PRI.. or the sprite's own, OPSET bit 5; raised to spri_min in
 *     primodes 4 and 5).
 *   - konamigx_mixer's primode 4 "Daisukiss bad shadow filter".
 *
 * ROM: one request per 8 pixels, rom_addr = { code[17:0], row[3:0], half },
 * rom_data = that half-row's bytes (byte 0 in [63:56]; within a byte the
 * leftmost pixel is the MSB). In every K055673 layout byte k of a half-row
 * is plane k: GX { 32, 24, 16, 8, 0 }, RNG { 24, 16, 8, 0 }, GX6 { 40, 32,
 * 24, 16, 8, 0 }, LE2 { 56, 48, 40, 32, 24, 16, 8, 0 } -- 5, 4, 6 and 8
 * bytes of the half-row, MSB plane first.
 *
 * OUTPUT per pixel, solid plane: valid (pen != 0), pen = (colour <<
 * bpp) + pixel, 13 bits (MAME: colour % (8192 >> bpp) times the layout's
 * granularity 2^bpp), pri (the K055555 input
 * priority), zcode, index. Shadow plane: valid, every-pen mode, code (which
 * K054338 shadow set), index, shadow priority, zcode. The index and zcode
 * are what the mixer needs to rank a sprite against a shadow as MAME does.
 */

module gx_obj #(parameter
    HOFFSET = 10'd62,
    HADJ    = 10'd0
)(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input      [ 9:0] voffset,
    input      [ 9:0] hoff_adj,     // the set's K055673 dx - (-26), signed
    input             dma_trig,     // start the sprite DMA now (gx_main)
    input             dma_hold,     // the ESC is writing the list: hold it off
    input             hs,
    input             lvbl,

    // sprite RAM, CPU side (16-bit)
    input             ram_cs,
    input      [ 1:0] ram_we,
    input      [13:1] ram_addr,        // 16 KB, 0xd20000-0xd23fff
    input      [15:0] ram_din,
    output     [15:0] ram_dout,

    // K053246 registers (jt053246_mmr)
    input             reg_cs,
    input             mmr_we,
    input      [ 3:0] mmr_addr,
    input      [15:0] mmr_din,
    input      [ 1:0] mmr_dsn,

    // K055673 registers, word n of 0xd4a010 (m_kx47_regs[n])
    input      [ 1:0] k47_we,         // byte lanes { 15:8, 7:0 }: the game writes some bytes alone
    input      [ 2:0] k47_addr,
    input      [15:0] k47_din,

    // from the K055555 and the board
    input      [ 7:0] opri,        // K55_PRIINP_8
    input      [ 7:0] oinprion,    // K55_OINPRI_ON
    input      [ 7:0] ocblk,       // K55_PALBASE_OBJ
    input      [ 7:0] wrport2,
    input      [ 3:0] primode,     // konamigx_mixer_primode, per machine config
    input      [ 2:0] shadowon,    // K054338 shadow set i has a delta outside +/-7
    input      [ 7:0] shdpri0,     // K55_SHAD1_PRI
    input      [ 7:0] shdpri1,     // K55_SHAD2_PRI
    input      [ 7:0] shdpri2,     // K55_SHAD3_PRI
    input      [ 7:0] spri_min,    // highest priority of a layer SHD_ON leaves unshadowed
    input      [ 1:0] obj_layout,  // K055673 set_config layout: 0 GX, 1 RNG, 2 GX6, 3 LE2
    input             vmirror,     // le2u/le2j: the sprite plane turned over its visible rows
    input      [ 2:0] shd_defer,   // shadow codes SHD PRI SEL defers (gx_mixer): the line buffer keeps others first
    input      [ 1:0] obj_pri_raw, // 1 dragoonj_sprite_callback: pri = attr bit 9 ? 4 : attr[7:4];
                                   // 2 salmndr2_sprite_callback: pri = attr[9:4]

    // sprite ROM
    output     [22:0] rom_addr,
    output            rom_cs,
    input             rom_ok,
    input      [63:0] rom_data,
    // the row the scan will draw next, for the port to fetch ahead of the
    // drawer: a fetch takes longer than the eight pixels the drawer has to
    // spare, so without this every row waits for memory before its first
    // pixel (docs/ROADMAP.md, sprite drawing time)
    output            pf_cs,
    output     [22:0] pf_addr,
    // the K053246's ROM readback address (registers 4, 6, 7), which the CPU
    // reads its sprite ROM back through at 0xd4a000
    output     [22:1] rmrd_out,

    // pixel output, one pxl_cen behind hdump as the line buffer reads it
    output            pxl_valid,
    output     [12:0] pxl_pen,
    output     [ 7:0] pxl_pri,
    output     [ 7:0] pxl_z,
    output     [ 7:0] pxl_idx,
    output            shd_valid,
    output            shd_full,
    output     [ 1:0] shd_code,
    output     [ 7:0] shd_idx,
    output     [ 7:0] shd_pri,
    output     [ 7:0] shd_z,
    output            dma_busy,      // the object DMA is copying (status bit, IRQ 3 at its end)
    output reg        ln_short,      // one clock: the scan had not finished the line when the next began
    // the first tile each frame of a sprite with shadow code 1: { rom data
    // [63:0], rom address [86:64], code18 [104:87], shadow mode [106:105],
    // solid [107], partial [108], attr_full [124:109], OBJSET1 [132:125],
    // captured [133], data seen [134] } (probe O)
    output reg [135:0] dbg_shd
);

// ------------------------------------------------------------ registers
reg  [15:0] kx47 [0:7];
reg  [ 7:0] objset1;        // K053246 register 5, as jt053246_mmr also holds it

// OBJSET1 is reset: it had no reset or initial value, and Quartus powered
// it up with bit 2 set. That bit switched this copy to jt053246_mmr's 8-bit
// addressing (register 5 at an odd address), which gx_main never presents,
// so the copy froze at 0x04 and the game's 0x20/0x30 never reached it; with
// bit 5 clear every shadow-code-1 sprite drew as a whole shadow (tkmmpzdm,
// tokkae, on the board only -- the benches start it at 0). The 8-bit path
// is gone: GX's registers are written a word at a time through gx_main.
always @(posedge clk) begin
    if( k47_we[1] ) kx47[k47_addr][15:8] <= k47_din[15:8];
    if( k47_we[0] ) kx47[k47_addr][ 7:0] <= k47_din[ 7:0];
    if( rst ) objset1 <= 8'd0;
    else if( reg_cs && mmr_we && mmr_addr[2:1]==2 && !mmr_dsn[0] )
        objset1 <= mmr_din[7:0];
end

// konamigx_precache_registers
wire [15:0] opset = kx47[6];
wire [ 2:0] opj   = opset[2:0] > 3'd4 ? 3'd4 : opset[2:0];
reg  [ 3:0] coregmask;
always @* case( opj )
    3'd0: coregmask = 4'hf;
    3'd1: coregmask = 4'he;
    3'd2: coregmask = 4'hc;
    3'd3: coregmask = 4'h8;
    default: coregmask = 4'h0;
endcase
wire [15:0] coreg      = { opset[11:8] & coregmask, 12'd0 };
wire [ 3:0] coregshift = 4'd4 + { 1'b0, opj };

// ------------------------------------------------------------ jt053246
wire [15:0] code;
wire [ 9:0] attr, hpos;
wire [15:0] attr_full;
wire [ 7:0] zcode, obj_idx;
wire        hflip, vflip, hz_keep, dr_start, dr_busy, dma_bsy;
wire        q_full, q_empty;            // the draw queue, below
assign dma_busy = dma_bsy;

// jt053246_scan's own test ("Obj scan did not finish"), for the board's probe:
// at a line start in its active range, the walk of the line before is not done
wire ln_done;
reg  hs_l2;
always @(posedge clk) begin
    hs_l2    <= hs;
    // the line is done when the scan is and the queue and the drawer are empty
    ln_short <= hs && !hs_l2 && vdump > 9'h10D && vdump <= 9'h1F7
                && !(ln_done && q_empty && !dr_busy);
end
wire [ 3:0] ysub;
wire        pf_on;
wire [15:0] pf_code;
wire [11:0] hzoom;
wire [ 1:0] pre_shd;
wire [13:1] dma_addr;
wire [15:0] dma_data;
wire [22:1] rmrd_addr;
assign rmrd_out = rmrd_addr;

jt053246 #(
    .K55673   ( 0       ),
    .GX_ORDER ( 1       ),
    .GX_DMA_ALWAYS ( 1  ),
    .HOFFSET  ( HOFFSET ),
    .HADJ     ( HADJ    )
) u_scan (
    .rst        ( rst       ),
    .clk        ( clk       ),
    .pxl2_cen   ( pxl2_cen  ),
    .pxl_cen    ( pxl_cen   ),
    .simson     ( 1'b0      ),
    .ln_done    ( ln_done        ),
    .cs         ( reg_cs    ),
    .cpu_we     ( mmr_we    ),
    .cpu_addr   ( mmr_addr  ),
    .cpu_dout   ( mmr_din   ),
    .cpu_dsn    ( mmr_dsn   ),
    .rmrd_addr  ( rmrd_addr ),
    .dma_addr   ( dma_addr  ),
    .dma_data   ( dma_data  ),
    .dma_bsy    ( dma_bsy   ),
    .code       ( code      ),
    .attr       ( attr      ),
    .hflip      ( hflip     ),
    .vflip      ( vflip     ),
    .hpos       ( hpos      ),
    .ysub       ( ysub      ),
    .hzoom      ( hzoom     ),
    .hz_keep    ( hz_keep   ),
    .zcode      ( zcode     ),
    .attr_full  ( attr_full ),
    .obj_idx    ( obj_idx   ),
    .hdump      ( hdump     ),
    .vdump      ( vmirror ? 9'h2fb - vdump : vdump ),
    .voffset    ( voffset   ),
    .hoff_adj   ( hoff_adj  ),
    .dma_trig   ( dma_trig  ),
    .dma_hold   ( dma_hold  ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),
    .pxl        ( 9'd0      ),
    .shd        ( pre_shd   ),
    .dr_start   ( dr_start  ),
    .dr_busy    ( q_full    ),
    .pf_on      ( pf_on     ),
    .pf_code    ( pf_code   ),
    .debug_bus  ( 8'd0      ),
    .st_addr    ( 8'd0      ),
    .st_dout    (           )
);

jtframe_dual_ram16 #(.AW(13)) u_ram(   // 16 KB; the DMA reads words 0-2047
    .clk0   ( clk              ),
    .data0  ( ram_din          ),
    .addr0  ( ram_addr         ),
    .we0    ( ram_we & {2{ram_cs}} ),
    .q0     ( ram_dout         ),
    .clk1   ( clk              ),
    .data1  ( 16'd0            ),
    .addr1  ( dma_addr[13:1]   ),
    .we1    ( 2'b0             ),
    .q1     ( dma_data         )
);

// ------------------------------------------------------------ GX callback
// type2_sprite_callback: K053247GX_combine_c18, K055555GX_decode_objcolor,
// K055555GX_decode_inpri. attr is word 6 bits 9:0.
reg  [15:0] c18, opon, ocb, csh;
reg  [ 7:0] color, pri;
reg  [17:0] code18;
always @* begin
    c18 = ({8'd0, attr[7:0]} << coregshift) | coreg;
    if( wrport2[2] )       c18 = c18 & 16'h3fff;
    else if( !wrport2[3] ) c18 = { attr[9:8], c18[13:0] };
    opon   = { oinprion, 8'hff };
    ocb    = { 3'd0, ocblk[2:0], 10'd0 } & ~opon;
    csh    = (ocb | (c18 & opon)) >> coregshift;
    color  = csh[7:0];
    pri    = ((obj_pri_raw == 2'd1 ? (attr[9] ? 8'd4 : { 4'd0, attr[7:4] }) :
               obj_pri_raw == 2'd2 ? { 2'd0, attr[9:4] } : c18[15:8]) & ~oinprion) | (opri & oinprion);
    case( code[15:14] )    // m_k053247_vrcbk
        2'd0: code18 = { kx47[4][ 3:0], code[13:0] };
        2'd1: code18 = { kx47[4][11:8], code[13:0] };
        2'd2: code18 = { kx47[5][ 3:0], code[13:0] };
        2'd3: code18 = { kx47[5][11:8], code[13:0] };
    endcase
end

// konamigx_mixer's solid/shadow split, shadow priority and primode filter
wire [1:0] shcode   = attr_full[11:10];
wire       partial  = shcode!=0 && ( shcode!=1 || objset1[5] );
wire [1:0] shset    = partial ? shcode - 2'd1 : 2'd0;
wire       solid    = shcode==0 || partial;
wire       mode1    = shcode!=0;            // pen 31 is not solid
wire [1:0] shmode   = !shcode ? 2'd0 :
                      partial ? ( shadowon[shset] ? 2'd1 : 2'd0 ) :
                                ( shadowon[0]     ? 2'd2 : 2'd0 );
wire       filtered = primode==4 && (attr_full[13:12]!=0 || attr_full==16'h0800);
wire       draw     = dr_start && !filtered && ( solid || shmode!=0 );
// konamigx_mixer: "invert z-order when opset_pri is set (see p.51 OPSET PRI)"
// -- OPSET bit 4 (tokkae and tkmmpzdm run with it set)
wire [7:0] zcode_e  = opset[4] ? 8'hff - zcode : zcode;
reg  [7:0] spri;
always @* begin
    spri = opset[5] ? pri : shset==2'd0 ? shdpri0 : shset==2'd1 ? shdpri1 : shdpri2;
    if( (primode==4 || primode==5) && spri < spri_min ) spri = spri_min;
end

// ------------------------------------------------------------ draw queue
// The scan used to wait for the drawer to finish each tile before going on,
// so a line cost the scan's walk of the table plus the drawing: dragoonj's
// busiest lines (112 tiles, gx_obj_tb +LINE_STATS) spent 1039 clocks reading
// entries and 2032 waiting, 3071 of the line's 3072, and the heavier ones ran
// out. Tiles now go into a queue, with everything the drawer latches from
// the scan and the callback, so the walk goes on while they are drawn and a
// line costs the longer of the two. The ROM hint is the queue's head, the
// tile the drawer takes next. A new line starts with the queue emptied, as
// the scan starts its walk again.
localparam QD = 8;
localparam QW = 18 + 10 + 4 + 12 + 3 + 55;
wire [54:0]   c_pal = { shd_defer[shset], shpen, zcode_e, pri, spri, obj_idx, color, solid, mode1, shmode, shset };
(* ramstyle = "logic" *) reg [QW-1:0] q_mem [0:QD-1];
reg  [ 2:0]   q_wp, q_rp;
reg  [ 3:0]   q_n;
reg  [QW-1:0] q_out;                    // the tile the drawer was given, held for its latch
reg           q_flag [0:QD-1];          // probe: the tile dbg_shd follows
reg           qf_out, shd_arm, lvbl_d;
reg           q_draw, draw_l;
wire          q_push = draw && !draw_l; // dr_start is high for a cen2 period
assign q_full  = q_n >= QD - 1;         // room for one more push in flight
assign q_empty = q_n == 4'd0;
wire          q_pop  = !q_empty && !dr_busy && !q_draw;
always @(posedge clk) begin
    draw_l <= draw;
    q_draw <= 1'b0;
    if( rst || (hs && !hs_l2) ) begin
        q_wp <= 3'd0; q_rp <= 3'd0; q_n <= 4'd0;
    end else begin
        if( q_push ) begin
            q_mem[q_wp] <= { code18, hpos, ysub, hzoom, hz_keep, hflip, vflip, c_pal };
            q_flag[q_wp] <= shd_arm && shcode == 2'd1;
            q_wp <= q_wp + 3'd1;
        end
        if( q_pop ) begin
            q_out  <= q_mem[q_rp];
            qf_out <= q_flag[q_rp];
            q_rp   <= q_rp + 3'd1;
            q_draw <= 1'b1;
        end
        q_n <= q_n + { 3'd0, q_push } - { 3'd0, q_pop };
    end
end
wire [17:0] qd_code  = q_out[QW-1 -: 18];
wire [ 9:0] qd_hpos  = q_out[QW-19 -: 10];
wire [ 3:0] qd_ysub  = q_out[QW-29 -: 4];
wire [11:0] qd_hzoom = q_out[QW-33 -: 12];
wire        qd_hzk   = q_out[57];
wire        qd_hflip = q_out[56];
wire        qd_vflip = q_out[55];
wire [54:0] qd_pal   = q_out[54:0];
// the head, for the ROM hint
wire [QW-1:0] q_head = q_mem[q_rp];

// ------------------------------------------------------------ draw
// The data word gx_obj_linebuf.v documents: { z, pri, spri, index, colour,
// solid, mode1, shadow mode, shadow code, pen }, padded to PW.
localparam PW = 75;
wire [PW-1:0] buf_pred, buf_din, pre_pxl;
wire [24:2]   draw_addr;
wire [63:0]   sorted;

// The ROM port answers a fetch with one clock of ok and does not fetch the
// same address again while cs stays high. jtframe_draw keeps cs high across
// a row's two halves, moves to the second half's address as it starts
// drawing the first, and only looks at ok again after eight pixels -- so an
// answer quicker than those pixels (zoomed sprites draw them slowly) was
// never seen, and drawer and port waited on each other for ever. On the
// board Twin Bee's sprites stopped at its first zoomed ones and never came
// back; the benches' ROM models repeated ok every clock and hid it. The
// answer is held here, with the address the port matched (the one the
// drawer showed the clock before the pulse), until the drawer takes it or
// moves on.
reg  [22:0]   addr_d, ok_addr;
reg  [63:0]   ok_data;
reg           ok_held;
always @(posedge clk) begin
    addr_d <= rom_addr;
    if( !rom_cs ) ok_held <= 0;
    else if( rom_ok ) begin ok_held <= 1; ok_addr <= addr_d; ok_data <= rom_data; end
end
wire          held_hit = ok_held && rom_cs && rom_addr == ok_addr;
wire          drw_ok   = rom_ok || held_hit;
wire [63:0]   drw_data = rom_ok ? rom_data : ok_data;

// probe O: armed each vblank, it takes the first shadow-code-1 tile queued,
// then the first granule the drawer is answered with for it
always @(posedge clk) begin
    lvbl_d <= lvbl;
    if( rst ) begin shd_arm <= 1'b0; dbg_shd <= 136'd0; end
    else begin
        if( !lvbl && lvbl_d ) shd_arm <= 1'b1;
        if( q_push && shd_arm && shcode == 2'd1 ) begin
            shd_arm <= 1'b0;
            dbg_shd[133:87] <= { 1'b1, objset1, attr_full, partial, solid, shmode, code18 };
            dbg_shd[134]    <= 1'b0;
        end
        if( qf_out && drw_ok && rom_cs && !dbg_shd[134] ) begin
            dbg_shd[63:0]  <= drw_data;
            dbg_shd[86:64] <= rom_addr;
            dbg_shd[134]   <= 1'b1;
        end
    end
end

// the half-row -> jtframe_draw's format (one plane per byte, leftmost pixel
// in the LSB); the planes past the layout's depth are zero
wire [3:0] obpp  = obj_layout==2'd1 ? 4'd4 : obj_layout==2'd2 ? 4'd6 :
                   obj_layout==2'd3 ? 4'd8 : 4'd5;
wire [7:0] shpen = 8'hff >> ( 4'd8 - obpp );          // 2^bpp - 1
genvar gk, gi;
generate for( gk=0; gk<8; gk=gk+1 ) begin : g_plane
    for( gi=0; gi<8; gi=gi+1 ) begin : g_bit
        assign sorted[8*gk+gi] = gk < obpp && drw_data[63-8*gk-gi];   // byte k, bit 7-i
    end
end endgenerate

assign buf_din = buf_pred;    // the solid/shadow split is in gx_obj_linebuf

// draw_addr = { code, H, Y } -> external { code, Y, H }
assign rom_addr = { draw_addr[24:7], draw_addr[5:2], draw_addr[6] };

// the hinted tile's first half, as jtframe_draw would ask for it: its code
// through the same bank mapping (only bits 4, 2 and 0 differ, so the bank
// bits are this sprite's), its row with vflip applied, half = hflip
reg [17:0] pf_code18;
always @* case( pf_code[15:14] )
    2'd0: pf_code18 = { kx47[4][ 3:0], pf_code[13:0] };
    2'd1: pf_code18 = { kx47[4][11:8], pf_code[13:0] };
    2'd2: pf_code18 = { kx47[5][ 3:0], pf_code[13:0] };
    2'd3: pf_code18 = { kx47[5][11:8], pf_code[13:0] };
endcase
// the queue's head when there is one, else the scan's next tile
wire [17:0] qh_code  = q_head[QW-1 -: 18];
wire [ 3:0] qh_ysub  = q_head[QW-29 -: 4];
wire        qh_hflip = q_head[56];
wire        qh_vflip = q_head[55];
assign pf_cs   = !q_empty || pf_on;
assign pf_addr = !q_empty ? { qh_code, qh_ysub ^ {4{qh_vflip}}, qh_hflip }
                          : { pf_code18, ysub ^ {4{vflip}}, hflip };

jtframe_objdraw_gate #(
    .AW(10), .CW(18), .PW(PW), .ZW(12), .ZI(6), .ZENLARGE(1),
    .SWAPH(0), .LATCH(1), .FLIP_OFFSET(9'h12), .BPP(8), .KEYW(16), .FIRST_PX(1)
) u_draw (
    .rst        ( rst            ),
    .clk        ( clk            ),
    .pxl_cen    ( pxl_cen        ),
    .hs         ( hs             ),
    .flip       ( 1'b0           ),
    .hdump      ( {1'b0, hdump}  ),
    .draw       ( q_draw         ),
    .busy       ( dr_busy        ),
    .code       ( qd_code        ),
    .xpos       ( qd_hpos        ),
    .ysub       ( qd_ysub        ),
    .trunc      ( 2'd0           ),
    .hzoom      ( qd_hzoom       ),
    .hz_keep    ( qd_hzk         ),
    .hflip      ( qd_hflip       ),
    .vflip      ( qd_vflip       ),
    .pal        ( { 12'd0, qd_pal } ),
    .rom_addr   ( draw_addr      ),
    .rom_cs     ( rom_cs         ),
    .rom_ok     ( drw_ok         ),
    .rom_data   ( sorted         ),
    .buf_pred   ( buf_pred       ),
    .buf_din    ( buf_din        ),
    .pxl        ( pre_pxl        )
);

// { colour, pen } with the colour at the layout's granularity (2^bpp)
wire [20:0] pen_sh = { 5'd0, pre_pxl[15:8], 8'd0 } >> ( 4'd8 - obpp );
assign pxl_valid = pre_pxl[7:0] != 0;
assign pxl_pen   = pen_sh[12:0] | { 5'd0, pre_pxl[7:0] };
assign pxl_idx   = pre_pxl[23:16];
assign pxl_pri   = pre_pxl[31:24];
assign pxl_z     = pre_pxl[39:32];
assign shd_z     = pre_pxl[47:40];
assign shd_pri   = pre_pxl[55:48];
assign shd_idx   = pre_pxl[63:56];
assign shd_code  = pre_pxl[65:64];
assign shd_full  = pre_pxl[66];
assign shd_valid = pre_pxl[67];

endmodule
