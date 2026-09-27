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
// +OBJ_HADJ=n: the set's K055673 dx less daiskiss's -26 (gx_board_cfg obj_hadj)
int obj_hadj = 0;
initial void'($value$plusargs("OBJ_HADJ=%d", obj_hadj));

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
reg         ram_cs = 0, reg_cs = 0, mmr_we = 0;
reg  [ 1:0] k47_we = 0;
reg  [ 1:0] ram_we = 0, mmr_dsn = 2'b11;
reg  [13:1] ram_addr;
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
wire        rom_ok;
wire [63:0] rom_data;
int         obj_layout = 0;      // +LAYOUT=0 GX, 1 RNG, 2 GX6, 3 LE2
int         obj_pri_raw = 0;     // +PRI_RAW=1: dragoonj's priority callback, 2 salmndr2's
wire        pxl_valid;
wire [12:0] pxl_pen;
wire [ 7:0] pxl_pri, pxl_z, pxl_idx;
wire        shd_valid, shd_full;
wire [ 1:0] shd_code;
wire [ 7:0] shd_idx, shd_pri, shd_z;

gx_obj #(.HOFFSET(10'(HOFFSET)), .HADJ(10'd0)) dut (
    .rst, .clk, .pxl_cen, .pxl2_cen, .hdump, .vdump, .voffset, .hoff_adj(10'(obj_hadj)), .dma_trig(1'b0), .dma_hold(1'b0), .hs, .lvbl,
    .ram_cs, .ram_we, .ram_addr, .ram_din, .ram_dout(),
    .reg_cs, .mmr_we, .mmr_addr, .mmr_din, .mmr_dsn,
    .k47_we, .k47_addr, .k47_din,
    .opri, .oinprion, .ocblk, .wrport2, .primode,
    .shadowon, .shdpri0, .shdpri1, .shdpri2, .spri_min, .obj_layout(2'(obj_layout)), .vmirror(1'b0), .shd_defer(3'd0), .obj_pri_raw(2'(obj_pri_raw)),
    .rom_addr, .rom_cs, .rom_ok, .rom_data,
    .pxl_valid, .pxl_pen, .pxl_pri, .pxl_z, .pxl_idx,
    .shd_valid, .shd_full, .shd_code, .shd_idx, .shd_pri, .shd_z, .dma_busy()
);

// ----------------------------------------------------------- ROM
reg [15:0] spr_v  [2048];
reg [ 7:0] k46_v  [8];
reg [15:0] k47_v  [8];
reg [ 7:0] misc_v [16];    // opri, oinprion, ocblk, wrport2, primode, shadowon, shdpri0-2, spri_min
reg [63:0] rom_v  [1 << 22];   // fixed size (tokkae: 2M half-rows): Verilator cannot $readmemh a dynamic array
int        ntiles, ROM_LAT = 6;

// +PORT=0 (default): the ideal model -- every fetch answered ROM_LAT clocks
// after the address, nothing held between fetches.
//
// +PORT=1: rtl/memory/gx_rom_port.sv, the board's own, against a memory that
// answers c_req ROM_LAT_M clk_mem cycles later. That is the path whose
// latency the sprite scan runs out of line time on, and the one the scan's
// prefetch hint (+HINT=1, the default with PORT) is there to hide. The
// board's measured numbers are in gx_sdram_tb: ROM_LAT_M 18 gives the 11
// clocks a first fetch costs there.
int  use_port = 0, use_hint = 1, ROM_LAT_M = 18;
initial begin
    void'($value$plusargs("PORT=%d", use_port));
    void'($value$plusargs("HINT=%d", use_hint));
    void'($value$plusargs("ROM_LAT_M=%d", ROM_LAT_M));
end

reg [22:0] last_addr;
int        lat;
reg         id_ok = 0;
reg  [63:0] id_data;
always @(posedge clk) if (!use_port) begin
    id_ok <= 1'b0;
    if (!rom_cs) lat <= 0;
    else if (lat == 0 || rom_addr != last_addr) begin
        last_addr <= rom_addr;
        lat       <= 1;
    end else if (lat < ROM_LAT) lat <= lat + 1;
    else begin
        id_ok   <= 1'b1;
        id_data <= rom_v[(((rom_addr >> 5) % ntiles) << 5) | rom_addr[4:0]];
    end
end

reg clk_mem = 0;
always #5.2085 clk_mem = ~clk_mem;

wire        p_req;
wire [25:0] p_addr;
reg         p_valid = 0;
reg  [63:0] p_rdata;
wire        p_ok;
wire [63:0] p_g;
int         m_cnt = 0;
reg         p_req_l = 0;

// the memory behind the arbiter
always @(posedge clk_mem) begin
    p_valid <= 0;
    p_req_l <= p_req;
    if (!p_req) m_cnt <= 0;
    else if (m_cnt < ROM_LAT_M) m_cnt <= m_cnt + 1;
    else if (!p_valid) begin
        int g, h; reg [63:0] row, r1;
        g   = p_addr >> 3;
        if (obj_layout == 1) begin
            // RNG, as the board's port asks for it (halfsel): the granule is
            // a whole row, the half-row the drawer asks for 2g in its low
            // four bytes and 2g + 1 in its high four
            h   = 2 * g;
            row = rom_v[((h >> 5) % ntiles) << 5 | h[4:0]];
            h   = h + 1;
            r1  = rom_v[((h >> 5) % ntiles) << 5 | h[4:0]];
            for (int k = 0; k < 4; k++) begin
                p_rdata[8*k +: 8]      <= row[63 - 8*k -: 8];
                p_rdata[32 + 8*k +: 8] <= r1[63 - 8*k -: 8];
            end
        end else begin
            row = rom_v[((g >> 5) % ntiles) << 5 | g[4:0]];
            for (int k = 0; k < 8; k++) p_rdata[8*k +: 8] <= row[63 - 8*k -: 8];   // granule byte k = row byte k
        end
        p_valid <= 1;
        m_cnt   <= 0;
    end
