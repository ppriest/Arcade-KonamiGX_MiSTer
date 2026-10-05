// SPDX-License-Identifier: GPL-3.0-or-later
//
// CRT Adjust: native raster -> crt_adjust (H-Position, V-Shift, H-Size) ->
// arcade_video. Passthrough while `active` is low.
// Arcade-Psikyo_MiSTer's rtl/video/crt_chain.sv, with GX's differences:
//   * the dot clock is set by the game (control_w's pixclock: 6, 8, 12 or
//     16 MHz on the 48 MHz clk), so the clocks a pixel are an input; H-Size
//     counts in eighths of a clock, which is Psikyo's +-31% at 8 MHz and
//     +-23% at 6 MHz;
//   * no V-Size: its line ring (30 M10K) went to the ESC's local memory.

module gx_crt_chain #(
    parameter int VTOTAL   = 264        // MAME's set_raw, and daiskiss's K053252 (ROADMAP)
) (
    input  logic              clk,
    input  logic              ce_pix,
    input  logic        [3:0] pxl_div,  // clk per pixel

    input  logic              active,
    input  logic              scale_en,
    input  logic signed [8:0] hoffset,
    input  logic signed [5:0] voffset,
    input  logic signed [4:0] hsize,

    input  logic [7:0]        r_in, g_in, b_in,
    input  logic              hs_in, vs_in, hb_in, vb_in,

    output logic              ce_out,
    output logic [7:0]        r_out, g_out, b_out,
    output logic              hs_out, vs_out, hb_out, vb_out
);

    wire scaling = active & scale_en;

    wire [7:0] vz_r = r_in, vz_g = g_in, vz_b = b_in;
    wire       vz_hs = hs_in, vz_vs = vs_in, vz_de = ~(hb_in | vb_in), vz_vb = vb_in, vz_ce = ce_pix;

    // H-Size read rate, in eighths of a clock; must restart on hs_ref_out,
    // not the raw HSync. The period stops at one pixel a clock.
    wire signed [4:0] hsize_eff = scaling ? hsize : 5'sd0;
    wire signed [8:0] rd_sum    = $signed({2'b00, pxl_div, 3'd0}) + {{4{hsize_eff[4]}}, hsize_eff};
    wire        [7:0] rd_period = rd_sum < 9'sd8 ? 8'd8 : rd_sum[7:0];

    logic       hs_ref;
    logic       hs_ref_d = 1'b0;
    logic [7:0] rd_acc = 8'd0;
    wire        rd_tick = (rd_acc + 8'd8) >= rd_period;
    always_ff @(posedge clk) begin
        hs_ref_d <= hs_ref;
        if      (hs_ref & ~hs_ref_d) rd_acc <= 8'd0;
        else if (rd_tick)            rd_acc <= rd_acc + 8'd8 - rd_period;
        else                         rd_acc <= rd_acc + 8'd8;
    end

    assign ce_out = active ? rd_tick : vz_ce;

    logic adj_hb, adj_vb;

    crt_adjust #(
        .VTOTAL   (VTOTAL),
        .HTOTAL   (512),                // HPOS_MODE 1 does not use it
        .HPOS_MODE(1)
    ) u_crt_adjust (
        .clk      (clk),
        .pxl_cen  (vz_ce),
        .pxl2_cen (rd_tick),
        .active   (active),
        .hsize    (hsize_eff),
        .hoffset  (active ? hoffset : 9'sd0),
        .voffset  (active ? voffset : 6'sd0),
        .r_in(vz_r), .g_in(vz_g), .b_in(vz_b),
        .hs_in(vz_hs), .vs_in(vz_vs), .hb_in(~vz_de), .vb_in(active ? 1'b0 : vz_vb),
        .r_out(r_out), .g_out(g_out), .b_out(b_out),
        .hs_out(hs_out), .vs_out(vs_out), .hb_out(adj_hb), .vb_out(adj_vb),
        .hs_ref_out(hs_ref)
    );

    // VBlank. crt_adjust reads out the line before the one it writes. It
    // blanks its DE with its VBlank input sampled at each HSync and held a
    // line, which lines up only when VBlank changes before HSync; a source
    // whose VBlank changes just after HSync loses the first picture line and
    // opens DE on the line after the last. So while active crt_adjust gets
    // no VBlank, and the glue blanks each line it reads out by whether that
    // line had DE when written.
    // The line's VBlank moves at the output HSync, not at hs_ref_out, which
    // leads it: a stretched blank line still reads out in between.
    logic hs_ref_q = 1'b0, had_de = 1'b0, vb_next = 1'b1;
    always_ff @(posedge clk) if (vz_ce) begin
        hs_ref_q <= hs_ref;
        if (hs_ref & ~hs_ref_q) begin
            vb_next <= ~had_de;
            had_de  <= 1'b0;
        end else if (vz_de)
            had_de  <= 1'b1;
    end

    logic hs_out_d = 1'b0, vb_line = 1'b1;
    always_ff @(posedge clk) if (ce_out) begin
        hs_out_d <= hs_out;
        if (hs_out & ~hs_out_d) vb_line <= vb_next;
    end

    // HBlank stays high through a blank line, as crt_adjust's own DE gating
    // kept it (arcade_video latches VBlank at HBlank's fall). Blanking the
    // HSync pulse removes a one-pixel DE stub when a stretched line overruns
    // into the next.
    assign vb_out = active ? vb_line : adj_vb;
    assign hb_out = active ? (adj_hb | hs_out | vb_line) : adj_hb;

endmodule
