// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Type 3 boards' K053936 (PSAC2) layer, as MAME draws it for Soccer
// Superstars (docs/TYPE34.md), a line ahead into a line buffer.
//
// WRITTEN FROM MAME'S CODE: scripts/psac2_model.py is the specification and
// sim/gx_psac_tb the test. jotego's jt053936 is not used: it is the chip's
// own pixel-rate counters fed by its line-RAM DMA, where this core renders a
// line ahead from SDRAM, and MAME reads the registers and the line control
// as 16-bit halves of 32-bit RAM (word n ^ 1), which the game is written
// for, since its picture is right in MAME.
//
// Per bitmap row y (K053936_zoom_draw, line mode, K053936_set_offset(0, -30,
// +1), wraparound), with line[k] the line control's word (4 * ((y - 1) &
// 0x1ff) + k) ^ 1 and ctrl[n] register n ^ 1:
//   incxx = s16(line[2]) (<< 8 if ctrl[6] bit 15), incxy = s16(line[3])
//   (<< 8 if ctrl[6] bit 7), ax = 256 * s16(line[0] + ctrl[0]) + 30 * incxx,
//   ay likewise; column c (0-287) is map pixel (ax + c * incxx)[22:11],
//   (ay + c * incxy)[22:11], of a 4096 x 4096 map.
// The map (get_gx_psac3_tile_info) is 256 x 256 tiles in column order, two
// bytes each, the second map 0x20000 on (type3_bank_w bit 4); a tile is
// 16 x 16 at 8 bpp stored by column (byte x * 16 + y). The output is
// { colour[1:0], pixel[7:0] }; the palette index is 0x1000 + that, and
// pixel 0 is not drawn (gx_draw_basic_extended_tilemaps_2), which also
// doubles each column across two screen pixels.
//
// Not drawn, flagged on `unsupported`: the simple mode (ctrl[7] bit 6 clear),
// which soccerss does not use.
//
// THREE PARTS, so that SDRAM fetches overlap. The map stage walks the
// columns, fetches each one's map entry and queues { column, colour, tile,
// fx, fy }. A dispatcher walks the queue ahead of the drawing and sends each
// tile granule the cache does not hold, and no port is already fetching, to
// one of NP SDRAM clients, which the arbiter serves back to back. The drawing
// takes the queue's head from the cache (16 KB, a granule an entry,
// direct-mapped) at two clocks a pixel. One fetch at a time was too slow
// where the pitch is turned: a line crosses a tile column every 1.4 pixels
// there (216 on row 85 of the 40 s dump), and the cache cannot hold a frame.

module gx_psac #(
    parameter NP = 4                    // tile clients
) (
    input             clk,
    input             rst,

    input      [15:0] regs [16],        // 0xe00000, the CPU's word order
    input             map_alt,          // type3_bank_w bit 4

    // line control (0xe60000), by word; the word is on lc_q a clock later
    output reg [10:0] lc_addr,
    input      [15:0] lc_q,

    input             line_start,
    input      [ 8:0] line_y,           // MAME's bitmap row
    output            busy,
    output reg        unsupported,

    // the map (gfx4): granules from its region's start
    output reg        map_cs,
    output reg [15:0] map_addr,
    input             map_ok,
    input      [63:0] map_data,         // byte 0 in [63:56]

    // the tiles (gfx3): NP clients
    output reg [NP-1:0] tile_cs,
    output reg [16:0]   tile_addr [NP],
    input      [NP-1:0] tile_ok,
    input      [63:0]   tile_data [NP],

    // the line before: column rd_x (0-287), a clock later
    input      [ 8:0] rd_x,
    output     [ 9:0] rd_pix
);

localparam [8:0] COLS = 9'd288;

function automatic [15:0] cr( input integer n );   // MAME's ctrl[n]
    cr = regs[n ^ 1];
endfunction

