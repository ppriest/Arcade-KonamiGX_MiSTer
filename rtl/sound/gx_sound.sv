// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GX sound board for Phase 3a: the sound 68000 running the real sound
// program, so that it answers the main CPU over the K056800 the way the
// hardware does. MAME's gxsndmap (konamigx.cpp):
//
//   0x000000-0x03ffff  ROM, the sound program (SDRAM, snd_base)
//   0x100000-0x10ffff  RAM, 64 KB (block RAM)
//   0x200000-0x2004ff  K054539 #1 in the high byte, #2 in the low
//   0x300001           TMS57002 data (gx_tms57002)
//   0x400000-0x40001f  K056800, the sound side, in the low byte
//   0x500000-0x500001  TMS57002 status (read) and the sound control word
//                      (write): bit 0 enables IRQ 2 and, cleared, drops it;
//                      bits 2-4 the DSP's PLOAD, CLOAD and reset
//   0x580000           NRES: nothing
//
// IRQ 1 is the K056800's, IRQ 2 the rising edge of K054539 #1's timer while
// the control word's bit 0 is set. Both are held until software drops them
// (MAME's ASSERT_LINE), so the acknowledge cycle clears nothing.
//
// The 68000 is fx68k, cycle-accurate (rtl/cpu/fx68k/PROVENANCE.md), clocked
// by phase enables at 8 MHz (SUB_CLOCK/2): phi1 and phi2 alternate every
// three clocks of 48 MHz. It was TG68K.C at first, for convenience -- one
// Verilog conversion for both CPUs -- but Seta measured TG68K running a
// nop/dbra loop in 4 clock enables an iteration against a 68000's 14, and
// here the sound program answered the main CPU visibly sooner than MAME's
// does, in a handshake whose timing the main CPU checks. The main CPU stays
// TG68K: it is a 68EC020, which fx68k does not implement.
//
// Memory is SDRAM, slower than a 68000 bus cycle, so the phi2 that samples
// DTACK is held until the access is ready (Seta's maincpu.sv): a slow read
// costs 48 MHz clocks rather than 68000 wait states, and the program's
// cycle counts stay the 68000's. Interrupts are autovectored (VPA in the
// acknowledge cycle).

module gx_sound (
    input             clk,          // 48 MHz
    input             clk_cpu,      // unused since fx68k: its phases come from clk
    input             rst,          // the main CPU holds the board in reset
    // the machine's reset. The main CPU's reset (control_w bit 22) is the
    // 68000's and the DSP's in MAME, not the K054539s': they, their reverb
    // position and the samples they make keep going through it. Resetting
    // them with the board put the reverb's position out of step with
    // MAME's (a ±1 in the delay line, k054539_model.py).
    input             rst_chip,

    input      [25:0] snd_base,     // the sound program in SDRAM
    input      [23:0] snd_pcm,      // the sample area's size (gx_board_cfg): the RAMs follow it
    // SDRAM reads: the program, the samples, the K054539s' RAM (absolute
    // granules); inval drops what the port holds after a RAM write
    output reg        m_cs,
    output reg [22:0] m_addr,
    input             m_ok,
    input      [63:0] m_data,
    output reg        m_inval,
    // SDRAM writes, a byte or (w_we16) an even-addressed pair, the even
    // byte low: the K054539s' RAM, the DSP's
    output reg        w_req,
    output reg [25:0] w_addr,
    output reg [15:0] w_data,
    output reg        w_we16,
    input             w_busy,
    // SDRAM reads of the DSP's 256 KB (snd_base + DSP_OFF): a port of its
    // own, so the DSP's writes flush only its own held granules
    output            x_cs,
    output     [14:0] x_addr,
    input             x_ok,
    input      [63:0] x_data,
    output reg        x_inval,
    // SDRAM reads for the K054539s' voices and reverb: granules from the
    // sample region (snd_base + PCM_OFF) on, which the chips' RAM follows;
    // one chip's request at a time. p_inval after a write to that RAM.
    output            p_cs,
    output     [20:0] p_addr,
    input             p_ok,
    input      [63:0] p_data,
    output reg        p_inval,

    // the board's output, MAME's mix (konamigx.cpp): each K054539 at 1.0,
    // the TMS57002's outputs 0 and 2 left and 1 and 3 right at 0.3
    output reg signed [15:0] aud_l,
    output reg signed [15:0] aud_r,

    // the K056800's sound side
    output reg        k8_wr,
    output reg        k8_rd,
    output reg [ 2:0] k8_addr,
    output reg [ 7:0] k8_din,
    input      [ 7:0] k8_dout,
    input             k8_irq,

    // { accesses served, irq2, IRQ 1 in, in reset, sctrl, the kernel's
    // address }, for a probe: enough to tell a running sound CPU from a
    // held or a lost one
    output     [63:0] dbg,
    output     [63:0] dsp_dbg,      // gx_tms57002's
    // every bus cycle as it completes, for the bench's +SND_TRACE: { clk count[15:0],
    // fc, R/W, /UDS, /LDS, irq2, irq1, address[23:0], data[15:0] }
    output reg        tr_valid,
    output reg [63:0] tr_data
);

