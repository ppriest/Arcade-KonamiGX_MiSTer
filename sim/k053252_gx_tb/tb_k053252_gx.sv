// SPDX-License-Identifier: GPL-3.0-or-later
//
// jtk053252 programmed with the registers daiskiss writes (captured from MAME,
// identical on every captured frame), and its outputs measured: line length,
// visible width, front porch, hsync width, back porch; the same vertically.
// MAME's decoding of the same registers (k053252_device::res_change) is
// 384 x 264 total and a 288 x 224 visible area; it names the rest
// front porch / sync / back porch 16 / 32 / 48 and 17 / 8 / 15, but never
// generates sync. Run: scripts/run_verilator.sh k053252_gx_tb, with
// debug/k053252_gx_tb/regs.hex holding the 16 registers (register n is byte
// 2n of a capture's reg_k053252.bin).
//
// 48 MHz clock, 6 MHz pixel enable (wrport2 & 3 == 0: pixclock[0]).

`timescale 1ns/1ps

module tb_k053252_gx;

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

reg [2:0] cnt = 0;
reg       pxl_cen = 0;
always @(posedge clk) begin
    cnt     <= cnt + 3'd1;
    pxl_cen <= cnt == 0;
end

reg        cs = 0;
reg  [3:0] addr;
reg  [7:0] din;
wire       lhbl, lvbl, hs, vs, int1, int2;

jtk053252 dut (
    .rst, .clk, .pxl_cen, .sel(3'd0), .vldi(1'b1), .hldi(1'b1),
    .cs, .addr, .rnw(1'b0), .din, .dout(),
    .lhbl, .lvbl, .hs, .vs, .int1, .int2, .hld(), .vld(), .lhbs(),
    .ioctl_addr(4'd0), .ioctl_din()
);

reg [7:0] regs [16];

// per line: pixels from one lhbl rise to the next, and the positions of the
// lhbl fall, hs rise and hs fall relative to the lhbl rise
int px, line_len, vis, hs_on, hs_off, fp, sw, bp;
reg lhbl_l, hs_l, lvbl_l, vs_l, lvbl_px_l = 0, vs_px_l = 0;
int lines, vlines, vis_lines, vs_on, vs_off;
int report = 0;

int ln = 0, lvbl_rise = 0, lvbl_fall = 0, vs_rise = 0, vs_fall = 0, prev_rise = 0, vtotal = 0;
always @(posedge clk) if (pxl_cen && !rst) begin
    lhbl_l <= lhbl; hs_l <= hs;
    px <= px + 1;
    if (lhbl && !lhbl_l) begin
        line_len <= px + 1; px <= 0;
        ln = ln + 1;                       // one running line count
        lvbl_l <= lvbl; vs_l <= vs;
        if (lvbl && !lvbl_l) begin vtotal <= ln - lvbl_rise; lvbl_rise <= ln; end
        if (!lvbl && lvbl_l) lvbl_fall <= ln;
        if (vs && !vs_l) vs_rise <= ln;
        if (!vs && vs_l) vs_fall <= ln;
    end
    if (!lhbl && lhbl_l) vis <= px + 1;
    lvbl_px_l <= lvbl;
    if (lvbl != lvbl_px_l) $display("LVBL %s at pixel %0d of the line (0 = first visible)", lvbl ? "rises" : "falls", px + 1);
    vs_px_l <= vs;
    if (vs != vs_px_l) $display("VS %s at pixel %0d", vs ? "rises" : "falls", px + 1);
    if (hs && !hs_l) hs_on <= px + 1;
    if (!hs && hs_l) hs_off <= px + 1;
end

initial begin
    $readmemh("debug/k053252_gx_tb/regs.hex", regs);
    px = 0; lines = 0;
    repeat (16) @(posedge clk);
    rst <= 0;
    for (int i = 0; i < 16; i++) begin
        @(posedge clk) begin cs <= 1; addr <= i[3:0]; din <= regs[i]; end
        @(posedge clk) cs <= 0;
        repeat (8) @(posedge clk);
    end
    // three frames to settle, then report
    repeat (3) @(posedge lvbl);
    @(negedge lvbl);
    @(posedge vs);
    @(negedge vs);
    @(posedge lvbl);
    repeat (4) @(posedge lhbl);
    $display("H total %0d visible %0d front_porch %0d hsync %0d back_porch %0d",
             line_len, vis, hs_on - vis, hs_off - hs_on, line_len - hs_off);
    // lines are counted at lhbl rises. At this point the latest events are,
    // in order: lvbl fall F (previous frame), vs rise, vs fall, lvbl rise R.
    begin
        int vblank;
        vblank = lvbl_rise - lvbl_fall;
        $display("V total %0d visible %0d front_porch %0d vsync %0d back_porch %0d",
                 vtotal, vtotal - vblank, vs_rise - lvbl_fall, vs_fall - vs_rise,
                 lvbl_rise - vs_fall);
        // MAME's k053252_device::res_change for the same registers:
        // 384 x 264 total, 288 x 224 visible
        if (line_len == 384 && vis == 288 && vtotal == 264 && vtotal - vblank == 224)
            $display("PASS: totals and visible area match MAME");
        else
            $display("FAIL: totals or visible area differ from MAME");
    end
    $display("K053252_GX_DONE");
    $finish;
end

endmodule
