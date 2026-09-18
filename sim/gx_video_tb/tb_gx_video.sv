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

localparam string TD = "debug/gx_tilemap_tb/";
localparam string OD = "debug/gx_obj_tb/";
localparam string MD = "debug/gx_mixer_tb/";

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

// ----------------------------------------------------------- clock enables
reg  [2:0] cen_cnt = 0;
reg        pxl_cen = 0, pxl2_cen = 0;
always @(posedge clk) begin
    cen_cnt  <= cen_cnt + 3'd1;
    pxl_cen  <= cen_cnt == 0;
    pxl2_cen <= cen_cnt == 0 || cen_cnt == 4;
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
reg  [39:0] tile_rom_data;

reg         spr_ram_cs = 0, k46_cs = 0, k46_we = 0, k47_we = 0;
reg  [ 1:0] spr_ram_we = 0, k46_dsn = 2'b11;
reg  [12:1] spr_ram_addr;
reg  [15:0] spr_ram_din, k46_din, k47_din;
reg  [ 3:0] k46_addr;
reg  [ 2:0] k47_addr;
reg  [ 7:0] wrport2;
reg  [ 3:0] primode;
wire [22:0] obj_rom_addr;
wire        obj_rom_cs;
reg         obj_rom_ok = 0;
reg  [39:0] obj_rom_data;

reg         k55_we = 0, k338_we = 0, pal_we = 0, bg_grad;
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
    .offs_x, .offs_y,
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .spr_ram_cs, .spr_ram_we, .spr_ram_addr, .spr_ram_din, .spr_ram_dout(),
    .k46_cs, .k46_we, .k46_addr, .k46_din, .k46_dsn,
    .k47_we, .k47_addr, .k47_din, .wrport2, .primode,
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din, .bg_grad,
    .pal_we, .pal_addr, .pal_din,
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .unsupported
);

// ----------------------------------------------------------- vectors, ROMs
reg [15:0] tregs_v [32];
reg [ 7:0] tbank_v [8];
reg [15:0] vram_v  [65536];
reg [ 7:0] offs_v  [8];
reg [39:0] trom_v  [1 << 20];     // K056832 5 bpp rows
reg [15:0] spr_v   [2048];
reg [ 7:0] k46_v   [8];
reg [15:0] k47_v   [8];
reg [ 7:0] omisc_v [16];
reg [39:0] orom_v  [1 << 20];     // K055673 half rows
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

reg [22:0] olast; int olat;
always @(posedge clk) begin
    obj_rom_ok <= 1'b0;
    if (!obj_rom_cs) olat <= 0;
    else if (olat == 0 || obj_rom_addr != olast) begin olast <= obj_rom_addr; olat <= 1; end
    else if (olat < ROM_LAT) olat <= olat + 1;
    else begin
        obj_rom_ok   <= 1'b1;
        obj_rom_data <= orom_v[(((obj_rom_addr >> 5) % ontiles) << 5) | obj_rom_addr[4:0]];
    end
end

// ----------------------------------------------------------- stimulus
integer f;
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
        @(posedge clk) begin k47_we <= 1; k47_addr <= i[2:0]; k47_din <= k47_v[i]; end
    @(posedge clk) k47_we <= 0;
    for (int i = 0; i < 2048; i++)
        @(posedge clk) begin spr_ram_cs <= 1; spr_ram_we <= 2'b11; spr_ram_addr <= i[11:0]; spr_ram_din <= spr_v[i]; end
    @(posedge clk) begin spr_ram_cs <= 0; spr_ram_we <= 0; end
    for (int i = 0; i < 64; i++)
        @(posedge clk) begin k55_we <= 1; k55_addr <= i[5:0]; k55_din <= k55_v[i]; end
    @(posedge clk) k55_we <= 0;
    for (int i = 0; i < 16; i++)
        @(posedge clk) begin k338_we <= 1; k338_addr <= i[3:0]; k338_din <= k338_v[i]; end
    @(posedge clk) k338_we <= 0;
    for (int i = 0; i < 8192; i++)
        @(posedge clk) begin pal_we <= 1; pal_addr <= i[12:0]; pal_din <= pal_v[i]; end
    @(posedge clk) pal_we <= 0;

    // frames counted at the rise of the delayed vertical blank; two for the
    // DMA to run in a vblank after loading, then one recorded
    for (int k = 0; k < 3; k++) @(posedge vid_lvbl);
    f = $fopen({MD, "video_out.hex"}, "w");
    npx = 0;
    while (npx == 0 || vid_lvbl) begin
        @(posedge clk);
        if (pxl_cen && vid_lhbl && vid_lvbl) begin
            $fwrite(f, "%06x\n", rgb);
            npx++;
        end
    end
    $fclose(f);
    if (unsupported) $display("UNSUPPORTED");
    $display("VISIBLE_PIXELS %0d", npx);
    $display("GX_VIDEO_DONE");
    $finish;
end

endmodule
