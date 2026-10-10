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
// Type 4 (t4; scripts/psac4_model.py, from K053936GP_zoom_draw): the line
// is row y's (no -1), 36 * inc in place of 30; the map pixel is 13 bits,
// read at offset srcy * 2048 + srcx of a 2048 x 2048 map and skipped past
// its end; the map is the RAM at 0xf00000 (pm_*), 128 x 128 tiles in column
// order, a word a tile: tile 12:0, colour 13, flip x 14, flip y 15; 384
// columns, not doubled. The output is { 0, colour, pixel } (pen 0x1800 + it).
// Row y is computed for y - oy (MAME's GP offset y + 1). Simple mode
// (ctrl[7] bit 6 clear): the row's start is 256 * ctrl[0] + 36 * incxx +
// (y - oy) * incyx, incyx ctrl[2], incyy ctrl[3] (<< 8 if ctrl[6] bit 14),
// incxx ctrl[4], incxy ctrl[5] (<< 8 if ctrl[6] bit 6); the product a
// shift-add over nine clocks (L_MUL). With dbl (Versus Net Soccer, 576
// wide: MAME's pixeldouble_output) a Type 4 row is 288 columns, doubled,
// and the GP offset x is -30 as Type 3's.
//
// THREE PARTS, so that SDRAM fetches overlap. The map stage walks the
// columns, fetches each one's map entry and queues { column, colour, tile,
// fx, fy }. A dispatcher walks the queue ahead of the drawing and sends each
// tile granule the cache does not hold, and no port is already fetching, to
// one of NP SDRAM clients, which the arbiter serves back to back. The drawing
// takes the queue's head from the cache (8 KB, a granule an entry,
// direct-mapped) at two clocks a pixel. One fetch at a time was too slow
// where the pitch is turned: a line crosses a tile column every 1.4 pixels
// there (216 on row 85 of the 40 s dump), and the cache cannot hold a frame.

module gx_psac #(
    parameter NP = 4,                   // tile clients
    parameter CW = 10                   // cache entries: 2^CW granules (8 KB; 16 KB, CW 11, takes 1-7% off the worst line in sim/gx_psac_tb for 11 more RAM blocks)
) (
    input             clk,
    input             rst,

    input      [15:0] regs [16],        // 0xe00000, the CPU's word order
    input             map_alt,          // type3_bank_w bit 4
    input             t4,               // a Type 4 set
    input      [ 1:0] oy,               // Type 4: the row offset
    input             dbl,              // Type 4: 288 columns doubled (576 wide)
    input             wrap,             // Type 4: the map repeats past its 2048 x 2048 edge

    // Type 4: the map RAM (0xf00000), by word; the word is on pm_q a clock later
    output reg [13:0] pm_addr,
    input      [15:0] pm_q,

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
    output reg [17:0]   tile_addr [NP],
    input      [NP-1:0] tile_ok,
    input      [63:0]   tile_data [NP],

    // the line before: column rd_x (0-287; Type 4 0-383), a clock later
    input      [ 8:0] rd_x,
    output     [ 9:0] rd_pix
);

wire [8:0] COLS = t4 && !dbl ? 9'd384 : 9'd288;
wire       o36  = t4 && !dbl;          // the GP offset x: 36, or 30

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

typedef enum logic [2:0] { L_IDLE, L_RD, L_SET, L_MUL, L_RUN } lstate_t;
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

