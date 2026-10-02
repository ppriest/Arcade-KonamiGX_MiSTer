// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/cpu/gx_ss_m68k.sv (M020 = 0) against fx68k: the save-state stub's
// capture and restore, self-checking. The bus handshake is gx_sound's: an
// access is served once and DTACK held until AS goes away; the acknowledge
// is answered by VPA.
//     scripts/run_verilator.sh gx_ss_fx_tb             all three tests
//     scripts/run_verilator.sh gx_ss_fx_tb +LOG=1      and every access
//
// A  capture and resume at several points of a loop storing D0 through
//    (A1)+: the stores stay one sequence and the bank holds D0/A1.
// B  a load: the bank is overwritten while held, and the loop continues
//    from it.
// C  STOP: taken while waiting in STOP, back in STOP after, woken by the
//    next level 1.
// The only write of the sequence that reaches memory is the PC-low push,
// at SSP - 2.
`timescale 1ns/1ps

module tb_gx_ss_fx;

logic clk = 0, rst = 1;
always #5 clk = ~clk;

byte unsigned mem [0:65535];

logic ph = 0;
always @(posedge clk) ph <= rst ? 1'b0 : ~ph;
wire en_phi1 = !rst && !ph, en_phi2 = !rst && ph;

wire        as_n, rw_n, uds_n, lds_n, fc0, fc1, fc2, stop;
wire [23:1] eab;
wire [15:0] dout;
wire [ 2:0] fc = {fc2, fc1, fc0};
wire [31:0] a32 = {8'd0, eab, 1'b0};
logic       irq1 = 0;
logic [15:0] cpu_din = 0;
logic       acc_ready = 0;
wire        in_iack = !as_n && fc == 3'b111;
wire        dtack_n = !(acc_ready && !as_n && !in_iack);
wire [15:0] a = a32[15:0];
wire [15:0] mem_q = {mem[a], mem[a + 1]};

logic        req = 0, go = 0;
logic [4:0]  b_idx = 0;
logic        b_we = 0;
logic [31:0] b_d = 0, b_q;
wire         ss_hit, ss_rdy, ss_held, ss_done, ss_ipl7;
wire  [15:0] ss_din;
wire  [ 2:0] ipl_n = ss_ipl7 ? 3'b000 : irq1 ? 3'b110 : 3'b111;

wire acc_active  = !as_n && !in_iack && !(uds_n && lds_n);
wire cpu_req_now = acc_active && !acc_ready;

fx68k u_cpu (
    .clk(clk), .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n), .E(), .VMAn(),
    .FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtack_n), .VPAn(!in_iack), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
    .iEdb(cpu_din), .oEdb(dout), .eab(eab), .stop_out(stop)
);

gx_ss_m68k #(.M020(0)) u_ss (
    .clk(clk), .rst(rst),
    .acc(acc_active), .take(cpu_req_now && (!ss_hit || ss_rdy)), .a32(a32), .wr(!rw_n),
    .fc(fc), .dout(dout), .iack7(in_iack && eab[3:1] == 3'd7), .stop_in(stop),
    .req(req), .ipl7(ss_ipl7), .hit(ss_hit), .rdy(ss_rdy), .din(ss_din),
    .held(ss_held), .go(go), .done(ss_done),
    .b_idx(b_idx), .b_we(b_we), .b_d(b_d), .b_q(b_q)
);

int log_on = 0, fails = 0, leaks = 0, pushes = 0;
int unsigned st_a [$], st_d [$];
logic [15:0] hi_w;
logic iack_l = 0;

always @(posedge clk) begin
    iack_l <= in_iack;
    if (in_iack && !iack_l && eab[3:1] == 3'd1) irq1 <= 0;
    if (as_n) acc_ready <= 0;
    else if (cpu_req_now) begin
        if (ss_hit) begin
            if (ss_rdy) begin cpu_din <= ss_din; acc_ready <= 1; end
        end else begin
            cpu_din <= mem_q; acc_ready <= 1;
            if (a32[23:16] != 0) begin
                leaks++;
                $display("LEAK: %s %06x reached memory", rw_n ? "read" : "write", a32);
            end
            if (!rw_n) begin
                if (!uds_n) mem[a] <= dout[15:8];
                if (!lds_n) mem[a + 1] <= dout[7:0];
                if (a == 16'h7FFE) pushes++;
                if (a >= 16'h2000 && a < 16'h7F00) begin
                    if (!a[1]) hi_w <= dout;
                    else begin st_a.push_back({a[15:2], 2'b00}); st_d.push_back({hi_w, dout}); end
                end
            end
        end
        if (log_on != 0 && (!ss_hit || ss_rdy))
            $display("%s%s fc%0d %06x %04x", ss_hit ? "*" : " ", rw_n ? "R" : "W", fc, a32,
                     rw_n ? (ss_hit ? ss_din : mem_q) : dout);
    end
end

task automatic w16(input int ad, input int v);
    mem[ad] = v[15:8]; mem[ad + 1] = v[7:0];
endtask
task automatic w32(input int ad, input int v);
    w16(ad, v >>> 16); w16(ad + 2, v & 16'hFFFF);
endtask

task automatic check(input bit ok, input string what);
    if (!ok) begin fails++; $display("FAIL %s", what); end
endtask
task automatic bank_rd(input int i, output int unsigned v);
    b_idx = i[4:0]; #1; v = b_q;
endtask
task automatic bank_wr(input int i, input int unsigned v);
    @(negedge clk) begin b_idx = i[4:0]; b_d = v; b_we = 1; end
    @(negedge clk) b_we = 0;
endtask
task automatic take();
    int t = 0;
    @(negedge clk) req = 1;
    @(negedge clk) req = 0;
    while (!ss_held) begin @(posedge clk); t++; if (t > 4000) $fatal(1, "never held"); end
endtask
task automatic release_cpu();
    int t = 0;
    @(negedge clk) go = 1;
    @(negedge clk) go = 0;
    while (!ss_done) begin @(posedge clk); t++; if (t > 4000) $fatal(1, "never done"); end
endtask
task automatic check_run(input int from, input string what);
    for (int i = from + 1; i < st_a.size(); i++)
        if (st_a[i] != st_a[i - 1] + 4 || st_d[i] != st_d[i - 1] + 1) begin
            check(0, $sformatf("%s: store %0d %08x=%08x after %08x=%08x", what, i,
                  st_a[i], st_d[i], st_a[i - 1], st_d[i - 1]));
            break;
        end
endtask

int unsigned d0, a1, pc, sr, a7, flags;

initial begin
    int p, n0;
    void'($value$plusargs("LOG=%d", log_on));
    foreach (mem[i]) mem[i] = 0;
    w32(0, 32'h00008000);
    w32(4, 32'h00000400);
    w32(32'h64, 32'h00000620);
    w32(32'h7C, 32'h00000600);
    w16(32'h600, 16'h4AFC);
    w16(32'h620, 16'h4E73);
    p = 32'h400;
    w16(p, 16'h203C); w32(p + 2, 32'h11111111); p += 6;
    w16(p, 16'h227C); w32(p + 2, 32'h00002000); p += 6;
    w16(p, 16'h46FC); w16(p + 2, 16'h2000); p += 4;
    w16(p, 16'h5280); p += 2;                              // 410 ADDQ.L #1,D0
    w16(p, 16'h22C0); p += 2;                              // 412 MOVE.L D0,(A1)+
    w16(p, 16'h60FA);                                      // 414 BRA.S 410
    repeat (4) @(posedge clk);
    rst = 0;

    for (int k = 0; k < 6; k++) begin
        repeat (197 + 29 * k) @(posedge clk);
        take();
        n0 = st_a.size();
        repeat (60) @(posedge clk);
        bank_rd(0, d0); bank_rd(9, a1); bank_rd(20, pc); bank_rd(19, sr);
        bank_rd(18, a7); bank_rd(22, flags);
        check(a7 == 32'h7FFA, $sformatf("A%0d A7 in the stub %08x", k, a7));
        check(sr == 32'h2000, $sformatf("A%0d SR %04x", k, sr));
        check(flags == 0, $sformatf("A%0d stopped %0d", k, flags));
        check(pc >= 32'h410 && pc <= 32'h414, $sformatf("A%0d PC %08x", k, pc));
        check(st_a.size() == n0, $sformatf("A%0d stores while held", k));
        check(st_a[$] == a1 - 4 && (st_d[$] == d0 || st_d[$] == d0 - 1),
              $sformatf("A%0d bank D0 %08x A1 %08x, last store %08x=%08x", k, d0, a1, st_a[$], st_d[$]));
        release_cpu();
    end
    repeat (400) @(posedge clk);
    check_run(0, "A");
    check(pushes == 6, $sformatf("A: %0d PC-low pushes reached memory, 6 expected", pushes));
    $display("A: %0d stores, 6 captures", st_a.size());

    take();
    bank_wr(0, 32'h50000000); bank_wr(9, 32'h3000);
    n0 = st_a.size();
    release_cpu();
    repeat (400) @(posedge clk);
    check(st_a[n0] == 32'h3000 && (st_d[n0] == 32'h50000000 || st_d[n0] == 32'h50000001),
          $sformatf("B first store %08x=%08x", st_a[n0], st_d[n0]));
    check_run(n0, "B");
    take();
    bank_wr(0, 32'h70000000); bank_wr(9, 32'h5000); bank_wr(20, 32'h410); bank_wr(19, 32'h2000);
    n0 = st_a.size();
    release_cpu();
    repeat (400) @(posedge clk);
    check(st_a[n0] == 32'h5000 && st_d[n0] == 32'h70000001,
          $sformatf("B PC load: first store %08x=%08x", st_a[n0], st_d[n0]));
    check_run(n0, "B PC");
    $display("B: loads continue from the bank");

    take();
    p = 32'h500;
    w16(p, 16'h4E72); w16(p + 2, 16'h2000);                // 500 STOP #$2000
    w16(p + 4, 16'h5282);                                  // 504 ADDQ.L #1,D2
    w16(p + 6, 16'h24C2);                                  // 506 MOVE.L D2,(A2)+
    w16(p + 8, 16'h60F6);                                  // 508 BRA.S 500
    bank_wr(2, 32'h0); bank_wr(10, 32'h6000); bank_wr(20, 32'h500); bank_wr(19, 32'h2000);
    release_cpu();
    while (!stop) @(posedge clk);
    repeat (100) @(posedge clk);
    n0 = st_a.size();
    take();
    bank_rd(22, flags); bank_rd(20, pc);
    check(flags == 1, $sformatf("C stopped %0d", flags));
    check(pc == 32'h504, $sformatf("C PC %08x (past the STOP)", pc));
    release_cpu();
    repeat (200) @(posedge clk);
    check(stop == 1, "C back in STOP");
    check(st_a.size() == n0, "C a store without an interrupt");
    @(negedge clk) irq1 = 1;
    repeat (400) @(posedge clk);
    check(st_a.size() == n0 + 1 && st_a[n0] == 32'h6000 && st_d[n0] == 1,
          $sformatf("C level 1 wakes it: %0d stores", st_a.size() - n0));
    check(stop == 1, "C waiting again");
    $display("C: STOP kept across a capture");

    check(leaks == 0, $sformatf("%0d accesses reached memory", leaks));
    if (fails != 0) $fatal(1, "%0d check(s) FAILED", fails);
    $display("ALL PASS");
    $finish;
end

endmodule
