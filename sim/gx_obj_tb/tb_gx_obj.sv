// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_obj (jt053246 pipeline, GX configuration) against a MAME capture.
// Driven by scripts/check_gx_obj.py, which writes debug/gx_obj_tb/*.hex and
// compares out.hex with the software model's solid-sprite stage. Run from
// the repository root (scripts/run_sim.sh).
//
// Video timing is GX-shaped: an 8 MHz pixel enable from a 48 MHz clock,
// 512 dots x 264 lines, vdump counting 0xF8-0x1FF as jt053246_scan expects.
// Sprite RAM and registers go in through the module's own ports. The DMA
// copies the list in the vblank after loading; the frame after that is
// recorded, every dot of every line.

`timescale 1ns/1ps

module tb_gx_obj;

parameter int HOFFSET = 62;

localparam string DIR = "debug/gx_obj_tb/";

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

// ----------------------------------------------------------- video timing
reg  [2:0] cen_cnt = 0;
reg        pxl_cen = 0, pxl2_cen = 0;
reg  [8:0] hdump = 0, vdump = 9'h0F8;
// hs spans hdump's wrap: jtframe_objdraw_gate's readout counter (HFIX) only
// resynchronises to hdump during hs, so a wrap outside hs leaves it reading
// the upper half of the line buffer for the whole next line.
wire       hs   = hdump >= 9'h1F8 || hdump < 9'h008;
wire       lvbl = vdump >= 9'h110 && vdump < 9'h1F0;
int        frame = 0;

always @(posedge clk) begin
    cen_cnt  <= cen_cnt == 5 ? 3'd0 : cen_cnt + 3'd1;
    pxl_cen  <= cen_cnt == 0;
    pxl2_cen <= cen_cnt == 0 || cen_cnt == 3;
    if (pxl_cen) begin
        hdump <= hdump + 9'd1;
        if (hdump == 9'h1FF) begin
            vdump <= vdump == 9'h1FF ? 9'h0F8 : vdump + 9'd1;
            if (vdump == 9'h1FF) frame <= frame + 1;
        end
    end
end

// ----------------------------------------------------------- DUT
reg         ram_cs = 0, reg_cs = 0, mmr_we = 0, k47_we = 0;
reg  [ 1:0] ram_we = 0, mmr_dsn = 2'b11;
reg  [12:1] ram_addr;
reg  [15:0] ram_din, mmr_din, k47_din;
reg  [ 3:0] mmr_addr;
reg  [ 2:0] k47_addr;
reg  [ 7:0] opri, oinprion, ocblk, wrport2;
reg  [ 3:0] primode;
reg  [ 2:0] shadowon;
reg  [ 7:0] shdpri0, shdpri1, shdpri2, spri_min;
reg  [ 9:0] voffset = 0;
wire [22:0] rom_addr;
wire        rom_cs;
reg         rom_ok = 0;
reg  [39:0] rom_data;
wire        pxl_valid;
wire [12:0] pxl_pen;
wire [ 7:0] pxl_pri, pxl_z, pxl_idx;
wire        shd_valid, shd_full;
wire [ 1:0] shd_code;
wire [ 7:0] shd_idx, shd_pri, shd_z;

gx_obj #(.HOFFSET(10'(HOFFSET)), .HADJ(10'd0)) dut (
    .rst, .clk, .pxl_cen, .pxl2_cen, .hdump, .vdump, .voffset, .hs, .lvbl,
    .ram_cs, .ram_we, .ram_addr, .ram_din, .ram_dout(),
    .reg_cs, .mmr_we, .mmr_addr, .mmr_din, .mmr_dsn,
    .k47_we, .k47_addr, .k47_din,
    .opri, .oinprion, .ocblk, .wrport2, .primode,
    .shadowon, .shdpri0, .shdpri1, .shdpri2, .spri_min,
    .rom_addr, .rom_cs, .rom_ok, .rom_data,
    .pxl_valid, .pxl_pen, .pxl_pri, .pxl_z, .pxl_idx,
    .shd_valid, .shd_full, .shd_code, .shd_idx, .shd_pri, .shd_z
);

// ----------------------------------------------------------- ROM
reg [15:0] spr_v  [2048];
reg [ 7:0] k46_v  [8];
reg [15:0] k47_v  [8];
reg [ 7:0] misc_v [16];    // opri, oinprion, ocblk, wrport2, primode, shadowon, shdpri0-2, spri_min
reg [39:0] rom_v  [1 << 20];   // fixed size: Verilator cannot $readmemh a dynamic array
int        ntiles, ROM_LAT = 6;

reg [22:0] last_addr;
int        lat;
always @(posedge clk) begin
    rom_ok <= 1'b0;
    if (!rom_cs) lat <= 0;
    else if (lat == 0 || rom_addr != last_addr) begin
        last_addr <= rom_addr;
        lat       <= 1;
    end else if (lat < ROM_LAT) lat <= lat + 1;
    else begin
        rom_ok   <= 1'b1;
        rom_data <= rom_v[(((rom_addr >> 5) % ntiles) << 5) | rom_addr[4:0]];
    end
end

// ----------------------------------------------------------- probes
int n_dma = 0, n_draw = 0, n_rom = 0, n_hreq = 0, n_shdraw = 0;
reg dma_l = 0, cs_l = 0;
always @(posedge clk) begin
    dma_l <= dut.dma_bsy;
    cs_l  <= rom_cs;
    if (dut.dma_bsy && !dma_l) n_dma++;
    if (dut.draw) n_draw++;
    if (rom_cs && !cs_l) n_rom++;
    if (dut.u_draw.g_keybuf.u_linebuf.h_req) n_hreq++;
    if (dut.draw && dut.shmode != 0) n_shdraw++;
end

// ----------------------------------------------------------- stimulus
integer f;
int     cap_frame;

initial begin
    if (!$value$plusargs("NTILES=%d", ntiles)) $fatal(1, "+NTILES= missing");
    void'($value$plusargs("ROM_LAT=%d", ROM_LAT));
    void'($value$plusargs("VOFFSET=%d", voffset));
    if (ntiles * 32 > (1 << 20)) $fatal(1, "sprite ROM larger than rom_v");
    $readmemh({DIR, "spr.hex"},  spr_v);
    $readmemh({DIR, "k46.hex"},  k46_v);
    $readmemh({DIR, "k47.hex"},  k47_v);
    $readmemh({DIR, "misc.hex"}, misc_v);
    $readmemh({DIR, "rom.hex"},  rom_v);
    { opri, oinprion, ocblk, wrport2 } = { misc_v[0], misc_v[1], misc_v[2], misc_v[3] };
    primode = misc_v[4][3:0];
    shadowon = misc_v[5][2:0];
    { shdpri0, shdpri1, shdpri2, spri_min } = { misc_v[6], misc_v[7], misc_v[8], misc_v[9] };

    repeat (8) @(posedge clk);
    rst <= 0;
    // K053246, 16-bit accesses (OBJSET1 bit 2 clear): word i = { reg 2i, reg 2i+1 }
    for (int i = 0; i < 4; i++) begin
        @(posedge clk) begin
            reg_cs <= 1; mmr_we <= 1; mmr_dsn <= 2'b00;
            mmr_addr <= { 1'b0, i[1:0], 1'b0 }; mmr_din <= { k46_v[2*i], k46_v[2*i+1] };
        end
    end
    @(posedge clk) begin reg_cs <= 0; mmr_we <= 0; mmr_dsn <= 2'b11; end
    for (int i = 0; i < 8; i++) begin
        @(posedge clk) begin k47_we <= 1; k47_addr <= i[2:0]; k47_din <= k47_v[i]; end
    end
    @(posedge clk) k47_we <= 0;
    for (int i = 0; i < 2048; i++) begin
        @(posedge clk) begin ram_cs <= 1; ram_we <= 2'b11; ram_addr <= i[11:0]; ram_din <= spr_v[i]; end
    end
    @(posedge clk) begin ram_cs <= 0; ram_we <= 0; end

    // one frame for the DMA to run in its vblank, then record the next one
    cap_frame = frame + 2;
    wait (frame == cap_frame);
    f = $fopen({DIR, "out.hex"}, "w");
    while (frame == cap_frame) begin
        @(posedge clk);
        if (pxl_cen) $fwrite(f, "%03x %03x %01x%02x%02x%04x %02x %01x%01x%01x%02x%02x%02x\n",
                             vdump, hdump, pxl_valid, pxl_z, pxl_pri, pxl_pen, pxl_idx,
                             shd_valid, shd_full, shd_code, shd_idx, shd_pri, shd_z);
    end
    $fclose(f);
    $display("PROBES dma %0d, draw cycles %0d, rom requests %0d, shadow draws %0d, shadow writes %0d", n_dma, n_draw, n_rom, n_shdraw, n_hreq);
    $display("GX_OBJ_DONE");
    $finish;
end

endmodule
