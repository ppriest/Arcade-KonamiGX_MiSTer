// Where HS falls in the line, against LHBL, for a set's K053252 registers
// (+R0..+R15, hex): gx_obj's line buffers swap at HS, so it must be in the
// horizontal blanking. Prints, for one line, the pixel (since LHBL rose) at
// which HS rises and falls, LHBL's high length, and the line's length.
`timescale 1ns/1ps
module tb_k053252_hs;
reg clk = 0, rst = 1;
always #5 clk = ~clk;
reg  [3:0] cnt = 0;
wire pxl_cen = cnt == 0;
always @(posedge clk) cnt <= cnt == 3 ? 4'd0 : cnt + 4'd1;
reg        cs = 0;
reg  [3:0] addr;
reg  [7:0] din;
wire lhbl, lvbl, hs, vs;
jtk053252 u_crtc (
    .rst, .clk, .pxl_cen, .sel(3'd0), .vldi(1'b1), .hldi(1'b1),
    .cs, .addr, .rnw(1'b0), .din, .dout(),
    .lhbl, .lvbl, .hs, .vs, .int1(), .int2(), .hld(), .vld(), .lhbs(),
    .ioctl_addr(4'd0), .ioctl_din()
);
reg [7:0] r [16];
integer p = -1, n = 0, hs_on = -1, hs_off = -1, vis = 0, len = 0;
reg lhbl_l = 0, hs_l = 0;
initial begin
    for( int i = 0; i < 16; i++ ) begin
        string s; s = $sformatf("R%0d=%%h", i);
        if( !$value$plusargs(s, r[i]) ) r[i] = 0;
    end
    repeat(4) @(posedge clk); rst <= 0;
    for( int i = 0; i < 16; i++ ) begin
        @(posedge clk); cs <= 1; addr <= 4'(i); din <= r[i];
        @(posedge clk); cs <= 0;
    end
end
always @(posedge clk) if( pxl_cen && !rst ) begin
    lhbl_l <= lhbl; hs_l <= hs;
    if( lhbl && !lhbl_l ) begin
        n++;
        if( n == 20 ) $display("line: %0d pixels, %0d visible; HS rises at p=%0d, falls at p=%0d", len, vis, hs_on, hs_off);
        if( n == 20 ) $finish;
        len = 0; p = 0; vis = 0; hs_on = -1; hs_off = -1;
    end
    len++;
    if( lhbl ) vis++;
    if( hs && !hs_l ) hs_on = p;
    if( !hs && hs_l ) hs_off = p;
    if( p >= 0 ) p++;
end
endmodule
