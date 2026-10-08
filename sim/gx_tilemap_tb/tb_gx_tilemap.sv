// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_tilemap against a MAME capture. Driven by scripts/check_gx_tilemap.py,
// which writes debug/gx_tilemap_tb/*.hex and compares out.hex with the
// software model. Run from the repository root (scripts/run_sim.sh).
//
// Registers, tile banks and all of VRAM go in through the module's write
// ports, not by preloading its arrays, so the write paths are exercised too.
// The tile ROM answers ROM_LAT cycles after each new request.

`timescale 1ns/1ps

module tb_gx_tilemap;

localparam string DIR = "debug/gx_tilemap_tb/";
localparam int Y0 = 16, H = 224, W = 288;

reg clk = 0, rst = 1;
always #5 clk = ~clk;

reg         reg_we = 0, tbank_we = 0, vram_we = 0, vram_rd = 0;
reg  [ 4:0] reg_addr;
reg  [15:0] reg_din, vram_din;
reg  [ 2:0] tbank_addr;
reg  [ 7:0] tbank_din;
reg  [15:0] vram_addr;
wire [15:0] vram_dout;
reg  signed [7:0] offs_x [4], offs_y [4];
reg         line_start = 0;
reg  [ 9:0] line_y;
wire        busy, unsupported;
wire [23:0] rom_addr;
wire        rom_cs;
reg         rom_ok = 0;
reg  [63:0] rom_data;
wire [23:0] rom2_addr;               // the Type 3/4 build's second client
wire        rom2_cs;
reg         rom2_ok = 0;
reg  [63:0] rom2_data;
int         tile_bpp = 0;        // +BPP=0 (5 bpp), 1 (6), 2 (8)
int         vis_x0 = 24, vis_w = 288;   // +VIS_X0, +VIS_W
reg  [ 9:0] rd_x = 0;
wire [13:0] rd_pix [4];

gx_tilemap dut (
    .clk, .rst,
    .reg_we, .reg_addr, .reg_din, .reg_be(2'b11),
    .tbank_we, .tbank_addr, .tbank_din,
    .vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be(2'b11), .vram_dout,
    .offs_x, .offs_y,
    .line_start, .line_y, .busy, .unsupported, .dbg_ev(), .blank_skip(1'b1),
    .tile_bpp(2'(tile_bpp)), .rom_addr, .rom_cs, .rom_ok, .rom_data,
    .rom2_addr, .rom2_cs, .rom2_ok, .rom2_data,
    .vis_x0(10'(vis_x0)), .vis_w(10'(vis_w)),
    .rd_x, .rd_pix
);

reg [15:0] regs_v [32];
reg [ 7:0] tbank_v [8];
reg [15:0] vram_v [65536];
reg [ 7:0] offs_v [8];
reg [63:0] rom_v [0:(1 << 20) - 1];   // a row an entry: 128K tiles
int        ntiles;
int        ROM_LAT = 6;          // +ROM_LAT=n overrides

// ROM: a new address (or cs rising) restarts the latency count; each client
// on its own (the SDRAM's sharing is not modelled)
reg [23:0] last_addr, last2_addr;
int        lat, lat2;
always @(posedge clk) begin
    rom_ok <= 1'b0;
    if (!rom_cs) lat <= 0;
    else if (lat == 0 || rom_addr != last_addr) begin
        last_addr <= rom_addr;
        lat       <= 1;
    end else if (lat < ROM_LAT) lat <= lat + 1;
    else begin
        rom_ok   <= 1'b1;
        rom_data <= rom_v[((rom_addr >> 3) % ntiles) * 8 + rom_addr[2:0]];
    end
    rom2_ok <= 1'b0;
    if (!rom2_cs) lat2 <= 0;
    else if (lat2 == 0 || rom2_addr != last2_addr) begin
        last2_addr <= rom2_addr;
        lat2       <= 1;
    end else if (lat2 < ROM_LAT) lat2 <= lat2 + 1;
    else begin
        rom2_ok   <= 1'b1;
        rom2_data <= rom_v[((rom2_addr >> 3) % ntiles) * 8 + rom2_addr[2:0]];
    end
end

integer f;

int max_cycles = 0;

task automatic render(input int y);
    int c = 2;
    @(posedge clk) begin line_start <= 1; line_y <= y[9:0]; end
    @(posedge clk) line_start <= 0;
    @(posedge clk);
    while (busy) begin @(posedge clk); c++; end
    if (c > max_cycles) max_cycles = c;
endtask

initial begin
    if (!$value$plusargs("NTILES=%d", ntiles)) $fatal(1, "+NTILES= missing");
    void'($value$plusargs("ROM_LAT=%d", ROM_LAT));
    void'($value$plusargs("BPP=%d", tile_bpp));
    void'($value$plusargs("VIS_X0=%d", vis_x0));
    void'($value$plusargs("VIS_W=%d", vis_w));
    $readmemh({DIR, "regs.hex"},  regs_v);
    $readmemh({DIR, "tbank.hex"}, tbank_v);
    $readmemh({DIR, "vram.hex"},  vram_v);
    $readmemh({DIR, "offs.hex"},  offs_v);
    $readmemh({DIR, "rom.hex"},   rom_v);
    for (int l = 0; l < 4; l++) begin
        offs_x[l] = offs_v[l];
        offs_y[l] = offs_v[4 + l];
    end

    repeat (4) @(posedge clk);
    rst <= 0;
    for (int i = 0; i < 32; i++) begin
        @(posedge clk) begin reg_we <= 1; reg_addr <= i[4:0]; reg_din <= regs_v[i]; end
    end
    for (int i = 0; i < 8; i++) begin
        @(posedge clk) begin reg_we <= 0; tbank_we <= 1; tbank_addr <= i[2:0]; tbank_din <= tbank_v[i]; end
    end
    for (int i = 0; i < 65536; i++) begin
        @(posedge clk) begin tbank_we <= 0; vram_we <= 1; vram_addr <= i[15:0]; vram_din <= vram_v[i]; end
    end
    @(posedge clk) vram_we <= 0;

    // read-back spot check of the VRAM write port
    for (int i = 0; i < 65536; i += 4099) begin
        @(posedge clk) begin vram_addr <= i[15:0]; vram_rd <= 1; end
        @(posedge clk) vram_rd <= 0;
        repeat (2) @(posedge clk);
        if (vram_dout !== vram_v[i]) $fatal(1, "VRAM word %0d: read %04x, wrote %04x", i, vram_dout, vram_v[i]);
    end

    f = $fopen({DIR, "out.hex"}, "w");
    // render line n, then start line n+1 and read line n from the other half
    render(Y0);
    for (int n = 0; n < H; n++) begin
        render(Y0 + n + 1);
        for (int l = 0; l < 4; l++)
            for (int x = 0; x < vis_w; x++) begin
                @(posedge clk) rd_x <= x[9:0];
                @(posedge clk);
                @(negedge clk) $fwrite(f, "%04x\n", rd_pix[l]);
            end
    end
    $fclose(f);
    if (unsupported) $display("UNSUPPORTED mode flagged");
    $display("RENDER_CYCLES max %0d per line, ROM latency %0d", max_cycles, ROM_LAT);
    $display("GX_TILEMAP_DONE");
    $finish;
end

endmodule
