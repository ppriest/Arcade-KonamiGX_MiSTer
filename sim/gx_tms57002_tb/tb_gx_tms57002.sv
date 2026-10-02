// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_tms57002 against MAME's host traffic. scripts/check_gx_tms57002.py
// turns a scripts/mame/dasp_log.lua log into events.txt, one per line:
//     <clock> <kind> <hex>     kind: 0 control write, 1 data write,
//                                    2 data read (MAME's byte), 3 status read
// at 48 MHz from the log's microseconds. Writes are replayed; every data
// read is compared with MAME's byte, every status read's dready and empty
// bits counted when they differ (they are timing: when the program posts,
// when it takes an update).
//
//     +EVENTS=path  +LAT=n (external-memory latency, clocks)  +MAXCLK=n
//
// +LOCK=expected: lockstep against scripts/tms57002.py lock. events.txt is
// then <sample> <kind> <hex>; a sample's accesses are made with the DSP
// idle, then its sync, with the model's synthetic inputs (si_of); after the
// program idles, the outputs and accumulators are compared with the
// model's line for that sample.

`timescale 1ns/1ps

module tb_gx_tms57002;

reg clk = 0;
always #10.4167 clk = ~clk;

reg        rst = 1;
reg        h_ctrl_wr = 0, h_wr = 0, h_rd = 0;
reg  [7:0] h_ctrl, h_din;
wire [7:0] h_dout;
wire [2:0] status;
reg        sync = 0;
wire       x_req, x_we;
wire [17:3] x_addr;
wire [63:0] x_wdata;
wire [7:0] x_wmask;
reg        x_ack = 0;
reg [63:0] x_rdata;
wire [63:0] dbg;
wire [95:0] so;

reg [95:0] si = 96'd0;

gx_tms57002 dut (
    .clk, .rst,
    .h_ctrl_wr, .h_ctrl, .h_wr, .h_din, .h_rd, .h_dout, .status,
    .sync, .si, .so,
    .x_req, .x_we, .x_addr, .x_wdata, .x_wmask, .x_ack, .x_rdata,
    .dbg, .dbg_clr(1'b0)
);

// external memory: 256 KB, answers LAT clocks after a read and WLAT after a
// write (+WLAT, default LAT: on the board a write is one to four SDRAM
// writes through gx_sound's write path, each waited out)
reg [7:0] xram [0:262143];
integer lat = 12, wlat = -1, lc = 0;
initial void'($value$plusargs("WLAT=%d", wlat));
// +XLOG=n: the first n external-memory transactions, as tb_gx_main's
int xlog = 0;
initial void'($value$plusargs("XLOG=%d", xlog));
always @(posedge clk) if (xlog > 0 && x_ack) begin
    if (x_we) $display("XLOG W %05x %02x %016x", {x_addr, 3'd0}, x_wmask, x_wdata);
    else      $display("XLOG R %05x %016x", {x_addr, 3'd0}, x_rdata);
    xlog--;
end
always @(posedge clk) begin
    x_ack <= 0;
    if( x_req && !x_ack ) begin
        if( lc == (x_we && wlat >= 0 ? wlat : lat) ) begin
            lc <= 0;
            x_ack <= 1;
            for( int k=0; k<8; k++ ) begin
                if( x_we && x_wmask[k] ) xram[{x_addr, 3'(k)}] <= x_wdata[8*k +: 8];
                x_rdata[8*k +: 8] <= xram[{x_addr, 3'(k)}];
            end
        end else lc <= lc + 1;
    end
end

// 48 kHz: every 1000 clocks (not in lockstep, which syncs itself)
integer sc = 0;
reg     lock = 0;
always @(posedge clk) begin
    if( !lock ) sync <= 0;
    if( !rst && !lock ) begin
        if( sc == 999 ) begin sc <= 0; sync <= 1; end else sc <= sc + 1;
    end
end

longint now = 0;
always @(posedge clk) now <= now + 1;

integer fd, r, kind, val, rd_bad = 0, rd_n = 0, st_bad = 0, st_n = 0;
longint t, maxclk = 64'h7fffffffffffffff;
string ev;
reg [2:0] st_last_bad = 3'b111;

function automatic [23:0] si_of( input longint n, input int k );
    reg [31:0] x;
    begin
        x = 32'(n * 64'h9E3779B1 + k * 64'h7F4A7C15);
        x = x ^ (x >> 15);
        x = 32'(x * 64'h2C1B3C6D);
        x = x ^ (x >> 12);
        si_of = x[23:0];
    end
endfunction

task automatic host_op( input int kind, input [7:0] v );
    case( kind )
    0: begin h_ctrl <= v; h_ctrl_wr <= 1; @(posedge clk); h_ctrl_wr <= 0; end
    1: begin h_din <= v; h_wr <= 1; @(posedge clk); h_wr <= 0; end
    2: begin h_rd <= 1; @(posedge clk); h_rd <= 0; end
    default: ;
    endcase
    @(posedge clk);
endtask

string lockf;
integer ef, en, bad = 0, lines = 0, maxs = 0, busy_max = 0;
longint ln, cur;
reg [23:0] e_so [0:3];
reg [31:0] e_a;
reg [63:0] e_m;

initial begin
    for( int k=0; k<262144; k++ ) xram[k] = 0;
    if( $value$plusargs("LOCK=%s", lockf) ) begin
        lock = 1;
        if( !$value$plusargs("EVENTS=%s", ev) ) ev = "events.txt";
        void'($value$plusargs("LAT=%d", lat));
        void'($value$plusargs("SAMPLES=%d", maxs));
        fd = $fopen(ev, "r");
        ef = $fopen(lockf, "r");
        if( fd == 0 || ef == 0 ) $fatal(1, "no %s or %s", ev, lockf);
        repeat(8) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        r = $fscanf(fd, "%d %d %h\n", t, kind, val);
        while( !$feof(ef) ) begin
            en = $fscanf(ef, "%d %h %h %h %h %h %h\n", ln, e_so[0], e_so[1], e_so[2], e_so[3], e_a, e_m);
            if( en != 7 ) break;
            if( maxs != 0 && ln >= maxs ) break;
            while( r == 3 && t <= ln ) begin
                host_op(kind, val[7:0]);
                r = $fscanf(fd, "%d %d %h\n", t, kind, val);
            end
            si <= { si_of(ln, 3), si_of(ln, 2), si_of(ln, 1), si_of(ln, 0) };
            @(posedge clk);
            sync <= 1; @(posedge clk); sync <= 0;
            cur = now;
            // the sync is taken, then the program runs to idle (or cannot run)
            while( dut.sync_pend || dut.st != 0 ) @(posedge clk);
            if( now - cur > busy_max ) busy_max = int'(now - cur);
            lines++;
            if( so[23:0] !== e_so[0] || so[47:24] !== e_so[1] || so[71:48] !== e_so[2]
             || so[95:72] !== e_so[3] || dut.aacc !== e_a || dut.macc !== e_m ) begin
                bad++;
                if( bad <= 10 )
                    $display("sample %0d: RTL so %06x %06x %06x %06x a %08x m %016x / model %06x %06x %06x %06x a %08x m %016x",
                             ln, so[23:0], so[47:24], so[71:48], so[95:72], dut.aacc, dut.macc,
                             e_so[0], e_so[1], e_so[2], e_so[3], e_a, e_m);
            end
        end
        $display("lockstep: %0d samples, %0d differ; longest sample %0d clocks", lines, bad, busy_max);
        $display(bad == 0 ? "PASS" : "FAIL");
        $finish;
    end
    if( !$value$plusargs("EVENTS=%s", ev) ) ev = "events.txt";
    void'($value$plusargs("LAT=%d", lat));
    void'($value$plusargs("MAXCLK=%d", maxclk));
    fd = $fopen(ev, "r");
    if( fd == 0 ) $fatal(1, "no %s", ev);
    repeat(8) @(posedge clk);
    rst <= 0;
    while( !$feof(fd) ) begin
        r = $fscanf(fd, "%d %d %h\n", t, kind, val);
        if( r != 3 ) break;
        if( t > maxclk ) break;
        while( now < t ) @(posedge clk);
        case( kind )
        0: begin h_ctrl <= val[7:0]; h_ctrl_wr <= 1; @(posedge clk); h_ctrl_wr <= 0; end
        1: begin h_din <= val[7:0]; h_wr <= 1; @(posedge clk); h_wr <= 0; end
        2: begin
            h_rd <= 1; @(posedge clk); h_rd <= 0; @(posedge clk);
            rd_n++;
            if( h_dout !== val[7:0] ) begin
                rd_bad++;
                if( rd_bad <= 20 ) $display("clk %0d: data read RTL %02x MAME %02x", t, h_dout, val[7:0]);
            end else if( rd_n <= 40 ) $display("clk %0d: data read %02x ok", t, h_dout);
        end
        3: begin
            st_n++;
            // dready and empty; pc0 is where the program happens to be
            if( (status & 3'b101) !== (val[2:0] & 3'b101) ) begin
                if( (status & 3'b101) != st_last_bad ) begin
                    st_bad++;
                    if( st_bad <= 20 ) $display("clk %0d: status RTL %0x MAME %0x", t, status, val[2:0]);
                end
                st_last_bad = status & 3'b101;
            end else st_last_bad = 3'b111;
        end
        endcase
    end
    $display("data reads %0d, mismatched %0d; status reads %0d, mismatch runs %0d; samples %0d, overruns %0d, longest sample %0d clocks",
             rd_n, rd_bad, st_n, st_bad, dut.smps, dut.ovr, dut.smp_max);
    $display(rd_bad == 0 ? "PASS" : "FAIL");
    $finish;
end

endmodule
