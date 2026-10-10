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
 *   A set whose callback is konamigx_esc_alert in mode 0 (tkmmpzdm_esc:
 *   work RAM + 0x142 dwords, 0x100 sprites) copies instead (gen_copy):
 *   gen_count sprites of 16 bytes from gen_src to 0xd20000, word for word.
 *
 *   Salamander 2 (sal2_esc: konamigx_esc_alert mode 1, gen_sal2) builds
 *   the list from the game's own object records: the Vic Viper (three
 *   records at 0x49c, dword layout "odd"), Lord British (three at 0x84c) and
 *   gen_count groups of 0xc0 bytes from gen_src, each with up to 15 records
 *   from +32; a magic dword at 0x71f0 picks a zcode/priority table, a
 *   position correction and the y mask. One 8-word sprite per record whose
 *   flag bit is set, word 7 left as it is; at 256 it stops, otherwise word
 *   0 of every slot left is cleared. The K055555 blend-enable write MAME
 *   makes for magic 0x10010011 ("TEMPORARY") is not reproduced.
 *
 *   Fantastic Journey's DMA (gameDefs special 9, fantjour_dma_w at 0xdb0000)
 *   starts with `fj`: mode 0x93 copies sz2 + 1 blocks of db bytes, a dword
 *   at a time, from sa to da, each dword XOR x; mode 0x8f fills them with
 *   x. The game copies within the palette RAM (0xd96000 to 0xd90000-
 *   0xd94fff) and clears sprite RAM at 0xd21000. No interrupt, as MAME.
 *
 *   A set with the type 4 Xilinx protection instead (winspike: gameDefs
 *   special 7, type4_prot_w) starts it with `p4`, data[15:0] the command
 *   word the CPU wrote to 0xcc0004: 0x0a56/0x0d96/0x0d14/0x0d1c copy 0x400
 *   bytes from 0xc01000 to 0xc01400; 0x057a copies the dwords at 0xc00f10,
 *   0xc00f14, 0xc00f20, 0xc00f24, 0xc00f30, 0xc00f34 to 0xc10f00, 0xc10f04,
 *   0xc10f20, 0xc10f24, 0xc0fe00, 0xc0fe04; Slam Dunk 2's 0x0b16 copies the
 *   high words of 0x100 longs from 0xc01000 to 0xd20000, a word apart, and
 *   0x3a4f 0x400 of them from 0xc18400 to 0xd21000; Versus Net Soccer's
 *   0x0515 and 0x115d copy 0x400 bytes, 0xc01800 to 0xc01c00 and 0xc18800
 *   to 0xc18c00. Rushing Heroes' 0x0d97 copies 256 sprites of five dwords
 *   from 0xc09ff0 down by 0x10 a sprite to 0xd20000 up by 0x10 (a sprite's
 *   fifth dword lands on the next's first, which the next copy replaces) --
 *   0xc19ff0 to 0xd21000 when the parameter was 0x0062 (data[16]) -- then
 *   the inputs: the inverted bytes at 0xc00507, 0xc00527, 0xc00547,
 *   0xc00567 to 0xc01cc0, 0xc01cc1, 0xc01cc4, 0xc01cc5 and again at
 *   0xc11cc0. Any other command does nothing.
 *   Then `irq` pulses; there is no packet to mark.
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
    input             p4,          // start is a type 4 protection command, data[15:0]
    input             fj,          // start is a fantjour DMA command, fj_* below
    input      [ 7:0] fj_mode,
    input      [ 7:0] fj_sz2,
    input      [23:0] fj_sa,
    input      [23:0] fj_da,
    input      [15:0] fj_db,
    input      [31:0] fj_x,
    // per set (gx_board_cfg, from konamigx.cpp's gameDefs and *_esc): whether
    // a run command generates sprites, and the list it walks
    input             gen_en,      // 0: no ESC callback -- the command only ends
    input      [23:0] gen_src,     // the first entry (entry i at gen_src + 0x100*i)
    input      [ 8:0] gen_count,   // entries (1-256)
    input             gen_copy,    // the callback is konamigx_esc_alert mode 0: a copy
    input             gen_sal2,    // ... mode 1 (sal2_esc)
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
localparam [6:0]
    S_IDLE=0, S_OP_HI=1, S_OP_LO=2, S_SUB=3, S_P1=4, S_P2=5,
    S_L_W2=6, S_L_PRI=7,
    S_H0=8, S_H1=9, S_H2=10, S_H3=11, S_H4=12, S_H5=13, S_H6=14, S_H7=15, S_H8=16, S_H9=17,
    S_H10=18, S_H11=19, S_HDONE=20,
    S_CNT=21, S_IDX=22, S_FLIP=23, S_COL=24, S_Y=25, S_X=26, S_DIVY=27, S_DIVX=28,
    S_POS=29, S_W0=30, S_W1=31, S_W2=32, S_W3=33, S_W4=34, S_W5=35, S_W6=36, S_NEXT=37,
    S_FILL=38, S_END=39, S_ENTRY=40, S_W7=41, S_DONE=42, S_CP_RD=43, S_CP_WR=44, S_CP_NEXT=45,
    S_CP_SEG=46, S_RH_IN=73, S_RH_WB=74, S_RH_NX=75,
    S2_MG0=47, S2_MG1=48, S2_VC=49, S2_HC=50, S2_VV=51, S2_VV1=52, S2_VV2=53, S2_LB=54,
    S2_LB1=55, S2_LB2=56, S2_G0=57, S2_G1=58, S2_GC=59, S2_GH=60, S2_GV=61, S2_GN=62,
    S2_ORD=63, S2_OT=64, S2_OW=65, S2_ONEXT=66, S2_CLR=67, S2_CLRW=68,
    F_RH=69, F_RL=70, F_WH=71, F_WL=72;
reg  [6:0]  st;

reg  [23:0] pkt;                 // command packet address
reg  [31:0] op;
reg  [7:0]  sub;
reg  [8:0]  i, ecount, e, scount;
reg  [7:0]  pri;
reg  [23:0] adr, set, spr;
reg  [23:0] cp_last;             // the copy's last destination word
reg         cp_s4;               // the source steps a long (0x0b16, 0x3a4f)
reg  [1:0]  cp_seg;              // 0x057a: which of its three copies
reg         rh_run;              // 0x0d97
reg  [23:0] rh_src, rh_dst;      // 0x0d97: this sprite's source and destination
reg  [ 8:0] rh_n;                // 0x0d97: sprites copied; then the input bytes
reg  [ 2:0] rh_b;
reg         p4_run, p4_in;       // a type 4 command; 0x057a
reg  [15:0] w_hi, glob_x, glob_y, glob_f, zoom_x, zoom_y, v16;
reg  [15:0] color_val, color_mask, color_set, color_rotate, count2;
reg  flip_x, flip_y;
reg  [15:0] idx, flip, col;
reg  signed [15:0] y, x;

wire in_set = set >= 24'h200000 && set < 24'hd00000;

// ---------------------------------------------------------- sal2_esc
localparam [23:0] W = 24'hc00000;       // srcbase: the work RAM
reg  [15:0] magic_hi, hcorr, vcorr, hoffs, voffs, vmask;
reg  [2:0]  tbl;                         // ztable/ptable row
reg  [15:0] ow [0:7];                    // the record, as words
reg  [2:0]  owk, dk;
reg  [23:0] obase, gadr;
reg  [3:0]  ocnt;
reg         odd;                         // EXTRACT_ODD's dword alignment
reg  [1:0]  phase;                       // 0 Vic Viper, 1 Lord British, 2 the groups
reg  [8:0]  g, j;                        // group; sprite slots left

// fantjour_dma_w
reg         fj_run, fj_fill;
reg  [7:0]  fj_blk;                      // blocks left after this one
reg  [15:0] fj_i2, fj_dbr;               // bytes done in this block; block size
reg  [31:0] fj_xr;

// konamigx_esc_alert's ztable and ptable (ptable >> 4)
function [2:0] ztab( input [2:0] t, input [2:0] k );
    case( t )
        3'd1, 3'd2: case( k ) 0: ztab = 4; 1: ztab = 3; 2: ztab = 2; 3: ztab = 1;
                              4: ztab = 0; 5: ztab = 7; 6: ztab = 6; default: ztab = 5; endcase
        3'd3: case( k ) 0: ztab = 3; 1: ztab = 2; 2: ztab = 1; 3: ztab = 0;
                        4: ztab = 5; 5: ztab = 7; 6: ztab = 4; default: ztab = 6; endcase
        3'd4: case( k ) 0: ztab = 6; 1: ztab = 5; 2: ztab = 1; 3: ztab = 4;
                        4: ztab = 3; 5: ztab = 7; 6: ztab = 0; default: ztab = 2; endcase
        default: case( k ) 0: ztab = 5; 1: ztab = 4; 2: ztab = 3; 3: ztab = 2;
                           4: ztab = 1; 5: ztab = 7; 6: ztab = 6; default: ztab = 0; endcase
    endcase
endfunction
function [1:0] ptab( input [2:0] t, input [2:0] k );
    case( t )
        3'd0: case( k ) 3: ptab = 1; 4: ptab = 2; 7: ptab = 3; default: ptab = 0; endcase
        3'd1: ptab = k == 3'd5 ? 2'd0 : 2'd2;
        3'd2: ptab = k == 3'd3 || k == 3'd4 ? 2'd2 : 2'd0;
        3'd3: case( k ) 0, 1, 2, 6: ptab = 1; 3: ptab = 2; default: ptab = 0; endcase
        3'd4: case( k ) 2, 6, 7: ptab = 2; 4: ptab = 1; default: ptab = 0; endcase
        3'd5: ptab = k == 3'd3 || k == 3'd4 || k == 3'd7 ? 2'd1 : 2'd0;
        default: ptab = k == 3'd7 ? 2'd1 : 2'd0;
    endcase
endfunction

// the sprite's words from the record (EXTRACT_ODD / EXTRACT_EVEN)
wire [2:0]  rk  = odd ? ow[1][2:0] : ow[0][2:0];
wire [2:0]  rz  = ztab( tbl, rk );
wire [1:0]  rp  = ptab( tbl, rk );
wire        rok = odd ? ow[1][15] : ow[0][15];
reg  [15:0] rd_w;
always @* begin
    case( dk )
        3'd0: rd_w = { (odd ? ow[1][15:8] : ow[0][15:8]), 5'd0, rz };
        3'd1: rd_w = odd ? ow[2] : ow[1];
        3'd2: rd_w = ((odd ? ow[3] : ow[2]) + voffs) & vmask;
        3'd3: rd_w = (odd ? ow[4] : ow[3]) + hoffs;
        3'd4: rd_w = odd ? ow[5] : ow[4];
        3'd5: rd_w = odd ? ow[6] : ow[5];
        default: rd_w = (odd ? ow[7] : ow[6]) | { 6'd0, rp, 8'd0 };
    endcase
