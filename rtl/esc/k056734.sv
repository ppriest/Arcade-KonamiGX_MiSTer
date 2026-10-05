// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami 056734 (ESC): the protection microcontroller of the GX ESC titles,
// run as the chip does rather than per game. Instruction set, kernel and
// image format: konami_056734_manual.md (ppriest/mame-ai-tips, branch
// 056734-cipher); the reference model is scripts/k056734/ (docs/ESC.md).
//
// The internal boot ROM and the boot object's self-tests are not run: on
// reset a loader decrypts the kernel image at 0x200A6C (the boot code's
// stream cipher) into local memory and enters it with the registers the
// boot code leaves (r2, r3, r24, r25, s1). In the model this start gives
// the same results for every packet as running the boot code.
//
// Per chip: s10[15:0], s11[27:24] and the instruction descrambler
// (canonical lane k = lane lanes[k] of stored ^ dxor), from gx_board_cfg.
//
// Local memory is 4K words; addresses 0x1000-0x1FFF alias it, which puts
// the kernel's stack (0x1D80-0x1FFF) at 0xD80. The kernel and every
// program end below that.
//
// Host accesses: one 16-bit bus access per aligned halfword, bytes
// otherwise (images and sets sit at odd addresses). A store to 0xCC0000
// clears the mailbox here and does not reach the bus.
//
// Save states (rtl/gx_ss_layout.svh): `hold` stops the chip at the next
// instruction (or, in the loader, the next kernel word); held, its state is
// on the state bus: ss_hi/ss_lo the halves of local memory, ss_rg the
// register file and the rest (words below). A state taken in the loader is
// restored as a fresh start of it.

module k056734 (
    input             clk,
    input             rst,          // held through the download and while the set has no ESC

    input      [15:0] s10,
    input      [ 3:0] s11n,
    input      [31:0] dxor,
    input      [63:0] dlanes,       // dlanes[4k+3:4k] = lanes[k]

    input             mail_we,      // the CPU's 32-bit write to 0xCC0000
    input      [23:0] mail_data,
    output reg        irq,          // one clock, on s6 bit 1 rising

    output reg        m_req,
    output reg        m_we,
    output reg [23:1] m_addr,
    output reg [ 1:0] m_be,         // { UDS, LDS }
    output reg [15:0] m_dout,
    input      [15:0] m_din,
    input             m_ack,

    input             hold,         // save states: stop at the next instruction
    input             ss_hi, ss_lo, ss_rg,
    input      [11:0] ss_addr,
    input             ss_we,
    input      [15:0] ss_wd,
    output reg [15:0] ss_rd,

    output     [31:0] icount,       // instructions executed (benches)
    output     [15:0] pc_out,
    output            running       // the loader is done
);

// ---------------------------------------------------------- memories
// in halves, so a save state can reach each 16-bit word
wire        held;
wire        ss_m = held && (ss_hi || ss_lo || ss_rg);
reg  [15:0] lmem_h [0:4095];
reg  [15:0] lmem_l [0:4095];
reg  [11:0] lm_a;
reg  [31:0] lm_d;
reg         lm_we;
reg  [31:0] lm_q;
wire [11:0] lma = ss_m ? ss_addr : lm_a;
always @(posedge clk) begin
    if( ss_m ? ss_we && ss_hi : lm_we ) lmem_h[lma] <= ss_m ? ss_wd : lm_d[31:16];
    if( ss_m ? ss_we && ss_lo : lm_we ) lmem_l[lma] <= ss_m ? ss_wd : lm_d[15:0];
    lm_q <= { lmem_h[lma], lmem_l[lma] };
end

