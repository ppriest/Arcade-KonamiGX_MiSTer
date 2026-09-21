// SPDX-License-Identifier: GPL-3.0-or-later
//
// TMS57002 "DASP", the sound board's effects DSP. Written against MAME's
// tms57002 (src/devices/cpu/tms57002, BSD-3-Clause, Olivier Galibert):
// its instruction set (tmsinstr.lst), host interface and external-memory
// stepping, instruction for instruction. scripts/tms57002.py is the same
// thing in Python, checked against MAME's own host traffic
// (scripts/mame/dasp_log.lua); this is checked against that model.
//
// Host side (the sound 68000, through gx_sound):
//   0x300001  data: program/coefficient load, coefficient updates, and the
//             four bytes the program posts with lpc
//   0x500000  status { dready, pc0, empty }
//   0x500001  control: bit 2 PLOAD (active low), bit 3 CLOAD (active low),
//             bit 4 reset released
//
// Execution: one instruction word per two clocks (A, B below), from pc 0 at
// every sample (sync, 48 kHz) until idle. MAME runs the chip at 12 MHz
// (MASTER_CLOCK/2), 250 words a sample, and the games' programs are 250
// words long; this has 500 words' time a sample at 48 MHz, less stalls. A
// sample that runs over keeps its sync pending until idle, where MAME would
// restart the program: a program is written to finish in time, so that is
// a difference only while external memory is slow.
//
// A word holds up to three ops, run in order: a category 2a op ("pre"), a
// category 1 op, a category 2b op ("post", flag changes). Category 3 words
// (branches, loads of ca/id, rptk, idle) are alone.
//   A  the pre op, category 3, the external-memory step, the multiply; ca,
//      id, pc, the pre op's memory write
//   B  the category 1 op (aacc, macc, external-memory requests), the post
//      op; the next word's operand reads
// The next word's program read is issued at the end of A, its operand reads
// at the end of B, so a word's writes (in A) are in memory before the next
// word reads.
//
// External memory (MAME: 256 KB of RAM on the data bus) is SDRAM, through
// x_*: a granule read, or a masked granule write. MAME steps an access one
// byte a word and ignores rde/wre while one is in progress; the same steps
// are counted here, so a program sees the same xrd at the same word. Only
// the SDRAM's own latency is extra, and it is waited for only where it
// shows: an srbd after the read's last step and before its data has come
// (xlate), or an access started while the last is still going out. The
// games' programs start one every 8 words and take each read's data 9
// words after starting it.
//
// Where this departs from MAME, beyond timing:
//   * a word whose pre op (lpc) and category 1 op both read c pops at most
//     one coefficient update; MAME's get_cmem pops once per read
//   * MAME applies a "f" op's st1 change when it first decodes a block as
//     well as when it runs it, so on a block's first run runtime reads of
//     st1 (AOVM, CRM) can see changes from later words. From the second run
//     on, and here always, st1 changes in program order.

module gx_tms57002 (
    input             clk,          // 48 MHz
    input             rst,          // the sound board's reset

    input             h_ctrl_wr,
    input      [ 7:0] h_ctrl,
    input             h_wr,
    input      [ 7:0] h_din,
    input             h_rd,
    output reg [ 7:0] h_dout,       // the clock after h_rd
    output     [ 2:0] status,       // { dready, pc0, empty }

    input             sync,         // a sample: one clock
    input      [95:0] si,           // { si3, si2, si1, si0 }, 24 bits each
    output     [95:0] so,

    output reg        x_req,        // held until x_ack
    output reg        x_we,
    output reg [17:3] x_addr,       // granule within the 256 KB
    output reg [63:0] x_wdata,
    output reg [ 7:0] x_wmask,
    input             x_ack,
    input      [63:0] x_rdata,

    output     [63:0] dbg
);

// ---------------------------------------------------------------- state
reg        pload, cload, in_rst, idle, hostf, upd, rd, wr, cval;
reg  [1:0] su;                  // loading: 0 st0, 1 st1, 2 program
reg [23:0] st0;
reg [21:0] st1;
reg  [7:0] pc, ca, id, ba0, ba1, rptc, rptc_next, sa;
reg [31:0] aacc;
reg [63:0] macc, mw;            // MAME's macc and macc_write
reg [31:0] xoa;
reg [18:0] xba;
reg [23:0] xwr, xrd;
reg  [7:0] host [0:3];
reg  [2:0] hidx;
reg [31:0] upd_q [0:15];
reg  [3:0] uh, ut;
reg [23:0] so_r [0:3];
reg  [2:0] xcnt;                // external-memory steps taken
reg  [2:0] xlo;                 // the access's first byte in its granule
reg [63:0] xg;                  // a read's granule
reg        xg_ok;
reg        xlate;               // a read has taken its last step, its data not yet come
reg        sync_pend;