end

assign dbg = { count2, m_req, busy, e, set, m_addr, st };

task rd( input [23:0] a );
    begin m_req <= 1; m_we <= 0; m_addr <= a[23:1]; m_be <= 2'b11; end
endtask
task wr( input [23:0] a, input [15:0] d );
    begin m_req <= 1; m_we <= 1; m_addr <= a[23:1]; m_be <= 2'b11; m_dout <= d; end
endtask
task wrb( input [23:0] a, input [7:0] d );     // one byte
    begin m_req <= 1; m_we <= 1; m_addr <= a[23:1]; m_be <= a[0] ? 2'b01 : 2'b10; m_dout <= { d, d }; end
endtask
// 0x0d97's input bytes: byte k of four from 0xc00507 + 0x20 * k, to the
// offsets 0, 1, 4, 5 at 0xc01cc0 (b 0-3) and 0xc11cc0 (b 4-7)
wire [23:0] rh_isrc = 24'hc00507 + { 17'd0, rh_b[1:0], 5'd0 };
wire [23:0] rh_idst = (rh_b[2] ? 24'hc11cc0 : 24'hc01cc0) + { 21'd0, rh_b[1], 1'b0, rh_b[0] };

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

// ---------------------------------------------------------- dividers
// q = trunc(|n| / d); the caller applies the sign. C: y = y*0x40/zoom_y
// with y short and zoom u16, so the result is truncated toward zero and
// then to 16 bits. y and x are divided at once, two quotient bits a clock
// (gx_esc_div): a title screen of zoomed sprites walks some ten thousand
// pieces a command, and one bit a clock, y then x, was most of its time.
reg         dv_go, dv_wait, dv_ny, dv_nx, dv_on_y, dv_on_x;
wire        dvy_busy, dvx_busy;
wire [15:0] dvy_q, dvx_q;
wire [15:0] y_abs = y[15] ? -y : y;
wire [15:0] x_abs = x[15] ? -x : x;
reg  [15:0] x_in;                // x as it is read, for the divider's start
wire [15:0] x_in_abs = x_in[15] ? -x_in : x_in;
gx_esc_div u_dvy ( .clk(clk), .rst(rst), .go(dv_go && dv_on_y), .n({ y_abs, 6'd0 }),    .d(zoom_y), .busy(dvy_busy), .q(dvy_q) );
gx_esc_div u_dvx ( .clk(clk), .rst(rst), .go(dv_go && dv_on_x), .n({ x_in_abs, 6'd0 }), .d(zoom_x), .busy(dvx_busy), .q(dvx_q) );

// ---------------------------------------------------------- the machine

always @(posedge clk) begin
    irq   <= 0;
    dv_go <= 0;
    if( rst ) begin
        st <= S_IDLE; busy <= 0; m_req <= 0; dv_wait <= 0; p4_run <= 0; fj_run <= 0;
    end else begin
        if( m_ack ) m_req <= 0;
        case( st )
        S_IDLE: if( start && fj ) begin
            busy <= 1; fj_run <= 1; p4_run <= 0;
            fj_fill <= fj_mode == 8'h8f; fj_blk <= fj_sz2; fj_i2 <= 0; fj_dbr <= fj_db; fj_xr <= fj_x;
            adr <= fj_sa; spr <= fj_da;
            if( fj_db == 0 || (fj_mode != 8'h93 && fj_mode != 8'h8f) ) st <= S_END;
            else if( fj_mode == 8'h93 ) begin rd( fj_sa ); st <= F_RH; end
            else begin w_hi <= fj_x[31:16]; v16 <= fj_x[15:0]; st <= F_WH; end
        end else if( start && p4 ) begin
            fj_run <= 0;
            busy <= 1; p4_run <= 1; p4_in <= data[15:0] == 16'h057a; cp_seg <= 0;
            rh_run <= data[15:0] == 16'h0d97; rh_n <= 0; rh_b <= 0;
            cp_s4 <= data[15:0] == 16'h0b16 || data[15:0] == 16'h3a4f;
            case( data[15:0] )
                16'h0a56, 16'h0d96, 16'h0d14, 16'h0d1c: begin
                    adr <= 24'hc01000; spr <= 24'hc01400; cp_last <= 24'hc017fe;
                    rd( 24'hc01000 ); st <= S_CP_RD;
                end
                16'h057a: begin
                    adr <= 24'hc00f10; spr <= 24'hc10f00; cp_last <= 24'hc10f06;
                    rd( 24'hc00f10 ); st <= S_CP_RD;
                end
                16'h0d97: begin
                    rh_src <= data[16] ? 24'hc19ff0 : 24'hc09ff0;
                    rh_dst <= data[16] ? 24'hd21000 : 24'hd20000;
                    adr <= data[16] ? 24'hc19ff0 : 24'hc09ff0;
                    spr <= data[16] ? 24'hd21000 : 24'hd20000;
                    cp_last <= (data[16] ? 24'hd21000 : 24'hd20000) + 24'h12;
                    rd( data[16] ? 24'hc19ff0 : 24'hc09ff0 ); st <= S_CP_RD;
                end
                16'h0b16: begin
                    adr <= 24'hc01000; spr <= 24'hd20000; cp_last <= 24'hd201fe;
                    rd( 24'hc01000 ); st <= S_CP_RD;
                end
                16'h3a4f: begin
                    adr <= 24'hc18400; spr <= 24'hd21000; cp_last <= 24'hd217fe;
                    rd( 24'hc18400 ); st <= S_CP_RD;
                end
                16'h0515: begin
                    adr <= 24'hc01800; spr <= 24'hc01c00; cp_last <= 24'hc01ffe;
                    rd( 24'hc01800 ); st <= S_CP_RD;
                end
                16'h115d: begin
                    adr <= 24'hc18800; spr <= 24'hc18c00; cp_last <= 24'hc18ffe;
                    rd( 24'hc18800 ); st <= S_CP_RD;
                end
                default: st <= S_END;
            endcase
        end else if( start ) begin
            p4_run <= 0; fj_run <= 0;
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
            if( m_din[15:8] == 8'd1 && gen_en && gen_copy ) begin   // run: esc_alert's copy
                adr <= SRC; spr <= DST; cp_last <= DST + { 11'd0, gen_count, 4'd0 } - 24'd2;
                rd( SRC ); st <= S_CP_RD;
            end else if( m_din[15:8] == 8'd1 && gen_en && gen_sal2 ) begin   // run: esc_alert mode 1
                spr <= DST; j <= 9'd256; rd( W + 24'h71f0 ); st <= S2_MG0;
            end else if( m_din[15:8] == 8'd1 && gen_en ) begin   // run: generate_sprites
                i <= 0; ecount <= 0; rd( SRC + 24'd2 ); st <= S_L_W2;
            end else st <= S_END;
        end
        // ---- konamigx_esc_alert mode 0: gen_count * 8 words, as they are
        S_CP_RD: if( m_ack ) begin v16 <= m_din; st <= S_CP_WR; end
        S_CP_WR: if( !m_req ) begin
            wr( spr, v16 );
            spr <= spr + 24'd2; adr <= adr + (p4_run && cp_s4 ? 24'd4 : 24'd2);
            if( spr == cp_last ) st <= S_CP_SEG;
            else st <= S_CP_NEXT;
        end
        S_CP_SEG: if( !m_req && fj_run ) begin
            spr <= spr + 24'd4;
            if( !fj_fill ) adr <= adr + 24'd4;
            if( fj_i2 + 16'd4 >= fj_dbr ) begin
                fj_i2 <= 0;
                if( fj_blk == 0 ) st <= S_END;
                else fj_blk <= fj_blk - 8'd1;
            end else fj_i2 <= fj_i2 + 16'd4;
            if( !(fj_i2 + 16'd4 >= fj_dbr && fj_blk == 0) ) begin
                if( fj_fill ) st <= F_WH;
                else begin rd( fj_fill ? adr : adr + 24'd4 ); st <= F_RH; end
            end
        end else if( !m_req && rh_run ) begin
            // 0x0d97: the next sprite, or the input bytes
            if( rh_n != 9'd255 ) begin
                rh_n   <= rh_n + 9'd1;
                rh_src <= rh_src - 24'h10; rh_dst <= rh_dst + 24'h10;
                adr <= rh_src - 24'h10; spr <= rh_dst + 24'h10; cp_last <= rh_dst + 24'h22;
                rd( rh_src - 24'h10 ); st <= S_CP_RD;
            end else begin
                rd( { rh_isrc[23:1], 1'b0 } ); st <= S_RH_IN;
            end
        end else if( !m_req ) begin
            cp_seg <= cp_seg + 2'd1;
            if( p4_in && cp_seg == 2'd0 ) begin
                adr <= 24'hc00f20; spr <= 24'hc10f20; cp_last <= 24'hc10f26;
                rd( 24'hc00f20 ); st <= S_CP_RD;
            end else if( p4_in && cp_seg == 2'd1 ) begin
                adr <= 24'hc00f30; spr <= 24'hc0fe00; cp_last <= 24'hc0fe06;
                rd( 24'hc00f30 ); st <= S_CP_RD;
            end else st <= S_END;
        end
        // ---- 0x0d97's input bytes (the source byte is the word's low one)
        S_RH_IN: if( m_ack ) begin v16 <= m_din; st <= S_RH_WB; end
        S_RH_WB: if( !m_req ) begin
            wrb( rh_idst, ~v16[7:0] );
            rh_b <= rh_b + 3'd1;
            if( rh_b == 3'd7 ) begin rh_run <= 1'b0; st <= S_END; end
            else st <= S_RH_NX;
        end
        S_RH_NX: if( !m_req ) begin rd( { rh_isrc[23:1], 1'b0 } ); st <= S_RH_IN; end
        // ---- fantjour_dma_w: a dword is two words, high first
        F_RH: if( m_ack ) begin w_hi <= m_din ^ fj_xr[31:16]; rd( adr + 24'd2 ); st <= F_RL; end
        F_RL: if( m_ack ) begin v16 <= m_din ^ fj_xr[15:0]; st <= F_WH; end
        F_WH: if( !m_req ) begin wr( spr, w_hi ); st <= F_WL; end
        F_WL: if( m_ack ) begin wr( spr + 24'd2, v16 ); st <= S_CP_SEG; end
        // ---- konamigx_esc_alert mode 1
        S2_MG0: if( m_ack ) begin magic_hi <= m_din; rd( W + 24'h71f2 ); st <= S2_MG1; end
        S2_MG1: if( m_ack ) begin
            vmask <= 16'h3ff;
            case( { magic_hi, m_din } )
                32'h10010801: tbl <= 3'd6;
                32'h11010010: begin tbl <= 3'd5; vmask <= 16'h1ff; end
                32'h01111018: tbl <= 3'd4;
                32'h10010011: tbl <= 3'd3;
                32'h11010811: tbl <= 3'd2;
                32'h10000010: tbl <= 3'd1;
                default:      tbl <= 3'd0;
            endcase
            if( { magic_hi, m_din } == 32'h11010111 ) begin
                hcorr <= 0; vcorr <= 0; rd( W + 24'h049c ); st <= S2_VV;
            end else begin rd( W + 24'h26a2 ); st <= S2_VC; end
        end
        S2_VC: if( m_ack ) begin vcorr <= m_din; rd( W + 24'h26a4 ); st <= S2_HC; end
        S2_HC: if( m_ack ) begin hcorr <= m_din - 16'd10; rd( W + 24'h049c ); st <= S2_VV; end
        // the Vic Viper: srcbase[0x049c/4] & 0xffff0000
        S2_VV: if( m_ack ) begin
            if( m_din != 0 ) begin rd( W + 24'h0502 ); st <= S2_VV1; end
            else begin rd( W + 24'h084a ); st <= S2_LB; end
        end
        S2_VV1: if( m_ack ) begin hoffs <= m_din - hcorr; rd( W + 24'h0506 ); st <= S2_VV2; end
        S2_VV2: if( m_ack ) begin
            voffs <= m_din - vcorr; odd <= 1; obase <= W + 24'h049c; ocnt <= 4'd3; phase <= 0;
            owk <= 0; rd( W + 24'h049c ); st <= S2_ORD;
        end
        // Lord British: srcbase[0x0848/4] & 0x0000ffff
        S2_LB: if( m_ack ) begin
            if( m_din != 0 ) begin rd( W + 24'h08b0 ); st <= S2_LB1; end
            else begin g <= 0; gadr <= SRC; rd( SRC ); st <= S2_G0; end
        end
        S2_LB1: if( m_ack ) begin hoffs <= m_din - hcorr; rd( W + 24'h08b4 ); st <= S2_LB2; end
        S2_LB2: if( m_ack ) begin
            voffs <= m_din - vcorr; odd <= 0; obase <= W + 24'h084c; ocnt <= 4'd3; phase <= 1;
            owk <= 0; rd( W + 24'h084c ); st <= S2_ORD;
        end
        // the groups: skipped if the first dword is 0 or the count (+30) is 0
        S2_G0: if( m_ack ) begin w_hi <= m_din; rd( gadr + 24'd2 ); st <= S2_G1; end
        S2_G1: if( m_ack ) begin
            if( w_hi == 0 && m_din == 0 ) st <= S2_GN;
            else begin rd( gadr + 24'd30 ); st <= S2_GC; end
        end
        S2_GC: if( m_ack ) begin
            if( m_din[3:0] == 0 ) st <= S2_GN;
            else begin ocnt <= m_din[3:0]; rd( gadr + 24'd20 ); st <= S2_GH; end
        end
        S2_GH: if( m_ack ) begin hoffs <= m_din - hcorr; rd( gadr + 24'd24 ); st <= S2_GV; end
        S2_GV: if( m_ack ) begin
            voffs <= m_din - vcorr; odd <= 0; obase <= gadr + 24'd32; phase <= 2;
            owk <= 0; rd( gadr + 24'd32 ); st <= S2_ORD;
        end
        S2_GN: begin
            if( g == LAST ) st <= S2_CLR;
            else begin
                g <= g + 9'd1; gadr <= gadr + 24'hc0; rd( gadr + 24'hc0 ); st <= S2_G0;
            end
        end
        // one record: eight words, then the sprite if its flag is set
        S2_ORD: if( m_ack ) begin
            ow[owk] <= m_din;
            if( owk == 3'd7 ) st <= S2_OT;
            else begin owk <= owk + 3'd1; rd( obase + { 20'd0, owk + 3'd1, 1'b0 } ); end
        end
        S2_OT: begin
            dk <= 0;
            st <= rok ? S2_OW : S2_ONEXT;
        end
        S2_OW: if( !m_req ) begin
            if( dk == 3'd7 ) begin
                spr <= spr + 24'd16; j <= j - 9'd1;
                st <= j == 9'd1 ? S_END : S2_ONEXT;   // 256: return
            end else begin
                wr( spr + { 20'd0, dk, 1'b0 }, rd_w ); dk <= dk + 3'd1;
            end
        end
        S2_ONEXT: if( !m_req ) begin
            ocnt <= ocnt - 4'd1;
            if( ocnt == 4'd1 ) begin
                case( phase )
                    2'd0: begin rd( W + 24'h084a ); st <= S2_LB; end
                    2'd1: begin g <= 0; gadr <= SRC; rd( SRC ); st <= S2_G0; end
                    default: st <= S2_GN;
                endcase
            end else begin
                obase <= obase + 24'd16; owk <= 0; rd( obase + 24'd16 ); st <= S2_ORD;
            end
        end
        // clear residual data: word 0 of the slots left
        S2_CLR: if( !m_req ) begin
            if( j == 0 ) st <= S_END;
            else begin wr( spr, 16'd0 ); st <= S2_CLRW; end
        end
        S2_CLRW: if( m_ack ) begin spr <= spr + 24'd16; j <= j - 9'd1; st <= S2_CLR; end
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
            x <= m_din; x_in <= m_din;
            dv_on_y <= zoom_y != 16'h40; dv_ny <= y[15];
            dv_on_x <= zoom_x != 16'h40; dv_nx <= m_din[15];
            if( zoom_y != 16'h40 || zoom_x != 16'h40 ) begin dv_go <= 1; dv_wait <= 0; st <= S_DIVY; end
            else st <= S_POS;
        end
        // both quotients (each divider only where its zoom is not 0x40)
        S_DIVY: if( !dv_go ) begin
            if( !dv_wait ) dv_wait <= 1;                 // the dividers start this clock
            else if( !dvy_busy && !dvx_busy ) begin
                if( dv_on_y ) y <= dv_ny ? -dvy_q : dvy_q;
                if( dv_on_x ) x <= dv_nx ? -dvx_q : dvx_q;
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
        S_CP_NEXT: if( !m_req ) begin rd( adr ); st <= S_CP_RD; end
        S_END: if( !m_req && fj_run ) begin
            busy <= 0; fj_run <= 0; st <= S_IDLE;           // no interrupt
        end else if( !m_req && p4_run ) begin
            irq <= 1; busy <= 0; st <= S_IDLE;
        end else if( !m_req ) begin
            m_req <= 1; m_we <= 1; m_addr <= pkt[23:1] + 23'd4; m_be <= 2'b01;
            m_dout <= 16'h0002; st <= S_DONE;
        end
        S_DONE: if( m_ack ) begin irq <= 1; busy <= 0; st <= S_IDLE; end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule

// q = trunc(n / d), two bits a clock: 11 clocks for the 22-bit dividend,
// busy from the clock after go. The ESC's two zoom divisions use one each.
module gx_esc_div (
    input             clk,
    input             rst,
    input             go,
    input      [21:0] n,
    input      [15:0] d,
    output reg        busy,
    output     [15:0] q
);
reg  [21:0] nr, qr;
reg  [15:0] dr;
reg  [22:0] r;
reg  [ 3:0] k;                   // step: bits 2k+1, 2k
reg  [22:0] t1, t2, r1, r2;
reg         b1, b2;
assign q = qr[15:0];
always @(*) begin
    t1 = { r[21:0], nr[2*k+1] };
    b1 = t1 >= { 7'd0, dr };
    r1 = b1 ? t1 - { 7'd0, dr } : t1;
    t2 = { r1[21:0], nr[2*k] };
    b2 = t2 >= { 7'd0, dr };
    r2 = b2 ? t2 - { 7'd0, dr } : t2;
end
always @(posedge clk) begin
    if( rst ) busy <= 1'b0;
    else if( go ) begin
        busy <= 1'b1; r <= 23'd0; qr <= 22'd0; k <= 4'd10; nr <= n; dr <= d;
    end else if( busy ) begin
        r <= r2;
        qr[2*k+1] <= b1;
        qr[2*k]   <= b2;
        if( k == 4'd0 ) busy <= 1'b0;
        else k <= k - 4'd1;
    end
end
endmodule