reg  [15:0] rf_h [0:63];            // r1-r31, and the s registers not kept below
reg  [15:0] rf_l [0:63];
reg  [ 5:0] rf_ra, rf_wa;
reg  [31:0] rf_wd;
reg         rf_we;
reg  [31:0] rf_q;
wire        ss_rfw = ss_m && ss_rg && ss_we && ss_addr < 12'd128;
wire [ 5:0] rfa_r = ss_m ? ss_addr[6:1] : rf_ra;
wire [ 5:0] rfa_w = ss_m ? ss_addr[6:1] : rf_wa;
always @(posedge clk) begin
    if( ss_rfw ? !ss_addr[0] : rf_we ) rf_h[rfa_w] <= ss_rfw ? ss_wd : rf_wd[31:16];
    if( ss_rfw ?  ss_addr[0] : rf_we ) rf_l[rfa_w] <= ss_rfw ? ss_wd : rf_wd[15:0];
    rf_q <= { rf_h[rfa_r], rf_l[rfa_r] };
end

// ---------------------------------------------------------- state
reg  [15:0] pc;
reg  [31:0] s0, s1, s6, s8, mail;
reg         fz, fn, fc, fv;
reg  [31:0] ir, va, vb, vc;
reg  [31:0] cnt;
reg         run;
assign icount  = cnt;
assign pc_out  = pc;
assign running = run;

wire [31:0] s11 = { 4'd0, s11n, 24'h200100 };

// descramble
function [31:0] descr( input [31:0] w );
    reg [31:0] x;
    integer k;
    begin
        x = w ^ dxor;
        for( k = 0; k < 16; k = k + 1 )
            descr[2*k +: 2] = x[2*dlanes[4*k +: 4] +: 2];
    end
endfunction

// fields (canonical)
wire [1:0] l0 = ir[1:0],   l3 = ir[7:6],   l7 = ir[15:14], l8 = ir[17:16], l10 = ir[21:20];
wire [5:0] fa  = { ir[11:10], ir[31:30], ir[19:18] };          // lanes 5, 15, 9
wire [5:0] fb  = { ir[5:4], ir[3:2], ir[9:8] };                 // lanes 2, 1, 4
wire [9:0] off10 = { ir[13:12], ir[29:28], ir[27:26], ir[25:24], ir[23:22] };   // 6, 14, 13, 12, 11
wire [15:0] imm16 = { fb, off10 };
wire [5:0] fc_ = off10[8:3];        // rC = off10 >> 3 (6 bits of a signed 10)
wire signed [31:0] off = { {22{off10[9]}}, off10 };
wire       is_br = l0 == 2'd0 && ir[11:10] == 2'd2 && l7 == 2'd2 && ir[19:18] == 2'd2 && ir[31:30] == 2'd0;
wire [4:0] rd_li = { 1'b0, l8[0], l3, l10[1], ~l10[0] };
wire [23:0] imm24 = { l7, fa, imm16 };

// register reads with the fixed and kept registers
function [31:0] rdv( input [5:0] n, input [31:0] q );
    case( n )
        6'd0:  rdv = 32'd0;
        6'd32: rdv = s0;
        6'd33: rdv = s1;
        6'd34: rdv = { 16'd0, pc } + 32'd2;
        6'd38: rdv = s6;
        6'd39: rdv = mail;
        6'd40: rdv = s8;
        6'd42: rdv = { 16'd0, s10 };
        6'd43: rdv = s11;
        default: rdv = q;
    endcase
endfunction

// ---------------------------------------------------------- sizes and flags
wire [1:0]  sz   = l7;
wire [31:0] msk  = sz == 2'd1 ? 32'h0000_00ff : sz == 2'd2 ? 32'h0000_ffff : 32'hffff_ffff;
wire [2:0]  nby  = sz == 2'd1 ? 3'd1 : sz == 2'd2 ? 3'd2 : 3'd4;
function topb( input [31:0] v, input [1:0] s );
    topb = s == 2'd1 ? v[7] : s == 2'd2 ? v[15] : v[31];
endfunction

