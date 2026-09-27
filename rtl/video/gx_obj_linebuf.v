/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX sprite line buffer: a solid plane and a shadow plane, each with a
 * per-pixel key compare.
 *
 * The drop-in for jtframe_obj_buffer (jotego/jtcores, GPL-3.0-or-later) that
 * jtframe_objdraw_gate instantiates when KEYW > 0. Same ports and the same
 * double-line, read-then-erase behaviour. What it adds:
 *
 *   ORDER. A pixel is written only over a blank one or one whose key is
 *   greater, so the lowest key wins and, among equal keys, the first
 *   written. For solid pixels the key is {z-code, priority}: MAME's
 *   konamigx_mixer order when the list is drawn in RAM order
 *   (docs/MAME_KLUDGES.md).
 *
 *   TWO PLANES. MAME draws a sprite's shadow as a separate object with its
 *   own z-buffer and its own priority (SHAD1_PRI...), so a shadow pen must
 *   not displace a solid pixel. The solid plane keeps the winning solid
 *   pixel; the shadow plane keeps one shadow pixel. Which one is the
 *   OPPOSITE of the solid rule: MAME draws back to front and its shadow
 *   z-buffer lets the first shadow drawn stand -- a later one at the same
 *   shadow priority is skipped -- so the one kept is the HIGHEST
 *   {shadow priority, z-code}, a later sprite winning a tie (the highest
 *   RAM offset). MAME can also stack a second shadow of lower priority on a
 *   pixel; this keeps one, and no capture so far stacks two
 *   (docs/ROADMAP.md).
 *
 * WHY NOT jtframe_obj_buffer's KEEP_OLD PATH: that shares one RAM port
 * between reading the old pixel and writing the new one, so each pixel takes
 * two clocks, and on daiskiss frame 4800 (145 sprites) jt053246_scan ran out
 * of line time on 94 lines. Here each line half of each plane is its own RAM:
 * the half being drawn uses its read port for the compare and its write port
 * for the result, one pixel per clock; the half being shown uses them to read
 * out and erase.
 *
 * INPUT word (wr_data), written by gx_obj.v for every drawn pixel:
 *   [7:0] pen  [9:8] shadow code  [11:10] shadow mode (0 none, 1 = the
 *   shadow pen is shadow, 2 = every pen is shadow)  [12] mode1 (the shadow
 *   pen is not solid)  [13] solid  [21:14] colour  [29:22] sprite index
 *   [37:30] shadow priority  [45:38] priority  [53:46] z-code  [61:54] the
 *   layout's shadow pen (2^bpp - 1: 31 at 5 bpp, 255 at 8)  [62] the shadow
 *   code is one SHD PRI SEL defers (MAME 5c75784 draws those after every
 *   other shadow, so a stored shadow that is not deferred stands against one
 *   that is, and replaces one that is)
 * OUTPUT word (rd_data):
 *   solid  [7:0] pen [15:8] colour [23:16] index [31:24] priority [39:32] z
 *   shadow [47:40] z [55:48] shadow priority [63:56] index [65:64] code
 *          [66] every-pen mode [67] valid
 *
 * Timing: the compare is one clock behind the write request, so a write
 * decided on the previous clock to the same address is forwarded -- the RAM
 * returns the old data on a read-during-write.
 */

module gx_obj_linebuf #(parameter
    DW        = 75,
    AW        = 10,
    ALPHAW    = 5,     // unused: the pen width is fixed by the layout above
    ALPHA     = 0,
    KEYW      = 16,    // unused beyond selecting this buffer (see jtframe_objdraw_gate)
    BLANK_DLY = 2
)(
    input               clk,
    input               LHBL,
    // new line: a pixel at wr_addr, and with we2 a second at wr_addr + 1
    // (jtframe_draw's PAIR)
    input      [DW-1:0] wr_data,
    input      [AW-1:0] wr_addr,
    input               we,
    input      [DW-1:0] wr_data2,
    input               we2,
    // previous line: read and erase
    input      [AW-1:0] rd_addr,
    input               rd,
    output reg [DW-1:0] rd_data
);