assign so = { so_r[3], so_r[2], so_r[1], so_r[0] };
wire [23:0] si_w [0:3];
assign si_w[0] = si[23:0];  assign si_w[1] = si[47:24];
assign si_w[2] = si[71:48]; assign si_w[3] = si[95:72];

localparam ST1_AOV = 0, ST1_SFAI = 1, ST1_SFAO = 2, ST1_AOVM = 3, ST1_MOVM = 5,
           ST1_MOV = 6, ST1_DBP = 20;
wire [1:0] sfma = st1[8:7];
wire [1:0] crm  = st1[19:18];

assign status = { !hostf, pc != 8'd0, uh == ut };

// external-memory geometry (xm_init/xm_step_*): bytes per access and the
// address shift, from st0's WORD and SEL
wire       m_word = st0[14], m_sel = st0[15];
wire [2:0] xn     = m_word ? (m_sel ? 3'd3 : 3'd6) : (m_sel ? 3'd2 : 3'd4);
wire [1:0] xsh    = m_word ? (m_sel ? 2'd2 : 2'd3) : (m_sel ? 2'd1 : 2'd2);

// ---------------------------------------------------------------- memories
localparam [1:0] S_HALT = 0, S_F = 1, S_A = 2, S_B = 3;
reg  [1:0] st;
reg        s_r;                 // in S_F: the program word is being read

wire [7:0]  p_ra;
wire [23:0] p_q;
reg         p_we;
reg  [7:0]  p_wa;
reg  [23:0] p_d;
gx_sdpram #(.AW(8), .DW(24)) u_pmem ( .clk, .we(p_we), .wa(p_wa), .d(p_d), .ra(p_ra), .q(p_q) );

// the host's writes (only while loading, the DSP stopped) are registered;
// stage A's go straight in, so they land at the end of A, before the next
// word's reads at the end of B (a read in the same clock as a write gets
// the old data)
wire [7:0]  c_ra;
wire [31:0] c_q;
reg         c_we;
reg  [7:0]  c_wa;
reg  [31:0] c_d;
wire        a_fire;
wire        a_cw, a_dw;
wire [7:0]  a_cwa;
wire [31:0] a_cd;
wire [8:0]  a_dwa;
wire [23:0] a_dd;
gx_sdpram #(.AW(8), .DW(32)) u_cmem ( .clk, .we(c_we || a_cw), .wa(a_cw ? a_cwa : c_wa),
    .d(a_cw ? a_cd : c_d), .ra(c_ra), .q(c_q) );

// dmem0 (256 words) and dmem1 (32) in one: bit 8 is the bank
wire [8:0]  d_ra;
wire [23:0] d_q;
gx_sdpram #(.AW(9), .DW(24)) u_dmem ( .clk, .we(a_dw), .wa(a_dwa), .d(a_dd), .ra(d_ra), .q(d_q) );

// ---------------------------------------------------------------- decode
// the operands each op takes (tmsmake.py: the ops whose body uses %c/%d),
// for the ca/id post-increments, which are decided at decode whether or
// not the op then does anything
function automatic [1:0] use1( input [5:0] o );     // { c, d }
    case( o )
    6'h03, 6'h05, 6'h09, 6'h0b, 6'h11, 6'h14, 6'h17, 6'h25, 6'h2a,
    6'h31, 6'h32:                                   use1 = 2'b01;
    6'h04, 6'h06, 6'h0a, 6'h0c, 6'h12, 6'h15, 6'h18, 6'h22, 6'h26,
    6'h2e, 6'h33, 6'h39:                            use1 = 2'b10;
    6'h07, 6'h0d, 6'h16, 6'h19, 6'h21, 6'h24, 6'h28, 6'h29, 6'h38:
                                                    use1 = 2'b11;
    default:                                        use1 = 2'b00;
    endcase
endfunction
function automatic [1:0] use2( input [6:0] o );
    case( o )
    7'h01, 7'h05, 7'h31:                            use2 = 2'b10;
    7'h02, 7'h03, 7'h06, 7'h07, 7'h0f,
    7'h10, 7'h11, 7'h12, 7'h13:                     use2 = 2'b01;
    default:                                        use2 = 2'b00;
    endcase
endfunction

