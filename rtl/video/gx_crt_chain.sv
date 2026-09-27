// SPDX-License-Identifier: GPL-3.0-or-later
//
// CRT Adjust: native raster -> crt_vsize (V-Size) -> crt_adjust (H-Position,
// V-Shift, H-Size) -> arcade_video. Passthrough while `active` is low.
// Arcade-Psikyo_MiSTer's rtl/video/crt_chain.sv, with GX's differences:
//   * the dot clock is set by the game (control_w's pixclock: 6, 8, 12 or
//     16 MHz on the 48 MHz clk), so the clocks a pixel are an input; H-Size
//     counts in eighths of a clock, which is Psikyo's +-31% at 8 MHz and
//     +-23% at 6 MHz;
//   * Cabinet mode needs 8 clocks a pixel (crt_vsize), so only the 6 MHz
//     sets have it: at 8 MHz and up, V-Size in Cabinet mode stays at 0;
//   * V-Size moves 2 lines a step, not 3, so the ring is 32 lines (30 M10K
//     at 384 wide) instead of 46: the block RAM left is what bounds it.

module gx_crt_chain #(
    parameter int VTOTAL   = 264,       // MAME's set_raw, and daiskiss's K053252 (ROADMAP)
    parameter int ACTIVE_W = 384,
    parameter int VSTEP    = 2,         // lines per V-Size step
    parameter int RING     = 32,        // crt_vsize ring: |vsize| <= RING/2 - 2
    parameter int PVM_FREE_LINES = 17   // lines after the picture PVM mode can drop, + 1
) (
    input  logic              clk,
    input  logic              ce_pix,
    input  logic        [3:0] pxl_div,  // clk per pixel

    input  logic              active,
    input  logic              scale_en,
    input  logic signed [8:0] hoffset,
    input  logic signed [5:0] voffset,
    input  logic signed [4:0] hsize,
    input  logic signed [3:0] vsize_step,
    input  logic              vsize_cabinet,

    input  logic [7:0]        r_in, g_in, b_in,
    input  logic              hs_in, vs_in, hb_in, vb_in,

    output logic              ce_out,
    output logic [7:0]        r_out, g_out, b_out,
    output logic              hs_out, vs_out, hb_out, vb_out
);

    wire scaling = active & scale_en;
    wire tube_ok = pxl_div >= 4'd8;

    // crt_vsize's +N means shorter, so negate.
    logic signed [5:0] vsize = 6'sd0;
    logic              cabinet = 1'b0;
    always_ff @(posedge clk) if (ce_pix) begin
        vsize   <= scaling && (tube_ok || !vsize_cabinet)
                 ? -(6'(VSTEP) * $signed({{2{vsize_step[3]}}, vsize_step})) : 6'sd0;
        cabinet <= vsize_cabinet;
    end

    // PVM mode drops lines from the end of the frame; past the lines after
    // the picture it would cut the bottom, so the VSync crt_vsize sees is
    // delayed and the dropped lines come out of the back porch instead.
    localparam int                VMAX        = 7 * VSTEP;
    localparam logic signed [6:0] PVM_MARGIN  = 7'(PVM_FREE_LINES - 1);
    localparam int                PVM_DLY_MAX = (VMAX - (PVM_FREE_LINES - 1)) > 1
                                              ? (VMAX - (PVM_FREE_LINES - 1)) : 1;

    logic                   hs_nat_d = 1'b0;
    logic [PVM_DLY_MAX-1:0] vs_lines = '0;
    always_ff @(posedge clk) if (ce_pix) begin
        hs_nat_d <= hs_in;
        if (hs_in & ~hs_nat_d) vs_lines <= { vs_lines, vs_in };
    end

    wire signed [6:0] pvm_need = -$signed({vsize[5], vsize}) - PVM_MARGIN;
    wire        [4:0] pvm_dly  = (!cabinet && pvm_need > 0) ? pvm_need[4:0] : 5'd0;
    wire              vs_pre   = (pvm_dly == 0) ? vs_in : vs_lines[pvm_dly - 1'd1];

    logic [7:0] vz_r, vz_g, vz_b;
    logic       vz_hs, vz_vs, vz_de, vz_vb, vz_ce;

    crt_vsize #(
        .RING_LINES(RING),
        .LINE_PX   (ACTIVE_W)
    ) u_crt_vsize (
        .clk      (clk),
        .pxl_cen  (ce_pix),
        .active   (scaling),
        .tube_mode(cabinet),
        .vsize    (vsize),
        .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .hs_in(hs_in), .vs_in(vs_pre),
        .de_in(~(hb_in | vb_in)),
        .vb_in(vb_in),
        .r_out(vz_r), .g_out(vz_g), .b_out(vz_b),
        .hs_out(vz_hs), .vs_out(vz_vs), .de_out(vz_de), .vb_out(vz_vb),
        .ce_out(vz_ce)
    );

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
    // line, which lines up only when VBlank changes before HSync: GX's own
    // raster does (at the end of the visible line), crt_vsize's output does
    // not (just after HSync), and there it lost the first picture line and
    // opened DE on the line after the last. Psikyo's glue latches vb_out at
    // the output HSync, which hides the extra line but not the lost one.
    // So while active crt_adjust gets no VBlank, and the glue blanks each
    // line it reads out by whether that line had DE when written.
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
