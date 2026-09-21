/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX sprites: K053246 + K055673, as jotego's jt053246 object pipeline.
 *
 * DERIVED FROM jtsimson_obj.v (jotego/jtcores e7958c86, cores/simson/hdl,
 * GPL-3.0-or-later, Jose Tejada Gomez), vendored unmodified beside this in
 * rtl/video/k055673/. What differs from it, and why, is in
 * rtl/video/k055673/PROVENANCE.md, "Local changes". In short:
 *
 *   - jt053246 runs with GX_ORDER=1: the DMA copies sprites in RAM order,
 *     and which sprite is in front is decided per pixel in the line buffer
 *     on the key {z-code, priority} -- lowest wins, first written wins a tie
 *     (MAME's konamigx_mixer order; docs/MAME_KLUDGES.md).
 *   - 5 bpp pixels (K055673_LAYOUT_GX) through jtframe_draw's BPP=5.
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
 * rom_data = the 5 bytes of that half-row as K055673_LAYOUT_GX assembles
 * them (byte 0 in [39:32]; within a byte the leftmost pixel is the MSB; the
 * pixel is b4<<4 | b3<<3 | b2<<2 | b1<<1 | b0).
 *
 * OUTPUT per pixel, solid plane: valid (pen != 0), pen = colour * 32 +
 * pixel (13 bits, K055673 colour granularity 32), pri (the K055555 input
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

    // sprite ROM
    output     [22:0] rom_addr,
    output            rom_cs,
    input             rom_ok,
    input      [39:0] rom_data,
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
    output reg        ln_short       // one clock: the scan had not finished the line when the next began
);

// ------------------------------------------------------------ registers
reg  [15:0] kx47 [0:7];
reg  [ 7:0] objset1;        // K053246 register 5, as jt053246_mmr also holds it

always @(posedge clk) begin
    if( k47_we[1] ) kx47[k47_addr][15:8] <= k47_din[15:8];
    if( k47_we[0] ) kx47[k47_addr][ 7:0] <= k47_din[ 7:0];
    if( reg_cs && mmr_we ) begin
        if( objset1[2] ) begin
            if( mmr_addr[2:0]==5 ) objset1 <= mmr_din[7:0];
        end else if( mmr_addr[2:1]==2 && !mmr_dsn[0] )
            objset1 <= mmr_din[7:0];
    end
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
assign dma_busy = dma_bsy;

// jt053246_scan's own test ("Obj scan did not finish"), for the board's probe:
// at a line start in its active range, the walk of the line before is not done
wire ln_done;
reg  hs_l2;
always @(posedge clk) begin
    hs_l2    <= hs;
    ln_short <= hs && !hs_l2 && vdump > 9'h10D && vdump <= 9'h1F7 && !ln_done;
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
    .vdump      ( vdump     ),
    .voffset    ( voffset   ),
    .hoff_adj   ( hoff_adj  ),
    .dma_trig   ( dma_trig  ),
    .dma_hold   ( dma_hold  ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),
    .pxl        ( 9'd0      ),
    .shd        ( pre_shd   ),
    .dr_start   ( dr_start  ),
    .dr_busy    ( dr_busy   ),
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
    pri    = (c18[15:8] & ~oinprion) | (opri & oinprion);
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
reg  [7:0] spri;
always @* begin
    spri = opset[5] ? pri : shset==2'd0 ? shdpri0 : shset==2'd1 ? shdpri1 : shdpri2;
    if( (primode==4 || primode==5) && spri < spri_min ) spri = spri_min;
end

// ------------------------------------------------------------ draw
// The data word gx_obj_linebuf.v documents: { z, pri, spri, index, colour,
// solid, mode1, shadow mode, shadow code, pen }, padded to PW.
localparam PW = 72;
wire [PW-1:0] buf_pred, buf_din, pre_pxl;
wire [24:2]   draw_addr;
wire [39:0]   sorted;

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
reg  [39:0]   ok_data;
reg           ok_held;
always @(posedge clk) begin
    addr_d <= rom_addr;
    if( !rom_cs ) ok_held <= 0;
    else if( rom_ok ) begin ok_held <= 1; ok_addr <= addr_d; ok_data <= rom_data; end
end
wire          held_hit = ok_held && rom_cs && rom_addr == ok_addr;
wire          drw_ok   = rom_ok || held_hit;
wire [39:0]   drw_data = rom_ok ? rom_data : ok_data;

// K055673_LAYOUT_GX half-row -> jtframe_draw's format (one plane per byte,
// leftmost pixel in the LSB)
genvar gk, gi;
generate for( gk=0; gk<5; gk=gk+1 ) begin : g_plane
    for( gi=0; gi<8; gi=gi+1 ) begin : g_bit
        assign sorted[8*gk+gi] = drw_data[39-8*gk-gi];   // byte k, bit 7-i
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
assign pf_cs   = pf_on;
assign pf_addr = { pf_code18, ysub ^ {4{vflip}}, hflip };

jtframe_objdraw_gate #(
    .AW(10), .CW(18), .PW(PW), .ZW(12), .ZI(6), .ZENLARGE(1),
    .SWAPH(0), .LATCH(1), .FLIP_OFFSET(9'h12), .BPP(5), .KEYW(16), .FIRST_PX(1)
) u_draw (
    .rst        ( rst            ),
    .clk        ( clk            ),
    .pxl_cen    ( pxl_cen        ),
    .hs         ( hs             ),
    .flip       ( 1'b0           ),
    .hdump      ( {1'b0, hdump}  ),
    .draw       ( draw           ),
    .busy       ( dr_busy        ),
    .code       ( code18         ),
    .xpos       ( hpos           ),
    .ysub       ( ysub           ),
    .trunc      ( 2'd0           ),
    .hzoom      ( hzoom          ),
    .hz_keep    ( hz_keep        ),
    .hflip      ( hflip          ),
    .vflip      ( vflip          ),
    .pal        ( { 21'd0, zcode, pri, spri, obj_idx, color, solid, mode1, shmode, shset } ),
    .rom_addr   ( draw_addr      ),
    .rom_cs     ( rom_cs         ),
    .rom_ok     ( drw_ok         ),
    .rom_data   ( sorted         ),
    .buf_pred   ( buf_pred       ),
    .buf_din    ( buf_din        ),
    .pxl        ( pre_pxl        )
);

assign pxl_valid = pre_pxl[4:0] != 0;
assign pxl_pen   = { pre_pxl[12:5], pre_pxl[4:0] };
assign pxl_idx   = pre_pxl[20:13];
assign pxl_pri   = pre_pxl[28:21];
assign pxl_z     = pre_pxl[36:29];
assign shd_z     = pre_pxl[44:37];
assign shd_pri   = pre_pxl[52:45];
assign shd_idx   = pre_pxl[60:53];
assign shd_code  = pre_pxl[62:61];
assign shd_full  = pre_pxl[63];
assign shd_valid = pre_pxl[64];

endmodule
