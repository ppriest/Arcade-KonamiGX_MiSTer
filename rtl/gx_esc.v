/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX ESC protection, as MAME emulates it for the sets whose ESC
 * program builds the sprite list: konamigx.cpp esc_w + generate_sprites
 * (daiskiss_esc, tbyahhoo_esc: src 0xc00000, dst 0xd20000, 0x100 entries).
 *
 * MAME runs this as C, instantly, on the CPU's write to 0xcc0000. On the
 * board the ESC is a microcontroller running a program the game uploads;
 * that program is not emulated anywhere, so this reproduces MAME's C
 * (docs/ROADMAP.md, "ESC protection: from scratch ... reproducing MAME's C").
 * It is a bus master: it starts on the second half of the CPU's 32-bit
 * write, and gx_main holds that write unacknowledged until `done`, so the
 * CPU is off the bus while it runs.
 *
 *   esc_w(data): ignored if data is 0 or outside 0xc00000-0xc1ffff. Reads
 *   the dword at data; if it is 0xfef724fb (the object magic), the command
 *   byte at data+8 selects: 1 run (generate_sprites), 2 load program and 5
 *   reset (no effect here: nothing uses the uploaded program). Then the
 *   byte at data+9 is set to 2 (ESTATE_END) and `irq` pulses -- gx_main
 *   raises IRQ 4 if its enable is set, as MAME does.
 *
 *   generate_sprites: pass 1 lists the entries at src + 0x100*i whose word
 *   +2 is non-zero and whose priority (+28) is below 256, in order. Pass 2,
 *   per entry, reads the header and walks the piece list at `set` (ROM or
 *   RAM, 0x200000-0xcfffff), writing one 8-word sprite per piece. The
 *   arithmetic is MAME's C, 16-bit where the C assigns to short: zoom by
 *   y*0x40/zoom (signed, truncated), positions offset or mirrored about
 *   glob_x/glob_y, pieces outside x -256..544 / y -256..512 skipped, colour
 *   mask/set/rotate. At 256 sprites it stops; otherwise the rest of the 256
 *   slots get word 0 = their slot number (bit 15 clear: disabled).
 */

module gx_esc (
    input             rst,
    input             clk,

    input             start,       // the CPU's write completed the 32-bit data
    input      [23:0] data,        // what it wrote: the command packet address
    // per set (gx_board_cfg, from konamigx.cpp's gameDefs and *_esc): whether
    // a run command generates sprites, and the list it walks
    input             gen_en,      // 0: no ESC callback -- the command only ends
    input      [23:0] gen_src,     // the first entry (entry i at gen_src + 0x100*i)
    input      [ 8:0] gen_count,   // entries (1-256)
    output reg        busy,
    output reg        irq,         // one clock, at the end of a magic command

    // bus master port: one 16-bit access per req, ack when complete
    output reg        m_req,
    output reg        m_we,
    output reg [23:1] m_addr,
    output reg [ 1:0] m_be,        // { UDS, LDS }
    output reg [15:0] m_dout,
    input      [15:0] m_din,
    input             m_ack,

    output     [79:0] dbg          // { count2, m_req, busy, e, set, m_addr, st }: the probe
);

localparam [31:0] MAGIC = 32'hfef724fb;
localparam [23:0] DST = 24'hd20000;
wire [23:0] SRC = gen_src;
wire [ 8:0] LAST = gen_count - 9'd1;

// ---------------------------------------------------------- the list
reg  [7:0] list_i  [0:255];     // entry index i (adr = SRC + 0x100*i)
reg  [7:0] list_pri[0:255];

// ---------------------------------------------------------- state
localparam [5:0]
    S_IDLE=0, S_OP_HI=1, S_OP_LO=2, S_SUB=3, S_P1=4, S_P2=5,
    S_L_W2=6, S_L_PRI=7,
    S_H0=8, S_H1=9, S_H2=10, S_H3=11, S_H4=12, S_H5=13, S_H6=14, S_H7=15, S_H8=16, S_H9=17,
    S_H10=18, S_H11=19, S_HDONE=20,
    S_CNT=21, S_IDX=22, S_FLIP=23, S_COL=24, S_Y=25, S_X=26, S_DIVY=27, S_DIVX=28,
    S_POS=29, S_W0=30, S_W1=31, S_W2=32, S_W3=33, S_W4=34, S_W5=35, S_W6=36, S_NEXT=37,
    S_FILL=38, S_END=39, S_ENTRY=40, S_W7=41, S_DONE=42;
reg  [5:0]  st;

