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
 *     (31) if the code is not 1 or OBJSET1 bit 5 is set; otherwise it is all
 *     shadow and is not drawn here. Shadows are the mixer's (not done yet).
 *   - konamigx_mixer's primode 4 "Daisukiss bad shadow filter".
 *
 * ROM: one request per 8 pixels, rom_addr = { code[17:0], row[3:0], half },
 * rom_data = the 5 bytes of that half-row as K055673_LAYOUT_GX assembles
 * them (byte 0 in [39:32]; within a byte the leftmost pixel is the MSB; the
 * pixel is b4<<4 | b3<<3 | b2<<2 | b1<<1 | b0).
 *
 * OUTPUT per pixel: valid (pen != 0), pen = colour * 32 + pixel (13 bits,
 * K055673 colour granularity 32), pri (the K055555 input priority), zcode.
 */

module gx_obj #(parameter
    HOFFSET = 10'd62,
    HADJ    = 10'd0,
    KEYW    = 16        // 0 = jotego's last-written-wins buffer (bench A/B only)
)(
    input             rst,
    input             clk,
    input             pxl_cen,
    input             pxl2_cen,
    input      [ 8:0] hdump,
    input      [ 8:0] vdump,
    input      [ 9:0] voffset,
    input             hs,
    input             lvbl,

    // sprite RAM, CPU side (16-bit)
    input             ram_cs,
    input      [ 1:0] ram_we,
    input      [12:1] ram_addr,
    input      [15:0] ram_din,
    output     [15:0] ram_dout,

    // K053246 registers (jt053246_mmr)
    input             reg_cs,
    input             mmr_we,
    input      [ 3:0] mmr_addr,
    input      [15:0] mmr_din,
    input      [ 1:0] mmr_dsn,

    // K055673 registers, word n of 0xd4a010 (m_kx47_regs[n])
    input             k47_we,
    input      [ 2:0] k47_addr,
    input      [15:0] k47_din,

    // from the K055555 and the board
    input      [ 7:0] opri,        // K55_PRIINP_8
    input      [ 7:0] oinprion,    // K55_OINPRI_ON
    input      [ 7:0] ocblk,       // K55_PALBASE_OBJ
    input      [ 7:0] wrport2,
    input      [ 3:0] primode,     // konamigx_mixer_primode, per machine config

    // sprite ROM
    output     [22:0] rom_addr,
    output            rom_cs,
    input             rom_ok,
    input      [39:0] rom_data,

    // pixel output, one pxl_cen behind hdump as the line buffer reads it
    output            pxl_valid,
    output     [12:0] pxl_pen,
    output     [ 7:0] pxl_pri,
    output     [ 7:0] pxl_z
);

// ------------------------------------------------------------ registers
reg  [15:0] kx47 [0:7];
reg  [ 7:0] objset1;        // K053246 register 5, as jt053246_mmr also holds it

always @(posedge clk) begin
    if( k47_we ) kx47[k47_addr] <= k47_din;
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
wire [ 7:0] zcode;
wire        hflip, vflip, hz_keep, dr_start, dr_busy, dma_bsy;
wire [ 3:0] ysub;
wire [11:0] hzoom;
wire [ 1:0] pre_shd;
wire [13:1] dma_addr;
wire [15:0] dma_data;
wire [22:1] rmrd_addr;

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
    .ln_done    (           ),
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
    .hdump      ( hdump     ),
    .vdump      ( vdump     ),
    .voffset    ( voffset   ),
    .lvbl       ( lvbl      ),
    .hs         ( hs        ),
    .pxl        ( 9'd0      ),
    .shd        ( pre_shd   ),
    .dr_start   ( dr_start  ),
    .dr_busy    ( dr_busy   ),
    .debug_bus  ( 8'd0      ),
    .st_addr    ( 8'd0      ),
    .st_dout    (           )
);

jtframe_dual_ram16 #(.AW(12)) u_ram(   // 8 KB; the DMA reads words 0-2047
    .clk0   ( clk              ),
    .data0  ( ram_din          ),
    .addr0  ( ram_addr         ),
    .we0    ( ram_we & {2{ram_cs}} ),
    .q0     ( ram_dout         ),
    .clk1   ( clk              ),
    .data1  ( 16'd0            ),
    .addr1  ( dma_addr[12:1]   ),
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

// konamigx_mixer's solid/shadow split and the primode 4 filter
wire [1:0] shcode   = attr_full[11:10];
wire       solid    = shcode==0 || shcode!=1 || objset1[5];
wire       mode1    = shcode!=0;            // shadow pen is not solid
wire       filtered = primode==4 && (attr_full[13:12]!=0 || attr_full==16'h0800);
wire       draw     = dr_start && solid && !filtered;

// ------------------------------------------------------------ draw
// pal = { zcode, pri, color, mode1 }; the key is its top 16 bits.
localparam PW = 8+8+8+1+5;
wire [PW-1:0] buf_pred, buf_din, pre_pxl;
wire [24:2]   draw_addr;
wire [39:0]   sorted;

// K055673_LAYOUT_GX half-row -> jtframe_draw's format (one plane per byte,
// leftmost pixel in the LSB)
genvar gk, gi;
generate for( gk=0; gk<5; gk=gk+1 ) begin : g_plane
    for( gi=0; gi<8; gi=gi+1 ) begin : g_bit
        assign sorted[8*gk+gi] = rom_data[39-8*gk-gi];   // byte k, bit 7-i
    end
end endgenerate

// mode 1: pen 31 is the shadow pen, not drawn as a colour
assign buf_din = ( buf_pred[5] && buf_pred[4:0]==5'd31 ) ? { buf_pred[PW-1:5], 5'd0 } : buf_pred;

// draw_addr = { code, H, Y } -> external { code, Y, H }
assign rom_addr = { draw_addr[24:7], draw_addr[5:2], draw_addr[6] };

jtframe_objdraw_gate #(
    .AW(10), .CW(18), .PW(PW), .ZW(12), .ZI(6), .ZENLARGE(1),
    .SWAPH(0), .LATCH(1), .FLIP_OFFSET(9'h12), .BPP(5), .KEYW(KEYW)
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
    .pal        ( { zcode, pri, color, mode1 } ),
    .rom_addr   ( draw_addr      ),
    .rom_cs     ( rom_cs         ),
    .rom_ok     ( rom_ok         ),
    .rom_data   ( sorted         ),
    .buf_pred   ( buf_pred       ),
    .buf_din    ( buf_din        ),
    .pxl        ( pre_pxl        )
);

assign pxl_valid = pre_pxl[4:0] != 0;
assign pxl_pen   = { pre_pxl[13:6], pre_pxl[4:0] };
assign pxl_pri   = pre_pxl[21:14];
assign pxl_z     = pre_pxl[29:22];

endmodule
