// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami GX video: the K053252 timing, gx_tilemap, gx_obj and gx_mixer.
//
// Each block is proven against the software model or MAME on its own
// (docs/ROADMAP.md, Progress); this module wires them to one timing and
// lines up their pixels.
//
// TIMING comes from jotego's jtk053252, programmed by the CPU as on the
// board. With the registers daiskiss writes it gives 384 x 264 with a
// 288 x 224 visible area -- MAME's decoding of the same registers
// (sim/k053252_gx_tb). At 6 MHz (wrport2 & 3 == 0) a pixel is eight 48 MHz
// clocks.
//
// The blocks index pixels by MAME's bitmap coordinates through two counters
// derived here from the K053252's blanking:
//
//   hdump = 0x70 + p for the p-th pixel after LHBL rises (p < 320), and
//           p - 0x110 after that, so the one jump in hdump falls inside HS,
//           where jtframe_objdraw_gate's readout counter re-synchronises
//   vdump = 0x110 on the first visible line, +1 a line, 0x1FF -> 0xF8;
//           it steps when HS falls, and LVBL -- which changes at the start
//           of horizontal blanking -- already says whether the next line is
//           visible
//
//   bitmap column = hdump - 0x58, bitmap row = vdump - 0x100
//
// with jt053246 at HOFFSET 62 and voffset 281, the values its bench found.
// The first visible pixel is therefore bitmap (24, 16), MAME's visarea
// origin for this machine (K053252 set_offsets(24, 16)).
//
// The tilemap renders one line ahead: at the last pixel before hdump's jump
// it is told to render the row after next, and its read half flips to the
// row it rendered during the previous line.

module gx_video #(
    parameter [9:0] HOFFSET = 10'd62,
    parameter [9:0] VOFFSET = 10'd281
)(
    input             rst,
    input             clk,
    input             pxl_cen,         // the dot clock, wrport2 & 3 selecting 6/8/12/16 MHz
    input             pxl2_cen,        // twice that, for the sprite DMA

    // ---- K053252 (0xd4c000, one register per byte)
    input             crtc_cs,
    input      [ 3:0] crtc_addr,
    input      [ 7:0] crtc_din,
    output     [ 7:0] crtc_dout,
    output            int1,            // vblank interrupt
    output            int2,            // the programmable line interrupt

    // ---- tilemap (K054156/K056832 registers, GX tile banks, VRAM)
    input             tm_reg_we,
    input      [ 4:0] tm_reg_addr,
    input      [15:0] tm_reg_din,
    input      [ 1:0] tm_reg_be,
    input             tbank_we,
    input      [ 2:0] tbank_addr,
    input      [ 7:0] tbank_din,
    input             vram_we,
    input             vram_rd,
    input      [15:0] vram_addr,
    input      [15:0] vram_din,
    input      [ 1:0] vram_be,
    output     [15:0] vram_dout,
    input  signed [7:0] offs_x [4],
    input  signed [7:0] offs_y [4],
    output     [23:0] tile_rom_addr,
    output            tile_rom_cs,
    input             tile_rom_ok,
    input      [39:0] tile_rom_data,

    // ---- sprites (sprite RAM, K053246, K055673)
    input             spr_ram_cs,
    input      [ 1:0] spr_ram_we,
    input      [12:1] spr_ram_addr,
    input      [15:0] spr_ram_din,
    output     [15:0] spr_ram_dout,
    input             k46_cs,
    input             k46_we,
    input      [ 3:0] k46_addr,
    input      [15:0] k46_din,
    input      [ 1:0] k46_dsn,
    input             k47_we,
    input      [ 2:0] k47_addr,
    input      [15:0] k47_din,
    input      [ 7:0] wrport2,
    input      [ 3:0] primode,
    output     [22:0] obj_rom_addr,
    output            obj_rom_cs,
    input             obj_rom_ok,
    input      [39:0] obj_rom_data,

    // ---- mixer (K055555, K054338, palette)
    input             k55_we,
    input      [ 5:0] k55_addr,
    input      [ 7:0] k55_din,
    input             k338_we,
    input      [ 3:0] k338_addr,
    input      [15:0] k338_din,
    input             bg_grad,
    input             pal_we,
    input      [12:0] pal_addr,
    input      [23:0] pal_din,

    // ---- video out: rgb and the K053252's blanking and syncs, aligned
    output     [23:0] rgb,
    output reg        vid_lhbl,
    output reg        vid_lvbl,
    output reg        vid_hs,
    output reg        vid_vs,
    output            unsupported
);