// Two banks, the even addresses and the odd: two pixels a clock are always
// one of each, so each bank takes at most one write a clock through the
// compare pipeline gx_obj_linebank holds.

localparam SW = 40, HW = 29;   // stored solid and shadow words

reg line = 0, last_LHBL = 0;

always @(posedge clk) begin
    last_LHBL <= LHBL;
    if( !LHBL && last_LHBL ) line <= ~line;
end

// ---- decode a request
function [SW+HW+1:0] decode( input [DW-1:0] d, input w );
    reg [7:0] pen, shpen;
    reg [1:0] shcode, shmode;
    reg       mode1, solid, defer, is_shpen;
    begin
        pen    = d[7:0];   shcode = d[9:8];   shmode = d[11:10];
        mode1  = d[12];    solid  = d[13];    shpen  = d[61:54];   defer = d[62];
        is_shpen = (shmode==2'd1 && pen==shpen) || (shmode==2'd2 && pen!=8'd0);
        decode = { w && solid && pen!=8'd0 && !(mode1 && pen==shpen),         // solid request
                   w && shmode!=2'd0 && is_shpen,                              // shadow request
                   d[53:46], d[45:38], d[29:22], d[21:14], pen,               // { z, pri, idx, colour, pen }
                   defer, 1'b1, shmode==2'd2, shcode, d[29:22], d[37:30], d[53:46] };  // shadow word
    end
endfunction

wire [SW+HW+1:0] q0 = decode( wr_data,  we  );
wire [SW+HW+1:0] q1 = decode( wr_data2, we2 );
wire [AW-1:0]    wa1 = wr_addr + 1'd1;

// each bank takes the request whose address has its parity
wire             p0_even = !wr_addr[0];
wire [SW+HW+1:0] qe = p0_even ? q0 : q1;
wire [SW+HW+1:0] qo = p0_even ? q1 : q0;
wire [AW-2:0]    ae = p0_even ? wr_addr[AW-1:1] : wa1[AW-1:1];
wire [AW-2:0]    ao = p0_even ? wa1[AW-1:1]     : wr_addr[AW-1:1];

// ---- read-out and erase, as jtframe_obj_buffer, from the bank rd_addr names
reg  [BLANK_DLY-1:0] dly = 0;
wire                 del = dly[0];
wire [SW-1:0] se, so;
wire [HW-1:0] he, ho;

gx_obj_linebank #(.AW(AW-1), .SW(SW), .HW(HW)) u_even (
    .clk(clk), .line(line), .req_s(qe[SW+HW+1]), .req_h(qe[SW+HW]), .s_word(qe[SW+HW-1:HW]), .h_word(qe[HW-1:0]),
    .wa(ae), .ra(rd_addr[AW-1:1]), .erase(del && !rd_addr[0]), .sq(se), .hq(he) );
gx_obj_linebank #(.AW(AW-1), .SW(SW), .HW(HW)) u_odd (
    .clk(clk), .line(line), .req_s(qo[SW+HW+1]), .req_h(qo[SW+HW]), .s_word(qo[SW+HW-1:HW]), .h_word(qo[HW-1:0]),
    .wa(ao), .ra(rd_addr[AW-1:1]), .erase(del && rd_addr[0]), .sq(so), .hq(ho) );

