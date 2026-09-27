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
//   hdump = 0x58 + vis_x0 + p for the p-th pixel after LHBL rises, less
//           the line's total (HC) from 64 dots before its end, so the one
//           jump in hdump falls inside HS, where jtframe_objdraw_gate's
//           readout counter re-synchronises (daiskiss: 0x70 + p, and p -
//           0x110 from p = 320, on a 384-dot line; dragoonj, 512 dots from
//           bitmap column 40: 0x80 + p, which wraps in nine bits)
//   vdump = 0x110 on the first visible line, +1 a line, 0x1FF -> 0xF8;
//           it steps when HS falls, and LVBL -- which changes at the start
//           of horizontal blanking -- already says whether the next line is
//           visible
//
//   bitmap column = hdump - 0x58, bitmap row = vdump - 0x100
//
// with jt053246 at HOFFSET 62 and voffset 281, the values its bench found.
// The first visible pixel is therefore bitmap (vis_x0, 16), MAME's visarea
// origin (K053252 set_offsets: 24 for konamigx(), 24 + 16 for dragoonj()).
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
    input      [ 9:0] vis_x0,          // the visible window's first bitmap column (set_offsets)
    input      [ 8:0] vis_w,           // and its width (288, or 384 at 8 MHz dots)
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
    input      [63:0] tile_rom_data,     // the row's bytes, byte 0 in [63:56]

    // ---- sprites (sprite RAM, K053246, K055673)
    input             spr_ram_cs,
    input      [ 1:0] spr_ram_we,
    input      [13:1] spr_ram_addr,
    input      [15:0] spr_ram_din,
    output     [15:0] spr_ram_dout,
    input             k46_cs,
    input             k46_we,
    input      [ 3:0] k46_addr,
    input      [15:0] k46_din,
    input      [ 1:0] k46_dsn,
    input      [ 1:0] k47_we,          // byte lanes { 15:8, 7:0 }
    input      [ 2:0] k47_addr,
    input      [15:0] k47_din,
    input      [ 7:0] wrport2,
    input      [ 3:0] primode,
    input      [ 1:0] tile_bpp,
    input      [ 1:0] obj_layout,
    // ORIENTATION_FLIP_Y sets (le2u, le2j): they flip their own screen in Y,
    // and MAME turns the picture back. Upright is the tilemaps as if
    // unflipped and the sprite plane turned over the visible rows: the
    // scanner builds output row r from the chip's row 255 - r (vdump
    // 0x2fb - vdump, the scanner working ahead of the line; measured on le2u
    // f2400, which then differs from MAME in zoomed sprites only)
    input             obj_vmirror,
    input       [1:0] obj_pri_raw,
    input      [ 9:0] obj_hadj,    // the set's K055673 dx - (-26), signed (gx_board_cfg)
    input             obj_dma_trig, // start the sprite DMA now (gx_main)
    input             obj_dma_hold, // the ESC is writing the sprite list
    output    [111:0] dbg_mix,     // the mixer's registers, for the board's probe
    output    [135:0] dbg_shd,     // gx_obj's shadow-code-1 tile probe
    output     [22:0] obj_rom_addr,
    output            obj_rom_cs,
    input             obj_rom_ok,
    input      [63:0] obj_rom_data,
    output     [22:0] obj_pf_addr,   // the row the sprite scan will draw next
    output            obj_pf_cs,
    // what the CPU's ROM readback windows need from the two chips
    output     [22:1] rmrd_addr,    // K053246 registers 4, 6, 7
    output     [31:0] tile_gfx_bank,// K056832 registers 0x1a, 0x1b

    // ---- mixer (K055555, K054338, palette)
    input             k55_we,
    input      [ 5:0] k55_addr,
    input      [ 7:0] k55_din,
    input      [ 1:0] k338_we,         // byte lanes { 15:8, 7:0 }: the game writes bytes alone
    input      [ 3:0] k338_addr,
    input      [15:0] k338_din,
    input             bg_grad,
    input      [ 2:0] pal_we,          // { R, G, B }
    input      [12:0] pal_addr,
    input      [23:0] pal_din,

    // ---- video out: rgb and the K053252's blanking and syncs, aligned
    output     [23:0] rgb,
    output reg        vid_lhbl,
    output reg        vid_lvbl,
    output reg        vid_hs,
    output reg        vid_vs,
    output            unsupported,
    output            obj_dma_busy,
    output            obj_ln_short        // the sprite scan did not finish a line (probe)
);

// ------------------------------------------------------------ K053252
wire lhbl, lvbl, hs, vs;

