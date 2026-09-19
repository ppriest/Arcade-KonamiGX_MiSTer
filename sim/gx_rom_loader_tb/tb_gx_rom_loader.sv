// gx_rom_loader + ddram_phy against a DDR3 model with random busy and read
// latency, and a download side that holds wait for a random time after each
// byte (as gx_sdram_top's ioctl_wait does). Every byte of the image must come
// out once, in order, at its address.
`timescale 1ns/1ps
module tb_gx_rom_loader;
localparam int N = 1003;            // not a multiple of 8: the last granule is partial
reg clk = 0, reset = 1, start = 0;
always #5 clk = ~clk;

byte unsigned img [0:N+7];
initial for (int i = 0; i < N + 8; i++) img[i] = 8'($urandom);

wire        DDRAM_RD, DDRAM_WE;
wire [28:0] DDRAM_ADDR;
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [63:0] DDRAM_DIN;
reg         DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0;
reg  [63:0] DDRAM_DOUT;
int         lat = -1; reg [28:0] a_l;
always @(posedge clk) begin
    DDRAM_BUSY <= ($urandom % 4) == 0;
    DDRAM_DOUT_READY <= 0;
    if (DDRAM_RD && !DDRAM_BUSY) begin a_l <= DDRAM_ADDR; lat <= 3 + $urandom % 20; end
    else if (lat > 0) lat <= lat - 1;
    else if (lat == 0) begin
        lat <= -1; DDRAM_DOUT_READY <= 1;
        for (int k = 0; k < 8; k++) DDRAM_DOUT[8*k +: 8] <= img[(a_l[24:0] << 3) + k];
    end
end

wire req, busy_p, valid; wire [27:0] addr; wire [63:0] rdata;
ddram_phy u_phy (.clk, .reset, .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT,
    .DDRAM_DOUT_READY, .DDRAM_RD, .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE,
    .req, .we(1'b0), .addr, .wdata(8'd0), .busy(busy_p), .valid, .rdata);

wire wr, busy; wire [26:0] waddr; wire [7:0] dout;
reg  wait_r = 0; int hold = 0;
wire wait_in = wait_r | wr;
always @(posedge clk) begin
    if (wr) begin wait_r <= 1; hold <= 1 + $urandom % 12; end
    else if (hold > 0) hold <= hold - 1;
    else wait_r <= 0;
end
gx_rom_loader u_ldr (.clk, .reset, .length(28'(N)), .start, .busy,
    .ddr_req(req), .ddr_addr(addr), .ddr_busy(busy_p), .ddr_valid(valid), .ddr_rdata(rdata),
    .wr, .addr(waddr), .dout, .wait_in);

int got = 0, bad = 0;
always @(posedge clk) if (wr) begin
    if (wait_in !== wr) ;                     // wr itself raises wait
    if (waddr != 27'(got) || dout != img[got]) begin
        if (bad < 5) $display("BAD byte %0d: addr %0d data %02x want %02x", got, waddr, dout, img[got]);
        bad++;
    end
    got++;
end
initial begin
    repeat (5) @(posedge clk); reset = 0;
    repeat (3) @(posedge clk); start = 1; @(posedge clk); start = 0;
    wait (busy); wait (!busy);
    repeat (5) @(posedge clk);
    // the copy runs whole granules: bytes N..(N rounded up to 8) - 1 are extra
    $display("bytes %0d (image %0d, rounded to %0d), mismatches %0d", got, N, (N + 7) / 8 * 8, bad);
    if (bad == 0 && got == (N + 7) / 8 * 8) $display("PASS"); else $display("FAIL");
    $finish;
end
initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