localparam [25:0] PCM_OFF = 26'h040000;     // the samples, after the program
wire [25:0] RAM_OFF = PCM_OFF + { 2'd0, snd_pcm };   // the K054539s' RAM, after the samples
wire [25:0] DSP_OFF = RAM_OFF + 26'h010000;          // the DSP's RAM, 256 KB, after theirs


// ---------------------------------------------------------------- CPU
localparam [3:0] CPU_HALF = 4'd3;          // 48 MHz clocks a phase: 8 MHz

wire        as_n, rw_n, nUDS, nLDS, fc0, fc1, fc2;
wire [23:1] eab;
wire [15:0] cpu_dout;
wire [ 2:0] fc = { fc2, fc1, fc0 };
wire        nWr = rw_n;
wire [31:0] a32 = { 8'd0, eab, 1'b0 };
reg  [15:0] cpu_din, u_din;
reg         u_ack, acc_ready, acc_busy;
reg  [ 2:0] ipl_n;
wire        en_phi1, en_phi2;

wire        in_iack = !as_n && fc == 3'b111;
wire        dtack_n = !(acc_ready && !as_n && !in_iack);

fx68k u_cpu (
    .clk, .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(rw_n), .ASn(as_n), .LDSn(nLDS), .UDSn(nUDS), .E(), .VMAn(),
    .FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtack_n), .VPAn(!in_iack), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
    .iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab)
);

