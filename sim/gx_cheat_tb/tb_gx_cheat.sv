// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/cheat/cheatengine.sv as gx_main uses it: the 68020's 16-bit reads of a
// big-endian memory, codes as the .mra gives them (flags, address, compare,
// data; big-endian), loaded a byte at a time. Each case loads one code and
// reads the words around it: the code's bytes must read back as its data,
// every other byte as memory holds it.
//     scripts/run_verilator.sh gx_cheat_tb
`timescale 1ns/1ps
module tb_gx_cheat;
logic clk = 0;
always #10 clk = ~clk;
logic         rst = 1;
logic [128:0] code = 0;
logic [23:0]  addr;
logic [15:0]  din;
wire  [15:0]  dout;
cheatengine_32_16 #(.ADDR_WIDTH(24), .MAX_CODES(16)) dut (
    .clk, .reset(rst), .enable(1'b1), .available(), .code, .addr_in(addr), .data_in(din), .data_out(dout)
);
byte unsigned mem [24'hC00000:24'hC0003F];
int fails = 0;

task automatic load(input logic [31:0] flags, input logic [31:0] a, input logic [31:0] cmp, input logic [31:0] d);
    logic [127:0] c;
    c = { flags, a, cmp, d };
    @(negedge clk) rst = 1;
    @(negedge clk) rst = 0;
    for (int k = 0; k < 16; k++) begin            // a byte at a time, as KonamiGX.sv shifts them in
        @(negedge clk) code = { k == 15, code[119:0], c[127 - 8*k -: 8] };
        @(negedge clk) ;
    end
    @(negedge clk) code[128] = 0;
endtask

// the read of the word at a, against what the code should make of it
task automatic check(input string what, input logic [23:0] a, input logic [15:0] want);
    @(negedge clk) begin addr = a; din = { mem[a], mem[a + 1] }; end
    #1;
    if (dout !== want) begin fails++; $display("FAIL %s: %06x reads %04x, want %04x", what, a, dout, want); end
endtask

initial begin
    for (int i = 'hC00000; i <= 'hC0003F; i++) mem[i] = 8'(i);   // byte = its address's low byte
    // byte codes, replace, at each alignment of a long
    load(32'h00000010, 32'hC00010, 0, 32'h000000AA);
    check("byte +0", 24'hC00010, 16'hAA11); check("byte +0 next", 24'hC00012, 16'h1213);
    load(32'h00000010, 32'hC00011, 0, 32'h000000BB);
    check("byte +1", 24'hC00010, 16'h10BB);
    load(32'h00000010, 32'hC00012, 0, 32'h000000CC);
    check("byte +2", 24'hC00012, 16'hCC13); check("byte +2 prev", 24'hC00010, 16'h1011);
    load(32'h00000010, 32'hC00013, 0, 32'h000000DD);
    check("byte +3", 24'hC00012, 16'h12DD);
    // words
    load(32'h00000020, 32'hC00020, 0, 32'h00001234);
    check("word +0", 24'hC00020, 16'h1234); check("word +0 next", 24'hC00022, 16'h2223);
    load(32'h00000020, 32'hC00022, 0, 32'h00005678);
    check("word +2", 24'hC00022, 16'h5678); check("word +2 prev", 24'hC00020, 16'h2021);
    // a long: its high word at the lower address
    load(32'h00000040, 32'hC00030, 0, 32'hDEADBEEF);
    check("long hi", 24'hC00030, 16'hDEAD); check("long lo", 24'hC00032, 16'hBEEF);
    // compare: replaced only while memory holds the compare value
    load(32'h00000021, 32'hC00020, 32'h00002021, 32'h0000ABCD);
    check("compare match", 24'hC00020, 16'hABCD);
    load(32'h00000021, 32'hC00020, 32'h00009999, 32'h0000ABCD);
    check("compare miss", 24'hC00020, 16'h2021);
    load(32'h00000041, 32'hC00030, 32'h30313233, 32'h01020304);
    check("long compare hi", 24'hC00030, 16'h0102); check("long compare lo", 24'hC00032, 16'h0304);
    // OR and AND
    load(32'h00000110, 32'hC00010, 0, 32'h00000080);
    check("byte OR", 24'hC00010, 16'h9011);
    load(32'h00000210, 32'hC00011, 0, 32'h0000000F);
    check("byte AND", 24'hC00010, 16'h1001);
    // elsewhere untouched
    check("other", 24'hC00000, 16'h0001);
    if (fails != 0) $fatal(1, "%0d check(s) FAILED", fails);
    $display("ALL PASS");
    $finish;
end
endmodule