// Type 4's simple mode
wire        simple = t4 && !ctrl7[6];
wire [15:0] ctrl6s = cr(6);
wire [15:0] cr0 = cr(0), cr1 = cr(1), cr2 = cr(2), cr3 = cr(3), cr4 = cr(4), cr5 = cr(5);
wire [31:0] syx = ctrl6s[14] ? { {8{cr2[15]}}, cr2, 8'd0 } : { {16{cr2[15]}}, cr2 };
wire [31:0] syy = ctrl6s[14] ? { {8{cr3[15]}}, cr3, 8'd0 } : { {16{cr3[15]}}, cr3 };
wire [31:0] sxx = ctrl6s[6]  ? { {8{cr4[15]}}, cr4, 8'd0 } : { {16{cr4[15]}}, cr4 };
wire [31:0] sxy = ctrl6s[6]  ? { {8{cr5[15]}}, cr5, 8'd0 } : { {16{cr5[15]}}, cr5 };
reg  [ 8:0] m_y;                        // y - oy, its bits taken low first
reg  [31:0] m_x, m_xy;                  // incyx, incyy, shifted up a bit a step
reg  [ 3:0] m_n;

// ------------------------------------------------------------ the queue
// { col 9, colour 2, tile 13, fx 4, fy 4, blank 1 }: blank, a Type 4
// column past the map's end
localparam FW = 33;
reg [FW-1:0] fifo [64];
reg [5:0]    f_wr, f_rd;
reg [6:0]    f_n;
wire         f_full  = f_n == 7'd64;
wire         f_empty = f_n == 7'd0;

function automatic [17:0] gran_of( input [FW-1:0] e );  // (tile * 256 + fx * 16 + fy) / 8
    gran_of = { e[21:9], e[8:5], e[4] };
endfunction
function automatic [CW-1:0] idx_of( input [17:0] g );  // the cache entry
    idx_of = CW'(g) ^ CW'({ g[17:11], 4'd0 } >> (11 - CW));
endfunction

// ------------------------------------------------------------ the map stage
wire [11:0] px = ax[22:11];
wire [11:0] py = ay[22:11];
// Type 4: srcy * 2048 + srcx, 13 bits each; past 2048 * 2048 not drawn
// with wrap the map repeats: each coordinate taken modulo 2048
wire [23:0] p4  = wrap ? { 2'b00, ay[21:11], ax[21:11] }
                      : { ay[23:11], 11'd0 } + { 11'd0, ax[23:11] };
wire        p4_out = p4[23:22] != 2'b00;
wire [13:0] p4_e = { p4[10:4], p4[21:15] };          // the map word: column order
reg  [13:0] pm_a1;                                   // the word on pm_q
reg         pm_v1;
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
reg  [CW-1:0] c_wa;
reg  [18:0] c_wt;
reg  [63:0] c_wd;
reg  [CW-1:0] a_ra, b_ra;
wire [18:0] a_tq, b_tq;
wire [63:0] a_dq;
gx_sdpram #(.AW(CW), .DW(19)) u_taga ( .clk, .we(c_we), .wa(c_wa), .d(c_wt), .ra(a_ra), .q(a_tq) );
gx_sdpram #(.AW(CW), .DW(19)) u_tagb ( .clk, .we(c_we), .wa(c_wa), .d(c_wt), .ra(b_ra), .q(b_tq) );
gx_sdpram #(.AW(CW), .DW(64)) u_cdat ( .clk, .we(c_we), .wa(c_wa), .d(c_wd), .ra(a_ra), .q(a_dq) );
reg  [CW:0]   c_clr;                    // [CW]: cleared
reg  [NP-1:0] pend;                     // a port's granule waiting to be written in
reg  [63:0]   pend_d [NP];

// a granule a port is fetching, or holds for the cache
function automatic in_flight( input [17:0] g );
    in_flight = 1'b0;
    for( int p = 0; p < NP; p++ )
        if( (tile_cs[p] || pend[p]) && tile_addr[p] == g ) in_flight = 1'b1;
endfunction

// ------------------------------------------------------------ the drawing
wire [FW-1:0] fq = fifo[f_rd];
reg  [17:0] t_g;                        // the head's granule, asked of the cache
reg         t_blank;
reg  [ 2:0] t_lane;
reg  [ 8:0] t_col;
reg  [ 1:0] t_clr;
reg         t_cmp;                      // a_tq and a_dq answer t_g
wire [ 7:0] tpix = a_dq[63 - 8 * t_lane -: 8];

// ------------------------------------------------------------ the dispatcher
reg  [ 6:0] dn;                         // the entries from the head it has looked at
reg  [17:0] d_g;
reg         d_cmp;
reg         d_blank;
reg  [17:0] d_last;                     // the granule last found held or sent
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
        if( !c_clr[CW] ) begin
            c_we <= 1'b1; c_wa <= c_clr[CW-1:0]; c_wt <= 19'd0; c_clr <= c_clr + 1'b1;
        end

        case( ls )
            L_IDLE: if( line_start && c_clr[CW] ) begin
                half    <= ~half;
                lc_addr <= { line_y - (t4 ? { 7'd0, oy } : 9'd1), 2'd0 } ^ 11'd1;   // MAME's line[0] is word 1
                m_y     <= line_y - { 7'd0, oy };
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
                // 30 * inc = (inc << 5) - (inc << 1); Type 4's 36 * inc = (inc << 5) + (inc << 2)
                if( simple ) begin
                    ax  <= { {8{cr0[15]}}, cr0, 8'd0 } + (sxx << 5) + (o36 ? (sxx << 2) : -(sxx << 1));
                    ay  <= { {8{cr1[15]}}, cr1, 8'd0 } + (sxy << 5) + (o36 ? (sxy << 2) : -(sxy << 1));
                    ixx <= sxx;
                    ixy <= sxy;
                    m_x <= syx; m_xy <= syy; m_n <= 0;
                    ls  <= L_MUL;
                end else begin
                    ax  <= { {8{l0[15]}}, l0, 8'd0 } + (incx << 5) + (o36 ? (incx << 2) : -(incx << 1));
                    ay  <= { {8{l1[15]}}, l1, 8'd0 } + (incy << 5) + (o36 ? (incy << 2) : -(incy << 1));
                    ixx <= incx;
                    ixy <= incy;
                    ls  <= L_RUN;
                end
                pm_v1 <= 1'b0;
                ca  <= 0;
                a_run <= ctrl7[6] || simple;
                b_run <= ctrl7[6] || simple;
                if( !ctrl7[6] && !t4 ) unsupported <= 1;
            end
            L_MUL: begin
                // + (y - oy) * incyx, incyy
                if( m_y[0] ) begin ax <= ax + m_x; ay <= ay + m_xy; end
                m_y  <= m_y >> 1;
                m_x  <= m_x << 1;
                m_xy <= m_xy << 1;
                m_n  <= m_n + 4'd1;
                if( m_n == 4'd8 ) ls <= L_RUN;
            end
            L_RUN: if( !a_run && !b_run ) ls <= L_IDLE;
            default: ls <= L_IDLE;
        endcase

        // the map stage: this column's entry, then on to the next
        pm_a1 <= pm_addr;
        if( ls == L_RUN && a_run && t4 ) begin
            // the map RAM: an entry two clocks after its word is asked for
            pm_addr <= p4_e;
            pm_v1   <= pm_addr == p4_e;
            if( (p4_out || (pm_v1 && pm_a1 == p4_e)) && !f_full ) begin
                push = 1'b1;
                fifo[f_wr] <= { ca, 1'b0, pm_q[13], pm_q[12:0],
                                p4[3:0] ^ {4{pm_q[14]}}, p4[14:11] ^ {4{pm_q[15]}}, p4_out };
                ax <= ax + ixx;
                ay <= ay + ixy;
                ca <= ca + 9'd1;
                pm_v1 <= 1'b0;
                if( ca == COLS - 9'd1 ) a_run <= 1'b0;
            end
        end else if( ls == L_RUN && a_run ) begin
            if( m_valid && m_have == mgran ) begin
                map_cs <= 1'b0;
                if( !f_full ) begin
                    push = 1'b1;
                    fifo[f_wr] <= { ca, mb1[7:6], 1'b0, mb1[3:0], mb0,
                                    px[3:0] ^ {4{mb1[4]}}, py[3:0] ^ {4{mb1[5]}}, 1'b0 };
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
        if( c_clr[CW] )
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
                if( t_blank || a_tq == { 1'b1, t_g } ) begin
                    pop    = 1'b1;
                    lb_we <= 1'b1;
                    lb_wa <= t_col;
                    lb_d  <= t_blank || tpix == 8'd0 ? 10'd0 : { t_clr, tpix };
                    if( t_col == COLS - 9'd1 ) b_run <= 1'b0;
                end else if( !in_flight(t_g) && dn != 0 ) restart = 1'b1;   // fetched, then replaced
            end else if( !f_empty ) begin
                t_g     <= gran_of(fq);
                a_ra    <= idx_of(gran_of(fq));
                t_lane  <= fq[3:1];
                t_col   <= fq[32:24];
                t_clr   <= fq[23:22];
                t_blank <= fq[0];
                t_cmp   <= 1'b1;
            end
        end

        // the dispatcher: look at the entry dn past the head, then fetch its
        // granule if nothing has it
        if( ls == L_RUN && c_clr[CW] ) begin
            if( d_cmp ) begin
                d_cmp <= 1'b0;
                if( d_blank || b_tq == { 1'b1, d_g } || in_flight(d_g) || (d_lastv && d_last == d_g) ) begin
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
                d_g     <= gran_of(fifo[f_rd + dn[5:0]]);
                b_ra    <= idx_of(gran_of(fifo[f_rd + dn[5:0]]));
                d_blank <= fifo[f_rd + dn[5:0]][0];
                d_cmp   <= 1'b1;
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
