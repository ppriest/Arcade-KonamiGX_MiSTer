// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_esc on its own: a work RAM and a sprite RAM behind its bus-master port,
// one command, the sprite RAM written out. scripts/check_gx_esc.py fills the
// work RAM from a capture, places a command packet at 0xc1ff00 and compares
// the result with the capture's sprite RAM.
//
//   +WRAM=path +SPR=path +OUT=path   (one 16-bit word a line)
//   +SAL2=1  konamigx_esc_alert mode 1 (gen_src 0xc07230, 0x172 groups)
module tb_gx_esc;
reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

reg  [15:0] wram [0:65535];              // 0xc00000-0xc1ffff
reg  [15:0] spr  [0:8191];               // 0xd20000-0xd23fff
reg         start = 0;
reg  [23:0] data  = 0;
wire        busy, irq, m_req, m_we;
wire [23:1] m_addr;
wire [ 1:0] m_be;
wire [15:0] m_dout;
reg  [15:0] m_din = 0;
reg         m_ack = 0;
int         sal2 = 0;

gx_esc dut (
    .rst, .clk, .start, .data, .p4(1'b0),
    .fj(1'b0), .fj_mode(8'd0), .fj_sz2(8'd0), .fj_sa(24'd0), .fj_da(24'd0), .fj_db(16'd0), .fj_x(32'd0),
    .gen_en(1'b1), .gen_src(sal2 != 0 ? 24'hc07230 : 24'hc00000), .gen_count(sal2 != 0 ? 9'h172 : 9'h100),
    .gen_copy(1'b0), .gen_sal2(sal2 != 0),
    .busy, .irq, .m_req, .m_we, .m_addr, .m_be, .m_dout, .m_din, .m_ack, .dbg()
);

// the bus: an access completes three clocks after it is asked for
reg [1:0] lat = 0;
always @(posedge clk) begin
    m_ack <= 0;
    if (m_req && !m_ack) begin
        if (lat == 2) begin
            lat <= 0; m_ack <= 1;
            if ({m_addr, 1'b0} >= 24'hc00000 && {m_addr, 1'b0} < 24'hc20000) begin
                if (m_we) begin
                    if (m_be[1]) wram[m_addr[16:1]][15:8] <= m_dout[15:8];
                    if (m_be[0]) wram[m_addr[16:1]][ 7:0] <= m_dout[ 7:0];
                end else m_din <= wram[m_addr[16:1]];
            end else if ({m_addr, 1'b0} >= 24'hd20000 && {m_addr, 1'b0} < 24'hd24000) begin
                if (m_we) begin
                    if (m_be[1]) spr[m_addr[13:1]][15:8] <= m_dout[15:8];
                    if (m_be[0]) spr[m_addr[13:1]][ 7:0] <= m_dout[ 7:0];
                end else m_din <= spr[m_addr[13:1]];
            end else m_din <= 16'h0000;
        end else lat <= lat + 1;
    end
end

initial begin
    string f;
    int fd, n;
    void'($value$plusargs("SAL2=%d", sal2));
    if (!$value$plusargs("WRAM=%s", f)) $fatal(1, "+WRAM");
    $readmemh(f, wram);
    if (!$value$plusargs("SPR=%s", f)) $fatal(1, "+SPR");
    $readmemh(f, spr);
    // the command packet: ESC_OBJECT_MAGIC_ID, then the run command at +8
    wram[16'hff80] = 16'hfef7; wram[16'hff81] = 16'h24fb;
    wram[16'hff84] = 16'h0100;
    repeat (4) @(posedge clk);
    rst <= 0;
    @(posedge clk); start <= 1; data <= 24'hc1ff00;
    @(posedge clk); start <= 0;
    n = 0;
    while (!busy && n < 10) begin @(posedge clk); n++; end
    n = 0;
    while (busy && n < 50000000) begin @(posedge clk); n++; end
    $display("ESC done after %0d clocks, busy %0d", n, busy);
    if (!$value$plusargs("OUT=%s", f)) $fatal(1, "+OUT");
    fd = $fopen(f, "w");
    for (int i = 0; i < 8192; i++) $fwrite(fd, "%04x\n", spr[i]);
    $fclose(fd);
    $finish;
end
endmodule
