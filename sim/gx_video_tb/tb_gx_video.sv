// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_video -- the K053252, tilemap, sprites and mixer -- against MAME's
// screenshot. Driven by scripts/check_gx_video.py, which writes the three
// block benches' vector files (debug/gx_tilemap_tb, gx_obj_tb, gx_mixer_tb)
// plus the K053252 registers, and compares the recorded frame with
// reference.png. Run from the repository root.
//
// Everything goes in through gx_video's ports: the K053252's registers (so
// the timing is the one the game programs), the other registers, VRAM,
// sprite RAM, palette. Two ROM models answer the tile and sprite fetches.
// 48 MHz clock, 6 MHz dot clock (wrport2 & 3 == 0). The sprite DMA runs in
// the vblank after loading; the frame after that is recorded -- every pixel
// gx_video's own blanking marks visible, in order.

`timescale 1ns/1ps

module tb_gx_video;
// +SPR_MIX=0: gx_mixer's spr_mix_on off -- no sprite blended, as MAME draws
int spr_mix_sel = 1;
initial void'($value$plusargs("SPR_MIX=%d", spr_mix_sel));
// +OBJ_HADJ=n: the set's K055673 dx less daiskiss's -26 (gx_board_cfg obj_hadj)
int obj_hadj = 0, tile_bpp = 0, obj_layout = 0, obj_pri_raw = 0, vis_x0 = 24, vis_w = 288, vmirror = 0;
initial void'($value$plusargs("VMIRROR=%d", vmirror));
initial void'($value$plusargs("OBJ_HADJ=%d", obj_hadj));
initial void'($value$plusargs("BPP=%d", tile_bpp));
initial void'($value$plusargs("LAYOUT=%d", obj_layout));
initial void'($value$plusargs("PRI_RAW=%d", obj_pri_raw));
initial void'($value$plusargs("VIS_X0=%d", vis_x0));
initial void'($value$plusargs("VIS_W=%d", vis_w));

localparam string TD = "debug/gx_tilemap_tb/";
localparam string OD = "debug/gx_obj_tb/";
localparam string MD = "debug/gx_mixer_tb/";

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

// ----------------------------------------------------------- clock enables
// the dot clock wrport2 & 3 selects (gx_main's divider): 6 MHz a pixel
// every eight clocks, 8 MHz (dragoonj, winspike) every six
reg  [2:0] cen_cnt = 0;
reg        pxl_cen = 0, pxl2_cen = 0;
wire [2:0] cen_last = wrport2[1:0] == 2'd1 ? 3'd5 : 3'd7;
always @(posedge clk) begin
    cen_cnt  <= cen_cnt == cen_last ? 3'd0 : cen_cnt + 3'd1;
    pxl_cen  <= cen_cnt == 0;
    pxl2_cen <= cen_cnt == 0 || cen_cnt == { 1'b0, cen_last[2:1] } + 3'd1;
end

// ----------------------------------------------------------- DUT
reg         crtc_cs = 0;
reg  [ 3:0] crtc_addr;
reg  [ 7:0] crtc_din;
wire        vid_lhbl, vid_lvbl, vid_hs, vid_vs;
reg         tm_reg_we = 0, tbank_we = 0, vram_we = 0;
reg  [ 4:0] tm_reg_addr;
reg  [15:0] tm_reg_din, vram_din;
reg  [ 2:0] tbank_addr;
reg  [ 7:0] tbank_din;
reg  [15:0] vram_addr;
reg  signed [7:0] offs_x [4], offs_y [4];
wire [23:0] tile_rom_addr;
wire        tile_rom_cs;
reg         tile_rom_ok = 0;
reg  [63:0] tile_rom_data;

reg         spr_ram_cs = 0, k46_cs = 0, k46_we = 0;
reg  [ 1:0] k47_we = 0;
reg  [ 1:0] spr_ram_we = 0, k46_dsn = 2'b11;
reg  [13:1] spr_ram_addr;
reg  [15:0] spr_ram_din, k46_din, k47_din;
reg  [ 3:0] k46_addr;
reg  [ 2:0] k47_addr;
reg  [ 7:0] wrport2;
reg  [ 3:0] primode;
wire [22:0] obj_rom_addr;
wire        obj_rom_cs;
reg         obj_rom_ok = 0;
reg  [63:0] obj_rom_data;

reg         k55_we = 0, bg_grad;
reg  [ 1:0] k338_we = 0;
reg  [ 2:0] pal_we = 0;
reg  [ 5:0] k55_addr;
reg  [ 7:0] k55_din;
reg  [ 3:0] k338_addr;
reg  [15:0] k338_din;
reg  [12:0] pal_addr;
reg  [23:0] pal_din;
wire [23:0] rgb;
wire        unsupported;

gx_video dut (
    .rst, .clk, .pxl_cen, .pxl2_cen,
    .crtc_cs, .crtc_addr, .crtc_din, .crtc_dout(), .int1(), .int2(),
    .tm_reg_we, .tm_reg_addr, .tm_reg_din, .tm_reg_be(2'b11),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd(1'b0), .vram_addr, .vram_din, .vram_be(2'b11), .vram_dout(),
    .offs_x, .offs_y, .vis_x0(10'(vis_x0)), .vis_w(10'(vis_w)),
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .spr_ram_cs, .spr_ram_we, .spr_ram_addr, .spr_ram_din, .spr_ram_dout(),
    .k46_cs, .k46_we, .k46_addr, .k46_din, .k46_dsn,
    .k47_we, .k47_addr, .k47_din, .wrport2, .primode, .tile_bpp(2'(tile_bpp)), .obj_layout(2'(obj_layout)), .obj_pri_raw(2'(obj_pri_raw)), .obj_vmirror(vmirror != 0), .obj_hadj(10'(obj_hadj)), .obj_dma_trig(1'b0), .obj_dma_hold(1'b0),
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr(), .obj_pf_cs(),
    .rmrd_addr(), .tile_gfx_bank(),
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din, .bg_grad,
    .pal_we, .pal_addr, .pal_din,
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .unsupported, .obj_dma_busy(), .tm_blank_skip(1'b1), .spr_mix_on(spr_mix_sel != 0), .dbg_line()
);

// ----------------------------------------------------------- vectors, ROMs
reg [15:0] tregs_v [32];
reg [ 7:0] tbank_v [8];
reg [15:0] vram_v  [65536];
reg [ 7:0] offs_v  [8];
reg [63:0] trom_v  [1 << 21];     // K056832 rows of 5, 6 or 8 bytes, byte 0 in [63:56]
reg [15:0] spr_v   [2048];
reg [ 7:0] k46_v   [8];
reg [15:0] k47_v   [8];
reg [ 7:0] omisc_v [16];
reg [63:0] orom_v  [1 << 22];     // K055673 half rows, byte 0 in [63:56]
reg [ 7:0] k55_v   [64];
reg [15:0] k338_v  [16];
reg [23:0] pal_v   [8192];
reg [ 7:0] mmisc_v [4];
reg [ 7:0] crtc_v  [16];
int        tntiles, ontiles, ROM_LAT = 6;

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

// ----------------------------------------------------------- stimulus
integer f, fl;
int     npx;

initial begin
    if (!$value$plusargs("TNTILES=%d", tntiles)) $fatal(1, "+TNTILES= missing");
    if (!$value$plusargs("ONTILES=%d", ontiles)) $fatal(1, "+ONTILES= missing");
    $readmemh({TD, "regs.hex"},  tregs_v);
    $readmemh({TD, "tbank.hex"}, tbank_v);
    $readmemh({TD, "vram.hex"},  vram_v);
    $readmemh({TD, "offs.hex"},  offs_v);
    $readmemh({TD, "rom.hex"},   trom_v);
    $readmemh({OD, "spr.hex"},   spr_v);
    $readmemh({OD, "k46.hex"},   k46_v);
    $readmemh({OD, "k47.hex"},   k47_v);
    $readmemh({OD, "misc.hex"},  omisc_v);
    $readmemh({OD, "rom.hex"},   orom_v);
    $readmemh({MD, "k55.hex"},   k55_v);
    $readmemh({MD, "k338.hex"},  k338_v);
    $readmemh({MD, "pal.hex"},   pal_v);
    $readmemh({MD, "misc.hex"},  mmisc_v);
    $readmemh({MD, "crtc.hex"},  crtc_v);
    for (int l = 0; l < 4; l++) begin offs_x[l] = offs_v[l]; offs_y[l] = offs_v[4 + l]; end
    wrport2 = omisc_v[3];
    primode = omisc_v[4][3:0];
    bg_grad = mmisc_v[0][0];

    repeat (8) @(posedge clk);
    rst <= 0;
    for (int i = 0; i < 16; i++) begin
        @(posedge clk) begin crtc_cs <= 1; crtc_addr <= i[3:0]; crtc_din <= crtc_v[i]; end
        @(posedge clk) crtc_cs <= 0;
    end
    for (int i = 0; i < 32; i++)
        @(posedge clk) begin tm_reg_we <= 1; tm_reg_addr <= i[4:0]; tm_reg_din <= tregs_v[i]; end
    @(posedge clk) tm_reg_we <= 0;
    for (int i = 0; i < 8; i++)
        @(posedge clk) begin tbank_we <= 1; tbank_addr <= i[2:0]; tbank_din <= tbank_v[i]; end
    @(posedge clk) tbank_we <= 0;
    for (int i = 0; i < 65536; i++)
        @(posedge clk) begin vram_we <= 1; vram_addr <= i[15:0]; vram_din <= vram_v[i]; end
    @(posedge clk) vram_we <= 0;
    for (int i = 0; i < 4; i++)
        @(posedge clk) begin
            k46_cs <= 1; k46_we <= 1; k46_dsn <= 2'b00;
            k46_addr <= { 1'b0, i[1:0], 1'b0 }; k46_din <= { k46_v[2*i], k46_v[2*i+1] };
        end
    @(posedge clk) begin k46_cs <= 0; k46_we <= 0; k46_dsn <= 2'b11; end
    for (int i = 0; i < 8; i++)
        @(posedge clk) begin k47_we <= 2'b11; k47_addr <= i[2:0]; k47_din <= k47_v[i]; end
    @(posedge clk) k47_we <= 0;
    for (int i = 0; i < 2048; i++)
        @(posedge clk) begin spr_ram_cs <= 1; spr_ram_we <= 2'b11; spr_ram_addr <= i[11:0]; spr_ram_din <= spr_v[i]; end
    @(posedge clk) begin spr_ram_cs <= 0; spr_ram_we <= 0; end
    // the K054338 before the K055555: the mixer's unsupported flag is sticky,
    // and VBRI read against brightness levels not yet loaded (zero) is flagged
    for (int i = 0; i < 16; i++)
        @(posedge clk) begin k338_we <= 2'b11; k338_addr <= i[3:0]; k338_din <= k338_v[i]; end
    @(posedge clk) k338_we <= 0;
    for (int i = 0; i < 64; i++)
        @(posedge clk) begin k55_we <= 1; k55_addr <= i[5:0]; k55_din <= k55_v[i]; end
    @(posedge clk) k55_we <= 0;
    for (int i = 0; i < 8192; i++)
        @(posedge clk) begin pal_we <= 3'b111; pal_addr <= i[12:0]; pal_din <= pal_v[i]; end
    @(posedge clk) pal_we <= 0;

    // frames counted at the rise of the delayed vertical blank; two for the
    // DMA to run in a vblank after loading, then one recorded
    for (int k = 0; k < 3; k++) @(posedge vid_lvbl);
    f = $fopen({MD, "video_out.hex"}, "w");
    // layers.hex: what each tilemap layer gives the mixer, every pixel the
    // mixer is handed in the frame: "bx by A B C D" ({ colour, pixel } each)
    fl = $fopen({MD, "layers.hex"}, "w");
    npx = 0;
    while (npx == 0 || vid_lvbl) begin
        @(posedge clk);
        if (pxl_cen && vid_lhbl && vid_lvbl) begin
            $fwrite(f, "%06x\n", rgb);
            npx++;
        end
        if (dut.u_mix.pxl_cen)
            $fwrite(fl, "%0d %0d %04x %04x %04x %04x\n", dut.u_mix.bx, dut.u_mix.by,
                    dut.u_mix.lyr_a, dut.u_mix.lyr_b, dut.u_mix.lyr_c, dut.u_mix.lyr_d);
    end
    $fclose(f);
    $fclose(fl);
    if (unsupported) $display("UNSUPPORTED");
    $display("VISIBLE_PIXELS %0d", npx);
    $display("GX_VIDEO_DONE");
    $finish;
end

endmodule