// ------------------------------------------------------------ the line
reg        half = 1'b0;                 // the half being written
reg [31:0] ax, ay, ixx, ixy;
reg [15:0] lw [4];                      // the line control, in MAME's order
reg [ 8:0] ca;                          // the map stage's column
reg [ 2:0] lc_n;
reg        a_run, b_run;

typedef enum logic [2:0] { L_IDLE, L_RD, L_SET, L_RUN } lstate_t;
lstate_t   ls;

wire [15:0] ctrl6   = cr(6);
wire [15:0] ctrl7   = cr(7);
wire        ctrl6_x = ctrl6[15];
wire        ctrl6_y = ctrl6[7];
wire [15:0] l0 = lw[0] + cr(0);
wire [15:0] l1 = lw[1] + cr(1);
wire [31:0] incx = ctrl6_x ? { {8{lw[2][15]}}, lw[2], 8'd0 } : { {16{lw[2][15]}}, lw[2] };
wire [31:0] incy = ctrl6_y ? { {8{lw[3][15]}}, lw[3], 8'd0 } : { {16{lw[3][15]}}, lw[3] };

assign busy = ls != L_IDLE;

// ------------------------------------------------------------ the queue
// { col 9, colour 2, tile 12, fx 4, fy 4 }
localparam FW = 31;
reg [FW-1:0] fifo [64];
reg [5:0]    f_wr, f_rd;
reg [6:0]    f_n;
wire         f_full  = f_n == 7'd64;
wire         f_empty = f_n == 7'd0;

function automatic [16:0] gran_of( input [FW-1:0] e );  // (tile * 256 + fx * 16 + fy) / 8
    gran_of = { e[19:8], e[7:4], e[3] };
endfunction
function automatic [10:0] idx_of( input [16:0] g );     // the cache entry
    idx_of = g[10:0] ^ { g[16:11], 5'd0 };
endfunction

// ------------------------------------------------------------ the map stage
wire [11:0] px = ax[22:11];
wire [11:0] py = ay[22:11];
wire [15:0] tix = { px[11:4], py[11:4] };           // column order
wire [17:0] mbyte = { map_alt, 17'd0 } + { 1'b0, tix, 1'b0 };
wire [15:0] mgran = mbyte[18-1:3];
reg  [15:0] m_have;                                  // the granule in m_data
reg  [63:0] m_data;
reg         m_valid;
wire [ 1:0] mlane = tix[1:0];
wire [ 7:0] mb0 = m_data[63 - 16 * mlane -: 8];
wire [ 7:0] mb1 = m_data[55 - 16 * mlane -: 8];

// ------------------------------------------------------------ the cache
// Written by the fills; read by the drawing (tag A, and the data) and by
// the dispatcher (tag B, a copy). A tag is { valid, granule }; cleared once
// after rst.
reg         c_we;
reg  [10:0] c_wa;
reg  [17:0] c_wt;
reg  [63:0] c_wd;
reg  [10:0] a_ra, b_ra;
wire [17:0] a_tq, b_tq;
wire [63:0] a_dq;
gx_sdpram #(.AW(11), .DW(18)) u_taga ( .clk, .we(c_we), .wa(c_wa), .d(c_wt), .ra(a_ra), .q(a_tq) );
gx_sdpram #(.AW(11), .DW(18)) u_tagb ( .clk, .we(c_we), .wa(c_wa), .d(c_wt), .ra(b_ra), .q(b_tq) );
gx_sdpram #(.AW(11), .DW(64)) u_cdat ( .clk, .we(c_we), .wa(c_wa), .d(c_wd), .ra(a_ra), .q(a_dq) );
reg  [11:0]   c_clr;                    // [11]: cleared
reg  [NP-1:0] pend;                     // a port's granule waiting to be written in
reg  [63:0]   pend_d [NP];

// a granule a port is fetching, or holds for the cache
function automatic in_flight( input [16:0] g );
    in_flight = 1'b0;
    for( int p = 0; p < NP; p++ )
        if( (tile_cs[p] || pend[p]) && tile_addr[p] == g ) in_flight = 1'b1;
endfunction

// ------------------------------------------------------------ the drawing
wire [FW-1:0] fq = fifo[f_rd];
reg  [16:0] t_g;                        // the head's granule, asked of the cache
reg  [ 2:0] t_lane;
reg  [ 8:0] t_col;
reg  [ 1:0] t_clr;
reg         t_cmp;                      // a_tq and a_dq answer t_g
wire [ 7:0] tpix = a_dq[63 - 8 * t_lane -: 8];

// ------------------------------------------------------------ the dispatcher
reg  [ 6:0] dn;                         // the entries from the head it has looked at
reg  [16:0] d_g;
reg         d_cmp;
reg  [16:0] d_last;                     // the granule last found held or sent
reg         d_lastv;

// ------------------------------------------------------------ line buffer
reg        lb_we;
reg [ 8:0] lb_wa;
reg [ 9:0] lb_d;
gx_sdpram #(.AW(10), .DW(10)) u_lb (
    .clk, .we(lb_we), .wa({ half, lb_wa }), .d(lb_d),
    .ra({ ~half, rd_x }), .q(rd_pix)
);

always @(posedge clk) begin
    reg push, pop, sent, done, restart, filled;
    lb_we <= 1'b0;
    c_we  <= 1'b0;
    push    = 1'b0;
    pop     = 1'b0;
    sent    = 1'b0;
    done    = 1'b0;
    restart = 1'b0;
    filled  = 1'b0;
    if( rst ) begin
        ls <= L_IDLE; map_cs <= 0; tile_cs <= 0; unsupported <= 0;
        m_valid <= 0; a_run <= 0; b_run <= 0;
        f_wr <= 0; f_rd <= 0; f_n <= 0; dn <= 0;
        pend <= 0; c_clr <= 0; t_cmp <= 0; d_cmp <= 0; d_lastv <= 0;
    end else begin
        // the cache's tags cleared once after rst; nothing renders before
        if( !c_clr[11] ) begin
            c_we <= 1'b1; c_wa <= c_clr[10:0]; c_wt <= 18'd0; c_clr <= c_clr + 12'd1;
        end

        case( ls )
            L_IDLE: if( line_start && c_clr[11] ) begin
                half    <= ~half;
                lc_addr <= { line_y - 9'd1, 2'd0 } ^ 11'd1;   // MAME's line[0] is word 1
                lc_n    <= 0;
                f_wr    <= 0; f_rd <= 0; f_n <= 0; dn <= 0;
                t_cmp   <= 0; d_cmp <= 0; d_lastv <= 0;
                ls      <= L_RD;
            end
            L_RD: begin
                // lc_q is the word asked for a clock before
                lc_n    <= lc_n + 3'd1;
                lc_addr <= { lc_addr[10:2], (lc_n[1:0] + 2'd1) ^ 2'd1 };
                if( lc_n != 0 ) lw[lc_n - 3'd1] <= lc_q;
                if( lc_n == 3'd4 ) ls <= L_SET;
            end
            L_SET: begin
                // 30 * inc = (inc << 5) - (inc << 1)
                ax  <= { {8{l0[15]}}, l0, 8'd0 } + (incx << 5) - (incx << 1);
                ay  <= { {8{l1[15]}}, l1, 8'd0 } + (incy << 5) - (incy << 1);
                ixx <= incx;
                ixy <= incy;
                ca  <= 0;
                a_run <= ctrl7[6];
                b_run <= ctrl7[6];
                if( !ctrl7[6] ) unsupported <= 1;
                ls  <= L_RUN;
            end
            L_RUN: if( !a_run && !b_run ) ls <= L_IDLE;
            default: ls <= L_IDLE;
        endcase

        // the map stage: this column's entry, then on to the next
        if( ls == L_RUN && a_run ) begin
            if( m_valid && m_have == mgran ) begin
                map_cs <= 1'b0;
                if( !f_full ) begin
                    push = 1'b1;
                    fifo[f_wr] <= { ca, mb1[7:6], mb1[3:0], mb0,
                                    px[3:0] ^ {4{mb1[4]}}, py[3:0] ^ {4{mb1[5]}} };
                    ax <= ax + ixx;
                    ay <= ay + ixy;
                    ca <= ca + 9'd1;
                    if( ca == COLS - 9'd1 ) a_run <= 1'b0;
                end
            end else begin
                map_cs   <= 1'b1;
                map_addr <= mgran;
                if( map_ok && map_addr == mgran && map_cs ) begin
                    m_have  <= mgran;
                    m_data  <= map_data;
                    m_valid <= 1'b1;
                    map_cs  <= 1'b0;
                end
            end
        end

        // the ports: an answer is held until the cache takes it, one a clock
        for( int p = 0; p < NP; p++ )
            if( tile_cs[p] && tile_ok[p] ) begin
                tile_cs[p] <= 1'b0; pend[p] <= 1'b1; pend_d[p] <= tile_data[p];
            end
        if( c_clr[11] )
            for( int p = 0; p < NP; p++ )
                if( pend[p] && !filled ) begin
                    c_we <= 1'b1; c_wa <= idx_of(tile_addr[p]); c_wt <= { 1'b1, tile_addr[p] };
                    c_wd <= pend_d[p];
                    pend[p] <= 1'b0;
                    filled = 1'b1;
                end

        // the drawing: the head from the cache, a pixel every two clocks
        if( ls == L_RUN && b_run ) begin
            if( t_cmp ) begin
                t_cmp <= 1'b0;
                if( a_tq == { 1'b1, t_g } ) begin
                    pop    = 1'b1;
                    lb_we <= 1'b1;
                    lb_wa <= t_col;
                    lb_d  <= tpix == 8'd0 ? 10'd0 : { t_clr, tpix };
                    if( t_col == COLS - 9'd1 ) b_run <= 1'b0;
                end else if( !in_flight(t_g) && dn != 0 ) restart = 1'b1;   // fetched, then replaced
            end else if( !f_empty ) begin
                t_g    <= gran_of(fq);
                a_ra   <= idx_of(gran_of(fq));
                t_lane <= fq[2:0];
                t_col  <= fq[30:22];
                t_clr  <= fq[21:20];
                t_cmp  <= 1'b1;
            end
        end

        // the dispatcher: look at the entry dn past the head, then fetch its
        // granule if nothing has it
        if( ls == L_RUN && c_clr[11] ) begin
            if( d_cmp ) begin
                d_cmp <= 1'b0;
                if( b_tq == { 1'b1, d_g } || in_flight(d_g) || (d_lastv && d_last == d_g) ) begin
                    done = 1'b1;
                end else begin
                    for( int p = 0; p < NP; p++ )
                        if( !sent && !tile_cs[p] && !pend[p] ) begin
                            tile_cs[p] <= 1'b1; tile_addr[p] <= d_g; sent = 1'b1;
                        end
                    done = sent;
                end
                if( done ) begin d_last <= d_g; d_lastv <= 1'b1; end
            end else if( dn < f_n ) begin
                d_g   <= gran_of(fifo[f_rd + dn[5:0]]);
                b_ra  <= idx_of(gran_of(fifo[f_rd + dn[5:0]]));
                d_cmp <= 1'b1;
            end
        end

        if( push ) f_wr <= f_wr + 6'd1;
        if( pop  ) f_rd <= f_rd + 6'd1;
        f_n <= f_n + 7'(push) - 7'(pop);
        // dn counts from the head: a pop moves the head on, a look moves dn on
        if( restart ) begin dn <= 0; d_cmp <= 1'b0; d_lastv <= 1'b0; end
        else dn <= dn + 7'(done) - 7'(pop && dn != 0);
    end
end

endmodule
