// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone synthesis of rtl/video/gx_tilemap.sv on the DE10-nano's Cyclone V
// (5CSEBA6U23I7). Not part of the core. It answers: do the VRAM and the line
// buffers become block RAM, how much, and does the module close at 48 MHz.
//
// Every input comes from a register loaded by a serial shift chain and every
// output is XOR-reduced into a register, so paths start and end on flops, the
// pin count stays small and nothing is optimised away. Pins are VIRTUAL (see
// the .qsf).
module gx_tilemap_synth_top (
    input  logic       clk,
    input  logic       rst,
    input  logic       sdi,
    input  logic       ld,
    output logic [7:0] sig
);
    localparam int N = 1 + 5 + 16 + 2 + 1 + 3 + 8 + 1 + 1 + 16 + 16 + 2 + 64 + 1 + 10 + 1 + 40 + 9;
    logic [N-1:0] sh, r;

    always_ff @(posedge clk) begin
        sh <= { sh[N-2:0], sdi };
        if (ld) r <= sh;
    end

    logic        reg_we, tbank_we, vram_we, vram_rd, line_start, rom_ok;
    logic [ 4:0] reg_addr;
    logic [15:0] reg_din, vram_addr, vram_din;
    logic [ 1:0] reg_be, vram_be;
    logic [ 2:0] tbank_addr;
    logic [ 7:0] tbank_din;
    logic [63:0] offs;
    logic [ 9:0] line_y;
    logic [39:0] rom_data;
    logic [ 8:0] rd_x;

    assign { reg_we, reg_addr, reg_din, reg_be, tbank_we, tbank_addr, tbank_din,
             vram_we, vram_rd, vram_addr, vram_din, vram_be, offs, line_start, line_y,
             rom_ok, rom_data, rd_x } = r;

    logic signed [7:0] offs_x [4], offs_y [4];
    always_comb for (int l = 0; l < 4; l++) begin
        offs_x[l] = offs[l*8 +: 8];
        offs_y[l] = offs[32 + l*8 +: 8];
    end

    logic [15:0] vram_dout;
    logic        busy, unsupported, rom_cs;
    logic [23:0] rom_addr;
    logic [10:0] rd_pix [4];

    gx_tilemap u_tm (
        .clk, .rst,
        .reg_we, .reg_addr, .reg_din, .reg_be,
        .tbank_we, .tbank_addr, .tbank_din,
        .vram_we, .vram_rd, .vram_addr, .vram_din, .vram_be, .vram_dout,
        .offs_x, .offs_y,
        .line_start, .line_y, .busy, .unsupported,
        .rom_addr, .rom_cs, .rom_ok, .rom_data,
        .rd_x, .rd_pix
    );

    always_ff @(posedge clk)
        sig <= { ^vram_dout, busy, unsupported, rom_cs, ^rom_addr,
                 ^rd_pix[0], ^rd_pix[1], ^{rd_pix[2], rd_pix[3]} };
endmodule
