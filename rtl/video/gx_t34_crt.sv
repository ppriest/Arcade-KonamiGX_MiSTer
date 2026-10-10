// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Type 3/4 boards' demux for the analog output (docs/TYPE34.md,
// "Screens on MiSTer"). The board draws its two monitors on alternate
// frames, vid_sub saying which; the cabinet's demux board held each
// monitor's picture, so each CRT saw a steady image. Sent as they come, one
// CRT shows the two pictures interleaved at 60 Hz: flicker and a double
// image wherever they differ.
//
// With `en`, the frames of monitor `mon` go out as they come and are stored
// in DDR3, two pixels a 64-bit word, a row of 1024 words a line; the other
// monitor's frames are replaced by the stored picture, a line read into a
// line buffer during the blanking before it. Without `en` the frames go out
// as the board sends them.
//
// DDR3 is shared with gx_t34_fb, whose writes do not wait: a request here is
// made only on a clock that has none of its (other_we), and is held until
// the port takes it. The two never read and write the same frame unless the
// HDMI and analog outputs show different monitors.
module gx_t34_crt (
    input             CLK_VIDEO,
    input             CE_PIXEL,
    input      [ 7:0] VGA_R,
    input      [ 7:0] VGA_G,
    input      [ 7:0] VGA_B,
    input             VGA_VS,
    input             VGA_DE,

    input             vid_sub,      // the frame now being sent is the sub monitor's (clk_sys)
    input             en_in,        // hold one monitor (clk_sys)
    input             mon_in,       // which: 0 main, 1 sub (clk_sys)

    output     [ 7:0] R_OUT,
    output     [ 7:0] G_OUT,
    output     [ 7:0] B_OUT,

    input             DDRAM_BUSY,
    input             other_we,     // gx_t34_fb writes on this clock
    output     [ 7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    output     [63:0] DDRAM_DIN,
    output     [ 7:0] DDRAM_BE,
    output            DDRAM_WE,
    output            DDRAM_RD,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY
);

localparam [6:0] MEM_BASE = 7'b0010011;     // 0x26000000, 8 MB, after gx_t34_fb's
localparam [7:0] BURST    = 8'd64;

reg  [1:0] sub_s, en_s, mon_s;
always @(posedge CLK_VIDEO) begin
    sub_s <= { sub_s[0], vid_sub };
    en_s  <= { en_s[0],  en_in };
    mon_s <= { mon_s[0], mon_in };
end
wire sub = sub_s[1];

// the frame: stored (live) or replaced (rep), decided as it starts.
// idx is the index in its line of the pixel now being sent (if it is an
// active one); nx that of the pixel the next CE_PIXEL starts.
reg        live = 1'b0, rep = 1'b0;
reg  [9:0] ly = 10'd0;                      // the line being sent
reg  [9:0] idx = 10'd0;
wire [9:0] nx = VGA_DE ? idx + 10'd1 : 10'd0;
reg        old_vs, old_de;
reg        rd_go;                           // read line ly now
always @(posedge CLK_VIDEO) begin
    rd_go <= 1'b0;
    if( CE_PIXEL ) begin
        old_vs <= VGA_VS;
        old_de <= VGA_DE;
        idx    <= nx;
        if( ~old_vs & VGA_VS ) begin
            ly    <= 10'd0;
            live  <= en_s[1] && sub == mon_s[1];
            rep   <= en_s[1] && sub != mon_s[1];
            rd_go <= en_s[1] && sub != mon_s[1];
        end
        if( old_de & ~VGA_DE ) begin
            ly    <= ly + 10'd1;
            rd_go <= rep;
        end
    end
end

// ---- the line buffer: even and odd pixels, a DDR3 word fills one of each
reg  [8:0]  lb_wa;
reg         lb_we;
reg  [63:0] lb_d;
wire [23:0] q_e, q_o;
gx_sdpram #(.AW(9), .DW(24)) u_lbe ( .clk(CLK_VIDEO), .we(lb_we), .wa(lb_wa), .d(lb_d[23:0]),  .ra(nx[9:1]), .q(q_e) );
gx_sdpram #(.AW(9), .DW(24)) u_lbo ( .clk(CLK_VIDEO), .we(lb_we), .wa(lb_wa), .d(lb_d[55:32]), .ra(nx[9:1]), .q(q_o) );

// the replayed pixel, taken as arcade_video takes its, on CE_PIXEL: nx is
// steady from the clock after the previous one, so the read is ready
reg  [23:0] o_q;
always @(posedge CLK_VIDEO) if( CE_PIXEL ) o_q <= nx[0] ? q_o : q_e;
wire show = rep && VGA_DE;
assign { B_OUT, G_OUT, R_OUT } = show ? o_q : { VGA_B, VGA_G, VGA_R };

// ---- the port: a stored word, or a line's reads in bursts
reg  [31:0] w_lo;
// the stored words wait in a queue of four: the port can stay busy for
// longer than the two pixels a word takes to arrive
reg  [63:0] wq_d [0:3];
reg  [19:0] wq_a [0:3];
reg  [ 1:0] wq_rd = 2'd0, wq_wr = 2'd0;
reg  [ 2:0] wq_n = 3'd0;
wire        w_full = wq_n != 3'd0;
wire [63:0] w_d = wq_d[wq_rd];
wire [19:0] w_a = wq_a[wq_rd];
reg  [9:0]  r_line;
reg  [9:0]  r_req;                          // words asked for
reg  [9:0]  r_got;
reg         r_on = 1'b0;
reg  [9:0]  r_len;
reg  [9:0]  wlen = 10'd288;                 // the line's words, from the last stored one
wire        r_more = r_on && r_req < r_len;
wire        can    = !DDRAM_BUSY && !other_we;
wire        w_take = can && w_full && !r_more;
wire        r_take = can && r_more;
wire [9:0]  r_n    = r_len - r_req > 10'(BURST) ? 10'(BURST) : r_len - r_req;

// the stores: at CE_PIXEL the pixel ending is pixel idx
always @(posedge CLK_VIDEO) begin
    reg push;
    push = CE_PIXEL && VGA_DE && live && idx[0] && wq_n != 3'd4;   // a full queue drops the word
    if( CE_PIXEL && VGA_DE && live && !idx[0] ) w_lo <= { 8'd0, VGA_B, VGA_G, VGA_R };
    if( push ) begin
        wq_d[wq_wr] <= { 8'd0, VGA_B, VGA_G, VGA_R, w_lo };
        wq_a[wq_wr] <= { ly, 1'b0, idx[9:1] };
        wq_wr <= wq_wr + 2'd1;
    end
    if( w_take ) wq_rd <= wq_rd + 2'd1;
    wq_n <= wq_n + (push ? 3'd1 : 3'd0) - (w_take ? 3'd1 : 3'd0);
    // at the line's end idx is its count of pixels
    if( CE_PIXEL && old_de && !VGA_DE && live ) wlen <= idx[9:1];
end

always @(posedge CLK_VIDEO) begin
    lb_we <= 1'b0;
    if( rd_go ) begin
        r_on <= 1'b1; r_line <= ly; r_req <= 10'd0; r_got <= 10'd0; r_len <= wlen;
    end else begin
        if( r_take ) r_req <= r_req + r_n;
        if( DDRAM_DOUT_READY && r_on ) begin
            lb_we <= 1'b1; lb_wa <= r_got[8:0]; lb_d <= DDRAM_DOUT;
            r_got <= r_got + 10'd1;
            if( r_got + 10'd1 == r_len ) r_on <= 1'b0;
        end
    end
end

assign DDRAM_RD       = r_take;
assign DDRAM_WE       = w_take;
assign DDRAM_BURSTCNT = r_take ? 8'(r_n) : 8'd1;
assign DDRAM_ADDR     = r_take ? { MEM_BASE, 2'b00, r_line, r_req } : { MEM_BASE, 2'b00, w_a };
assign DDRAM_DIN      = w_d;
assign DDRAM_BE       = 8'hff;

endmodule