// an operand's address: bit 10 picks which of c and d may be direct
// (tms57kdec.cpp xmode)
function automatic [8:0] daddr( input [23:0] op, input [7:0] id_, input dbp,
                                input [7:0] b0, input [7:0] b1 );
    reg [7:0] ix;
    begin
        ix = ( !op[10] && op[8] ) ? op[7:0] : id_;
        daddr = dbp ? { 1'b1, 3'd0, 5'(ix + b1) } : { 1'b0, 8'(ix + b0) };
    end
endfunction
function automatic [7:0] caddr( input [23:0] op, input [7:0] ca_ );
    caddr = ( op[10] && op[8] ) ? op[7:0] : ca_;
endfunction

// ---------------------------------------------------------------- macc out
// macc_to_output_N(s) and check_macc_overflow_N(s): { overflow, value }
localparam [63:0] OV0 = 64'h000f800000000000, OV1 = 64'h000fe00000000000,
                  OV2 = 64'h000ff80000000000;
function automatic ovf_chk( input [63:0] m, input [63:0] msk );
    ovf_chk = (m & msk) != 64'd0 && (m & msk) != msk;
endfunction
function automatic [63:0] sat( input [63:0] m );
    sat = m[51] ? 64'hffff800000000000 : 64'h00007fffffffffff;
endfunction
function automatic [64:0] mo_f( input [63:0] m, input [1:0] sfmo, input [2:0] rnd, input movm );
    reg        over;
    reg [63:0] v, rm, ro;
    begin
        case( sfmo )
        2'd0: begin over = ovf_chk(m, OV0); v = m; end
        2'd1: begin over = ovf_chk(m, OV1); v = m << 2; end
        2'd2: begin over = ovf_chk(m, OV2); v = m << 4; end
        default: begin over = 1'b0; v = { {8{m[63]}}, m[63:8] }; end
        endcase
        case( rnd )
        3'd1: begin ro = 64'h1 << 15; rm = ~64'hffff; end
        3'd2: begin ro = 64'h1 << 23; rm = ~64'hffffff; end
        3'd3: begin ro = 64'h1 << 17; rm = ~64'h3ffff; end
        3'd4: begin ro = 64'h1 << 31; rm = ~64'hffffffff; end
        default: begin ro = 64'd0; rm = ~64'd0; end
        endcase
        v = (v + ro) & rm;
        over = over | ovf_chk(v, OV0);
        mo_f = { over, (over && movm) ? sat(v) : v };
    end
endfunction
function automatic [64:0] mv_f( input [63:0] m, input [1:0] sfmo, input movm );
    reg over;
    begin
        case( sfmo )
        2'd0: over = ovf_chk(m, OV0);
        2'd1: over = ovf_chk(m, OV1);
        2'd2: over = ovf_chk(m, OV2);
        default: over = 1'b0;
        endcase
        mv_f = { over, (over && movm) ? sat(m) : m };
    end
endfunction

// the current word, and what was prepared for it at the end of the last
reg [23:0] op;
reg [63:0] mo_r, mv_r;          // %mo, %mv: from macc_read, with st1 as of this word
reg        mo_ov, mv_ov;
wire       is3  = op[23:18] == 6'h3f;
wire [5:0] o1   = is3 ? 6'd0 : op[23:18];
wire [6:0] o2   = is3 ? 7'd0 : op[17:11];
wire [6:0] o3   = op[17:11];
wire [7:0] prm  = op[7:0];
wire [1:0] u1   = use1(o1), u2 = use2(o2);
wire       usec = u1[1] | u2[1], used = u1[0] | u2[0];
wire       cinc = usec && ( op[10] ? (!op[8] && op[7]) : op[9] );
wire       dinc = used && ( !op[10] ? (!op[8] && op[7]) : op[9] );
wire [7:0] cadr = caddr(op, ca);
wire [8:0] dadr = daddr(op, id, st1[ST1_DBP], ba0, ba1);

wire [31:0] a_val = st1[ST1_SFAO] ? { aacc[24:0], 7'd0 } : aacc;      // %a

// ================================================================ stage A
// the external-memory step (MAME: at the start of the word, before its ops)
wire        xstep  = rd || wr;
wire        xdone  = xstep && xcnt == xn - 3'd1;
wire        xnew   = xlate || (xdone && rd);         // xrd is the last read's
wire        xstall = xnew && !xg_ok && op[17:11] == 7'h0f && !is3;   // srbd needs it
function automatic [23:0] xasm( input [63:0] g, input [2:0] lo, input word, input sel );
    integer k;
    reg [7:0] b;
    reg [23:0] v;
    begin
        v = 24'd0;
        for( k=0; k<6; k=k+1 ) begin
            b = lo + k < 8 ? g[8*(lo+k) +: 8] : 8'd0;
            if( sel ) begin
                if( k < (word ? 3 : 2) ) v = v | ( {16'd0, b} << (16 - 8*k) );
            end else begin
                if( k < (word ? 6 : 4) ) v = v | ( {20'd0, b[3:0]} << (20 - 4*k) );
            end
        end
        xasm = v;
    end
endfunction
wire [23:0] xrd_n = xnew && xg_ok ? xasm(xg, xlo, m_word, m_sel) : xrd;

// coefficient read: a pending update replaces it (get_cmem)
// lpc, rde and wre return before reading c when the host latch or an
// access is busy (MAME), so they pop nothing then
wire        xbusy_a = xstep && !xdone;                     // an access still going, after the step
wire        crd    = ( u1[1] && !((o1 == 6'h38 || o1 == 6'h39) && xbusy_a) )
                  || ( o2 == 7'h31 && !hostf );
wire        pop    = crd && ( upd || (sa == cadr && uh != ut) );
wire [31:0] updv   = upd_q[ut];
function automatic [31:0] crm_f( input [31:0] v, input [1:0] m );
    crm_f = m == 2'd1 ? { v[31:16], 16'd0 } : m == 2'd2 ? { v[15:0], 16'd0 } : v;
endfunction

// the pre op
reg         pre_cw, pre_dw;
reg  [31:0] pre_c;
reg  [23:0] pre_d;
reg         pre_mo, pre_mv;             // it used %mo / %mv
always @* begin
    pre_cw = 1'b0; pre_dw = 1'b0; pre_c = a_val; pre_d = 24'd0;
    pre_mo = 1'b0; pre_mv = 1'b0;
    case( o2 )
    7'h01: pre_cw = 1'b1;                                               // sacc
    7'h02: begin pre_dw = 1'b1; pre_d = a_val[31:8]; end                // sacd
    7'h03: begin pre_dw = 1'b1; pre_d = mo_r[47:24]; pre_mo = 1'b1; end // smhd
    7'h05: begin pre_cw = 1'b1; pre_c = mo_r[47:16]; pre_mo = 1'b1; end // smhc
    7'h06: begin pre_dw = 1'b1; pre_d = { mv_r[47:32], 8'd0 }; pre_mv = 1'b1; end   // slmh
    7'h07: begin pre_dw = 1'b1; pre_d = mv_r[31:8]; pre_mv = 1'b1; end  // slml
    7'h0f: begin pre_dw = 1'b1; pre_d = xrd_n; end                      // srbd
    7'h10, 7'h11, 7'h12, 7'h13: begin pre_dw = 1'b1; pre_d = si_w[o2[1:0]]; end   // dis
    7'h20, 7'h21, 7'h22, 7'h23: pre_mo = 1'b1;                          // domh
    default: ;
    endcase
end

// the category 1 op's operands, after the pre op's writes
wire [31:0] c_raw  = pre_cw ? pre_c : c_q;
wire [31:0] c1v    = pop ? updv : crm_f(c_raw, crm);
wire [23:0] d1v    = pre_dw ? pre_d : d_q;

// the multiply (the mpy/mac family), registered for B
wire        m_ua   = o1 == 6'h25 || o1 == 6'h2a;                     // X is %a
wire        m_ya   = o1 == 6'h22 || o1 == 6'h26 || o1 == 6'h2e;      // Y is %a
wire        m_uns  = o1 == 6'h28 || o1 == 6'h29 || o1 == 6'h2a;      // d unsigned
wire signed [31:0] mx = m_ua ? a_val : c1v;
wire signed [32:0] my = m_ya  ? { a_val[31], a_val }
                      : m_uns ? { 9'd0, d1v } : { {9{d1v[23]}}, d1v };
wire signed [64:0] mprod = mx * my;

// category 3
wire        aneg = aacc[31], az = aacc == 32'd0;
reg         br;
always @* begin
    br = 1'b0;
    if( is3 ) case( o3 )
        7'h48: br = 1'b1;                                   // b
        7'h50: br = !aneg && !az;                           // bgz
        7'h58: br = aneg;                                   // blz
        7'h60: br = !az;                                    // bnz
        7'h78: br = st1[ST1_AOV];                           // bv
        default: ;
    endcase
end

// ca, id, pc after this word
reg [7:0] ca_n, id_n, pc_n, rptc_n, rptcn_n;
always @* begin
    ca_n = ca; id_n = id;
    if( is3 ) case( o3 )
        7'h18: ca_n = prm;                                  // lcak
        7'h40: if( !aneg ) ca_n = prm;                      // lcac
        7'h20: id_n = prm;                                  // lirk
        default: ;
    endcase
    if( o2 == 7'h08 ) ca_n = a_val[31:24];                  // lcaa
    if( o2 == 7'h09 ) id_n = a_val[31:24];                  // lira
    if( cinc ) ca_n = ca_n + 8'd1;
    if( dinc ) id_n = id_n + 8'd1;
    rptcn_n = rptc_next;
    if( is3 && o3 == 7'h10 ) rptcn_n = prm;                 // rptk
    rptc_n = rptc;
    pc_n   = pc;
    if( rptc != 8'd0 ) rptc_n = rptc - 8'd1;
    else if( br )      pc_n = prm;
    else               pc_n = pc + 8'd1;
    if( rptcn_n != 8'd0 ) begin rptc_n = rptcn_n; rptcn_n = 8'd0; end
end

// ================================================================ stage B
reg  [5:0]  b_o1;
reg  [6:0]  b_o2;
reg  [31:0] b_c;
reg  [23:0] b_d;
reg  signed [64:0] b_prod;
reg         b_mov;              // MOV from the pre op

wire [31:0] b_d32  = { b_d, 8'd0 };
wire [31:0] b_dsf  = st1[ST1_SFAI] ? { b_d32[31], b_d32[31:1] } : b_d32;   // %sfai
wire signed [63:0] b_ml = sfma == 2'd0 ? macc : sfma == 2'd1 ? (macc << 2)
                        : sfma == 2'd2 ? (macc << 4) : { {16{macc[63]}}, macc[63:16] };
wire signed [63:0] mo16 = { {16{mo_r[63]}}, mo_r[63:16] };

reg         wa_en, abs_ov, mo_used, b_iss;
reg  signed [49:0] wa_r;
reg  [31:0] aacc_n;
reg  [63:0] macc_n;
reg         lm;                  // lmhc/lmhd/lmld: macc_write too
always @* begin
    wa_en = 1'b0; wa_r = 50'sd0; abs_ov = 1'b0; mo_used = 1'b0; b_iss = 1'b0; lm = 1'b0;
    aacc_n = aacc; macc_n = macc;
    case( b_o1 )
    6'h01: begin aacc_n = a_val; if( a_val[31] ) begin aacc_n = -a_val; abs_ov = aacc_n[31]; end end
    6'h02: begin wa_en = 1'b1; wa_r = -$signed({ 18'd0, a_val }); end
    6'h03: begin wa_en = 1'b1; wa_r = $signed(b_d32) + $signed(a_val); end
    6'h04: begin wa_en = 1'b1; wa_r = $signed(b_c) + $signed(a_val); end
    6'h05: begin wa_en = 1'b1; wa_r = $signed(b_dsf) + mo16; mo_used = 1'b1; end
    6'h06: begin wa_en = 1'b1; wa_r = $signed(b_c) + mo16; mo_used = 1'b1; end
    6'h07: begin wa_en = 1'b1; wa_r = $signed(b_d32) + $signed(b_c); end
    6'h09: begin wa_en = 1'b1; wa_r = $signed(b_d32) - $signed(a_val); end
    6'h0a: begin wa_en = 1'b1; wa_r = $signed(b_c) - $signed(a_val); end
    6'h0b: begin wa_en = 1'b1; wa_r = $signed(b_dsf) - mo16; mo_used = 1'b1; end
    6'h0c: begin wa_en = 1'b1; wa_r = $signed(b_c) - mo16; mo_used = 1'b1; end
    6'h0d: begin wa_en = 1'b1; wa_r = $signed(b_d32) - $signed(b_c); end
    6'h11: aacc_n = b_dsf;                                              // lacd
    6'h12: aacc_n = b_c;                                                // lacc
    6'h14: aacc_n = aacc & b_dsf;
    6'h15: aacc_n = aacc & b_c;
    6'h16: aacc_n = b_c & b_dsf;
    6'h17: aacc_n = aacc | b_dsf;
    6'h18: aacc_n = aacc | b_c;
    6'h19: aacc_n = b_c | b_dsf;
    6'h21, 6'h22, 6'h28: macc_n = b_o1 == 6'h22 ? 64'(b_prod >>> 15) : 64'(b_prod >>> 7);
    6'h24, 6'h25, 6'h29, 6'h2a: macc_n = b_ml + 64'(b_prod >>> 7);
    6'h26: macc_n = b_ml + 64'(b_prod >>> 15);
    6'h2e: macc_n = b_ml + 64'(b_prod >>> 14);
    6'h31: begin lm = 1'b1; macc_n = { {16{b_d[23]}}, b_d, 24'd0 }; end            // lmhd
    6'h32: begin lm = 1'b1; macc_n = { macc[63:24], b_d }; end                     // lmld
    6'h33: begin lm = 1'b1; macc_n = { {16{b_c[31]}}, b_c, 16'd0 }; end            // lmhc
    6'h34: macc_n = { 12'd0, macc[51], macc[49:0], 1'b0 };                         // sfml
    6'h35: macc_n = { 12'd0, macc[51], macc[51:1] };                               // sfmr
    6'h38, 6'h39: b_iss = !(rd || wr);                                             // wre, rde
    default: ;
    endcase
end
wire wa_ov  = wa_en && ( wa_r < -50'sd2147483648 || wa_r > 50'sd2147483647 );
wire [31:0] wa_v = ( wa_ov && st1[ST1_AOVM] ) ? ( wa_r < 0 ? 32'h80000000 : 32'h7fffffff )
                                              : wa_r[31:0];
wire bstall = b_iss && x_req;

// st1 after this word's category 1 and post ops
reg [21:0] st1_n;
always @* begin
    st1_n = st1;
    if( wa_ov || abs_ov ) st1_n[ST1_AOV] = 1'b1;
    if( mo_used && mo_ov ) st1_n[ST1_MOV] = 1'b1;
    case( b_o2 )
    7'h3a: st1_n[ST1_MOV]  = 1'b0;
    7'h3c: st1_n[ST1_AOVM] = 1'b0;
    7'h3d: st1_n[ST1_AOVM] = 1'b1;
    7'h40: st1_n[ST1_MOVM] = 1'b0;
    7'h41: st1_n[ST1_MOVM] = 1'b1;
    7'h44: st1_n[ST1_DBP]  = 1'b0;
    7'h45: st1_n[ST1_DBP]  = 1'b1;
    7'h48, 7'h49, 7'h4a, 7'h4b: st1_n[19:18] = b_o2[1:0];
    7'h50: st1_n[ST1_SFAO] = 1'b0;
    7'h51: st1_n[ST1_SFAO] = 1'b1;
    7'h54: st1_n[ST1_SFAI] = 1'b0;
    7'h55: st1_n[ST1_SFAI] = 1'b1;
    7'h58, 7'h59, 7'h5a, 7'h5b: st1_n[8:7]   = b_o2[1:0];
    7'h60, 7'h61, 7'h62, 7'h63: st1_n[12:11] = b_o2[1:0];
    7'h68, 7'h69, 7'h6a, 7'h6b, 7'h6c, 7'h6d, 7'h6e, 7'h6f: st1_n[17:15] = b_o2[2:0];
    default: ;
    endcase
end

// the next word's %mo/%mv: macc_read for it is macc_write after this word
wire [63:0] mr_n   = lm ? macc_n : mw;
wire [2:0]  rnd_n  = st1_n[17:15] > 3'd4 ? 3'd0 : st1_n[17:15];
wire [64:0] mo_n   = mo_f(mr_n, st1_n[12:11], rnd_n, st1_n[ST1_MOVM]);
wire [64:0] mv_n   = mv_f(mr_n, st1_n[12:11], st1_n[ST1_MOVM]);
// at a fresh start (S_F) nothing is pending: macc_write as it stands
wire [2:0]  rnd_c  = st1[17:15] > 3'd4 ? 3'd0 : st1[17:15];
wire [64:0] mo_c   = mo_f(mw, st1[12:11], rnd_c, st1[ST1_MOVM]);
wire [64:0] mv_c   = mv_f(mw, st1[12:11], st1[ST1_MOVM]);

// ================================================================ reads
// program: the word after this one, at the end of A; otherwise pc
assign p_ra = st == S_A ? pc_n : pc;
// operands: at the end of S_F (the first word) and of B (the next), from
// the program word read then; held otherwise
reg  [7:0] c_ra_r;
reg  [8:0] d_ra_r;
wire       prep  = (st == S_F && s_r) || (st == S_B && !bstall);
wire [7:0] c_ra_n = caddr(p_q, ca);
wire [8:0] d_ra_n = daddr(p_q, id, st == S_B ? st1_n[ST1_DBP] : st1[ST1_DBP], ba0, ba1);
assign c_ra = prep ? c_ra_n : c_ra_r;
assign d_ra = prep ? d_ra_n : d_ra_r;

// ================================================================ control
wire run_ok  = !idle && !pload && !in_rst;
wire host_wr = h_wr || h_ctrl_wr;
wire astall  = xstall || host_wr;
assign a_fire = st == S_A && run_ok && !astall;
assign a_cw   = a_fire && (pre_cw || pop);
assign a_cwa  = cadr;
assign a_cd   = pop ? updv : pre_c;
assign a_dw   = a_fire && pre_dw;
assign a_dwa  = dadr;
assign a_dd   = pre_d;

integer i;
always @(posedge clk) begin
    p_we <= 1'b0; c_we <= 1'b0;
    if( sync ) sync_pend <= 1'b1;
    if( x_ack ) begin
        x_req <= 1'b0;
        if( !x_we ) begin xg <= x_rdata; xg_ok <= 1'b1; end
    end
    if( prep ) begin
        op <= p_q; c_ra_r <= c_ra_n; d_ra_r <= d_ra_n;
    end
    if( xlate && xg_ok ) begin xrd <= xasm(xg, xlo, m_word, m_sel); xlate <= 1'b0; end

    if( rst ) begin
        st <= S_HALT; s_r <= 1'b0;
        pload <= 1'b0; cload <= 1'b0; in_rst <= 1'b1; idle <= 1'b1;
        hostf <= 1'b0; upd <= 1'b0; rd <= 1'b0; wr <= 1'b0; cval <= 1'b0;
        su <= 2'd0; hidx <= 3'd0; uh <= 4'd0; ut <= 4'd0;
        pc <= 8'd0; ca <= 8'd0; id <= 8'd0; ba0 <= 8'd0; ba1 <= 8'd0;
        rptc <= 8'd0; rptc_next <= 8'd0; sa <= 8'd0;
        xba <= 19'd0; xoa <= 32'd0; st0 <= 24'd0; st1 <= 22'd0;
        x_req <= 1'b0; xg_ok <= 1'b0; xlate <= 1'b0; sync_pend <= 1'b0;
        for( i=0; i<4; i=i+1 ) so_r[i] <= 24'd0;
    end else begin
        // ------------------------------------------------ host
        if( h_rd && hostf ) begin
            hidx <= hidx + 3'd1;
            if( hidx == 3'd3 ) begin hidx <= 3'd0; hostf <= 1'b0; end
        end
        if( h_wr ) begin
            case( { pload, cload } )
            2'b00: begin hidx <= 3'd0; cval <= 1'b0; end
            2'b10: begin
                host[hidx[1:0]] <= h_din;
                hidx <= hidx + 3'd1;
                if( hidx == 3'd2 ) begin
                    hidx <= 3'd0;
                    case( su )
                    2'd0: begin st0 <= { host[0], host[1], h_din }; su <= 2'd1; end
                    2'd1: begin st1 <= 22'({ host[0], host[1], h_din }); su <= 2'd2; end
                    default: begin
                        p_we <= 1'b1; p_wa <= pc; p_d <= { host[0], host[1], h_din };
                        pc <= pc + 8'd1;
                    end
                    endcase
                end
            end
            2'b01: if( cval ) begin
                host[hidx[1:0]] <= h_din;
                hidx <= hidx + 3'd1;
                if( hidx == 3'd3 ) begin
                    upd_q[uh] <= { host[0], host[1], host[2], h_din };
                    uh <= uh + 4'd1;
                    cval <= 1'b0;
                    hidx <= 3'd1;           // as MAME
                end
            end else begin
                sa <= h_din; hidx <= 3'd0; cval <= 1'b1;
            end
            2'b11: begin
                host[hidx[1:0]] <= h_din;
                hidx <= hidx + 3'd1;
                if( hidx == 3'd3 ) begin
                    hidx <= 3'd0;
                    c_we <= 1'b1; c_wa <= ca; c_d <= { host[0], host[1], host[2], h_din };
                    ca <= ca + 8'd1;
                end
            end
            endcase
        end
        if( h_ctrl_wr ) begin
            pload <= !h_ctrl[2];
            cload <= !h_ctrl[3];
            in_rst <= !h_ctrl[4];
            if( !h_ctrl[2] && !pload ) begin
                hidx <= 3'd0; pc <= 8'd0; ca <= 8'd0; su <= 2'd0;
            end
            if( !h_ctrl[3] && !cload ) hidx <= 3'd0;
            // MAME resets a CPU when its reset line is released (diexec.cpp)
            if( in_rst && h_ctrl[4] ) begin
                su <= 2'd0; rd <= 1'b0; wr <= 1'b0; hostf <= 1'b0; upd <= 1'b0; xlate <= 1'b0;
                idle <= 1'b1;
                pc <= 8'd0; ca <= 8'd0; hidx <= 3'd0; id <= 8'd0;
                ba0 <= 8'd0; ba1 <= 8'd0; sa <= 8'd0;
                rptc <= 8'd0; rptc_next <= 8'd0; uh <= 4'd0; ut <= 4'd0;
                st0[13:0] <= st0[13:0] & 14'h0010;
                st1 <= st1 & 22'h200000;            // CAS stays
                xba <= 19'd0; xoa <= 32'd0;
            end
        end

        // ------------------------------------------------ execution
        case( st )
        S_HALT: begin
            s_r <= 1'b0;
            if( sync_pend && !pload && !host_wr ) begin
                sync_pend <= 1'b0;
                pc <= 8'd0; ca <= 8'd0; id <= 8'd0;
                if( !st0[0] ) begin ba0 <= ba0 - 8'd1; ba1 <= ba1 + 8'd1; end
                xba <= xba - 19'd1;
                st1[ST1_AOV] <= 1'b0; st1[ST1_MOV] <= 1'b0;
                idle <= 1'b0;
            end else if( run_ok && !host_wr ) st <= S_F;
        end
        // the program word at pc is read (s_r 0), then its operands (s_r 1)
        S_F: begin
            if( !run_ok || host_wr ) st <= S_HALT;
            else if( !s_r ) s_r <= 1'b1;
            else begin
                s_r <= 1'b0;
                { mo_ov, mo_r } <= mo_c;
                { mv_ov, mv_r } <= mv_c;
                st <= S_A;
            end
        end
        S_A: if( !run_ok ) st <= S_HALT;
        else if( !astall ) begin
            // the external-memory step
            if( xstep ) begin
                xcnt <= xcnt + 3'd1;
                if( xdone ) begin
                    rd <= 1'b0; wr <= 1'b0;
                    if( rd ) xlate <= 1'b1;
                end
            end
            // macc_write = macc (MAME's macc_read = macc_write was done in
            // preparing mo_r)
            mw <= macc;
            // the pre op
            if( pop ) begin
                ut <= ut + 4'd1;
                upd <= ut + 4'd1 != uh;
            end
            if( o2[6:2] == 5'b01000 ) so_r[o2[1:0]] <= mo_r[47:24];     // domh
            if( o2 == 7'h31 && !hostf ) begin                           // lpc
                host[0] <= c1v[31:24]; host[1] <= c1v[23:16];
                host[2] <= c1v[15:8];  host[3] <= c1v[7:0];
                hidx <= 3'd0; hostf <= 1'b1;
            end
            if( (pre_mo && mo_ov) || (pre_mv && mv_ov) ) st1[ST1_MOV] <= 1'b1;
            // category 3
            if( is3 && o3 == 7'h78 && st1[ST1_AOV] ) st1[ST1_AOV] <= 1'b0;   // bv
            if( is3 && o3 == 7'h08 ) idle <= 1'b1;
            ca <= ca_n; id <= id_n; pc <= pc_n; rptc <= rptc_n; rptc_next <= rptcn_n;
            // for B
            b_o1 <= o1; b_o2 <= o2; b_c <= c1v; b_d <= d1v; b_prod <= mprod;
            st <= S_B;
        end
        S_B: if( !bstall ) begin
            aacc <= wa_en ? wa_v : aacc_n;
            macc <= macc_n;
            if( lm ) mw <= macc_n;
            st1  <= st1_n;
            if( b_iss ) begin
                xcnt <= 3'd0; xg_ok <= 1'b0;
                if( b_o1 == 6'h38 ) begin
                    wr <= 1'b1; xwr <= b_d;
                end else rd <= 1'b1;
                xoa <= b_c;
                x_req <= 1'b1; x_we <= b_o1 == 6'h38;
            end
            { mo_ov, mo_r } <= mo_n;
            { mv_ov, mv_r } <= mv_n;
            st <= ( idle || !run_ok ) ? S_HALT : S_A;
        end
        default: st <= S_HALT;
        endcase
    end
end

// the access's address and bytes (xm_init; xm_step_write's bytes, all at
// once: nothing else can touch memory before the steps are done)
wire [31:0] xbyte = ( b_c + { 13'd0, xba } ) << xsh;
always @(posedge clk) if( st == S_B && !bstall && b_iss ) begin
    x_addr <= xbyte[17:3];
    xlo    <= xbyte[2:0];
    for( int j=0; j<8; j=j+1 ) begin
        x_wmask[j] <= 1'b0;
        x_wdata[8*j +: 8] <= 8'd0;
        if( j >= xbyte[2:0] && j < xbyte[2:0] + xn ) begin
            x_wmask[j] <= b_o1 == 6'h38;
            x_wdata[8*j +: 8] <= m_sel ? 8'(b_d >> (16 - 8*(j - xbyte[2:0])))
                                       : { 4'd0, 4'(b_d >> (20 - 4*(j - xbyte[2:0]))) };
        end
    end
end

always @(posedge clk) if( h_rd ) h_dout <= hostf ? host[hidx[1:0]] : 8'hff;

// ---------------------------------------------------------------- probe
// the longest sample (clocks from its sync being taken to idle, of 1000),
// syncs that came while a sample was still running, samples run
reg [11:0] smp_clk, smp_max, ovr;
reg [13:0] smps;
always @(posedge clk) begin
    if( rst ) begin
        smp_clk <= 12'd0; smp_max <= 12'd0; ovr <= 12'd0; smps <= 14'd0;
    end else begin
        if( st != S_HALT && smp_clk != 12'hfff ) smp_clk <= smp_clk + 12'd1;
        if( st == S_HALT && sync_pend && !pload && !host_wr ) begin
            smp_clk <= 12'd0;
            smps <= smps + 14'd1;
        end
        if( smp_clk > smp_max ) smp_max <= smp_clk;
        if( sync && st != S_HALT && ovr != 12'hfff ) ovr <= ovr + 12'd1;
    end
end
assign dbg = { smps, ovr, smp_max, st, pload, cload, in_rst, idle, hostf, rd, wr, x_req,
               ut, uh, pc };

endmodule