// ---------------------------------------------------------- the host engine
// The sequencer sets rq_* and pulses hx_go; the engine runs the access of
// rq_n bytes and leaves reads, big-endian, in hx_q.
reg  [23:0] rq_a;
reg  [ 2:0] rq_n;
reg         rq_w;
reg  [31:0] rq_d;
reg         hx_go, hx_busy;
reg  [23:0] hx_a;
reg  [ 2:0] hx_n;
reg         hx_w;
reg  [31:0] hx_d, hx_q;
always @(posedge clk) begin
    if( rst ) begin
        hx_busy <= 0; m_req <= 0;
    end else if( hx_go && !hx_busy ) begin
        hx_busy <= 1;
        hx_a <= rq_a; hx_n <= rq_n; hx_w <= rq_w; hx_d <= rq_d; hx_q <= 0;
    end else if( hx_busy && !m_req ) begin
        if( hx_n == 0 ) hx_busy <= 0;
        else if( hx_w && hx_a[23:2] == 22'h330000 ) hx_n <= 0;    // 0xCC0000-3: the mailbox
        else begin
            m_req  <= 1;
            m_we   <= hx_w;
            m_addr <= hx_a[23:1];
            if( !hx_a[0] && hx_n >= 3'd2 ) begin
                m_be   <= 2'b11;
                m_dout <= hx_d[31:16];
            end else begin
                m_be   <= hx_a[0] ? 2'b01 : 2'b10;
                m_dout <= { hx_d[31:24], hx_d[31:24] };
            end
        end
    end else if( m_req && m_ack ) begin
        m_req <= 0;
        if( m_be == 2'b11 ) begin
            hx_q <= { hx_q[15:0], m_din };
            hx_d <= { hx_d[15:0], 16'd0 };
            hx_a <= hx_a + 24'd2;
            hx_n <= hx_n - 3'd2;
        end else begin
            hx_q <= { hx_q[23:0], m_be[1] ? m_din[15:8] : m_din[7:0] };
            hx_d <= { hx_d[23:0], 8'd0 };
            hx_a <= hx_a + 24'd1;
            hx_n <= hx_n - 3'd1;
        end
    end
end
wire hx_done = !hx_go && !hx_busy;

// ---------------------------------------------------------- multiply / divide
reg  [31:0] mul_a, mul_b, mul_p;
reg         mul_h;
reg  [15:0] dv_q, dv_d;
reg  [16:0] dv_r;
reg  [ 4:0] dv_i;

// ---------------------------------------------------------- the sequencer
localparam [5:0]
    S_RST = 0, S_KH = 1, S_KH1 = 2, S_KW = 3, S_KW1 = 4, S_KR = 5,
    S_F0 = 8, S_F1 = 9, S_F2 = 10, S_R1 = 11, S_R2 = 12, S_R3 = 13, S_R4 = 14, S_R5 = 15,
    S_EX = 16, S_HW = 17, S_LR = 18, S_LR1 = 19, S_LM = 20, S_POP = 21, S_POP1 = 22,
    S_MUL = 23, S_MUL1 = 24, S_DIV = 25, S_NEXT = 26;
reg  [5:0]  st;
reg  [15:0] ka, kb, kc, ki;          // kernel A, B, C; words done
reg  [31:0] ks_a, ks_b;               // stream cipher state
reg  [2:0]  kr;                       // register writes left after the load
reg  [3:0]  hop;                      // what to do with a host result
reg  [15:0] npc;
reg         irq_s6;
assign held = hold && (st == S_F0 || st == S_KW);

// state bus reads: registered, a clock after the memories'
reg  [11:0] ss_a1;
reg         ss_h1, ss_l1, ss_r1;
always @(posedge clk) begin
    ss_a1 <= ss_addr; ss_h1 <= ss_m && ss_hi; ss_l1 <= ss_m && ss_lo; ss_r1 <= ss_m && ss_rg;
    ss_rd <= 16'd0;
    if( ss_h1 ) ss_rd <= lm_q[31:16];
    if( ss_l1 ) ss_rd <= lm_q[15:0];
    if( ss_r1 ) case( ss_a1 )
        12'd128: ss_rd <= pc;
        12'd129: ss_rd <= s0[31:16];   12'd130: ss_rd <= s0[15:0];
        12'd131: ss_rd <= s1[31:16];   12'd132: ss_rd <= s1[15:0];
        12'd133: ss_rd <= s6[31:16];   12'd134: ss_rd <= s6[15:0];
        12'd135: ss_rd <= s8[31:16];   12'd136: ss_rd <= s8[15:0];
        12'd137: ss_rd <= mail[31:16]; 12'd138: ss_rd <= mail[15:0];
        12'd139: ss_rd <= { 12'd0, fz, fn, fc, fv };
        12'd140: ss_rd <= { 15'd0, run && st != S_KW };
        default: ss_rd <= ss_a1[0] ? rf_q[15:0] : rf_q[31:16];
    endcase
end

wire [31:0] ks_s = ks_a + ks_b;
wire [31:0] kkey = { 4'd0, s11n, 4'd0, s11n, 4'd0, s11n, 4'd0, s11n } ^ 32'h36AE2592 ^ { s10, s10 };

// flag helpers
task automatic setzn( input [31:0] r );
    begin fz <= (r & msk) == 0; fn <= topb(r, sz); end
endtask
task automatic setadd( input [31:0] a, input [31:0] b, input [32:0] r );
    begin
        fz <= (r[31:0] & msk) == 0; fn <= topb(r[31:0], sz);
        fc <= sz == 2'd1 ? r[8] : sz == 2'd2 ? r[16] : r[32];
        fv <= topb(a, sz) == topb(b, sz) && topb(r[31:0], sz) != topb(a, sz);
    end
endtask
task automatic setsub( input [31:0] a, input [31:0] b, input [31:0] r );
    begin
        fz <= (r & msk) == 0; fn <= topb(r, sz);
        fc <= (a & msk) < (b & msk);
        fv <= topb(a, sz) != topb(b, sz) && topb(r, sz) != topb(a, sz);
    end
endtask
// register write, with the kept s registers
task automatic put( input [5:0] n, input [31:0] v );
    begin
        case( n )
            6'd0, 6'd34, 6'd39, 6'd42, 6'd43: ;
            6'd32: s0 <= v;
            6'd33: s1 <= v;
            6'd38: begin s6 <= v; if( v[1] && !s6[1] ) irq_s6 <= 1; end
            6'd40: s8 <= v;
            default: begin rf_we <= 1; rf_wa <= n; rf_wd <= v; end
        endcase
    end
endtask

// branch condition
reg take_c;
always @* begin
    case( { l10, l8, l3 } )
        6'b01_00_00, 6'b01_01_00: take_c = 1'b1;
        6'b10_00_00: take_c = fz;
        6'b11_00_00: take_c = !fz;
        6'b00_00_01: take_c = fn;
        6'b01_00_01: take_c = !fn;
        6'b10_00_01: take_c = fc;
        6'b11_00_01: take_c = !fc;
        6'b01_00_10: take_c = !fz && fn == fv;
        6'b11_00_10: take_c = !fc && !fz;
        6'b00_00_11: take_c = fn != fv;
        default:     take_c = 1'b0;
    endcase
end

// one-word decode of class 3/2 operations: { lane10, lane8, lane3 }
wire [5:0] op3 = { l10, l8, l3 };
wire [31:0] ea   = vb + off;                    // host byte / local word address
wire [31:0] mskn = ~msk;

reg [32:0] r33;
reg [31:0] r32;

always @(posedge clk) begin
    lm_we <= 0; rf_we <= 0; hx_go <= 0; irq <= 0;
    if( irq_s6 ) begin irq <= 1; irq_s6 <= 0; end
    if( mail_we ) mail <= { 8'd0, mail_data };
    if( rst ) begin
        st <= S_RST; run <= 0; cnt <= 0; irq_s6 <= 0;
        s0 <= 0; s6 <= 0; s8 <= 0; mail <= 0; pc <= 0;
        fz <= 0; fn <= 0; fc <= 0; fv <= 0;
    end else if( ss_m && ss_rg && ss_we ) case( ss_addr )        // a load: the kept registers
        12'd128: pc <= ss_wd;
        12'd129: s0[31:16] <= ss_wd;   12'd130: s0[15:0] <= ss_wd;
        12'd131: s1[31:16] <= ss_wd;   12'd132: s1[15:0] <= ss_wd;
        12'd133: s6[31:16] <= ss_wd;   12'd134: s6[15:0] <= ss_wd;
        12'd135: s8[31:16] <= ss_wd;   12'd136: s8[15:0] <= ss_wd;
        12'd137: mail[31:16] <= ss_wd; 12'd138: mail[15:0] <= ss_wd;
        12'd139: { fz, fn, fc, fv } <= ss_wd[3:0];
        12'd140: begin run <= ss_wd[0]; st <= ss_wd[0] ? S_F0 : S_RST; end
        default: ;
    endcase
    else case( st )
    // ------------------------------------------------ kernel loader
    S_RST: begin
        rq_a <= 24'h200A70; rq_n <= 3'd4; rq_w <= 0; hx_go <= 1;   // A, B
        st <= S_KH;
    end
    S_KH: if( hx_done ) begin
        ka <= hx_q[31:16] ^ 16'h3C96;
        kb <= hx_q[15:0]  ^ 16'hB9E5;
        rq_a <= 24'h200A74; rq_n <= 3'd2; hx_go <= 1;            // C
        st <= S_KH1;
    end
    S_KH1: if( hx_done ) begin
        kc <= hx_q[15:0] ^ 16'h67A5;
        ki <= 0;
        ks_a <= kkey ^ 32'h6E8EF8FC; ks_b <= kkey;
        st <= S_KW;
    end
    S_KW: if( !hold ) begin                                       // the next word, or done
        if( ki == ka + kb ) begin
            kr <= 3'd4; st <= S_KR;
        end else begin
            if( ki == ka ) begin ks_a <= kkey ^ 32'h6E8EF8FC; ks_b <= kkey; end   // data restarts
            rq_a <= 24'h200A84 + { 6'd0, ki, 2'b00 }; rq_n <= 3'd4; hx_go <= 1;
            st <= S_KW1;
        end
    end
    S_KW1: if( hx_done ) begin
        lm_a <= ki[11:0]; lm_d <= hx_q ^ ks_a; lm_we <= 1;
        ks_a <= ks_s;
        ks_b <= ks_b ^ { ks_s[15:0], ks_s[31:16] };
        ki <= ki + 16'd1;
        st <= S_KW;
    end
    S_KR: begin                                                   // r2, r3, r24, r25
        kr <= kr - 3'd1;
        rf_we <= 1;
        case( kr )
            3'd4: begin rf_wa <= 6'd2;  rf_wd <= { 16'd0, ka + kb }; end
            3'd3: begin rf_wa <= 6'd3;  rf_wd <= { 16'd0, ka }; end
            3'd2: begin rf_wa <= 6'd24; rf_wd <= { 16'd0, (ka + kb + kc + 16'd4) & 16'hFFFC }; end
            default: begin rf_wa <= 6'd25; rf_wd <= 32'h2000; end
        endcase
        if( kr == 3'd1 ) begin s1 <= 32'h2000; pc <= 0; run <= 1; st <= S_F0; end
    end
    // ------------------------------------------------ fetch, read operands
    S_F0: if( !hold ) begin lm_a <= pc[11:0]; st <= S_F1; end
    S_F1: st <= S_F2;
    S_F2: begin ir <= descr(lm_q); st <= S_R1; end
    S_R1: begin rf_ra <= fb;  st <= S_R2; end
    S_R2: begin rf_ra <= fc_; st <= S_R3; end
    S_R3: begin vb <= rdv(fb, rf_q);  rf_ra <= fa; st <= S_R4; end
    S_R4: begin vc <= rdv(fc_, rf_q); st <= S_R5; end
    S_R5: begin va <= rdv(fa, rf_q); npc <= pc + 16'd1; cnt <= cnt + 32'd1; st <= S_EX; end
    // ------------------------------------------------ execute
    S_EX: begin
        pc <= npc; st <= S_F0;
        if( ir == 32'd0 ) ;                                        // nop
        else if( l0 == 2'd0 ) begin
            if( is_br ) begin
                if( take_c ) begin
                    pc <= npc + imm16;                              // 16-bit wrap: signed displacement
                    if( { l10, l8, l3 } == 6'b01_01_00 ) begin     // call
                        s1 <= s1 - 32'd1; lm_a <= s1[11:0] - 12'd1; lm_d <= { 16'd0, npc }; lm_we <= 1;
                    end
                end
            end else if( { l10, l8, sz, l3 } == 8'b01_00_10_00 ) pc <= va[15:0] + off[15:0];   // jr
            else if( { l10, l8, sz, l3 } == 8'b01_01_10_00 ) begin                           // jsr
                pc <= va[15:0];
                s1 <= s1 - 32'd1; lm_a <= s1[11:0] - 12'd1; lm_d <= { 16'd0, npc }; lm_we <= 1;
            end else put( { 1'b0, rd_li }, { 8'd0, imm24 } );                               // li
        end else if( l0 == 2'd1 ) begin                            // ld.abs / st.abs (32-bit)
            rq_a <= imm24; rq_n <= 3'd4; rq_w <= l8[1];
            if( l8[1] ) begin                                        // a store reads rD first
                hop <= 4'd0; rf_ra <= { 1'b0, rd_li }; st <= S_LR;
                if( imm24[23:2] == 22'h330000 ) mail <= 0;
            end else begin
                hop <= 4'd1; hx_go <= 1; st <= S_HW;
            end
        end else if( l0 == 2'd3 ) begin
            case( op3 )
            // register ALU: rA = rB op rC
            6'b01_10_00: begin r33 = { 1'b0, vb & msk } + { 1'b0, vc & msk }; setadd(vb, vc, r33); put(fa, (vb & mskn) | (r33[31:0] & msk)); end
            6'b01_10_01: begin r32 = vb - vc; setsub(vb, vc, r32); put(fa, (vb & mskn) | (r32 & msk)); end
            6'b01_10_10: begin r32 = vb & vc; setzn(r32); put(fa, (vb & mskn) | (r32 & msk)); end
            6'b01_10_11: begin r32 = vb ^ vc; setzn(r32); put(fa, (vb & mskn) | (r32 & msk)); end
            6'b11_10_01: begin r32 = vb | vc; setzn(r32); put(fa, (vb & mskn) | (r32 & msk)); end
            6'b11_10_11: begin r32 = ~(vb | vc); setzn(r32); put(fa, (vb & mskn) | (r32 & msk)); end
            // immediate: rA = rA op imm16
            6'b01_11_00: begin r33 = { 1'b0, va & msk } + { 17'd0, imm16 & msk[15:0] }; setadd(va, { 16'd0, imm16 }, r33); put(fa, (va & mskn) | (r33[31:0] & msk)); end
            6'b01_11_01: begin r32 = va - { 16'd0, imm16 }; setsub(va, { 16'd0, imm16 }, r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b01_11_10: begin r32 = va & { 16'd0, imm16 }; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b01_11_11: begin r32 = va ^ { 16'd0, imm16 }; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b11_11_01: begin r32 = va | { 16'd0, imm16 }; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            // host loads and stores, host compares
            6'b10_00_11: begin rq_a <= ea[23:0]; rq_n <= nby; rq_w <= 0; hx_go <= 1; hop <= 4'd1; st <= S_HW; end
            6'b11_00_11: begin
                rq_a <= ea[23:0]; rq_n <= nby; rq_w <= 1; hx_go <= 1; hop <= 4'd0; st <= S_HW;
                rq_d <= sz == 2'd1 ? { va[7:0], 24'd0 } : sz == 2'd2 ? { va[15:0], 16'd0 } : va;
                if( ea[23:2] == 22'h330000 ) mail <= 0;
            end
            6'b00_00_01: begin rq_a <= ea[23:0]; rq_n <= nby; rq_w <= 0; hx_go <= 1; hop <= 4'd2; st <= S_HW; end   // cmp.m
            6'b01_00_01: begin rq_a <= ea[23:0]; rq_n <= nby; rq_w <= 0; hx_go <= 1; hop <= 4'd3; st <= S_HW; end   // cmpm
            // everything else in class 3 reads local memory first
            default: begin lm_a <= ea[11:0]; st <= S_LM; end
            endcase
        end else begin                                             // class 2
            casez( { l10, l8, sz, l3 } )
            8'b01_01_00_00: begin                                    // push
                s1 <= s1 - 32'd1; lm_a <= s1[11:0] - 12'd1; lm_d <= va; lm_we <= 1;
            end
            8'b11_01_00_00: begin lm_a <= s1[11:0]; st <= S_POP; end                    // pop
            8'b01_01_00_01, 8'b11_01_00_01: begin lm_a <= s1[11:0]; st <= S_POP; end    // ret
            8'b01_00_00_11: put(fa, { imm16, va[15:0] });                                // lih
            8'b11_00_00_01: put(fa, { vb[15:0], vb[31:16] });                            // swap16
            8'b01_00_10_01: put(fa, { {16{vb[15]}}, vb[15:0] });                         // ext.h
            8'b01_00_01_01: put(fa, { {24{vb[7]}}, vb[7:0] });                           // ext.b
            8'b11_00_00_00: put(fa, -vb);                                                // 30002, taken as neg
            8'b01_00_00_10: begin mul_a <= va; mul_b <= vb; mul_h <= 0; st <= S_MUL; end  // mul
            8'b01_00_10_10: begin mul_a <= { {16{va[15]}}, va[15:0] }; mul_b <= { {16{vb[15]}}, vb[15:0] }; mul_h <= 1; st <= S_MUL; end
            8'b11_00_10_10: begin                                                        // div.h
                if( vb[15:0] == 0 ) s8 <= 32'h0000_FFFF;
                else begin dv_q <= va[15:0]; dv_d <= vb[15:0]; dv_r <= 0; dv_i <= 5'd16; st <= S_DIV; end
            end
            8'b01_10_??_0?: begin                                    // shl / asl
                r32 = (vb & msk) << 1; setzn(r32); put(fa, (vb & mskn) | (r32 & msk));
            end
            8'b01_10_??_10: begin                                    // rol
                r32 = ((vb & msk) << 1) | { 31'd0, topb(vb, sz) }; setzn(r32); put(fa, (vb & mskn) | (r32 & msk));
            end
            8'b11_10_??_00: begin                                    // shr
                r32 = (vb & msk) >> 1; setzn(r32); put(fa, (vb & mskn) | (r32 & msk));
            end
            8'b11_10_??_01: begin                                    // asr
                r32 = ((vb & msk) >> 1) | (topb(vb, sz) ? (msk ^ (msk >> 1)) : 32'd0); setzn(r32); put(fa, (vb & mskn) | (r32 & msk));
            end
            8'b11_10_??_10: begin                                    // ror
                r32 = ((vb & msk) >> 1) | (vb[0] ? (msk ^ (msk >> 1)) : 32'd0); setzn(r32); put(fa, (vb & mskn) | (r32 & msk));
            end
            default: ;
            endcase
        end
    end
    // ------------------------------------------------ class 1 store: rD's value
    S_LR:  st <= S_LR1;
    S_LR1: begin rq_d <= rdv({ 1'b0, rd_li }, rf_q); hx_go <= 1; st <= S_HW; end
    // ------------------------------------------------ host access done
    S_HW: if( hx_done ) begin
        st <= S_F0;
        case( hop )
            4'd1: put( l0 == 2'd1 ? { 1'b0, rd_li } : fa, hx_q );                  // loads zero-extend
            4'd2: begin r32 = va - hx_q; setsub(va, hx_q, r32); end                  // cmp.m
            4'd3: begin r32 = hx_q - va; setsub(hx_q, va, r32); end                  // cmpm
            default: ;
        endcase
    end
    // ------------------------------------------------ local memory operand
    S_LM: st <= S_NEXT;
    S_NEXT: begin
        st <= S_F0;
        case( op3 )
            6'b10_01_11: put(fa, lm_q & msk);                                        // ld(l)
            6'b11_01_11: begin lm_d <= (lm_q & mskn) | (va & msk); lm_we <= 1; end    // st(l)
            6'b00_01_00: begin r33 = { 1'b0, va & msk } + { 1'b0, lm_q & msk }; setadd(va, lm_q, r33); put(fa, (va & mskn) | (r33[31:0] & msk)); end
            6'b00_01_01: begin r32 = va - lm_q; setsub(va, lm_q, r32); end
            6'b00_01_10: begin r32 = va & lm_q; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b00_01_11: begin r32 = va ^ lm_q; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b10_01_01: begin r32 = va | lm_q; setzn(r32); put(fa, (va & mskn) | (r32 & msk)); end
            6'b01_01_00: begin r33 = { 1'b0, lm_q & msk } + { 1'b0, va & msk }; setadd(lm_q, va, r33); lm_d <= (lm_q & mskn) | (r33[31:0] & msk); lm_we <= 1; end
            6'b01_01_01: begin r32 = lm_q - va; setsub(lm_q, va, r32); lm_d <= (lm_q & mskn) | (r32 & msk); lm_we <= 1; end
            6'b01_01_10: begin r32 = lm_q & va; setzn(r32); lm_d <= (lm_q & mskn) | (r32 & msk); lm_we <= 1; end
            6'b01_01_11: begin r32 = lm_q ^ va; setzn(r32); lm_d <= (lm_q & mskn) | (r32 & msk); lm_we <= 1; end
            default: ;
        endcase
    end
    // ------------------------------------------------ pop / ret
    S_POP:  st <= S_POP1;
    S_POP1: begin
        s1 <= s1 + 32'd1; st <= S_F0;
        if( l3 == 2'd1 ) pc <= lm_q[15:0];                  // ret
        else put(fa, lm_q);                                  // pop
    end
    // ------------------------------------------------ multiply, divide
    S_MUL:  begin mul_p <= mul_a * mul_b; st <= S_MUL1; end
    S_MUL1: begin s8 <= mul_p; st <= S_F0; end
    S_DIV:  begin
        if( dv_i == 0 ) begin s8 <= { 16'd0, dv_q }; st <= S_F0; end
        else begin
            dv_i <= dv_i - 5'd1;
            if( { dv_r[15:0], dv_q[15] } >= { 1'b0, dv_d } ) begin
                dv_r <= { dv_r[15:0], dv_q[15] } - { 1'b0, dv_d };
                dv_q <= { dv_q[14:0], 1'b1 };
            end else begin
                dv_r <= { dv_r[15:0], dv_q[15] };
                dv_q <= { dv_q[14:0], 1'b0 };
            end
        end
    end
    default: st <= S_RST;
    endcase
end

endmodule
