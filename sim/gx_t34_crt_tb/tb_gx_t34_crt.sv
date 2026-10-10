// gx_t34_crt: frames alternate main and sub, each pixel tagged with its
// frame, line and column; with the hold on, every active pixel of a frame of
// the other monitor must be the held monitor's last frame's pixel at the same
// place, and every pixel of the held monitor's frames must pass unchanged.
// The DDR3 model is busy at random and answers reads after RLAT clocks;
// gx_t34_fb's writes are played as `other_we` on one clock in four.
//   +MON=0|1  the held monitor   +W=n the active width (288, 384, 576)
`timescale 1ns/1ps
module tb_gx_t34_crt;

integer W = 576, MON = 0;
localparam HT_X = 192, VA = 32, VT = 40, CEDIV = 4, RLAT = 12;

reg clk = 0;
always #5 clk = ~clk;

reg  [1:0] cdiv = 0;
wire       ce = cdiv == 0;
always @(posedge clk) cdiv <= cdiv + 1'd1;

reg  [7:0] r = 0, g = 0, b = 0;
reg        vs = 0, de = 0, vid_sub = 0;
wire [7:0] ro, go, bo;
wire [ 7:0] bc, be;
wire [28:0] addr;
wire [63:0] din;
wire        we, rd;
reg  [63:0] dout;
reg         dready = 0;
reg         busy = 0;
wire        other_we = cdiv == 2'd1;

gx_t34_crt uut (
    .CLK_VIDEO(clk), .CE_PIXEL(ce), .VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_VS(vs), .VGA_DE(de),
    .vid_sub, .en_in(1'b1), .mon_in(MON[0]),
    .R_OUT(ro), .G_OUT(go), .B_OUT(bo),
    .DDRAM_BUSY(busy), .other_we, .DDRAM_BURSTCNT(bc), .DDRAM_ADDR(addr), .DDRAM_DIN(din),
    .DDRAM_BE(be), .DDRAM_WE(we), .DDRAM_RD(rd), .DDRAM_DOUT(dout), .DDRAM_DOUT_READY(dready)
);

// DDR3: busy one clock in three at random; a read's burst after RLAT clocks
reg [63:0] mem [int unsigned];
int unsigned q_addr [$];
int          q_due  [$];
int          t = 0;
always @(posedge clk) begin
    t <= t + 1;
    busy <= ($urandom % 3) == 0;
    dready <= 1'b0;
    if( !busy && we ) begin
        if( other_we ) begin $display("FAIL: a request on gx_t34_fb's clock"); $finish; end
        mem[addr] = din;
    end
    if( !busy && rd ) begin
        if( other_we ) begin $display("FAIL: a request on gx_t34_fb's clock"); $finish; end
        for( int k = 0; k < bc; k++ ) begin q_addr.push_back(addr + k); q_due.push_back(t + RLAT + k); end
    end
    if( q_due.size() != 0 && q_due[0] <= t ) begin
        dout   <= mem.exists(q_addr[0]) ? mem[q_addr[0]] : 64'hdeadbeef_deadbeef;
        dready <= 1'b1;
        void'(q_addr.pop_front()); void'(q_due.pop_front());
    end
end

// the source: frame f is sub if odd; pixel = { f, y, x } folded to 24 bits
function automatic [23:0] pix( input int f, input int y, input int x );
    pix = { 8'(f), 6'(y), 10'(x) };
endfunction
int f = 0, x = 0, y = 0, held = -1, bad = 0, good = 0, passed = 0;
// what the output should show, checked a pixel late (the output is taken on CE)
reg [23:0] want; reg chk = 0;
always @(posedge clk) if( ce ) begin
    // check the pixel that was being sent
    if( chk ) begin
        if( { bo, go, ro } !== want ) begin
            if( bad < 10 ) $display("BAD f%0d y%0d x%0d: %06x, want %06x", f, y, x, { bo, go, ro }, want);
            bad++;
        end else good++;
    end
    chk <= 0;
    // the next pixel
    x = x + 1;
    if( x == W + HT_X ) begin x = 0; y = y + 1; end
    if( y == VT ) begin
        y = 0;
        if( (f & 1) == MON ) held = f;
        f = f + 1;
        if( f == 12 ) begin
            $display("%s: %0d pixels as expected, %0d not", bad == 0 ? "PASS" : "FAIL", good, bad);
            $finish;
        end
    end
    // vid_sub changes in the blanking, before VS
    if( y == VA + 2 && x == 0 ) vid_sub <= (f + 1) & 1;
    vs <= y == VA + 4;
    de <= y < VA && x < W;
    { b, g, r } <= pix(f, y, x);
    if( y < VA && x < W ) begin
        chk  <= f >= 2;                     // the hold needs a stored frame
        want <= ((f & 1) == MON || held < 0) ? pix(f, y, x) : pix(held, y, x);
    end
end

initial begin
    void'($value$plusargs("W=%d", W));
    void'($value$plusargs("MON=%d", MON));
    vid_sub = 0;
end
endmodule