reg  [23:0] pkt;                 // command packet address
reg  [31:0] op;
reg  [7:0]  sub;
reg  [8:0]  i, ecount, e, scount;
reg  [7:0]  pri;
reg  [23:0] adr, set, spr;
reg  [15:0] w_hi, glob_x, glob_y, glob_f, zoom_x, zoom_y, v16;
reg  [15:0] color_val, color_mask, color_set, color_rotate, count2;
reg  flip_x, flip_y;
reg  [15:0] idx, flip, col;
reg  signed [15:0] y, x;

wire in_set = set >= 24'h200000 && set < 24'hd00000;

assign dbg = { count2, m_req, busy, e, set, m_addr, st };

task rd( input [23:0] a );
    begin m_req <= 1; m_we <= 0; m_addr <= a[23:1]; m_be <= 2'b11; end
endtask
task wr( input [23:0] a, input [15:0] d );
    begin m_req <= 1; m_we <= 1; m_addr <= a[23:1]; m_be <= 2'b11; m_dout <= d; end
endtask

// the colour and position arithmetic for the piece just read
reg  [15:0] col_m;
reg  signed [15:0] xs, ys;
always @* begin
    col_m = (col & color_mask) | color_val;
    if( color_set    != 0 ) col_m = { col_m[15:5], color_set[4:0] };
    if( color_rotate != 0 ) col_m = { col_m[15:5], col_m[4:0] + color_rotate[4:0] };
    xs = flip_x ? glob_x - x : glob_x + x;
    ys = flip_y ? glob_y - y : glob_y + y;
end

// ---------------------------------------------------------- divider
// q = trunc(|n| / d), one bit a clock; the caller applies the sign. C:
// y = y*0x40/zoom_y with y short and zoom u16, so the result is truncated
// toward zero and then to 16 bits.
reg         dv_go, dv_busy;
reg  [21:0] dv_n, dv_q;
reg  [15:0] dv_d;
reg  [22:0] dv_r;
reg  [4:0]  dv_k;
reg  [22:0] dv_t;