// ------------------------------------------------------------ K053252
wire lhbl, lvbl, hs, vs;

jtk053252 u_crtc (
    .rst, .clk, .pxl_cen, .sel(3'd0), .vldi(1'b1), .hldi(1'b1),
    .cs(crtc_cs), .addr(crtc_addr), .rnw(1'b0), .din(crtc_din), .dout(crtc_dout),
    .lhbl, .lvbl, .hs, .vs, .int1, .int2, .hld(), .vld(), .lhbs(),
    .ioctl_addr(4'd0), .ioctl_din()
);

// hdump and vdump, from the K053252's blanking (see the header)
reg  [8:0] pcnt, hdump, vdump;
reg        lhbl_l, hs_l, lvbl_hsf;
wire [8:0] p = pcnt >= 9'd384 ? pcnt - 9'd384 : pcnt;   // pixel since LHBL rose

always @(posedge clk) if( pxl_cen ) begin
    lhbl_l <= lhbl;
    hs_l   <= hs;
    pcnt   <= ( lhbl && !lhbl_l ) ? 9'd1 : pcnt + 9'd1;
    if( !hs && hs_l ) begin
        lvbl_hsf <= lvbl;
        vdump    <= ( lvbl && !lvbl_hsf ) ? 9'h110 : vdump == 9'h1FF ? 9'h0F8 : vdump + 9'd1;
    end
end

always @* hdump = p < 9'd320 ? 9'h070 + p : p - 9'h110;

// gx_mixer latches a pixel on the pxl_cen that ends it and drives rgb with
// it on the next, so rgb shows a pixel two pixel periods later; two register
// stages delay the blanking and syncs to match
reg [3:0] vd1;
always @(posedge clk) if( pxl_cen ) begin
    vd1 <= { lhbl, lvbl, hs, vs };
    { vid_lhbl, vid_lvbl, vid_hs, vid_vs } <= vd1;
end

// ------------------------------------------------------------ coordinates
wire [9:0] bx = { 1'b0, hdump } - 10'h058;
wire [9:0] by = { 1'b0, vdump } - 10'h100;

// the K055555 fields the sprite side reads, mirrored from the mixer's writes
reg  [7:0] k55 [0:63];
reg  [15:0] k338 [0:15];
always @(posedge clk) begin
    if( k55_we  ) k55[k55_addr]   <= k55_din;
    if( k338_we ) k338[k338_addr] <= k338_din;
end

// konamigx_mixer: shadow set i is on if a K054338 delta is outside +/-7;
// spri_min is the highest priority of a layer K55_SHD_ON leaves unshadowed
function shd_set_on( input [8:0] r, input [8:0] g, input [8:0] b );
    shd_set_on = ( $signed(r) < -7 || $signed(r) > 7 ||
                   $signed(g) < -7 || $signed(g) > 7 ||
                   $signed(b) < -7 || $signed(b) > 7 );
endfunction

wire [2:0] shadowon = { shd_set_on(k338[8][8:0], k338[9][8:0], k338[10][8:0]),
                        shd_set_on(k338[5][8:0], k338[6][8:0], k338[7][8:0]),
                        shd_set_on(k338[2][8:0], k338[3][8:0], k338[4][8:0]) };
reg  [7:0] spri_min;
always @* begin
    spri_min = 8'd0;
    if( !k55[40][0] && spri_min < k55[ 7] ) spri_min = k55[ 7];
    if( !k55[40][1] && spri_min < k55[10] ) spri_min = k55[10];
    if( !k55[40][2] && spri_min < k55[13] ) spri_min = k55[13];
    if( !k55[40][3] && spri_min < k55[14] ) spri_min = k55[14];
end

// ------------------------------------------------------------ tilemap
reg        line_start;
reg  [9:0] line_y;
wire [10:0] tm_pix [4];

always @(posedge clk) begin
    line_start <= 1'b0;
    if( pxl_cen && p == 9'd319 ) begin         // before hdump's jump: render the row after next
        line_start <= 1'b1;
        line_y     <= { 1'b0, vdump } - 10'h100 + 10'd2;
    end
end

gx_tilemap u_tm (
    .clk, .rst,
    .reg_we(tm_reg_we), .reg_addr(tm_reg_addr), .reg_din(tm_reg_din), .reg_be(tm_reg_be),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
    .offs_x, .offs_y,
    .line_start, .line_y, .busy(), .unsupported(),
    .rom_addr(tile_rom_addr), .rom_cs(tile_rom_cs), .rom_ok(tile_rom_ok), .rom_data(tile_rom_data),
    .rd_x( bx[8:0] - 9'd24 ), .rd_pix(tm_pix)
);

// ------------------------------------------------------------ sprites
wire        s_valid, h_valid, h_full;
wire [12:0] s_pen;
wire [ 7:0] s_pri, s_z, s_idx, h_idx, h_pri, h_z;
wire [ 1:0] h_code;

gx_obj #(.HOFFSET(HOFFSET), .HADJ(10'd0)) u_obj (
    .rst, .clk, .pxl_cen, .pxl2_cen, .hdump, .vdump, .voffset(VOFFSET), .hs, .lvbl,
    .ram_cs(spr_ram_cs), .ram_we(spr_ram_we), .ram_addr(spr_ram_addr), .ram_din(spr_ram_din),
    .ram_dout(spr_ram_dout),
    .reg_cs(k46_cs), .mmr_we(k46_we), .mmr_addr(k46_addr), .mmr_din(k46_din), .mmr_dsn(k46_dsn),
    .k47_we, .k47_addr, .k47_din,
    .opri(k55[15]), .oinprion(k55[19]), .ocblk(k55[27]), .wrport2, .primode,
    .shadowon, .shdpri0(k55[37]), .shdpri1(k55[38]), .shdpri2(k55[39]), .spri_min,
    .rom_addr(obj_rom_addr), .rom_cs(obj_rom_cs), .rom_ok(obj_rom_ok), .rom_data(obj_rom_data),
    .pxl_valid(s_valid), .pxl_pen(s_pen), .pxl_pri(s_pri), .pxl_z(s_z), .pxl_idx(s_idx),
    .shd_valid(h_valid), .shd_full(h_full), .shd_code(h_code), .shd_idx(h_idx),
    .shd_pri(h_pri), .shd_z(h_z)
);

// ------------------------------------------------------------ mixer
gx_mixer u_mix (
    .rst, .clk, .pxl_cen,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din, .bg_grad,
    .pal_we, .pal_addr, .pal_din,
    .bx, .by,
    .lyr_a(tm_pix[0]), .lyr_b(tm_pix[1]), .lyr_c(tm_pix[2]), .lyr_d(tm_pix[3]),
    .spr_valid(s_valid), .spr_pen(s_pen), .spr_pri(s_pri), .spr_z(s_z), .spr_idx(s_idx),
    .shd_valid(h_valid), .shd_code(h_code), .shd_pri(h_pri), .shd_z(h_z), .shd_idx(h_idx),
    .rgb, .unsupported
);

endmodule
