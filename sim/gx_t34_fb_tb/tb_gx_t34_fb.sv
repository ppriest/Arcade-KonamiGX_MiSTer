// gx_t34_fb: frames tagged with their number and monitor go in; at each
// output vblank the shown buffer is read back from the DDR3 model and must
// be one picture -- one frame of the selected monitor, or in Both a main
// frame and the sub frame after it -- never older than the last one shown.
//   +MODE=0..4    First, Second, Both, Stacked CCW, Stacked CW
//   +OUTP=n       the output's frame period in clocks (the input's is 336)
`timescale 1ns/1ps
module tb_gx_t34_fb;

localparam HA = 16, HT = 24, VA = 8, VT = 14;   // active and total, pixels and lines

reg clk = 0;
always #5 clk = ~clk;

reg  [2:0] mode;
integer    outp;
reg  [7:0] r, g, b;
reg        vs = 0, de = 0, vid_sub = 0, fb_vbl = 0;
wire        fb_en;
wire [11:0] fb_w, fb_h;
wire [31:0] fb_base;
wire [13:0] fb_stride;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire [ 7:0] ddr_be;
wire        ddr_we;

gx_t34_fb uut (
    .CLK_VIDEO(clk), .CE_PIXEL(1'b1), .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_VS(vs), .VGA_DE(de),
    .vid_sub, .mode_in(mode),
    .FB_EN(fb_en), .FB_FORMAT(), .FB_WIDTH(fb_w), .FB_HEIGHT(fb_h), .FB_BASE(fb_base), .FB_STRIDE(fb_stride),
    .FB_VBL(fb_vbl),
    .DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din),
    .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we), .DDRAM_RD()
);

// DDR3, 64-bit words
reg [63:0] mem [int unsigned];
always @(posedge clk) if( ddr_we ) begin
    reg [63:0] w;
    w = mem.exists(ddr_addr) ? mem[ddr_addr] : 64'h0;
    for( int i = 0; i < 8; i++ ) if( ddr_be[i] ) w[8*i +: 8] = ddr_din[8*i +: 8];
    mem[ddr_addr] = w;
end

function automatic [31:0] px( input [31:0] byte_addr );
    reg [63:0] w;
    w  = mem.exists(byte_addr >> 3) ? mem[byte_addr >> 3] : 64'h0;
    px = byte_addr[2] ? w[63:32] : w[31:0];
endfunction

// the input raster: R the frame number, G { monitor, line }, B the column;
// the monitor flag changes as vblank begins, as gx_main's does
integer frame = 0;
initial begin
    r = 0; g = 0; b = 0;
    forever begin
        for( int y = 0; y < VT; y++ ) begin
            if( y == VA ) vid_sub <= ~vid_sub;
            for( int x = 0; x < HT; x++ ) begin
                @(posedge clk);
                de <= y < VA && x < HA;
                vs <= y >= VA + 2 && y < VA + 4;
                r  <= frame[7:0];
                g  <= { vid_sub, y[6:0] };
                b  <= x[7:0];
            end
        end
        frame = frame + 1;
    end
end

// the output's vblank, and the check of what it shows
integer shown = -1, checks = 0, last_l = -1;
initial begin
    if( !$value$plusargs("MODE=%d", mode) ) mode = 0;
    if( !$value$plusargs("OUTP=%d", outp) ) outp = 336;
    #3_333;
    forever begin
        repeat( outp - 4 ) @(posedge clk);
        fb_vbl <= 1;
        repeat( 4 ) @(posedge clk);
        fb_vbl <= 0;
        @(posedge clk);
        check();
    end
end

// where output pixel (X, Y) comes from: monitor s, its column sx and line sy
task automatic src( input integer X, input integer Y, output integer s, output integer sx, output integer sy );
    case( mode )
        2: begin s = X >= HA; sx = X % HA; sy = Y; end
        3: begin s = X >= VA; sy = X % VA; sx = HA - 1 - Y; end          // CCW, main left
        4: begin s = X < VA;  sy = VA - 1 - X % VA; sx = Y; end          // CW, main right
        default: begin s = mode; sx = X; sy = Y; end
    endcase
endtask

task automatic check;
    integer fl, w, h, s2, sx, sy;
    reg [31:0] p;
    reg bad;
    if( !fb_en ) return;
    p = px(fb_base);
    if( p == 0 ) return;                    // nothing finished yet
    w = mode == 2 ? 2 * HA : mode >= 3 ? 2 * VA : HA;
    h = mode >= 3 ? HA : VA;
    if( fb_w != w || fb_h != h ) $fatal(1, "size %0dx%0d, want %0dx%0d", fb_w, fb_h, w, h);
    src(0, 0, s2, sx, sy);
    fl = p[7:0] - (mode >= 2 && s2 ? 1 : 0);   // the main frame's number
    bad = 0;
    for( int y = 0; y < h; y++ )
        for( int x = 0; x < w; x++ ) begin
            p = px(fb_base + y * fb_stride + x * 4);
            src(x, y, s2, sx, sy);
            if( p[7:0] != 8'(mode >= 2 && s2 ? fl + 1 : fl) || p[15] != s2 || p[14:8] != sy || p[23:16] != sx ) begin
                if( !bad ) $display("pixel %0d,%0d = %06x: frame %0d monitor %0d at %0d,%0d", x, y, p, fl, s2, sx, sy);
                bad = 1;
            end
        end
    if( bad ) $fatal(1, "a mixed or wrong picture");
    // frame numbers are 8 bits: a step back is a difference of 128 or more
    if( last_l >= 0 && ((fl - last_l) & 255) >= 128 ) $fatal(1, "frame %0d shown after %0d", fl, last_l);
    last_l = fl;
    checks++;
endtask

initial begin
    #2_000_000;
    if( checks < 100 ) $fatal(1, "only %0d checks", checks);
    $display("PASS mode %0d, output period %0d: %0d pictures checked, last frame %0d of %0d", mode, outp, checks, last_l, frame);
    $finish;
end

endmodule