// phase enables; the DTACK-sampling phi2 (the second after AS) waits for
// acc_ready (Seta's maincpu.sv)
reg  [3:0] ph_cnt = 4'd0;
reg        next_phi2 = 1'b0;
reg  [1:0] phi2_in_as = 2'd0;
wire       ph_due  = !rst && ( ph_cnt + 4'd1 >= CPU_HALF );
wire       ph_hold = next_phi2 && !as_n && !in_iack && !acc_ready && phi2_in_as != 2'd0;
assign en_phi1 = ph_due && !next_phi2;
assign en_phi2 = ph_due && next_phi2 && !ph_hold;
always @(posedge clk) begin
    if( rst ) begin
        ph_cnt <= 4'd0; next_phi2 <= 1'b0;
    end else if( !ph_due ) ph_cnt <= ph_cnt + 4'd1;
    else if( !ph_hold ) begin
        ph_cnt    <= 4'd0;
        next_phi2 <= ~next_phi2;
    end
    if( as_n )                               phi2_in_as <= 2'd0;
    else if( en_phi2 && phi2_in_as != 2'd3 ) phi2_in_as <= phi2_in_as + 2'd1;
end

// an access: AS and a strobe (a write's strobes follow AS by a state, with
// the data bus driven by then); it is served once, and DTACK held until AS
// goes away. It is marked taken (acc_busy) when the bus below takes it
// (u_take), not when it appears: the DSP's writes share the bus, and a
// request marked on appearing while a DSP write was going through was
// never served -- the sound CPU hung on it (tokkae in the bench, and the
// board with the 68000 selected).
wire acc_active = !as_n && !in_iack && !(nUDS && nLDS);
wire cpu_req_now = acc_active && !acc_busy && !acc_ready;
reg  u_take;
always @(posedge clk) begin
    if( rst || as_n ) begin
        acc_ready <= 1'b0; acc_busy <= 1'b0;
    end else begin
        if( u_take ) acc_busy <= 1'b1;
        if( u_ack ) begin cpu_din <= u_din; acc_ready <= 1'b1; acc_busy <= 1'b0; end
    end
end


// ---------------------------------------------------------------- RAM
reg         ram_we_h, ram_we_l;
reg  [14:0] ram_a;
reg  [15:0] ram_d;
wire [ 7:0] ram_qh, ram_ql;
gx_sdpram #(.AW(15), .DW(8)) u_ramh ( .clk, .we(ram_we_h), .wa(ram_a), .d(ram_d[15:8]), .ra(ram_a), .q(ram_qh) );
gx_sdpram #(.AW(15), .DW(8)) u_raml ( .clk, .we(ram_we_l), .wa(ram_a), .d(ram_d[ 7:0]), .ra(ram_a), .q(ram_ql) );

// ---------------------------------------------------------------- K054539s
reg         kc_cs0, kc_cs1;
reg         kc_we;
reg  [10:0] kc_addr;
reg  [ 7:0] kc_din;
wire [ 7:0] kc_dout0, kc_dout1;
wire        kc_ack0, kc_ack1;
wire        kc_timer0, kc_timer1;
wire        km_req0, km_req1, km_we0, km_we1, km_ram0, km_ram1;
wire        kp_cs0, kp_cs1;
wire [20:0] kp_addr0, kp_addr1;
wire signed [25:0] ko_l0, ko_r0, ko_l1, ko_r1;
wire        ko_v0, ko_v1;
wire [15:0] ko_ovr0, ko_ovr1;
wire        kr_req0, kr_req1;
wire [12:0] kr_word0, kr_word1;
wire [15:0] kr_data0, kr_data1;
reg         kr_ack0, kr_ack1;
reg         kr_p0, kr_p1;           // a reverb write asked for and not yet taken
reg         kr_w;                   // the chip whose reverb write is going through
reg         d_sync;
wire [23:0] pcm_mask = snd_pcm - 24'd1;
// the sample port: a chip keeps it until it drops its request
reg         kp_own;
always @(posedge clk)
    if( rst_chip ) kp_own <= 1'b0;
    else if( !(kp_own ? kp_cs1 : kp_cs0) ) kp_own <= kp_own ? !kp_cs0 : kp_cs1;
assign p_cs   = kp_own ? kp_cs1   : kp_cs0;
assign p_addr = kp_own ? kp_addr1 : kp_addr0;
wire [21:0] km_addr0, km_addr1;
wire [ 7:0] km_wdata0, km_wdata1;
reg         km_ack0, km_ack1;
reg  [ 7:0] km_rdata;

gx_k054539 #(.CHIP(0)) u_k0 (
    .clk, .rst(rst_chip), .cs(kc_cs0), .we(kc_we), .addr(kc_addr), .din(kc_din), .dout(kc_dout0), .ack(kc_ack0),
    .timer_out(kc_timer0),
    .m_req(km_req0), .m_we(km_we0), .m_ram(km_ram0), .m_addr(km_addr0),
    .m_wdata(km_wdata0), .m_ack(km_ack0), .m_rdata(km_rdata),
    .smp(d_sync), .pcm_mask, .p_cs(kp_cs0), .p_addr(kp_addr0), .p_ok(p_ok && !kp_own), .p_data,
    .out_l(ko_l0), .out_r(ko_r0), .out_v(ko_v0), .ovr(ko_ovr0),
    .r_req(kr_req0), .r_word(kr_word0), .r_data(kr_data0), .r_ack(kr_ack0)
);
gx_k054539 #(.CHIP(1)) u_k1 (
    .clk, .rst(rst_chip), .cs(kc_cs1), .we(kc_we), .addr(kc_addr), .din(kc_din), .dout(kc_dout1), .ack(kc_ack1),
    .timer_out(kc_timer1),
    .m_req(km_req1), .m_we(km_we1), .m_ram(km_ram1), .m_addr(km_addr1),
    .m_wdata(km_wdata1), .m_ack(km_ack1), .m_rdata(km_rdata),
    .smp(d_sync), .pcm_mask, .p_cs(kp_cs1), .p_addr(kp_addr1), .p_ok(p_ok && kp_own), .p_data,
    .out_l(ko_l1), .out_r(ko_r1), .out_v(ko_v1), .ovr(ko_ovr1),
    .r_req(kr_req1), .r_word(kr_word1), .r_data(kr_data1), .r_ack(kr_ack1)
);