jtk053252 u_crtc (
    .rst, .clk, .pxl_cen, .sel(3'd0), .vldi(1'b1), .hldi(1'b1),
    .cs(crtc_cs), .addr(crtc_addr), .rnw(1'b0), .din(crtc_din), .dout(crtc_dout),
    .lhbl, .lvbl, .hs, .vs, .int1, .int2, .hld(), .vld(), .lhbs(),
    .ioctl_addr(4'd0), .ioctl_din()
);

// the line's total, HC: K053252 registers 0 (bit 8) and 1, plus one
// (daiskiss 0x17f: 384 dots, dragoonj 0x1ff: 512). 384 until written.
reg        hc_hi = 1'b1;
reg  [7:0] hc_lo = 8'h7f;
always @(posedge clk) if( crtc_cs ) begin
    if( crtc_addr == 4'd0 ) hc_hi <= crtc_din[0];
    if( crtc_addr == 4'd1 ) hc_lo <= crtc_din;
end
wire [9:0] hc = { 1'b0, hc_hi, hc_lo } + 10'd1;

// hdump and vdump, from the K053252's blanking (see the header)
reg  [8:0] pcnt, hdump, vdump;
reg        lhbl_l, hs_l, lvbl_hsf;
wire [9:0] pc10 = { 1'b0, pcnt };
wire [8:0] p = pc10 >= hc ? 9'(pc10 - hc) : pcnt;   // pixel since LHBL rose

always @(posedge clk) if( pxl_cen ) begin
    lhbl_l <= lhbl;
    hs_l   <= hs;
    pcnt   <= ( lhbl && !lhbl_l ) ? 9'd1 : pcnt + 9'd1;
    if( !hs && hs_l ) begin
        lvbl_hsf <= lvbl;
        vdump    <= ( lvbl && !lvbl_hsf ) ? 9'h110 : vdump == 9'h1FF ? 9'h0F8 : vdump + 9'd1;
    end
end

wire [9:0] hd0 = 10'h058 + vis_x0 + { 1'b0, p };
always @* hdump = { 1'b0, p } < hc - 10'd64 ? hd0[8:0] : 9'(hd0 - hc);

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
    if( k338_we[1] ) k338[k338_addr][15:8] <= k338_din[15:8];
    if( k338_we[0] ) k338[k338_addr][ 7:0] <= k338_din[ 7:0];
end

// konamigx_mixer: shadow set i is on if a K054338 delta is outside +/-7;
// spri_min is the highest priority of a layer K55_SHD_ON leaves unshadowed
function shd_set_on( input [8:0] r, input [8:0] g, input [8:0] b );
    shd_set_on = ( $signed(r) < -7 || $signed(r) > 7 ||
                   $signed(g) < -7 || $signed(g) > 7 ||
                   $signed(b) < -7 || $signed(b) > 7 );
endfunction

wire [15:0] tm_regs5;   // gx_tilemap's register 0x0a, for the probe

// K055555 VINMIX/VMIXON/INPUT_ENABLES, K054338 alpha levels and control, and
// the K056832 line-scroll mode register: what the game asks the mixer for
// the K055555's registers are bytes: pad them, or every field shifts
assign dbg_mix = { tm_regs5, k338[15], k338[14], k338[13],
                   8'd0, k55[45], 8'd0, k55[34], 8'd0, k55[33] };

wire [2:0] shadowon = { shd_set_on(k338[8][8:0], k338[9][8:0], k338[10][8:0]),
                        shd_set_on(k338[5][8:0], k338[6][8:0], k338[7][8:0]),
                        shd_set_on(k338[2][8:0], k338[3][8:0], k338[4][8:0]) };
// layer C's priority: PRIINP_6, or under primode -1 (le2) PRIINP_3 + 0x20,
// konamigx_mixer's "Lethal Enforcer hack"
wire [7:0] pri_c = primode == 4'hf ? k55[10] + 8'h20 : k55[13];
// the shadow codes SHD PRI SEL defers (conditions 1, 2; primode -1: none),
// as gx_mixer decides them
wire [7:0] shd_sel_v = primode == 4'hf ? 8'h3f : k55[41];
wire [2:0] shd_defer = { shd_sel_v[5:4] == 2'd1 || shd_sel_v[5:4] == 2'd2,
                         shd_sel_v[3:2] == 2'd1 || shd_sel_v[3:2] == 2'd2,
                         shd_sel_v[1:0] == 2'd1 || shd_sel_v[1:0] == 2'd2 };
reg  [7:0] spri_min, spri_min_c;
always @* begin
    spri_min_c = 8'd0;
    if( !k55[40][0] && spri_min_c < k55[ 7] ) spri_min_c = k55[ 7];
    if( !k55[40][1] && spri_min_c < k55[10] ) spri_min_c = k55[10];
    if( !k55[40][2] && spri_min_c < pri_c ) spri_min_c = pri_c;
    if( !k55[40][3] && spri_min_c < k55[14] ) spri_min_c = k55[14];
end
always @(posedge clk) spri_min <= spri_min_c;   // registers the CPU writes: one clock late is nothing

// ------------------------------------------------------------ tilemap
reg        line_start;
reg  [9:0] line_y;
wire [13:0] tm_pix [4];

always @(posedge clk) begin
    line_start <= 1'b0;
    if( pxl_cen && { 1'b0, p } == hc - 10'd65 ) begin   // before hdump's jump: render the row after next
        line_start <= 1'b1;
        line_y     <= { 1'b0, vdump } - 10'h100 + 10'd2;
    end
end

gx_tilemap u_tm (
    .clk, .rst,
    .reg_we(tm_reg_we), .reg_addr(tm_reg_addr), .reg_din(tm_reg_din), .reg_be(tm_reg_be),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
    .offs_x, .offs_y, .dbg_regs5(tm_regs5), .gfx_bank(tile_gfx_bank),
    .line_start, .line_y, .busy(), .unsupported(),
    .tile_bpp, .rom_addr(tile_rom_addr), .rom_cs(tile_rom_cs), .rom_ok(tile_rom_ok), .rom_data(tile_rom_data),
    .vis_x0, .vis_w,
    .rd_x( 9'(bx - vis_x0) ), .rd_pix(tm_pix)
);

// ------------------------------------------------------------ sprites
wire        s_valid, h_valid, h_full;
wire [12:0] s_pen;
wire [ 7:0] s_pri, s_z, s_idx, h_idx, h_pri, h_z;
wire [ 1:0] h_code;

gx_obj #(.HOFFSET(HOFFSET), .HADJ(10'd0)) u_obj (
    .dbg_shd,
    .rst, .clk, .pxl_cen, .pxl2_cen, .hdump, .vdump, .voffset(VOFFSET), .hoff_adj(obj_hadj), .dma_trig(obj_dma_trig), .dma_hold(obj_dma_hold), .hs, .lvbl,
    .ram_cs(spr_ram_cs), .ram_we(spr_ram_we), .ram_addr(spr_ram_addr), .ram_din(spr_ram_din),
    .ram_dout(spr_ram_dout),
    .reg_cs(k46_cs), .mmr_we(k46_we), .mmr_addr(k46_addr), .mmr_din(k46_din), .mmr_dsn(k46_dsn),
    .k47_we, .k47_addr, .k47_din,
    .opri(k55[15]), .oinprion(k55[19]), .ocblk(k55[27]), .wrport2, .primode,
    .shadowon, .shdpri0(k55[37]), .shdpri1(k55[38]), .shdpri2(k55[39]), .spri_min, .obj_layout, .vmirror(obj_vmirror), .shd_defer, .obj_pri_raw,
    .rom_addr(obj_rom_addr), .rom_cs(obj_rom_cs), .rom_ok(obj_rom_ok), .rom_data(obj_rom_data),
    .pf_addr(obj_pf_addr), .pf_cs(obj_pf_cs), .rmrd_out(rmrd_addr),
    .pxl_valid(s_valid), .pxl_pen(s_pen), .pxl_pri(s_pri), .pxl_z(s_z), .pxl_idx(s_idx),
    .shd_valid(h_valid), .shd_full(h_full), .shd_code(h_code), .shd_idx(h_idx),
    .shd_pri(h_pri), .shd_z(h_z), .dma_busy(obj_dma_busy), .ln_short(obj_ln_short)
);

// ------------------------------------------------------------ mixer
gx_mixer u_mix (
    .rst, .clk, .pxl_cen,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din, .bg_grad,
    .pri_c_le2(primode == 4'hf),
    .pal_we, .pal_addr, .pal_din,
    .bx, .by,
    .lyr_a(tm_pix[0]), .lyr_b(tm_pix[1]), .lyr_c(tm_pix[2]), .lyr_d(tm_pix[3]),
    .spr_valid(s_valid), .spr_pen(s_pen), .spr_pri(s_pri), .spr_z(s_z), .spr_idx(s_idx),
    .shd_valid(h_valid), .shd_code(h_code), .shd_pri(h_pri), .shd_z(h_z), .shd_idx(h_idx),
    .rgb, .unsupported
);

endmodule
