// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_esc_div (rtl/gx_esc.v) against integer division: the ESC's zoom
// divide, q = trunc(n / d) to 16 bits, for random 22-bit dividends whose
// low six bits are zero (|y| * 0x40, as the ESC gives it) and any, and
// random non-zero 16-bit divisors, plus the edges.
//     scripts/run_verilator.sh gx_esc_div_tb
`timescale 1ns/1ps
module tb_gx_esc_div;
logic clk = 0, rst = 1, go = 0;
always #5 clk = ~clk;
logic [21:0] n;
logic [15:0] d;
wire         busy;
wire  [15:0] q;
gx_esc_div dut (.clk, .rst, .go, .n, .d, .busy, .q);
int fails = 0, runs = 0;
task automatic one(input logic [21:0] nn, input logic [15:0] dd);
    logic [21:0] want;
    @(negedge clk) begin n = nn; d = dd; go = 1; end
    @(negedge clk) go = 0;
    while (busy) @(negedge clk);
    want = nn / dd;
    runs++;
    if (q !== want[15:0]) begin
        fails++;
        if (fails < 10) $display("FAIL %h / %h = %h, got %h", nn, dd, want[15:0], q);
    end
endtask
initial begin
    repeat (3) @(posedge clk);
    rst = 0;
    one(22'h0, 16'h40); one(22'h3fffc0, 16'h1); one(22'h3fffff, 16'hffff); one(22'h40, 16'h40);
    one(22'h3fffc0, 16'h40); one(22'h1, 16'h2);
    for (int k = 0; k < 20000; k++) begin
        logic [15:0] dd;
        dd = $urandom;
        if (dd == 0) dd = 1;
        if (k & 1) one({ 16'($urandom), 6'd0 }, dd & 16'h01ff ? dd & 16'h01ff : 16'd1);
        else       one(22'($urandom), dd);
    end
    if (fails != 0) $fatal(1, "%0d of %0d FAILED", fails, runs);
    $display("ALL PASS: %0d divisions", runs);
    $finish;
end
endmodule
