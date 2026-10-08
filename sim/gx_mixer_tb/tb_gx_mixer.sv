// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_mixer against MAME. Driven by scripts/check_gx_mixer.py, which writes
// debug/gx_mixer_tb/*.hex -- the K055555/K054338 registers, the palette, and
// per pixel the inputs the tilemap and sprite RTL deliver (both proven
// equal to the software model on these captures) -- and compares out.hex
// with MAME's screenshot. Run from the repository root.
//
// One pixel per pxl_cen, DIV clocks apart: 6 as at 48 MHz / 8 MHz, 4 at 12 MHz.

`timescale 1ns/1ps

module tb_gx_mixer;

localparam string DIR = "debug/gx_mixer_tb/";
localparam int W = 288, H = 224, X0 = 24, Y0 = 16;

parameter int DIV = 6;
reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

reg  [2:0] cnt = 0;
reg        pxl_cen = 0;
always @(posedge clk) begin
    cnt     <= cnt == 3'(DIV - 1) ? 3'd0 : cnt + 3'd1;
    pxl_cen <= cnt == 0 && !rst;
end

reg         k55_we = 0, bg_grad;
reg  [ 1:0] k338_we = 0;
reg  [ 2:0] pal_we = 0;
reg  [ 5:0] k55_addr;
reg  [ 7:0] k55_din;
reg  [ 3:0] k338_addr;
reg  [15:0] k338_din;
reg  [12:0] pal_addr;
reg  [23:0] pal_din;
reg  [ 9:0] bx, by;
reg  [10:0] lyr_a, lyr_b, lyr_c, lyr_d;
reg         spr_valid, shd_valid;
reg  [12:0] spr_pen;
reg  [ 7:0] spr_pri, spr_z, spr_idx, shd_pri, shd_z, shd_idx;
reg  [ 1:0] shd_code;
wire [23:0] rgb;
wire        unsupported;

gx_mixer dut (
    .rst, .clk, .pxl_cen,
    .k55_we, .k55_addr, .k55_din, .k338_we, .k338_addr, .k338_din, .bg_grad,
    .pal_we, .pal_addr, .pal_din,
    .bx, .by, .lyr_a, .lyr_b, .lyr_c, .lyr_d,
    .spr_valid, .spr_pen, .spr_pri, .spr_z, .spr_idx,
    .shd_valid, .shd_code, .shd_pri, .shd_z, .shd_idx,
    .rgb, .unsupported
);

reg [ 7:0] k55_v  [64];
reg [15:0] k338_v [16];
reg [23:0] pal_v  [8192];
reg [ 7:0] misc_v [4];
// per pixel: { lyr_a, lyr_b, lyr_c, lyr_d } then the sprite and shadow words
reg [43:0] lyr_v  [W*H];
reg [45:0] spr_v  [W*H];      // { valid, pen13, pri8, z8, idx8, 8'd0 }
reg [34:0] shd_v  [W*H];      // { valid, code2, pri8, z8, idx8, 8'd0 }

integer f;

initial begin
    $readmemh({DIR, "k55.hex"},  k55_v);
    $readmemh({DIR, "k338.hex"}, k338_v);
    $readmemh({DIR, "pal.hex"},  pal_v);
    $readmemh({DIR, "misc.hex"}, misc_v);
    $readmemh({DIR, "lyr.hex"},  lyr_v);
    $readmemh({DIR, "spr.hex"},  spr_v);
    $readmemh({DIR, "shd.hex"},  shd_v);
    bg_grad = misc_v[0][0];

    repeat (4) @(posedge clk);
    for (int i = 0; i < 64; i++)
        @(posedge clk) begin k55_we <= 1; k55_addr <= i[5:0]; k55_din <= k55_v[i]; end
    @(posedge clk) k55_we <= 0;
    for (int i = 0; i < 16; i++)
        @(posedge clk) begin k338_we <= 2'b11; k338_addr <= i[3:0]; k338_din <= k338_v[i]; end
    @(posedge clk) k338_we <= 0;
    for (int i = 0; i < 8192; i++)
        @(posedge clk) begin pal_we <= 3'b111; pal_addr <= i[12:0]; pal_din <= pal_v[i]; end
    @(posedge clk) begin pal_we <= 0; rst <= 0; end

    f = $fopen({DIR, "out.hex"}, "w");
    // Drive on the falling edge of the cycle in which pxl_cen is high: the
    // mixer samples on the next rising edge, and outputs that pixel's colour
    // on the pxl_cen after. So at the n-th such falling edge, rgb holds
    // pixel n-2.
    for (int n = 0; n < W*H + 2; n++) begin
        @(negedge clk);
        while (!pxl_cen) @(negedge clk);
        if (n >= 2) $fwrite(f, "%06x\n", rgb);
        if (n < W*H) begin
            bx = 10'(X0 + n % W);
            by = 10'(Y0 + n / W);
            { lyr_a, lyr_b, lyr_c, lyr_d } = lyr_v[n];
            { spr_valid, spr_pen, spr_pri, spr_z, spr_idx } = spr_v[n][45:8];
            { shd_valid, shd_code, shd_pri, shd_z, shd_idx } = shd_v[n][34:8];
        end
    end
    $fclose(f);
    if (unsupported) $display("UNSUPPORTED");
    $display("GX_MIXER_DONE");
    $finish;
end

endmodule