always @(posedge clk) begin
    if( rst ) dv_busy <= 0;
    else if( dv_go ) begin
        dv_busy <= 1; dv_r <= 0; dv_q <= 0; dv_k <= 5'd21;
    end else if( dv_busy ) begin
        dv_t = { dv_r[21:0], dv_n[dv_k] };
        if( dv_t >= { 7'd0, dv_d } ) begin
            dv_r <= dv_t - { 7'd0, dv_d };
            dv_q[dv_k] <= 1'b1;
        end else dv_r <= dv_t;
        if( dv_k == 0 ) dv_busy <= 0;
        else dv_k <= dv_k - 5'd1;
    end
end

wire [15:0] dv_mag = dv_q[15:0];

// ---------------------------------------------------------- the machine
reg        dv_neg, dv_wait;
wire [15:0] y_abs = y[15] ? -y : y;
wire [15:0] x_abs = x[15] ? -x : x;

always @(posedge clk) begin
    irq   <= 0;
    dv_go <= 0;
    if( rst ) begin
        st <= S_IDLE; busy <= 0; m_req <= 0; dv_wait <= 0;
    end else begin
        if( m_ack ) m_req <= 0;
        case( st )
        S_IDLE: if( start ) begin
            // pkt[0]: MAME reads the packet with unaligned word reads; not modelled
            if( data != 0 && data >= 24'hc00000 && data <= 24'hc1ffff && !data[0] ) begin
                busy <= 1; pkt <= data; rd( data ); st <= S_OP_HI;
            end
        end
        // ---- the command packet
        S_OP_HI: if( m_ack ) begin op[31:16] <= m_din; rd( pkt + 24'd2 ); st <= S_OP_LO; end
        S_OP_LO: if( m_ack ) begin
            op[15:0] <= m_din;
            if( { op[31:16], m_din } == MAGIC ) begin rd( pkt + 24'd8 ); st <= S_SUB; end
            else begin busy <= 0; st <= S_IDLE; end    // ESC_INIT_CONSTANT or unknown: nothing
        end
        S_SUB: if( m_ack ) begin
            sub <= m_din[15:8];                  // the byte at data+8
            if( m_din[15:8] == 8'd1 && gen_en ) begin   // run: generate_sprites
                i <= 0; ecount <= 0; rd( SRC + 24'd2 ); st <= S_L_W2;
            end else st <= S_END;
        end
        // ---- pass 1: the list
        S_L_W2: if( m_ack ) begin
            if( m_din != 0 ) begin rd( SRC + { 8'd0, i[7:0], 8'd28 } ); st <= S_L_PRI; end
            else if( i == LAST ) begin e <= 0; scount <= 0; spr <= DST; st <= S_ENTRY; end
            else begin i <= i + 9'd1; rd( SRC + { 8'd0, i[7:0] + 8'd1, 8'd2 } ); end
        end
        S_L_PRI: if( m_ack ) begin
            if( m_din < 16'd256 ) begin
                list_i[ecount[7:0]]   <= i[7:0];
                list_pri[ecount[7:0]] <= m_din[7:0];
                ecount <= ecount + 9'd1;
            end
            if( i == LAST ) begin e <= 0; scount <= 0; spr <= DST; st <= S_ENTRY; end
            else begin i <= i + 9'd1; rd( SRC + { 8'd0, i[7:0] + 8'd1, 8'd2 } ); st <= S_L_W2; end
        end
        // ---- pass 2: per entry
        S_ENTRY: if( !m_req ) begin
            if( e == ecount ) st <= S_FILL;
            else begin
                adr <= SRC + { 8'd0, list_i[e[7:0]], 8'd0 };
                pri <= list_pri[e[7:0]];
                rd( SRC + { 8'd0, list_i[e[7:0]], 8'd0 } );
                st <= S_H0;
            end
        end
        S_H0:  if( m_ack ) begin w_hi <= m_din; rd( adr + 24'd2 ); st <= S_H1; end
        S_H1:  if( m_ack ) begin
            // set is a u32 in the C; anything at or above 0x1000000 is out of range
            set <= w_hi[15:8] != 0 ? 24'hffffff : { w_hi[7:0], m_din };
            rd( adr + 24'd4 ); st <= S_H2;
        end
        S_H2:  if( m_ack ) begin glob_x <= m_din;             rd( adr + 24'd8  ); st <= S_H3; end
        S_H3:  if( m_ack ) begin glob_y <= m_din;             rd( adr + 24'd12 ); st <= S_H4; end
        S_H4:  if( m_ack ) begin flip_x <= m_din != 0;        rd( adr + 24'd14 ); st <= S_H5; end
        S_H5:  if( m_ack ) begin flip_y <= m_din != 0;        rd( adr + 24'd20 ); st <= S_H6; end
        S_H6:  if( m_ack ) begin zoom_x <= m_din == 0 ? 16'h40 : m_din; rd( adr + 24'd22 ); st <= S_H7; end
        S_H7:  if( m_ack ) begin zoom_y <= m_din == 0 ? 16'h40 : m_din; rd( adr + 24'd24 ); st <= S_H8; end
        S_H8:  if( m_ack ) begin
            color_val  <= m_din[15] ? { 4'd0, m_din[1:0], 10'd0 } : 16'd0;
            color_mask <= m_din[15] ? 16'hf3ff : 16'hffff;
            rd( adr + 24'd26 ); st <= S_H9;
        end
        S_H9:  if( m_ack ) begin
            if( m_din[15] ) begin
                color_mask <= color_mask & 16'hfcff;
                color_val  <= color_val | { 6'd0, m_din[1:0], 8'd0 };
            end
            rd( adr + 24'd18 ); st <= S_H10;
        end
        S_H10: if( m_ack ) begin
            if( m_din[15] ) begin
                color_mask <= color_mask & 16'hff1f;
                color_val  <= color_val | { 8'd0, m_din[7:5], 5'd0 };
            end
            rd( adr + 24'd16 ); st <= S_H11;
        end
        S_H11: if( m_ack ) begin
            color_set    <= m_din[15] ? { 11'd0, m_din[4:0] } : 16'd0;
            color_rotate <= m_din[14] ? { 11'd0, m_din[4:0] } : 16'd0;
            glob_f <= { 2'b00, !flip_y, flip_x, 12'd0 };     // flip_x | (flip_y ^ 0x2000)
            st <= S_HDONE;
        end
        S_HDONE: begin
            if( in_set ) begin rd( set ); st <= S_CNT; end
            else begin e <= e + 9'd1; st <= S_ENTRY; end
        end
        S_CNT: if( m_ack ) begin
            count2 <= m_din;
            set <= set + 24'd2;
            if( m_din == 0 ) begin e <= e + 9'd1; st <= S_ENTRY; end
            else begin rd( set + 24'd2 ); st <= S_IDX; end
        end
        // ---- one piece: idx, flip, col, y, x at set+0..+8
        S_IDX:  if( m_ack ) begin idx  <= m_din; rd( set + 24'd2 ); st <= S_FLIP; end
        S_FLIP: if( m_ack ) begin flip <= m_din; rd( set + 24'd4 ); st <= S_COL; end
        S_COL:  if( m_ack ) begin
            col <= m_din;
            if( idx == 16'hffff ) begin                  // jump: set = flip << 16 | col
                if( flip[15:8] == 0 && { flip[7:0], m_din } >= 24'h200000
                                    && { flip[7:0], m_din } <  24'hd00000 ) begin
                    set <= { flip[7:0], m_din };
                    rd( { flip[7:0], m_din } ); st <= S_IDX;       // continue: count2 unchanged
                end else begin e <= e + 9'd1; st <= S_ENTRY; end  // break
            end else begin rd( set + 24'd6 ); st <= S_Y; end
        end
        S_Y: if( m_ack ) begin y <= m_din; rd( set + 24'd8 ); st <= S_X; end
        S_X: if( m_ack ) begin
            x <= m_din;
            if( zoom_y != 16'h40 ) begin
                dv_neg <= y[15]; dv_n <= { y_abs, 6'd0 }; dv_d <= zoom_y;
                dv_go <= 1; dv_wait <= 0; st <= S_DIVY;
            end else if( zoom_x != 16'h40 ) begin
                dv_neg <= m_din[15]; dv_n <= { m_din[15] ? -m_din : m_din, 6'd0 }; dv_d <= zoom_x;
                dv_go <= 1; dv_wait <= 0; st <= S_DIVX;
            end else st <= S_POS;
        end
        S_DIVY: if( !dv_go ) begin
            if( !dv_wait ) dv_wait <= 1;                 // the divider starts this clock
            else if( !dv_busy ) begin
                y <= dv_neg ? -dv_mag : dv_mag;
                if( zoom_x != 16'h40 ) begin
                    dv_neg <= x[15]; dv_n <= { x_abs, 6'd0 }; dv_d <= zoom_x;
                    dv_go <= 1; dv_wait <= 0; st <= S_DIVX;
                end else st <= S_POS;
            end
        end
        S_DIVX: if( !dv_go ) begin
            if( !dv_wait ) dv_wait <= 1;
            else if( !dv_busy ) begin
                x <= dv_neg ? -dv_mag : dv_mag;
                st <= S_POS;
            end
        end
        // ---- place it, or skip it
        S_POS: begin
            if( xs < -16'sd256 || xs > 16'sd544 || ys < -16'sd256 || ys > 16'sd512 )
                st <= S_NEXT;
            else begin
                x <= xs; y <= ys;
                wr( spr, (flip ^ glob_f) | { 8'd0, pri } ); st <= S_W0;
            end
        end
        S_W0: if( m_ack ) begin wr( spr + 24'd2,  idx    ); st <= S_W1; end
        S_W1: if( m_ack ) begin wr( spr + 24'd4,  y      ); st <= S_W2; end
        S_W2: if( m_ack ) begin wr( spr + 24'd6,  x      ); st <= S_W3; end
        S_W3: if( m_ack ) begin wr( spr + 24'd8,  zoom_y ); st <= S_W4; end
        S_W4: if( m_ack ) begin wr( spr + 24'd10, zoom_x ); st <= S_W5; end
        S_W5: if( m_ack ) begin wr( spr + 24'd12, col_m  ); st <= S_W6; end
        S_W6: if( m_ack ) begin
            spr    <= spr + 24'd16;
            scount <= scount + 9'd1;
            if( scount == 9'd255 ) st <= S_END;           // 256 sprites: return, no fill
            else st <= S_NEXT;
        end
        S_NEXT: if( !m_req ) begin
            count2 <= count2 - 16'd1;
            set    <= set + 24'd10;
            if( count2 == 16'd1 ) begin e <= e + 9'd1; st <= S_ENTRY; end
            else begin rd( set + 24'd10 ); st <= S_IDX; end
        end
        // ---- the rest of the 256 slots: word 0 = the slot number (disabled)
        S_FILL: if( !m_req ) begin
            if( scount == 9'd256 ) st <= S_END;
            else begin wr( spr, { 7'd0, scount } ); st <= S_W7; end
        end
        S_W7: if( m_ack ) begin spr <= spr + 24'd16; scount <= scount + 9'd1; st <= S_FILL; end
        // ---- the byte at data+9 = ESTATE_END (2), then the interrupt
        S_END: if( !m_req ) begin
            m_req <= 1; m_we <= 1; m_addr <= pkt[23:1] + 23'd4; m_be <= 2'b01;
            m_dout <= 16'h0002; st <= S_DONE;
        end
        S_DONE: if( m_ack ) begin irq <= 1; busy <= 0; st <= S_IDLE; end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule
