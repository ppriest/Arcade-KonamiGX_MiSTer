// SPDX-License-Identifier: GPL-3.0-or-later
//
// Self-checking test of rtl/video/gx_crt_chain.sv on the K053252's raster,
// sampled the way arcade_video samples it. Arcade-Psikyo_MiSTer's
// sim/crt_chain_tb with its scenarios, the expectations worked out from the
// raster instead of written in:
//     scripts/run_verilator.sh gx_crt_chain_tb +REGS=sim/gx_crt_chain_tb/daiskiss.hex +PDIV=8
//     scripts/run_verilator.sh gx_crt_chain_tb +REGS=sim/gx_crt_chain_tb/dragoonj.hex +PDIV=6
// REGS: the 16 K053252 registers a game writes (byte 2n of a capture's
// reg_k053252.bin); PDIV: 48 MHz clocks a pixel (8 = 6 MHz, 6 = 8 MHz).

`timescale 1ns/1ps

module tb_gx_crt_chain;

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

int pdiv = 8;
reg [3:0] cnt = 0;
wire      ce_pix = cnt == 0;
always @(posedge clk) cnt <= cnt + 4'd1 >= pdiv[3:0] ? 4'd0 : cnt + 4'd1;

reg        cs = 0;
reg  [3:0] addr;
reg  [7:0] din;
wire       lhbl, lvbl, hsync, vsync;

jtk053252 u_crtc (
    .rst, .clk, .pxl_cen(ce_pix), .sel(3'd0), .vldi(1'b1), .hldi(1'b1),
    .cs, .addr, .rnw(1'b0), .din, .dout(),
    .lhbl, .lvbl, .hs(hsync), .vs(vsync), .int1(), .int2(), .hld(), .vld(), .lhbs(),
    .ioctl_addr(4'd0), .ioctl_din()
);

// the source: red is the pixel in the line, green the picture line
reg [7:0] sx = 0, sy = 0;
reg       lhbl_l = 0;
always @(posedge clk) if (ce_pix) begin
    lhbl_l <= lhbl;
    sx <= lhbl ? sx + 8'd1 : 8'd0;
    if (!lvbl)              sy <= 8'd0;
    else if (!lhbl && lhbl_l) sy <= sy + 8'd1;
end
wire act_in = lhbl & lvbl;

logic              active = 0, scale_en = 1, cabinet = 0;
logic signed [8:0] hoffset = 0;
logic signed [5:0] voffset = 0;
logic signed [4:0] hsize = 0;
logic signed [3:0] vsize_step = 0;

logic       ce;
logic [7:0] r, g, b;
logic       hs, vs, hb, vb;

gx_crt_chain dut (
    .clk(clk), .ce_pix(ce_pix), .pxl_div(4'(pdiv)),
    .active(active), .scale_en(scale_en),
    .hoffset(hoffset), .voffset(voffset), .hsize(hsize),
    .vsize_step(vsize_step), .vsize_cabinet(cabinet),
    .r_in(act_in ? sx : 8'd0), .g_in(act_in ? sy : 8'd0), .b_in(act_in ? 8'h5A : 8'd0),
    .hs_in(hsync), .vs_in(vsync), .hb_in(~lhbl), .vb_in(~lvbl),
    .ce_out(ce), .r_out(r), .g_out(g), .b_out(b),
    .hs_out(hs), .vs_out(vs), .hb_out(hb), .vb_out(vb)
);

// arcade_video latches VBlank at the start of each line's HBlank
logic av_hbl = 1, av_vbl = 1;
always_ff @(posedge clk) if (ce) begin
    av_hbl <= hb;
    if (av_hbl & ~hb) av_vbl <= vb;
end
wire pic = ~hb & ~((av_hbl & ~hb) ? vb : av_vbl);

int clk_n = 0;
always_ff @(posedge clk) clk_n <= clk_n + 1;

logic old_hs = 0, old_vs = 0, old_pic = 0, line_has_pic = 0;
logic [7:0] exp_r;
int lines, pic_lines, px, pic_start, line_start;
int px_min, px_max, w_min, w_max, per_min, per_max, bad, g_first, g_last;
int frames = 0;
int f_lines, f_pic_lines, f_px_min, f_px_max, f_w_min, f_w_max;
int f_per_min, f_per_max, f_bad, f_g_first, f_g_last;

task automatic new_frame;
    lines = 0; pic_lines = 0; bad = 0; g_first = -1; g_last = -1;
    px_min = 1 << 30; px_max = 0; w_min = 1 << 30; w_max = 0;
    per_min = 1 << 30; per_max = 0;
endtask
initial begin new_frame(); line_start = 0; end

always @(posedge clk) if (ce && !rst) begin
    old_hs <= hs; old_vs <= vs; old_pic <= pic;
    if (hs & ~old_hs) begin
        if (line_start != 0) begin
            per_min = (clk_n - line_start < per_min) ? clk_n - line_start : per_min;
            per_max = (clk_n - line_start > per_max) ? clk_n - line_start : per_max;
        end
        line_start = clk_n;
        lines++;
        if (line_has_pic) pic_lines++;
        line_has_pic = 0;
    end
    if (pic & ~old_pic) begin
        if (g_first < 0) g_first = int'(g);
        g_last = int'(g); pic_start = clk_n; px = 0; exp_r = r;
    end
    if (pic) begin
        px++; line_has_pic = 1;
        if (r != exp_r || b != 8'h5A) bad++;
        exp_r = r + 8'd1;
    end
    if (~pic & old_pic) begin
        w_min  = (clk_n - pic_start < w_min) ? clk_n - pic_start : w_min;
        w_max  = (clk_n - pic_start > w_max) ? clk_n - pic_start : w_max;
        px_min = (px < px_min) ? px : px_min;
        px_max = (px > px_max) ? px : px_max;
    end
    if (vs & ~old_vs) begin
        f_lines = lines; f_pic_lines = pic_lines; f_bad = bad;
        f_px_min = px_min; f_px_max = px_max; f_w_min = w_min; f_w_max = w_max;
        f_per_min = per_min; f_per_max = per_max;
        f_g_first = g_first; f_g_last = g_last;
        frames++;
        new_frame();
    end
end

int fails = 0;

// Checks the last of `n` frames; -1 = don't care.
task automatic check(string name, int n, int e_lines, int e_pic, int e_px,
                     int e_w, int e_per, int e_gf, int e_gl);
    int f0 = frames;
    bit ok;
    wait (frames >= f0 + n);
    ok = (e_lines < 0 || f_lines == e_lines) && (e_pic < 0 || f_pic_lines == e_pic)
      && (f_px_min == f_px_max) && (e_px < 0 || f_px_max == e_px)
      && (e_w < 0 || f_w_max == e_w) && (f_bad == 0)
      && (f_per_max - f_per_min <= 1) && (e_per < 0 || f_per_min == e_per)
      && (e_gf < 0 || f_g_first == e_gf) && (e_gl < 0 || f_g_last == e_gl);
    $display("%s %-28s lines=%0d pic_lines=%0d px=%0d..%0d w=%0d..%0d period=%0d..%0d bad=%0d src=%0d..%0d",
        ok ? "PASS" : "FAIL", name, f_lines, f_pic_lines, f_px_min, f_px_max,
        f_w_min, f_w_max, f_per_min, f_per_max, f_bad, f_g_first, f_g_last);
    if (!ok) fails++;
endtask

reg [7:0] regs [16];
string    regs_file;

initial begin
    int L, P, W, T, F, VS;
    if (!$value$plusargs("REGS=%s", regs_file)) regs_file = "sim/gx_crt_chain_tb/daiskiss.hex";
    void'($value$plusargs("PDIV=%d", pdiv));
    $readmemh(regs_file, regs);
    repeat (16) @(posedge clk);
    rst <= 0;
    for (int i = 0; i < 16; i++) begin
        @(posedge clk) begin cs <= 1; addr <= i[3:0]; din <= regs[i]; end
        @(posedge clk) cs <= 0;
        repeat (8) @(posedge clk);
    end
    repeat (2) @(posedge vs);

    // the native raster, measured with the chain off
    check("off (native)", 3, -1, -1, -1, -1, -1, 0, -1);
    L = f_lines; P = f_pic_lines; W = f_px_max; T = f_per_min; F = L * T;
    VS = 2;                                 // gx_crt_chain's VSTEP
    $display("raster: %0d lines, %0d in the picture, %0d px, %0d clk a line, %0d clk a pixel",
             L, P, W, T, pdiv);
    if (W * pdiv != f_w_max || F % L != 0) fails++;

    //            name                   frames lines     pic          px   w                    period             src
    active = 1;
    check("on, all zero",                 3, L,        P,           W,   W * pdiv,            T,                 0, P - 1);
    hoffset = -1;
    check("H-Position -1",                3, L,        P,           W,   W * pdiv,            T,                 0, P - 1);
    hoffset = -48;
    check("H-Position -48",               3, L,        P,           W,   W * pdiv,            T,                 0, P - 1);
    hsize = 8;
    check("H-Size +8, H-Position -48",    3, L,        P,           -1,  -1,                  T,                 0, P - 1);
    hoffset = 0;
    check("H-Size +8",                    3, L,        P,           -1,  -1,                  T,                 0, P - 1);
    hsize = -16;
    check("H-Size -16",                   3, L,        P,           W,   W * (pdiv - 2),      T,                 0, P - 1);
    hsize = 8; vsize_step = 7; scale_en = 0;
    check("scaling locked out",           3, L,        P,           W,   W * pdiv,            T,                 0, P - 1);
    hsize = 0; vsize_step = 0; scale_en = 1;
    vsize_step = 1;
    check("PVM +1 (taller)",              8, L - VS,   P,           W,   W * pdiv,                F / (L - VS),      0, P - 1);
    vsize_step = 2;
    check("PVM +2",                       8, L - 2*VS, P,           W,   W * pdiv,                F / (L - 2*VS),    0, P - 1);
    vsize_step = 7;
    check("PVM +7",                      25, L - 7*VS, P,           W,   W * pdiv,                F / (L - 7*VS),    0, P - 1);
    vsize_step = -7;
    check("PVM -7 (shorter)",            50, L + 7*VS, P,           W,   W * pdiv,                F / (L + 7*VS),    0, P - 1);
    vsize_step = 0;
    check("PVM back to 0",               25, L,        P,           W,   W * pdiv,            T,                 0, P - 1);
    // Cabinet needs 8 clocks a pixel; below that V-Size stays at 0
    cabinet = 1; vsize_step = 7;
    check("Cabinet +7",                  25, L,        pdiv >= 8 ? P + 7*VS : P, pdiv >= 8 ? -1 : W, -1, T, 0, pdiv >= 8 ? -1 : P - 1);
    hsize = 8; hoffset = -20; voffset = 3;
    check("Cabinet +7, all controls",     5, L,        pdiv >= 8 ? P + 7*VS : P, -1, -1,     T,                 -1, -1);
    active = 0;
    check("off again",                    3, L,        P,           W,   W * pdiv,            T,                 0, P - 1);

    if (fails != 0) $fatal(1, "%0d scenario(s) FAILED", fails);
    $display("ALL PASS");
    $finish;
end

endmodule