end

gx_rom_port #(.AW(22), .PAIR(1)) u_port (
    .clk(clk), .clk_mem(clk_mem), .rst(rst),
    .cs(rom_cs && use_port != 0), .addr(rom_addr[21:0]), .ok(p_ok), .data(p_g),
    .hint_cs(dut.pf_cs && use_port != 0 && use_hint != 0), .hint_addr(dut.pf_addr[21:0]),
    .inval(1'b0), .halfsel(obj_layout == 1),         // as gx_sdram_top: RNG
    .base(26'd0),
    .c_req(p_req), .c_addr(p_addr), .c_valid(p_valid), .c_rdata(p_rdata)
);

assign rom_ok   = use_port ? p_ok : id_ok;
assign rom_data = use_port ? { p_g[7:0], p_g[15:8], p_g[23:16], p_g[31:24], p_g[39:32], p_g[47:40], p_g[55:48], p_g[63:56] }
                           : id_data;

// ----------------------------------------------------------- probes
// +ROM_DUMP=n: print the first n sprite ROM answers (address, data)
int rom_dump = 0;
always @(posedge clk) if (rom_ok && rom_dump > 0) begin
    $display("DUMP rom  %06x -> %016x", last_addr, rom_data);
    rom_dump--;
end
// +SCAN_TRACE=i+1: each tile the scan starts for table entry i -- line, code,
// row within the tile, flips, x
int scan_trace = 0;
initial void'($value$plusargs("SCAN_TRACE=%d", scan_trace));
always @(posedge clk) if (scan_trace != 0 && dut.u_scan.u_scan.dr_start && dut.u_scan.u_scan.cen2
                          && dut.u_scan.u_scan.obj_idx == 8'(scan_trace - 1))
    $display("SCAN v %03x code %04x ysub %x vflip %b hflip %b hpos %03x hstep %0d ydiff %03x ydiff_b %03x yz %05x vzoom %03x",
             dut.u_scan.u_scan.vlatch, dut.u_scan.u_scan.code, dut.u_scan.u_scan.ysub,
             dut.u_scan.u_scan.vflip, dut.u_scan.u_scan.hflip, dut.u_scan.u_scan.hpos,
             dut.u_scan.u_scan.hstep, dut.u_scan.u_scan.ydiff, dut.u_scan.u_scan.ydiff_b,
             dut.u_scan.u_scan.yz_add, dut.u_scan.u_scan.vzoom);
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
// +LINE_STATS=1: per line, clocks the scan spent reading entries, waiting on
// the drawer, the drawer's pixel writes and its ROM waits; the worst line
int line_stats = 0;
initial void'($value$plusargs("LINE_STATS=%d", line_stats));
int ls_scan = 0, ls_wait = 0, ls_pix = 0, ls_rom = 0, ls_tiles = 0, ls_line = 0, ls_skip = 0, ls_rd = 0, ls_mv = 0;
int ls_worst = 0;
reg ls_hs = 0;
always @(posedge clk) if (line_stats != 0) begin
    ls_hs <= hs;
    if (hs && !ls_hs) begin
        if (ls_scan + ls_wait > ls_worst || ls_tiles > 100) begin
            if (ls_scan + ls_wait > ls_worst) ls_worst = ls_scan + ls_wait;
            $display("LINE %03x tiles %0d scan %0d wait %0d pix %0d romwait %0d done %0d idle_q %0d busy %0d starved %0d",
                     vdump, ls_tiles, ls_scan, ls_wait, ls_pix, ls_rom, dut.u_scan.u_scan.done, ls_skip, ls_rd, ls_mv);
        end
        ls_scan = 0; ls_wait = 0; ls_pix = 0; ls_rom = 0; ls_tiles = 0; ls_skip = 0; ls_rd = 0; ls_mv = 0;
    end else begin
        if (!dut.u_scan.u_scan.done) begin
            if ({dut.u_scan.u_scan.indr, dut.u_scan.u_scan.scan_sub} >= 5) ls_wait++;
            else ls_scan++;
        end
        if (dut.u_draw.u_draw.buf_we) ls_pix++;
        if (dut.u_draw.u_draw.busy && dut.u_draw.u_draw.cnt[3]) ls_rom++;
        if (dut.q_push) ls_tiles++;
        // idle_q: the drawer free with tiles queued; busy: the drawer's
        // clocks; starved: nothing queued while the scan is still walking
        if (!dut.q_empty && !dut.dr_busy) ls_skip++;
        if (dut.dr_busy) ls_rd++;
        if (dut.q_empty && !dut.dr_busy && !dut.u_scan.u_scan.done) ls_mv++;
    end
end

// ----------------------------------------------------------- stimulus
integer f;
int     cap_frame;

initial begin
    if (!$value$plusargs("NTILES=%d", ntiles)) $fatal(1, "+NTILES= missing");
    void'($value$plusargs("ROM_LAT=%d", ROM_LAT));
    void'($value$plusargs("LAYOUT=%d", obj_layout));
    void'($value$plusargs("PRI_RAW=%d", obj_pri_raw));
    void'($value$plusargs("ROM_DUMP=%d", rom_dump));
    void'($value$plusargs("VOFFSET=%d", voffset));
    if (ntiles * 32 > (1 << 22)) $fatal(1, "sprite ROM larger than rom_v");
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
        @(posedge clk) begin k47_we <= 2'b11; k47_addr <= i[2:0]; k47_din <= k47_v[i]; end
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
