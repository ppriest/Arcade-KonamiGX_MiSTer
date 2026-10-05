// SPDX-License-Identifier: GPL-3.0-or-later
//
// k056734 against the Python model (scripts/esc_chip_check.py): the host bus
// holds the BIOS, the game ROM, work RAM and sprite RAM; each packet of a
// capture loads its work RAM, posts the mailbox and runs until the kernel is
// back in its mailbox wait; work RAM and sprite RAM are then dumped.
//
// +DATA=<dir>: bios.hex, rom.hex (0x200000-), cfg.hex (s10, s11 nibble, xor,
// lanes), packets.txt ("<wram hex> <ptr hex>" per line); out_<n>_w.hex and
// out_<n>_s.hex are written there.

`timescale 1ns/1ps

module tb_k056734;

logic clk = 0, rst = 1;
// +SS_AT=k: after packet k, read the chip's state over the state bus, reset
// it, write the state back and carry on (a save state's round trip)
logic        hold = 0, ss_hi = 0, ss_lo = 0, ss_rg = 0, ss_we = 0;
logic [11:0] ss_addr = 0;
logic [15:0] ss_wd = 0, ss_rd;
logic [15:0] img_h [0:4095], img_l [0:4095], img_r [0:140];
always #5 clk = ~clk;

logic [7:0] bios [0:24'h7FFFF];
logic [7:0] rom  [0:24'h1FFFFF];
logic [7:0] wram [0:24'h1FFFF];
logic [7:0] spr  [0:24'h3FFF];
logic [31:0] cfg [0:3];
logic [63:0] lanes;          // cfg.hex words 3 (high) and 4

logic        mail_we = 0;
logic [23:0] mail_data = 0;
logic        irq;
logic        m_req, m_we, m_ack = 0;
logic [23:1] m_addr;
logic [ 1:0] m_be;
logic [15:0] m_dout, m_din = 0;
logic [31:0] icount;
logic [15:0] pc;
logic        running;

k056734 dut (
    .clk, .rst,
    .s10(cfg[0][15:0]), .s11n(cfg[1][3:0]), .dxor(cfg[2]), .dlanes(lanes),
    .mail_we, .mail_data, .irq,
    .m_req, .m_we, .m_addr, .m_be, .m_dout, .m_din, .m_ack,
    .hold, .ss_hi, .ss_lo, .ss_rg, .ss_addr, .ss_we, .ss_wd, .ss_rd,
    .icount, .pc_out(pc), .running
);


function automatic logic [7:0] rd8( input logic [23:0] a );
    if( a < 24'h080000 )                     return bios[a];
    if( a >= 24'h200000 && a < 24'h400000 )  return rom[a - 24'h200000];
    if( a >= 24'hc00000 && a < 24'hc20000 )  return wram[a - 24'hc00000];
    if( a >= 24'hd20000 && a < 24'hd24000 )  return spr[a - 24'hd20000];
    return 8'd0;
endfunction
task automatic wr8( input logic [23:0] a, input logic [7:0] d );
    if( a >= 24'hc00000 && a < 24'hc20000 ) wram[a - 24'hc00000] = d;
    else if( a >= 24'hd20000 && a < 24'hd24000 ) spr[a - 24'hd20000] = d;
    else if( a != 24'hd56000 ) $display("write outside RAM: %06x = %02x", a, d);
endtask

int lat = 0;
int nrd = 0, nwr = 0;
always @(posedge clk) begin
    m_ack <= 0;
    if( m_req && !m_ack ) begin
        lat <= lat + 1;
        if( lat == 2 ) begin
            lat <= 0;
            m_ack <= 1;
            if( m_we ) begin
                nwr <= nwr + 1;
                if( m_be[1] ) wr8({ m_addr, 1'b0 }, m_dout[15:8]);
                if( m_be[0] ) wr8({ m_addr, 1'b1 }, m_dout[ 7:0]);
            end else begin
                nrd <= nrd + 1;
                m_din <= { rd8({ m_addr, 1'b0 }), rd8({ m_addr, 1'b1 }) };
            end
        end
    end
end

int nirq = 0;
always @(posedge clk) if( irq ) nirq <= nirq + 1;

string dir;
task automatic dump( input int n );
    int f;
    f = $fopen($sformatf("%s/out_%0d_w.hex", dir, n), "w");
    for( int i = 0; i < 24'h20000; i++ ) $fwrite(f, "%02x\n", wram[i]);
    $fclose(f);
    f = $fopen($sformatf("%s/out_%0d_s.hex", dir, n), "w");
    for( int i = 0; i < 24'h4000; i++ ) $fwrite(f, "%02x\n", spr[i]);
    $fclose(f);
endtask

// back in the kernel's mailbox wait (words 376-377) with an empty mailbox
task automatic wait_idle( input int limit );
    int still, c0;
    still = 0; c0 = 0;
    while( still < 400 && c0 < limit ) begin
        @(posedge clk);
        c0++;
        if( dut.mail == 0 && (pc == 16'd376 || pc == 16'd377) ) still++; else still = 0;
    end
    if( c0 >= limit ) $display("TIMEOUT pc=%0d", pc);
endtask

task automatic ss_word( input int sel, input int a, input logic we, input logic [15:0] d, output logic [15:0] q );
    @(posedge clk) begin ss_hi <= sel == 0; ss_lo <= sel == 1; ss_rg <= sel == 2; ss_addr <= a[11:0]; ss_we <= we; ss_wd <= d; end
    @(posedge clk) ss_we <= 0;
    @(posedge clk);
    @(posedge clk) q = ss_rd;
    ss_hi <= 0; ss_lo <= 0; ss_rg <= 0;
endtask
task automatic round_trip;
    logic [15:0] q;
    hold <= 1;
    wait( dut.held );
    for( int i = 0; i < 4096; i++ ) begin ss_word(0, i, 0, 0, q); img_h[i] = q; end
    for( int i = 0; i < 4096; i++ ) begin ss_word(1, i, 0, 0, q); img_l[i] = q; end
    for( int i = 0; i < 141; i++ )  begin ss_word(2, i, 0, 0, q); img_r[i] = q; end
    $display("state read: pc %0d, running %0d", img_r[128], img_r[140]);
    @(posedge clk) rst <= 1;
    repeat( 4 ) @(posedge clk);
    rst <= 0;
    wait( dut.held );                                   // the loader, stopped at its first word
    for( int i = 0; i < 4096; i++ ) ss_word(0, i, 1, img_h[i], q);
    for( int i = 0; i < 4096; i++ ) ss_word(1, i, 1, img_l[i], q);
    for( int i = 0; i < 141; i++ )  ss_word(2, i, 1, img_r[i], q);
    @(posedge clk) hold <= 0;
    $display("state written back");
endtask

initial begin
    string wf, line;
    int ss_at;
    int fd, n, ptr, r;
    logic [31:0] c0;
    if( !$value$plusargs("DATA=%s", dir) ) $fatal(1, "+DATA=<dir>");
    if( !$value$plusargs("SS_AT=%d", ss_at) ) ss_at = -1;
    $readmemh({ dir, "/bios.hex" }, bios);
    $readmemh({ dir, "/rom.hex" }, rom);
    begin
        logic [31:0] cf [0:4];
        $readmemh({ dir, "/cfg.hex" }, cf);
        cfg[0] = cf[0]; cfg[1] = cf[1]; cfg[2] = cf[2];
        lanes = { cf[3], cf[4] };
    end
    for( int i = 0; i < 24'h4000; i++ ) spr[i] = 0;
    for( int i = 0; i < 24'h20000; i++ ) wram[i] = 0;
    repeat( 10 ) @(posedge clk);
    rst <= 0;
    wait( running );
    $display("kernel loaded at icount %0d, cycle %0t", icount, $time);
    wait_idle(5_000_000);
    $display("idle after %0d instructions", icount);
    fd = $fopen({ dir, "/packets.txt" }, "r");
    n = 0;
    while( $fgets(line, fd) ) begin
        r = $sscanf(line, "%s %h", wf, ptr);
        if( r != 2 ) continue;
        $readmemh({ dir, "/", wf }, wram);
        c0 = icount;
        @(posedge clk) begin mail_we <= 1; mail_data <= ptr[23:0]; end
        @(posedge clk) mail_we <= 0;
        wait_idle(20_000_000);
        $display("packet %0d ptr %06x: %0d instructions, irqs %0d, bus rd %0d wr %0d", n, ptr, icount - c0, nirq, nrd, nwr);
        dump(n);
        if( n == ss_at ) round_trip();
        n++;
    end
    $display("K056734_DONE");
    $finish;
end

endmodule
