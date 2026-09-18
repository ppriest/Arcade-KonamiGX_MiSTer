/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX sprite line buffer with a per-pixel key compare.
 *
 * The drop-in for jtframe_obj_buffer (jotego/jtcores, GPL-3.0-or-later) that
 * jtframe_objdraw_gate instantiates when KEYW > 0. Same ports and the same
 * double-line, read-then-erase behaviour; what it adds is the ordering rule:
 * a pixel is written only over a blank one or one whose key -- the top KEYW
 * bits of the data, {z-code, priority} for GX -- is greater. So the lowest
 * key wins and, among equal keys, the first written: MAME's konamigx_mixer
 * order when the list is drawn in RAM order (docs/MAME_KLUDGES.md).
 *
 * WHY NOT jtframe_obj_buffer's KEEP_OLD PATH: that shares one RAM port
 * between reading the old pixel and writing the new one, so each pixel takes
 * two clocks. On daiskiss frame 4800 (145 sprites) jt053246_scan then ran out
 * of line time on 94 lines. Here each line half is its own RAM: the half
 * being drawn uses its read port for the compare and its write port for the
 * result, one pixel per clock; the half being shown uses them to read out and
 * erase.
 *
 * Timing: the compare is one clock behind the write request (stage 1), so a
 * write decided on the previous clock to the same address is forwarded --
 * the RAM returns the old data on a read-during-write.
 */

module gx_obj_linebuf #(parameter
    DW        = 8,
    AW        = 9,
    ALPHAW    = 4,
    ALPHA     = 0,
    KEYW      = 8,
    BLANK_DLY = 2
)(
    input               clk,
    input               LHBL,
    // new line
    input      [DW-1:0] wr_data,
    input      [AW-1:0] wr_addr,
    input               we,
    // previous line: read and erase
    input      [AW-1:0] rd_addr,
    input               rd,
    output reg [DW-1:0] rd_data
);

reg line = 0, last_LHBL = 0;

always @(posedge clk) begin
    last_LHBL <= LHBL;
    if( !LHBL && last_LHBL ) line <= ~line;
end

// stage 1: the request of the previous clock, and the RAM word it read
reg  [AW-1:0] a1, a2;
reg  [DW-1:0] d1, d2;
reg           v1, h1, w2, h2;
wire [DW-1:0] q0, q1;
wire [DW-1:0] qdraw   = h1 ? q1 : q0;
wire [DW-1:0] old     = ( w2 && h2==h1 && a2==a1 ) ? d2 : qdraw;
wire          old_blk = old[ALPHAW-1:0] == ALPHA[ALPHAW-1:0];
wire          wr_now  = v1 && ( old_blk || d1[DW-1-:KEYW] < old[DW-1-:KEYW] );

always @(posedge clk) begin
    a1 <= wr_addr;
    d1 <= wr_data;
    v1 <= we && wr_data[ALPHAW-1:0] != ALPHA[ALPHAW-1:0];
    h1 <= line;
    a2 <= a1;
    d2 <= d1;
    w2 <= wr_now;
    h2 <= h1;
end

// read-out and erase, as jtframe_obj_buffer
reg  [BLANK_DLY-1:0] dly = 0;
wire                 del = dly[0];

always @(posedge clk) begin
    dly <= rd ? { 1'b1, {BLANK_DLY-1{1'b0}} } : dly >> 1;
    if( del ) rd_data <= line ? q0 : q1;
end

// half h: drawn while line==h, shown while line!=h
wire draw0 = wr_now && !h1, draw1 = wr_now && h1;

gx_sdpram #(.AW(AW), .DW(DW)) u_half0 (
    .clk ( clk ),
    .we  ( draw0 || ( line && del ) ),
    .wa  ( draw0 ? a1 : rd_addr ),
    .d   ( draw0 ? d1 : {DW{1'b0}} ),
    .ra  ( !line ? wr_addr : rd_addr ),
    .q   ( q0 )
);

gx_sdpram #(.AW(AW), .DW(DW)) u_half1 (
    .clk ( clk ),
    .we  ( draw1 || ( !line && del ) ),
    .wa  ( draw1 ? a1 : rd_addr ),
    .d   ( draw1 ? d1 : {DW{1'b0}} ),
    .ra  ( line ? wr_addr : rd_addr ),
    .q   ( q1 )
);

endmodule