always @(posedge clk) begin
    dly <= rd ? { 1'b1, {BLANK_DLY-1{1'b0}} } : dly >> 1;
    if( del ) rd_data <= { {DW-SW-HW+1{1'b0}}, rd_addr[0] ? ho[27:0] : he[27:0], rd_addr[0] ? so : se };
end

endmodule

// One bank of the line buffer: both line halves of both planes, the compare
// against what is there (a solid pixel over a blank one or a greater key; a
// shadow as the header describes), forwarded when the previous clock wrote
// the same address -- the RAM returns the old data on a read-during-write.
// The half being drawn uses its read port for the compare and its write
// port for the result; the half being shown uses them to read out (sq, hq,
// a clock after ra) and, with erase, to clear what was read.
module gx_obj_linebank #(parameter AW = 9, SW = 40, HW = 29) (
    input               clk,
    input               line,
    input               req_s,
    input               req_h,
    input      [SW-1:0] s_word,
    input      [HW-1:0] h_word,
    input      [AW-1:0] wa,
    input      [AW-1:0] ra,
    input               erase,
    output     [SW-1:0] sq,
    output     [HW-1:0] hq
);

reg  [AW-1:0] a1, a2;
reg  [SW-1:0] sd1, sd2;
reg  [HW-1:0] hd1, hd2;
reg           sv1, hv1, h1, sw2, hw2, hh2;
wire [SW-1:0] sq0, sq1;
wire [HW-1:0] hq0, hq1;

// solid plane: old word, forwarded if written on the previous clock
wire [SW-1:0] s_old   = ( sw2 && hh2==h1 && a2==a1 ) ? sd2 : ( h1 ? sq1 : sq0 );
wire          s_blank = s_old[7:0] == 8'd0;
wire          s_wr    = sv1 && ( s_blank || sd1[39:24] < s_old[39:24] );   // {z, pri}

// shadow plane
wire [HW-1:0] h_old   = ( hw2 && hh2==h1 && a2==a1 ) ? hd2 : ( h1 ? hq1 : hq0 );
wire          h_blank = !h_old[27];
wire          h_wr    = hv1 && ( h_blank || ( h_old[28] && !hd1[28] )
                              || ( h_old[28] == hd1[28] && { hd1[15:8], hd1[7:0] } >= { h_old[15:8], h_old[7:0] } ) ); // {spri, z}

always @(posedge clk) begin
    a1  <= wa;
    sd1 <= s_word;
    hd1 <= h_word;
    sv1 <= req_s;
    hv1 <= req_h;
    h1  <= line;
    a2  <= a1;
    sd2 <= sd1;
    hd2 <= hd1;
    sw2 <= s_wr;
    hw2 <= h_wr;
    hh2 <= h1;
end

assign sq = line ? sq0 : sq1;       // the half being shown
assign hq = line ? hq0 : hq1;

// half h: drawn while line==h, shown while line!=h
wire s0 = s_wr && !h1, s1 = s_wr && h1;
wire g0 = h_wr && !h1, g1 = h_wr && h1;

gx_sdpram #(.AW(AW), .DW(SW)) u_solid0 (
    .clk ( clk ), .we ( s0 || ( line && erase ) ), .wa ( s0 ? a1 : ra ),
    .d ( s0 ? sd1 : {SW{1'b0}} ), .ra ( !line ? wa : ra ), .q ( sq0 ) );
gx_sdpram #(.AW(AW), .DW(SW)) u_solid1 (
    .clk ( clk ), .we ( s1 || ( !line && erase ) ), .wa ( s1 ? a1 : ra ),
    .d ( s1 ? sd1 : {SW{1'b0}} ), .ra ( line ? wa : ra ), .q ( sq1 ) );
gx_sdpram #(.AW(AW), .DW(HW)) u_shadow0 (
    .clk ( clk ), .we ( g0 || ( line && erase ) ), .wa ( g0 ? a1 : ra ),
    .d ( g0 ? hd1 : {HW{1'b0}} ), .ra ( !line ? wa : ra ), .q ( hq0 ) );
gx_sdpram #(.AW(AW), .DW(HW)) u_shadow1 (
    .clk ( clk ), .we ( g1 || ( !line && erase ) ), .wa ( g1 ? a1 : ra ),
    .d ( g1 ? hd1 : {HW{1'b0}} ), .ra ( line ? wa : ra ), .q ( hq1 ) );

endmodule