// the chip being served, as one set of wires
reg         kw;
wire        k_req   = kw ? km_req1   : km_req0;
wire        k_we    = kw ? km_we1    : km_we0;
wire        k_ram   = kw ? km_ram1   : km_ram0;
wire [21:0] k_addr  = kw ? km_addr1  : km_addr0;
wire [ 7:0] k_wdata = kw ? km_wdata1 : km_wdata0;
wire        k_ack   = kw ? kc_ack1   : kc_ack0;
wire [ 7:0] k_dout  = kw ? kc_dout1  : kc_dout0;
reg         k_acked;                    // the chip's memory request was answered
reg         k_both;                     // a word access: #1, then #2
reg  [ 7:0] k_hi;                       // #1's byte of a word read
// where the chip's byte lives in SDRAM: its own 32 KB of RAM (chip n at
// n * 0x8000), or the shared samples
wire [25:0] k_byte  = k_ram ? snd_base + RAM_OFF + { 10'd0, kw, k_addr[14:0] }
                            : snd_base + PCM_OFF + { 2'd0, 24'(k_addr) & pcm_mask };   // mirrored, as MAME's rom interface

// ---------------------------------------------------------------- TMS57002
reg         d_ctrl_wr, d_wr, d_rd;
reg  [ 7:0] d_din;
wire [ 7:0] d_dout;
wire [ 2:0] d_status;
wire        dx_req, dx_we;
wire [17:3] dx_addr;
wire [63:0] dx_wdata;
wire [ 7:0] dx_wmask;
reg         dx_wack;
wire [95:0] d_so;
wire        d_sim;              // ST0 SIM: the inputs are 256 times larger
reg  [95:0] d_si;

// a sample: 48 kHz, the K054539s' rate (18.432 MHz / 384), which MAME
// syncs the DSP to
reg  [9:0]  smp_cnt;
always @(posedge clk) begin
    d_sync <= 1'b0;
    if( rst_chip ) smp_cnt <= 10'd0;
    else if( smp_cnt == 10'd999 ) begin smp_cnt <= 10'd0; d_sync <= 1'b1; end
    else smp_cnt <= smp_cnt + 10'd1;
end

// ---------------------------------------------------------------- the mix
// Each chip's sample (8 bits of fraction), kept from its out_v. On the
// clock before sync the DSP's inputs are set from them -- in MAME each
// chip reaches the DSP at 0.5, and tms57002 takes s32(v * 32768 * (SIM ?
// 256 : 1)) & 0xffffff -- and the board's output is made from them and the
// DSP's outputs of its last run. A chip's sample is the one it made after
// the last sync, so the DSP hears it a sample later than in MAME.
reg signed [25:0] kl0, kr0, kl1, kr1;
// MAME's s32() of v / 2^k, v with 8 bits of fraction: towards zero
function [23:0] to_si( input signed [25:0] v, input sim );
    reg signed [25:0] t;
    begin
        if( sim ) t = (v + (v < 0 ? 26'sd1   : 26'sd0)) >>> 1;       // * 0.5 * 256 / 256
        else      t = (v + (v < 0 ? 26'sd511 : 26'sd0)) >>> 9;       // * 0.5 / 256
        to_si = t[23:0];
    end
endfunction
// 0.3 of the DSP's pair, 24-bit words that are v / 2^23 of full scale: in
// the chips' units (2^15 full scale, 8 bits of fraction) 0.3 * (a + b)
wire signed [24:0] so_sl = 25'($signed(d_so[23:0]))  + 25'($signed(d_so[71:48]));
wire signed [24:0] so_sr = 25'($signed(d_so[47:24])) + 25'($signed(d_so[95:72]));
localparam signed [17:0] K03 = 18'sd19661;                    // 0.3 * 2^16
wire signed [27:0] mix_l = 28'(kl0) + 28'(kl1) + 28'((43'(so_sl) * 43'(K03)) >>> 16);
wire signed [27:0] mix_r = 28'(kr0) + 28'(kr1) + 28'((43'(so_sr) * 43'(K03)) >>> 16);
function signed [15:0] sat16( input signed [27:0] v );     // v with 8 bits of fraction
    sat16 = (v >>> 8) > 28'sd32767 ? 16'sh7fff : (v >>> 8) < -28'sd32768 ? 16'sh8000 : 16'(v >>> 8);
endfunction
always @(posedge clk) begin
    if( rst_chip ) begin
        kl0 <= 26'sd0; kr0 <= 26'sd0; kl1 <= 26'sd0; kr1 <= 26'sd0;
        d_si <= 96'd0; aud_l <= 16'sd0; aud_r <= 16'sd0;
    end else begin
        if( ko_v0 ) begin kl0 <= ko_l0; kr0 <= ko_r0; end
        if( ko_v1 ) begin kl1 <= ko_l1; kr1 <= ko_r1; end
        if( smp_cnt == 10'd999 ) begin
            d_si  <= { to_si(kr1, d_sim), to_si(kl1, d_sim), to_si(kr0, d_sim), to_si(kl0, d_sim) };
            aud_l <= sat16( mix_l );
            aud_r <= sat16( mix_r );
        end
    end
end

gx_tms57002 u_dsp (
    .clk, .rst,
    .h_ctrl_wr(d_ctrl_wr), .h_ctrl(d_din), .h_wr(d_wr), .h_din(d_din),
    .h_rd(d_rd), .h_dout(d_dout), .status(d_status),
    .sync(d_sync), .si(d_si), .so(d_so), .sim(d_sim),
    .x_req(dx_req), .x_we(dx_we), .x_addr(dx_addr), .x_wdata(dx_wdata), .x_wmask(dx_wmask),
    .x_ack(dx_wack || x_ok), .x_rdata(x_data),
    .dbg(dsp_dbg)
);
// reads straight to the port (it answers ok for one clock, and the DSP
// drops the request on it); writes through the bus below
assign x_cs   = dx_req && !dx_we;
assign x_addr = dx_addr;
reg  [7:0] xw_mask;             // the write's bytes still to go

// ---------------------------------------------------------------- interrupts
reg  [7:0] sctrl;               // the sound control word (0x500001)
reg        irq2, tim_l;
always @(posedge clk) begin
    tim_l <= kc_timer0;
    if( rst ) irq2 <= 1'b0;
    else if( sctrl[0] && kc_timer0 && !tim_l ) irq2 <= 1'b1;
    else if( !sctrl[0] ) irq2 <= 1'b0;
    ipl_n <= irq2 ? 3'b101 : k8_irq ? 3'b110 : 3'b111;     // levels 2, 1: active low
end

// ---------------------------------------------------------------- the bus
localparam [4:0] U_IDLE = 0, U_WAIT = 1, U_ROM = 2, U_K539 = 3, U_KMEM = 4, U_KWR = 5, U_RAM = 6,
                 U_WAIT2 = 7, U_RAM2 = 8, U_KWR2 = 9, U_DR = 10, U_DR2 = 11,
                 U_XW = 12, U_XW1 = 13, U_XW2 = 14, U_RW1 = 15, U_RW2 = 16, U_KINV = 17;
reg  [4:0] ust;
reg  [2:1] u_w;                 // the word of the granule the ROM read wants
wire [23:0] ub = { a32[23:1], 1'b0 };


function [15:0] word( input [63:0] gr, input [1:0] w );
    word = { gr[16*w +: 8], gr[16*w+8 +: 8] };      // even byte high, as gx_romcache
endfunction

always @(posedge clk) begin
    u_ack <= 1'b0;
    { ram_we_h, ram_we_l } <= 2'b00;
    k8_wr <= 1'b0; k8_rd <= 1'b0;
    kc_cs0 <= 1'b0; kc_cs1 <= 1'b0;
    km_ack0 <= 1'b0; km_ack1 <= 1'b0;
    m_inval <= 1'b0;
    d_ctrl_wr <= 1'b0; d_wr <= 1'b0; d_rd <= 1'b0; dx_wack <= 1'b0; x_inval <= 1'b0;
    u_take <= 1'b0;
    kr_ack0 <= 1'b0; kr_ack1 <= 1'b0; p_inval <= 1'b0;
    if( kr_req0 ) kr_p0 <= 1'b1;
    if( kr_req1 ) kr_p1 <= 1'b1;
    if( rst ) sctrl <= 8'd0;
    // the bus finishes what it has started, and serves the K054539s' reverb
    // writes, through the board's reset; the 68000 and the DSP ask for
    // nothing while in it
    if( rst_chip ) begin
        ust <= U_IDLE; m_cs <= 1'b0; w_req <= 1'b0; sctrl <= 8'd0; k_acked <= 1'b0;
        kr_p0 <= 1'b0; kr_p1 <= 1'b0;
    end else case( ust )
    // the DSP's writes first: it may be holding its program for one, the
    // CPU only its bus cycle
    U_IDLE: if( dx_req && dx_we && !dx_wack ) begin
        xw_mask <= dx_wmask;
        ust <= U_XW;
    end else if( kr_p0 || kr_p1 ) begin
        // a K054539's reverb word, into its RAM
        kr_w   <= !kr_p0;
        w_req  <= 1'b1; w_we16 <= 1'b1;
        w_addr <= snd_base + RAM_OFF + { 10'd0, !kr_p0, 1'b0, (kr_p0 ? kr_word0 : kr_word1), 1'b0 };   // chip n at n * 0x8000
        w_data <= kr_p0 ? kr_data0 : kr_data1;
        if( kr_p0 ) kr_p0 <= 1'b0; else kr_p1 <= 1'b0;
        ust <= U_RW1;
    end else if( cpu_req_now && !u_ack && !u_take ) begin
        u_take <= 1'b1;
        u_w <= a32[2:1];
        if( ub < 24'h040000 ) begin
            m_cs <= 1'b1; m_addr <= 23'((snd_base + { 2'd0, ub }) >> 3); ust <= U_ROM;
        end else if( ub >= 24'h100000 && ub < 24'h110000 ) begin
            ram_a <= a32[15:1]; ram_d <= cpu_dout;
            if( !nWr ) begin ram_we_h <= ~nUDS; ram_we_l <= ~nLDS; u_ack <= 1'b1; end
            else ust <= U_RAM;
        end else if( ub >= 24'h200000 && ub < 24'h200a00 ) begin
            // #1 on UDS, #2 on LDS; the register is the word's index. A
            // word access is both chips' (MAME's umask16 handlers are each
            // called): the sound program sets 0x22f on both with one write,
            // and #2 stayed disabled while only #1 was served.
            kw <= nUDS;
            k_both <= !nUDS && !nLDS;
            if( nUDS ) kc_cs1 <= 1'b1; else kc_cs0 <= 1'b1;
            kc_we <= !nWr; kc_addr <= a32[11:1];
            kc_din <= nUDS ? cpu_dout[7:0] : cpu_dout[15:8];
            k_acked <= 1'b0;
            ust <= U_K539;
        end else if( ub >= 24'h400000 && ub < 24'h400020 ) begin
            k8_addr <= a32[3:1]; k8_din <= cpu_dout[7:0];
            if( !nWr ) begin k8_wr <= 1'b1; u_ack <= 1'b1; end
            else begin k8_rd <= 1'b1; ust <= U_WAIT; end
        end else if( ub == 24'h300000 && !nLDS ) begin
            // the DSP's data byte; the high byte is not decoded (MAME maps
            // 0x300001 alone)
            d_din <= cpu_dout[7:0];
            if( !nWr ) begin d_wr <= 1'b1; u_din <= 16'd0; u_ack <= 1'b1; end
            else begin d_rd <= 1'b1; ust <= U_DR; end
        end else if( ub >= 24'h500000 && ub < 24'h500002 ) begin
            // tms57002_control_word_w, on the low byte
            if( !nWr && !nLDS ) begin
                sctrl <= cpu_dout[7:0];
                d_din <= cpu_dout[7:0]; d_ctrl_wr <= 1'b1;
            end
            u_din <= { 13'd0, d_status };
            u_ack <= 1'b1;
        end else begin
            u_din <= 16'd0; u_ack <= 1'b1;   // nothing there
        end
    end
    // the K056800's read answers the clock after
    // the mailbox and the RAM register what they are asked for on the clock
    // after the request, so the answer is read a clock after that
    U_WAIT:  ust <= U_WAIT2;
    U_WAIT2: begin u_din <= { 8'd0, k8_dout }; u_ack <= 1'b1; ust <= U_IDLE; end
    U_DR:    ust <= U_DR2;
    U_DR2:   begin u_din <= { 8'd0, d_dout }; u_ack <= 1'b1; ust <= U_IDLE; end
    // a DSP write: its granule's bytes, a pair at a time where both are
    // written, then its read port's held granules dropped
    U_XW: begin
        if( xw_mask == 8'd0 ) begin
            x_inval <= 1'b1; dx_wack <= 1'b1;
            ust <= U_IDLE;
        end else begin
            w_req <= 1'b1;
            if( xw_mask[1:0] != 2'b00 ) begin
                w_addr <= snd_base + DSP_OFF + { 8'd0, dx_addr, 3'd0 } + { 25'd0, !xw_mask[0] };
                w_we16 <= xw_mask[1:0] == 2'b11;
                w_data <= xw_mask[0] ? dx_wdata[15:0] : { 8'd0, dx_wdata[15:8] };
                xw_mask[1:0] <= 2'b00;
            end else if( xw_mask[3:2] != 2'b00 ) begin
                w_addr <= snd_base + DSP_OFF + { 8'd0, dx_addr, 3'd2 } + { 25'd0, !xw_mask[2] };
                w_we16 <= xw_mask[3:2] == 2'b11;
                w_data <= xw_mask[2] ? dx_wdata[31:16] : { 8'd0, dx_wdata[31:24] };
                xw_mask[3:2] <= 2'b00;
            end else if( xw_mask[5:4] != 2'b00 ) begin
                w_addr <= snd_base + DSP_OFF + { 8'd0, dx_addr, 3'd4 } + { 25'd0, !xw_mask[4] };
                w_we16 <= xw_mask[5:4] == 2'b11;
                w_data <= xw_mask[4] ? dx_wdata[47:32] : { 8'd0, dx_wdata[47:40] };
                xw_mask[5:4] <= 2'b00;
            end else begin
                w_addr <= snd_base + DSP_OFF + { 8'd0, dx_addr, 3'd6 } + { 25'd0, !xw_mask[6] };
                w_we16 <= xw_mask[7:6] == 2'b11;
                w_data <= xw_mask[6] ? dx_wdata[63:48] : { 8'd0, dx_wdata[63:56] };
                xw_mask[7:6] <= 2'b00;
            end
            ust <= U_XW1;
        end
    end
    U_XW1: if( w_busy ) begin w_req <= 1'b0; ust <= U_XW2; end
    U_XW2: if( !w_busy ) ust <= U_XW;
    U_RW1: if( w_busy ) begin w_req <= 1'b0; ust <= U_RW2; end
    U_RW2: if( !w_busy ) begin
        p_inval <= 1'b1;                    // the sample port may hold the granule
        if( kr_w ) kr_ack1 <= 1'b1; else kr_ack0 <= 1'b1;
        ust <= U_IDLE;
    end
    U_RAM:   ust <= U_RAM2;
    U_RAM2:  begin u_din <= { ram_qh, ram_ql }; u_ack <= 1'b1; ust <= U_IDLE; end
    U_ROM:  if( m_ok ) begin
        m_cs <= 1'b0;
        u_din <= word( m_data, u_w );
        u_ack <= 1'b1; ust <= U_IDLE;
    end
    // a K054539 register, or its 0x22d port, which may go out to SDRAM
    U_K539: begin
        if( k_req && !k_acked ) begin
            if( k_we ) begin
                w_req <= 1'b1; w_addr <= k_byte; w_data <= { 8'd0, k_wdata }; w_we16 <= 1'b0;
                ust <= U_KWR;
            end else if( k_ram ) begin
                // the reverb writes the RAM without dropping this port's
                // granules (which would cost the sound CPU its program's),
                // so they go before a read of it
                m_inval <= 1'b1; m_addr <= k_byte[25:3];
                ust <= U_KINV;
            end else begin
                m_cs <= 1'b1; m_addr <= k_byte[25:3];
                ust <= U_KMEM;
            end
        end else if( k_ack && k_both && !kw ) begin
            // #1 done: now #2, with the low byte
            k_hi <= k_dout; kw <= 1'b1; kc_cs1 <= 1'b1;
            kc_din <= cpu_dout[7:0]; k_acked <= 1'b0;
        end else if( k_ack ) begin
            u_din <= k_both ? { k_hi, k_dout } : kw ? { 8'd0, k_dout } : { k_dout, 8'd0 };
            u_ack <= 1'b1; ust <= U_IDLE;
        end
    end
    U_KINV: begin m_cs <= 1'b1; ust <= U_KMEM; end
    U_KMEM: if( m_ok ) begin
        m_cs <= 1'b0;
        km_rdata <= m_data[8 * k_byte[2:0] +: 8];
        if( kw ) km_ack1 <= 1'b1; else km_ack0 <= 1'b1;
        k_acked <= 1'b1;
        ust <= U_K539;
    end
    // The arbiter samples its write request as a level: wait for it to be
    // taken (busy), drop it so no second write starts, then wait for the
    // write to finish. Treating !busy as taken, before the arbiter had even
    // seen the request, was a race.
    U_KWR:  if( w_busy ) begin w_req <= 1'b0; ust <= U_KWR2; end
    U_KWR2: if( !w_busy ) begin
        m_inval <= 1'b1;                 // the read ports may hold the granule it changed
        p_inval <= 1'b1;
        if( kw ) km_ack1 <= 1'b1; else km_ack0 <= 1'b1;
        k_acked <= 1'b1;
        ust <= U_K539;
    end
    default: ust <= U_IDLE;
    endcase
end

// ---------------------------------------------------------------- trace
reg  [15:0] tr_ts;
always @(posedge clk) begin
    tr_ts <= tr_ts + 16'd1;
    tr_valid <= u_ack && !rst;
    tr_data  <= { tr_ts, fc, nWr, nUDS, nLDS, irq2, k8_irq, a32[23:0], nWr ? u_din : cpu_dout };
end

// ---------------------------------------------------------------- probe
reg  [15:0] acc_cnt;
always @(posedge clk) if( rst ) acc_cnt <= 16'd0; else if( u_ack ) acc_cnt <= acc_cnt + 16'd1;
assign dbg = { 9'd0, acc_cnt, irq2, k8_irq, rst, 4'd0, sctrl, a32[23:0] };

endmodule
