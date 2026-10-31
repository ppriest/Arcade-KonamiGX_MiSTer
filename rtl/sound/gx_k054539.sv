// SPDX-License-Identifier: GPL-3.0-or-later
//
// K054539, written from MAME's sound/k054539.cpp (BSD-3-Clause, Olivier
// Galibert), with the dry level and the pan from furrtek's SiliconRE
// register notes and ROM contents. Its HDL is not used (THIRD-PARTY.md).
//
// The CPU side, as k054539.cpp:
//
//   every write lands in the register file, and a read returns it, except:
//   0x227 write  timer period: a square wave of (38 + n) * clock/384/14400
//                Hz, restarted, output low
//   0x22f write  bit 5 clear: output low (the timer only toggles while set)
//   0x22e write  rom_addr = n, pointer = 0
//   0x22d write  rom_addr == 0x80: the byte into the RAM; pointer + 1
//   0x22d read   0x22f bit 4 set: the sample ROM's byte at
//                0x20000 * rom_addr + pointer, or the RAM's when rom_addr is
//                0x80; pointer + 1. Otherwise 0.
//   0x0c-0x0e of a channel (its position), while 0x22f bit 0 is set: held
//                aside and not written (UPDATE_AT_KEYON, MAME's default)
//   0x214 write  key on: those channels' held positions written, then
//                (0x22f bit 7 clear) their 0x22c bits set
//   0x215 write  key off: (0x22f bit 7 clear) their 0x22c bits cleared
//
// The RAM address from the pointer is (p & 0x3fff) | ((p & 0x10000) >> 2),
// 32 KB. Both RAM and ROM are in SDRAM (docs/ROADMAP.md: the block RAM left
// would not hold two chips' RAM with the CPU's), reached through m_*.
//
// The voices, sound_stream_update, once a sample (smp, 48 kHz) while 0x22f
// bit 0 is set, for each channel whose 0x22c bit is set:
//
//   position from 0x0c-0x0e; if it is not where the channel was left, the
//   fraction and the last two values restart at 0
//   the fraction gains the pitch (0x00-0x02, negated with 0x200 bit 5,
//   reverse); for each whole step out of it, the position moves one sample
//   (8-bit, 16-bit LSB first, or a 4-bit DPCM nibble: 0x200 bits 3-2 = 0, 1,
//   2) and the sample is read. An end marker (0x80, 0x8000, the byte 0x88)
//   jumps to the loop point (0x08-0x0a) with 0x201 bit 0, and is read again
//   there; one still there keys the channel off with a value of 0 and ends
//   its steps. A DPCM nibble adds dpcm[n] to the value before, clamped.
//   the value, times the dry level and the pan, into each side; the
//   position back into 0x0c-0x0e unless 0x22f bit 7 is set
//
// The dry level and the pan are the chip's, not MAME's (dv and pc below):
// MAME's voltab is 0.5625 dB a step over all of 0x03, has no group volumes,
// and its pan is sqrt(i/14). MAME caps a side's volume at 1.8, which with a
// gain of 1 is never reached.
//
// The reverb, as MAME: the RAM's first 16 KB are 0x2000 16-bit words
// (little-endian, MAME's int16_t view on its host), a delay line. Each
// sample both sides start from the word at the line's position, which is
// then zeroed; each channel adds int16(value * voltab[min(0x03 + 0x04,
// 255)] / 2) into the word at ((0x06-0x07 >> 3) + 2 * position) & 0x1fff;
// the position then moves on. The words are read through p_* (the RAM
// follows the samples in SDRAM, gx_sound) and written through r_*;
// channels that add into the same word add once, which with int16
// wrapping is the same sum.
//
// The engine takes its bytes a granule at a time through p_*, one granule
// held per channel. A sample's channels are worked through in a few hundred
// clocks at ordinary pitches; a smp that comes while the last is still in
// progress starts the next as soon as it is done (ovr counts them).

module gx_k054539 #(
    parameter CHIP = 0              // which of the pair: its RAM is the CHIP'th 32 KB after the samples
) (
    input             clk,          // 48 MHz
    input             rst,

    input             cs,
    input             we,
    input      [10:0] addr,         // 0x000-0x4ff
    input      [ 7:0] din,
    output reg [ 7:0] dout,
    output reg        ack,          // one clock: the access is done

    output reg        timer_out,

    // the 0x22d port's byte, in SDRAM
    output reg        m_req,
    output reg        m_we,
    output reg        m_ram,        // 1: the chip's RAM, 0: the sample ROM
    output reg [21:0] m_addr,       // a byte of that space
    output reg [ 7:0] m_wdata,
    input             m_ack,
    input      [ 7:0] m_rdata,

    // the voices
    input             smp,          // a sample is due (48 kHz)
    input      [23:0] pcm_mask,     // the sample region's size - 1: addresses mirror over it
    output reg        p_cs,         // a granule of the sample region: held until p_ok
    output reg [20:0] p_addr,
    input             p_ok,
    input      [63:0] p_data,
    output reg signed [25:0] out_l, // a sample, MAME's lval and rval with 8 bits of fraction
    output reg signed [25:0] out_r,
    output reg        out_v,        // one clock: out_l and out_r are the new sample
    output reg [15:0] ovr,          // samples that started late

    // the reverb's writes: a word of the RAM, r_req a pulse, r_ack when it is
    // written
    output reg        r_req,
    output reg [12:0] r_word,
    output reg [15:0] r_data,
    input             r_ack,

    // save states (gx_savestate): the register file at 0x000-0x4ff, then
    // the rest of the chip's state as a shift chain, 16 bits a word (below).
    // ss_freeze stops the chip between samples, the timer with it.
    input             ss_freeze,
    input             ss_step,      // the word read has been taken: shift
    input             ss_sel,
    input      [11:0] ss_addr,
    input             ss_we,
    input      [15:0] ss_wd,
    output     [15:0] ss_rd
);

// ---------------------------------------------------------------- registers
reg  [7:0] regs [0:2047];
reg  [7:0] rq;
reg  [7:0] r22f, rom_addr;
reg [16:0] cur_ptr;
reg [10:0] ra;                  // the register being read

wire [14:0] ram_a = { cur_ptr[16], cur_ptr[13:0] };   // (p & 0x3fff) | ((p & 0x10000) >> 2)

// what the voices use of a channel's registers, kept beside the register file
(* ramstyle = "logic" *) reg [23:0] delta [0:7];     // 0x00-0x02, the pitch
(* ramstyle = "logic" *) reg [ 7:0] vol   [0:7];     // 0x03
(* ramstyle = "logic" *) reg [ 7:0] pan   [0:7];     // 0x05
(* ramstyle = "logic" *) reg [ 7:0] rvl   [0:7];     // 0x04, the reverb's volume
(* ramstyle = "logic" *) reg [15:0] rdl   [0:7];     // 0x06-0x07, the reverb's delay
(* ramstyle = "logic" *) reg [23:0] lpos  [0:7];     // 0x08-0x0a, the loop point
(* ramstyle = "logic" *) reg [23:0] cpos  [0:7];     // 0x0c-0x0e, the position: read back from here
(* ramstyle = "logic" *) reg [23:0] hpos  [0:7];     // positions written for the next key on
(* ramstyle = "logic" *) reg [ 7:0] ctype [0:7];     // 0x200 + 2n: bits 3-2 the type, 5 reverse
(* ramstyle = "logic" *) reg [ 6:0] gvol  [0:3];     // 0x228-0x22b bits 6-0, the group volumes
reg  [7:0] lflag;                                     // 0x201 + 2n bit 0: loop
reg  [7:0] act;                                       // 0x22c: the channels playing

wire       latch  = r22f[0];
wire       regupd = !r22f[7];
wire       a_ch   = addr < 11'h100;
wire [2:0] a_n    = addr[7:5];
wire [4:0] a_off  = addr[4:0];
wire       a_pos  = a_ch && a_off >= 5'h0c && a_off <= 5'h0e;
wire [1:0] a_pb   = 2'(a_off - 5'h0c);                // the position's byte

function [23:0] setb( input [23:0] w, input [1:0] b, input [7:0] d );
    setb = w;
    setb[8*b +: 8] = d;
endfunction

// ---------------------------------------------------------------- timer
// Toggles every 7,200,000 / (38 + n) clocks of 48 MHz: an accumulator gains
// (38 + n) a clock and toggles each time it passes 7,200,000, which is the
// exact period on average without a divider.
localparam [23:0] TPER = 24'd7_200_000;
reg  [ 8:0] tstep;
reg  [23:0] tacc;
reg         t_run;

// ---------------------------------------------------------------- voices
// voltab (MAME device_start), rounded: vt = 2^24 * 10^(-36i/64/20) / 4; the
// reverb's send only
function [22:0] vt( input [7:0] v );
    case( v )
        8'h00: vt = 23'd4194304;  8'h01: vt = 23'd3931288;  8'h02: vt = 23'd3684766;  8'h03: vt = 23'd3453702;
        8'h04: vt = 23'd3237128;  8'h05: vt = 23'd3034135;  8'h06: vt = 23'd2843871;  8'h07: vt = 23'd2665538;
        8'h08: vt = 23'd2498388;  8'h09: vt = 23'd2341720;  8'h0a: vt = 23'd2194876;  8'h0b: vt = 23'd2057240;
        8'h0c: vt = 23'd1928235;  8'h0d: vt = 23'd1807319;  8'h0e: vt = 23'd1693986;  8'h0f: vt = 23'd1587760;
        8'h10: vt = 23'd1488195;  8'h11: vt = 23'd1394874;  8'h12: vt = 23'd1307404;  8'h13: vt = 23'd1225420;
        8'h14: vt = 23'd1148576;  8'h15: vt = 23'd1076552;  8'h16: vt = 23'd1009044;  8'h17: vt = 23'd945769;
        8'h18: vt = 23'd886462;  8'h19: vt = 23'd830873;  8'h1a: vt = 23'd778771;  8'h1b: vt = 23'd729936;
        8'h1c: vt = 23'd684164;  8'h1d: vt = 23'd641261;  8'h1e: vt = 23'd601049;  8'h1f: vt = 23'd563359;
        8'h20: vt = 23'd528032;  8'h21: vt = 23'd494920;  8'h22: vt = 23'd463885;  8'h23: vt = 23'd434795;
        8'h24: vt = 23'd407530;  8'h25: vt = 23'd381975;  8'h26: vt = 23'd358022;  8'h27: vt = 23'd335571;
        8'h28: vt = 23'd314528;  8'h29: vt = 23'd294805;  8'h2a: vt = 23'd276318;  8'h2b: vt = 23'd258991;
        8'h2c: vt = 23'd242750;  8'h2d: vt = 23'd227528;  8'h2e: vt = 23'd213260;  8'h2f: vt = 23'd199887;
        8'h30: vt = 23'd187353;  8'h31: vt = 23'd175604;  8'h32: vt = 23'd164592;  8'h33: vt = 23'd154271;
        8'h34: vt = 23'd144597;  8'h35: vt = 23'd135530;  8'h36: vt = 23'd127031;  8'h37: vt = 23'd119065;
        8'h38: vt = 23'd111599;  8'h39: vt = 23'd104601;  8'h3a: vt = 23'd98041;  8'h3b: vt = 23'd91894;
        8'h3c: vt = 23'd86131;  8'h3d: vt = 23'd80730;  8'h3e: vt = 23'd75668;  8'h3f: vt = 23'd70923;
        8'h40: vt = 23'd66475;  8'h41: vt = 23'd62307;  8'h42: vt = 23'd58400;  8'h43: vt = 23'd54737;
        8'h44: vt = 23'd51305;  8'h45: vt = 23'd48088;  8'h46: vt = 23'd45072;  8'h47: vt = 23'd42246;
        8'h48: vt = 23'd39597;  8'h49: vt = 23'd37114;  8'h4a: vt = 23'd34786;  8'h4b: vt = 23'd32605;
        8'h4c: vt = 23'd30560;  8'h4d: vt = 23'd28644;  8'h4e: vt = 23'd26848;  8'h4f: vt = 23'd25164;
        8'h50: vt = 23'd23586;  8'h51: vt = 23'd22107;  8'h52: vt = 23'd20721;  8'h53: vt = 23'd19422;
        8'h54: vt = 23'd18204;  8'h55: vt = 23'd17062;  8'h56: vt = 23'd15992;  8'h57: vt = 23'd14989;
        8'h58: vt = 23'd14049;  8'h59: vt = 23'd13168;  8'h5a: vt = 23'd12343;  8'h5b: vt = 23'd11569;
        8'h5c: vt = 23'd10843;  8'h5d: vt = 23'd10163;  8'h5e: vt = 23'd9526;  8'h5f: vt = 23'd8929;
        8'h60: vt = 23'd8369;  8'h61: vt = 23'd7844;  8'h62: vt = 23'd7352;  8'h63: vt = 23'd6891;
        8'h64: vt = 23'd6459;  8'h65: vt = 23'd6054;  8'h66: vt = 23'd5674;  8'h67: vt = 23'd5318;
        8'h68: vt = 23'd4985;  8'h69: vt = 23'd4672;  8'h6a: vt = 23'd4379;  8'h6b: vt = 23'd4105;
        8'h6c: vt = 23'd3847;  8'h6d: vt = 23'd3606;  8'h6e: vt = 23'd3380;  8'h6f: vt = 23'd3168;
        8'h70: vt = 23'd2969;  8'h71: vt = 23'd2783;  8'h72: vt = 23'd2609;  8'h73: vt = 23'd2445;
        8'h74: vt = 23'd2292;  8'h75: vt = 23'd2148;  8'h76: vt = 23'd2013;  8'h77: vt = 23'd1887;
        8'h78: vt = 23'd1769;  8'h79: vt = 23'd1658;  8'h7a: vt = 23'd1554;  8'h7b: vt = 23'd1456;
        8'h7c: vt = 23'd1365;  8'h7d: vt = 23'd1279;  8'h7e: vt = 23'd1199;  8'h7f: vt = 23'd1124;
        8'h80: vt = 23'd1054;  8'h81: vt = 23'd987;  8'h82: vt = 23'd926;  8'h83: vt = 23'd868;
        8'h84: vt = 23'd813;  8'h85: vt = 23'd762;  8'h86: vt = 23'd714;  8'h87: vt = 23'd670;
        8'h88: vt = 23'd628;  8'h89: vt = 23'd588;  8'h8a: vt = 23'd551;  8'h8b: vt = 23'd517;
        8'h8c: vt = 23'd484;  8'h8d: vt = 23'd454;  8'h8e: vt = 23'd426;  8'h8f: vt = 23'd399;
        8'h90: vt = 23'd374;  8'h91: vt = 23'd350;  8'h92: vt = 23'd328;  8'h93: vt = 23'd308;
        8'h94: vt = 23'd289;  8'h95: vt = 23'd270;  8'h96: vt = 23'd253;  8'h97: vt = 23'd238;
        8'h98: vt = 23'd223;  8'h99: vt = 23'd209;  8'h9a: vt = 23'd196;  8'h9b: vt = 23'd183;
        8'h9c: vt = 23'd172;  8'h9d: vt = 23'd161;  8'h9e: vt = 23'd151;  8'h9f: vt = 23'd142;
        8'ha0: vt = 23'd133;  8'ha1: vt = 23'd124;  8'ha2: vt = 23'd117;  8'ha3: vt = 23'd109;
        8'ha4: vt = 23'd102;  8'ha5: vt = 23'd96;  8'ha6: vt = 23'd90;  8'ha7: vt = 23'd84;
        8'ha8: vt = 23'd79;  8'ha9: vt = 23'd74;  8'haa: vt = 23'd69;  8'hab: vt = 23'd65;
        8'hac: vt = 23'd61;  8'had: vt = 23'd57;  8'hae: vt = 23'd54;  8'haf: vt = 23'd50;
        8'hb0: vt = 23'd47;  8'hb1: vt = 23'd44;  8'hb2: vt = 23'd41;  8'hb3: vt = 23'd39;
        8'hb4: vt = 23'd36;  8'hb5: vt = 23'd34;  8'hb6: vt = 23'd32;  8'hb7: vt = 23'd30;
        8'hb8: vt = 23'd28;  8'hb9: vt = 23'd26;  8'hba: vt = 23'd25;  8'hbb: vt = 23'd23;
        8'hbc: vt = 23'd22;  8'hbd: vt = 23'd20;  8'hbe: vt = 23'd19;  8'hbf: vt = 23'd18;
        8'hc0: vt = 23'd17;  8'hc1: vt = 23'd16;  8'hc2: vt = 23'd15;  8'hc3: vt = 23'd14;
        8'hc4: vt = 23'd13;  8'hc5: vt = 23'd12;  8'hc6: vt = 23'd11;  8'hc7: vt = 23'd11;
        8'hc8: vt = 23'd10;  8'hc9: vt = 23'd9;  8'hca: vt = 23'd9;  8'hcb: vt = 23'd8;
        8'hcc: vt = 23'd8;  8'hcd: vt = 23'd7;  8'hce: vt = 23'd7;  8'hcf: vt = 23'd6;
        8'hd0: vt = 23'd6;  8'hd1: vt = 23'd6;  8'hd2: vt = 23'd5;  8'hd3: vt = 23'd5;
        8'hd4: vt = 23'd5;  8'hd5: vt = 23'd4;  8'hd6: vt = 23'd4;  8'hd7: vt = 23'd4;
        8'hd8: vt = 23'd4;  8'hd9: vt = 23'd3;  8'hda: vt = 23'd3;  8'hdb: vt = 23'd3;
        8'hdc: vt = 23'd3;  8'hdd: vt = 23'd3;  8'hde: vt = 23'd2;  8'hdf: vt = 23'd2;
        8'he0: vt = 23'd2;  8'he1: vt = 23'd2;  8'he2: vt = 23'd2;  8'he3: vt = 23'd2;
        8'he4: vt = 23'd2;  8'he5: vt = 23'd2;  8'he6: vt = 23'd1;  8'he7: vt = 23'd1;
        8'he8: vt = 23'd1;  8'he9: vt = 23'd1;  8'hea: vt = 23'd1;  8'heb: vt = 23'd1;
        8'hec: vt = 23'd1;  8'hed: vt = 23'd1;  8'hee: vt = 23'd1;  8'hef: vt = 23'd1;
        8'hf0: vt = 23'd1;  8'hf1: vt = 23'd1;  8'hf2: vt = 23'd1;  8'hf3: vt = 23'd1;
        8'hf4: vt = 23'd1;  8'hf5: vt = 23'd1;  8'hf6: vt = 23'd1;  8'hf7: vt = 23'd0;
        8'hf8: vt = 23'd0;  8'hf9: vt = 23'd0;  8'hfa: vt = 23'd0;  8'hfb: vt = 23'd0;
        8'hfc: vt = 23'd0;  8'hfd: vt = 23'd0;  8'hfe: vt = 23'd0;  8'hff: vt = 23'd0;
    endcase
endfunction

// The dry level, from the chip (furrtek's SiliconRE, Konami/054539): the
// channel's 0x03 bits 6-0 and the group volume it selects are each 0.75 dB a
// step, 0x7f silent. dv(s) = 2^24 * 10^(-0.75s/20) / 4 for their sum s, at
// MAME's level for 0.
function [22:0] dv( input [7:0] v );
    case( v )
        8'h00: dv = 23'd4194304;  8'h01: dv = 23'd3847334;  8'h02: dv = 23'd3529067;  8'h03: dv = 23'd3237128;
        8'h04: dv = 23'd2969340;  8'h05: dv = 23'd2723704;  8'h06: dv = 23'd2498388;  8'h07: dv = 23'd2291711;
        8'h08: dv = 23'd2102132;  8'h09: dv = 23'd1928235;  8'h0a: dv = 23'd1768723;  8'h0b: dv = 23'd1622407;
        8'h0c: dv = 23'd1488195;  8'h0d: dv = 23'd1365086;  8'h0e: dv = 23'd1252160;  8'h0f: dv = 23'd1148576;
        8'h10: dv = 23'd1053562;  8'h11: dv = 23'd966407;  8'h12: dv = 23'd886462;  8'h13: dv = 23'd813130;
        8'h14: dv = 23'd745864;  8'h15: dv = 23'd684164;  8'h16: dv = 23'd627567;  8'h17: dv = 23'd575652;
        8'h18: dv = 23'd528032;  8'h19: dv = 23'd484351;  8'h1a: dv = 23'd444283;  8'h1b: dv = 23'd407530;
        8'h1c: dv = 23'd373818;  8'h1d: dv = 23'd342894;  8'h1e: dv = 23'd314528;  8'h1f: dv = 23'd288509;
        8'h20: dv = 23'd264643;  8'h21: dv = 23'd242750;  8'h22: dv = 23'd222669;  8'h23: dv = 23'd204249;
        8'h24: dv = 23'd187353;  8'h25: dv = 23'd171854;  8'h26: dv = 23'd157638;  8'h27: dv = 23'd144597;
        8'h28: dv = 23'd132636;  8'h29: dv = 23'd121663;  8'h2a: dv = 23'd111599;  8'h2b: dv = 23'd102367;
        8'h2c: dv = 23'd93899;  8'h2d: dv = 23'd86131;  8'h2e: dv = 23'd79006;  8'h2f: dv = 23'd72470;
        8'h30: dv = 23'd66475;  8'h31: dv = 23'd60976;  8'h32: dv = 23'd55932;  8'h33: dv = 23'd51305;
        8'h34: dv = 23'd47061;  8'h35: dv = 23'd43168;  8'h36: dv = 23'd39597;  8'h37: dv = 23'd36321;
        8'h38: dv = 23'd33317;  8'h39: dv = 23'd30560;  8'h3a: dv = 23'd28032;  8'h3b: dv = 23'd25713;
        8'h3c: dv = 23'd23586;  8'h3d: dv = 23'd21635;  8'h3e: dv = 23'd19845;  8'h3f: dv = 23'd18204;
        8'h40: dv = 23'd16698;  8'h41: dv = 23'd15317;  8'h42: dv = 23'd14049;  8'h43: dv = 23'd12887;
        8'h44: dv = 23'd11821;  8'h45: dv = 23'd10843;  8'h46: dv = 23'd9946;  8'h47: dv = 23'd9123;
        8'h48: dv = 23'd8369;  8'h49: dv = 23'd7676;  8'h4a: dv = 23'd7041;  8'h4b: dv = 23'd6459;
        8'h4c: dv = 23'd5925;  8'h4d: dv = 23'd5435;  8'h4e: dv = 23'd4985;  8'h4f: dv = 23'd4573;
        8'h50: dv = 23'd4194;  8'h51: dv = 23'd3847;  8'h52: dv = 23'd3529;  8'h53: dv = 23'd3237;
        8'h54: dv = 23'd2969;  8'h55: dv = 23'd2724;  8'h56: dv = 23'd2498;  8'h57: dv = 23'd2292;
        8'h58: dv = 23'd2102;  8'h59: dv = 23'd1928;  8'h5a: dv = 23'd1769;  8'h5b: dv = 23'd1622;
        8'h5c: dv = 23'd1488;  8'h5d: dv = 23'd1365;  8'h5e: dv = 23'd1252;  8'h5f: dv = 23'd1149;
        8'h60: dv = 23'd1054;  8'h61: dv = 23'd966;  8'h62: dv = 23'd886;  8'h63: dv = 23'd813;
        8'h64: dv = 23'd746;  8'h65: dv = 23'd684;  8'h66: dv = 23'd628;  8'h67: dv = 23'd576;
        8'h68: dv = 23'd528;  8'h69: dv = 23'd484;  8'h6a: dv = 23'd444;  8'h6b: dv = 23'd408;
        8'h6c: dv = 23'd374;  8'h6d: dv = 23'd343;  8'h6e: dv = 23'd315;  8'h6f: dv = 23'd289;
        8'h70: dv = 23'd265;  8'h71: dv = 23'd243;  8'h72: dv = 23'd223;  8'h73: dv = 23'd204;
        8'h74: dv = 23'd187;  8'h75: dv = 23'd172;  8'h76: dv = 23'd158;  8'h77: dv = 23'd145;
        8'h78: dv = 23'd133;  8'h79: dv = 23'd122;  8'h7a: dv = 23'd112;  8'h7b: dv = 23'd102;
        8'h7c: dv = 23'd94;  8'h7d: dv = 23'd86;  8'h7e: dv = 23'd79;  8'h7f: dv = 23'd72;
        8'h80: dv = 23'd66;  8'h81: dv = 23'd61;  8'h82: dv = 23'd56;  8'h83: dv = 23'd51;
        8'h84: dv = 23'd47;  8'h85: dv = 23'd43;  8'h86: dv = 23'd40;  8'h87: dv = 23'd36;
        8'h88: dv = 23'd33;  8'h89: dv = 23'd31;  8'h8a: dv = 23'd28;  8'h8b: dv = 23'd26;
        8'h8c: dv = 23'd24;  8'h8d: dv = 23'd22;  8'h8e: dv = 23'd20;  8'h8f: dv = 23'd18;
        8'h90: dv = 23'd17;  8'h91: dv = 23'd15;  8'h92: dv = 23'd14;  8'h93: dv = 23'd13;
        8'h94: dv = 23'd12;  8'h95: dv = 23'd11;  8'h96: dv = 23'd10;  8'h97: dv = 23'd9;
        8'h98: dv = 23'd8;  8'h99: dv = 23'd8;  8'h9a: dv = 23'd7;  8'h9b: dv = 23'd6;
        8'h9c: dv = 23'd6;  8'h9d: dv = 23'd5;  8'h9e: dv = 23'd5;  8'h9f: dv = 23'd5;
        8'ha0: dv = 23'd4;  8'ha1: dv = 23'd4;  8'ha2: dv = 23'd4;  8'ha3: dv = 23'd3;
        8'ha4: dv = 23'd3;  8'ha5: dv = 23'd3;  8'ha6: dv = 23'd2;  8'ha7: dv = 23'd2;
        8'ha8: dv = 23'd2;  8'ha9: dv = 23'd2;  8'haa: dv = 23'd2;  8'hab: dv = 23'd2;
        8'hac: dv = 23'd1;  8'had: dv = 23'd1;  8'hae: dv = 23'd1;  8'haf: dv = 23'd1;
        8'hb0: dv = 23'd1;  8'hb1: dv = 23'd1;  8'hb2: dv = 23'd1;  8'hb3: dv = 23'd1;
        8'hb4: dv = 23'd1;  8'hb5: dv = 23'd1;  8'hb6: dv = 23'd1;  8'hb7: dv = 23'd1;
        8'hb8: dv = 23'd1;  8'hb9: dv = 23'd0;  8'hba: dv = 23'd0;  8'hbb: dv = 23'd0;
        8'hbc: dv = 23'd0;  8'hbd: dv = 23'd0;  8'hbe: dv = 23'd0;  8'hbf: dv = 23'd0;
        8'hc0: dv = 23'd0;  8'hc1: dv = 23'd0;  8'hc2: dv = 23'd0;  8'hc3: dv = 23'd0;
        8'hc4: dv = 23'd0;  8'hc5: dv = 23'd0;  8'hc6: dv = 23'd0;  8'hc7: dv = 23'd0;
        8'hc8: dv = 23'd0;  8'hc9: dv = 23'd0;  8'hca: dv = 23'd0;  8'hcb: dv = 23'd0;
        8'hcc: dv = 23'd0;  8'hcd: dv = 23'd0;  8'hce: dv = 23'd0;  8'hcf: dv = 23'd0;
        8'hd0: dv = 23'd0;  8'hd1: dv = 23'd0;  8'hd2: dv = 23'd0;  8'hd3: dv = 23'd0;
        8'hd4: dv = 23'd0;  8'hd5: dv = 23'd0;  8'hd6: dv = 23'd0;  8'hd7: dv = 23'd0;
        8'hd8: dv = 23'd0;  8'hd9: dv = 23'd0;  8'hda: dv = 23'd0;  8'hdb: dv = 23'd0;
        8'hdc: dv = 23'd0;  8'hdd: dv = 23'd0;  8'hde: dv = 23'd0;  8'hdf: dv = 23'd0;
        8'he0: dv = 23'd0;  8'he1: dv = 23'd0;  8'he2: dv = 23'd0;  8'he3: dv = 23'd0;
        8'he4: dv = 23'd0;  8'he5: dv = 23'd0;  8'he6: dv = 23'd0;  8'he7: dv = 23'd0;
        8'he8: dv = 23'd0;  8'he9: dv = 23'd0;  8'hea: dv = 23'd0;  8'heb: dv = 23'd0;
        8'hec: dv = 23'd0;  8'hed: dv = 23'd0;  8'hee: dv = 23'd0;  8'hef: dv = 23'd0;
        8'hf0: dv = 23'd0;  8'hf1: dv = 23'd0;  8'hf2: dv = 23'd0;  8'hf3: dv = 23'd0;
        8'hf4: dv = 23'd0;  8'hf5: dv = 23'd0;  8'hf6: dv = 23'd0;  8'hf7: dv = 23'd0;
        8'hf8: dv = 23'd0;  8'hf9: dv = 23'd0;  8'hfa: dv = 23'd0;  8'hfb: dv = 23'd0;
        8'hfc: dv = 23'd0;  default: dv = 23'd0;
    endcase
endfunction

// The pan curve, from the chip's ROM (SiliconRE), Q16: one side's level for
// the pan register's low nibble n; the other side's is pc(16 - n), 0 for n < 2.
// MAME's sqrt(i/14) falls off less on the far side.
function [16:0] pc( input [3:0] n );
    case( n )
        4'd0: pc = 17'd0;  4'd1: pc = 17'd65536;  4'd2: pc = 17'd63426;  4'd3: pc = 17'd61148;
        4'd4: pc = 17'd58672;  4'd5: pc = 17'd55958;  4'd6: pc = 17'd52960;  4'd7: pc = 17'd49608;
        4'd8: pc = 17'd45807;  4'd9: pc = 17'd44797;  4'd10: pc = 17'd36229;  4'd11: pc = 17'd29879;
        4'd12: pc = 17'd21691;  4'd13: pc = 17'd10150;  4'd14: pc = 17'd9576;  4'd15: pc = 17'd0;
    endcase
endfunction

function signed [15:0] dpcm( input [3:0] n );
    case( n )
        4'd0:  dpcm = 16'sd0;      4'd1:  dpcm = 16'sh0100;   4'd2:  dpcm = 16'sh0200;   4'd3:  dpcm = 16'sh0400;
        4'd4:  dpcm = 16'sh0800;   4'd5:  dpcm = 16'sh1000;   4'd6:  dpcm = 16'sh2000;   4'd7:  dpcm = 16'sh4000;
        4'd8:  dpcm = 16'sd0;      4'd9:  dpcm = -16'sh4000;  4'd10: dpcm = -16'sh2000;  4'd11: dpcm = -16'sh1000;
        4'd12: dpcm = -16'sh0800;  4'd13: dpcm = -16'sh0400;  4'd14: dpcm = -16'sh0200;  default: dpcm = -16'sh0100;
    endcase
endfunction

// where each channel was left (MAME's channel struct), and the granule it
// last read
(* ramstyle = "logic" *) reg        [23:0] vpos  [0:7];
(* ramstyle = "logic" *) reg        [15:0] vpf   [0:7];
(* ramstyle = "logic" *) reg signed [15:0] vval  [0:7];
(* ramstyle = "logic" *) reg signed [15:0] vpval [0:7];
(* ramstyle = "logic" *) reg        [20:0] vgt   [0:7];
(* ramstyle = "logic" *) reg        [63:0] vgd   [0:7];
reg  [7:0] vgv;

// the channel being worked on. Positions are in bytes, or nibbles for DPCM;
// the position and the fraction are two's complement, wide enough for
// reverse to pass below 0 and for a fraction plus the largest pitch
reg  [ 2:0] ch;
reg  [26:0] w_pos, w_pf;
reg signed [15:0] w_val, w_pval;
reg  [ 1:0] w_typ;
reg         w_rev, w_lp, w_looped;
reg  [23:0] w_loop;
reg  [20:0] g_t;
reg  [63:0] g_d;
reg         g_v;
reg  [23:0] fa;                 // the byte being read
reg  [ 7:0] b0, b1;
reg  [22:0] vt_q, lv, rv;
reg  [16:0] pl_q, pr_q;
reg signed [41:0] acc_l, acc_r;
reg         pend;

// the reverb: the delay line's position, and the words this sample adds to
reg  [12:0] rpos;
reg  [ 3:0] rt_n;
reg  [ 2:0] rk;
(* ramstyle = "logic" *) reg        [12:0] rt_t [0:7];
(* ramstyle = "logic" *) reg signed [15:0] rt_a [0:7];
reg  [22:0] rb_q;
reg  [15:0] rdl_q;
reg signed [15:0] rc;
reg  [12:0] rtg;
reg         rt_hit;
// a word of the RAM: its granule in the sample port's space, and its place there
wire [20:0] ram_g0  = 21'((pcm_mask + 24'd1) >> 3) + 21'(CHIP * 'h1000);
wire [15:0] p_word  = p_data[16 * r_word[1:0] +: 16];
wire [ 8:0] c_bval  = { 1'b0, vol[ch] } + { 1'b0, rvl[ch] };
wire signed [39:0] rc_p = w_val * $signed({ 1'b0, rb_q });

wire        f_hit  = g_v && g_t == fa[23:3];
wire [ 7:0] f_byte = g_d[8 * fa[2:0] +: 8];
wire [26:0] w_pd   = w_typ == 2'd1 ? 27'd2 : 27'd1;
wire [26:0] np     = w_rev ? w_pos - w_pd : w_pos + w_pd;
wire [23:0] np_a   = (w_typ == 2'd2 ? np[24:1] : np[23:0]) & pcm_mask;
wire        marker = w_typ == 2'd0 ? b0 == 8'h80 : w_typ == 2'd1 ? { b1, b0 } == 16'h8000 : b0 == 8'h88;
wire [ 3:0] nib    = w_pos[0] ? b0[7:4] : b0[3:0];
wire signed [16:0] dsum = 17'(w_pval) + 17'(dpcm(nib));
wire signed [15:0] dcl  = dsum > 17'sd32767 ? 16'sh7fff : dsum < -17'sd32768 ? 16'sh8000 : 16'(dsum);
wire [23:0] f_pos  = w_typ == 2'd2 ? w_pos[24:1] : w_pos[23:0];
wire [15:0] f_pf   = w_typ == 2'd2 ? { w_pf[16] | w_pos[0], w_pf[15:1] } : w_pf[15:0];

// the channel's fraction plus its pitch, negated in reverse
wire [23:0] c_delta = delta[ch];
wire [26:0] c_step  = ctype[ch][5] ? 27'd0 - { 3'd0, c_delta } : { 3'd0, c_delta };

// the pan register's nibble for pc: 0x11-0x1f and 0x81-0x8f as written, any
// other value the centre, as MAME
function [3:0] pan_n( input [7:0] p );
    if( (p[7:4] == 4'h1 || p[7:4] == 4'h8) && p[3:0] != 4'h0 ) pan_n = p[3:0];
    else                                                       pan_n = 4'd8;
endfunction
wire [3:0] c_pan = pan_n( pan[ch] );
wire [3:0] c_pfar = 4'd0 - c_pan;                      // 16 - n

// the dry level's index: 0x03 bits 6-0 plus the group volume 0x228-0x22b
// that 0x200 + 2n bits 1-0 select, inverted (0 picks 0x22b); either at 0x7f
// is silent
wire [6:0] c_gv  = gvol[~ctype[ch][1:0]];
wire [7:0] c_dv  = (vol[ch][6:0] == 7'h7f || c_gv == 7'h7f) ? 8'hff : { 1'b0, vol[ch][6:0] } + { 1'b0, c_gv };

typedef enum logic [3:0] { E_IDLE, E_RV0, E_RV1, E_CH, E_VOL, E_STEP, E_F0, E_F1, E_CHK, E_MIX, E_RVM,
                           E_OUT, E_RW0, E_RW1, E_ADV } est_t;
est_t es;

typedef enum logic [1:0] { K_IDLE, K_RD, K_MEM } kst_t;
kst_t st;

reg [7:0] act_n;
reg        rf_we;
reg [10:0] rf_a;
reg [ 7:0] rf_d;
integer i;

always @(posedge clk) begin
    ack   <= 1'b0;
    out_v <= 1'b0;
    r_req <= 1'b0;
    rq    <= regs[ss_sel ? ss_addr[10:0] : addr];
    rf_we  = 1'b0; rf_a = addr; rf_d = din;
    act_n = act;
    if( rst ) begin
        st <= K_IDLE; m_req <= 1'b0; timer_out <= 1'b0; t_run <= 1'b0;
        tacc <= 24'd0; r22f <= 8'd0; rom_addr <= 8'd0; cur_ptr <= 17'd0;
        es <= E_IDLE; p_cs <= 1'b0; pend <= 1'b0; ovr <= 16'd0; vgv <= 8'd0; rpos <= 13'd0;
        out_l <= 26'sd0; out_r <= 26'sd0;
        act_n = 8'd0;
        for( i=0; i<8; i=i+1 ) begin
            vpos[i] <= 24'd0; vpf[i] <= 16'd0; vval[i] <= 16'sd0; vpval[i] <= 16'sd0;
        end
    end else begin
        // the timer
        if( t_run && !ss_freeze ) begin
            if( tacc + { 15'd0, tstep } >= TPER ) begin
                tacc <= tacc + { 15'd0, tstep } - TPER;
                if( r22f[5] ) timer_out <= ~timer_out;
            end else tacc <= tacc + { 15'd0, tstep };
        end

        // -------------------------------------------------------- the voices
        if( smp && es != E_IDLE ) begin pend <= 1'b1; ovr <= ovr + 16'd1; end
        case( es )
        E_IDLE: if( smp || pend ) begin
            pend <= 1'b0;
            if( r22f[0] ) begin
                ch <= 3'd0; rt_n <= 4'd0; r_word <= rpos;
                es <= E_RV0;
            end else begin
                out_l <= 26'sd0; out_r <= 26'sd0; out_v <= 1'b1;
            end
        end
        // the delay line's word: both sides start from it, and it is zeroed
        E_RV0: if( !p_cs ) begin
            p_cs <= 1'b1; p_addr <= ram_g0 + 21'(r_word >> 2);
        end else if( p_ok ) begin
            p_cs   <= 1'b0;
            acc_l  <= 42'($signed(p_word)) <<< 24; acc_r <= 42'($signed(p_word)) <<< 24;
            r_req  <= 1'b1; r_data <= 16'd0;
            es     <= E_RV1;
        end
        E_RV1: if( r_ack ) es <= E_CH;
        E_CH: if( !act[ch] ) begin
            if( ch == 3'd7 ) es <= E_OUT;
            ch <= ch + 3'd1;
        end else begin
            if( cpos[ch] != vpos[ch] ) begin
                // 0x0c-0x0e moved: a restart
                w_val <= 16'sd0; w_pval <= 16'sd0;
                if( ctype[ch][3:2] == 2'd2 ) w_pos <= { 2'd0, cpos[ch], 1'b0 };
                else                         w_pos <= { 3'd0, cpos[ch] };
                w_pf <= ctype[ch][3:2] == 2'd3 ? 27'd0 : c_step;
            end else begin
                w_val <= vval[ch]; w_pval <= vpval[ch];
                if( ctype[ch][3:2] == 2'd2 ) begin
                    // cur_pos <<= 1; cur_pfrac <<= 1, its bit 16 into the position
                    w_pos <= { 2'd0, vpos[ch], vpf[ch][15] };
                    w_pf  <= { 11'd0, vpf[ch][14:0], 1'b0 } + c_step;
                end else begin
                    w_pos <= { 3'd0, vpos[ch] };
                    w_pf  <= { 11'd0, vpf[ch] } + (ctype[ch][3:2] == 2'd3 ? 27'd0 : c_step);
                end
            end
            w_typ <= ctype[ch][3:2]; w_rev <= ctype[ch][5]; w_lp <= lflag[ch]; w_loop <= lpos[ch];
            g_t <= vgt[ch]; g_d <= vgd[ch]; g_v <= vgv[ch];
            vt_q <= dv( c_dv ); pl_q <= c_pan < 4'd2 ? 17'd0 : pc( c_pfar ); pr_q <= pc( c_pan );
            rb_q <= vt( c_bval[8] ? 8'hff : c_bval[7:0] ); rdl_q <= rdl[ch];
            es <= E_VOL;
        end
        E_VOL: begin
            lv <= 23'(({ 17'd0, vt_q } * { 23'd0, pl_q }) >> 16);
            rv <= 23'(({ 17'd0, vt_q } * { 23'd0, pr_q }) >> 16);
            es <= w_typ == 2'd3 ? E_MIX : E_STEP;       // an unknown type does not move
        end
        // while the fraction has whole steps in it, one sample on
        E_STEP: if( w_pf[26:16] == 11'd0 ) es <= E_MIX;
        else begin
            w_pf     <= w_rev ? w_pf + 27'h10000 : w_pf - 27'h10000;
            w_pos    <= np;
            w_pval   <= w_val;
            w_looped <= 1'b0;
            fa       <= np_a;
            es       <= E_F0;
        end
        E_F0: if( f_hit ) begin
            b0 <= f_byte;
            if( w_typ == 2'd1 ) begin fa <= (fa + 24'd1) & pcm_mask; es <= E_F1; end
            else es <= E_CHK;
        end else if( !p_cs ) begin
            p_cs <= 1'b1; p_addr <= fa[23:3];
        end else if( p_ok ) begin
            p_cs <= 1'b0; g_t <= p_addr; g_d <= p_data; g_v <= 1'b1;
        end
        E_F1: if( f_hit ) begin
            b1 <= f_byte; es <= E_CHK;
        end else if( !p_cs ) begin
            p_cs <= 1'b1; p_addr <= fa[23:3];
        end else if( p_ok ) begin
            p_cs <= 1'b0; g_t <= p_addr; g_d <= p_data; g_v <= 1'b1;
        end
        E_CHK: if( marker && w_lp && !w_looped ) begin
            // the loop point, read again there
            w_pos    <= w_typ == 2'd2 ? { 2'd0, w_loop, 1'b0 } : { 3'd0, w_loop };
            fa       <= w_loop & pcm_mask;
            w_looped <= 1'b1;
            es       <= E_F0;
        end else if( marker ) begin
            if( regupd ) act_n[ch] = 1'b0;             // keyoff
            w_val <= 16'sd0;
            es    <= E_MIX;
        end else begin
            case( w_typ )
                2'd0:    w_val <= $signed({ b0, 8'h00 });
                2'd1:    w_val <= $signed({ b1, b0 });
                default: w_val <= dcl;
            endcase
            es <= E_STEP;
        end
        E_MIX: begin
            vpos[ch] <= f_pos; vpf[ch] <= f_pf; vval[ch] <= w_val; vpval[ch] <= w_pval;
            vgt[ch] <= g_t; vgd[ch] <= g_d; vgv[ch] <= g_v;
            if( regupd ) cpos[ch] <= f_pos;
            acc_l <= acc_l + 42'(w_val * $signed({ 1'b0, lv }));
            acc_r <= acc_r + 42'(w_val * $signed({ 1'b0, rv }));
            // into the delay line: value * voltab / 2, towards zero as C's int16_t()
            rc  <= 16'((rc_p + (rc_p < 0 ? 40'sh1ffffff : 40'sd0)) >>> 25);
            rtg <= 13'((rdl_q >> 3) + { rpos, 1'b0 });
            es  <= E_RVM;
        end
        E_RVM: begin
            if( rc != 16'sd0 ) begin
                rt_hit = 1'b0;
                for( i=0; i<8; i=i+1 )
                    if( i < rt_n && rt_t[i] == rtg ) begin rt_a[i] <= rt_a[i] + rc; rt_hit = 1'b1; end
                if( !rt_hit ) begin rt_t[rt_n[2:0]] <= rtg; rt_a[rt_n[2:0]] <= rc; rt_n <= rt_n + 4'd1; end
            end
            ch <= ch + 3'd1;
            es <= ch == 3'd7 ? E_OUT : E_CH;
        end
        E_OUT: begin
            out_l <= 26'(acc_l >>> 16); out_r <= 26'(acc_r >>> 16); out_v <= 1'b1;
            rk <= 3'd0; r_word <= rt_t[0];
            es <= rt_n != 4'd0 ? E_RW0 : E_ADV;
        end
        // the delay line's words this sample added to: read, add, written
        E_RW0: if( !p_cs ) begin
            p_cs <= 1'b1; p_addr <= ram_g0 + 21'(r_word >> 2);
        end else if( p_ok ) begin
            p_cs  <= 1'b0;
            r_req <= 1'b1; r_data <= p_word + rt_a[rk];
            es    <= E_RW1;
        end
        E_RW1: if( r_ack ) begin
            if( 4'(rk) + 4'd1 == rt_n ) es <= E_ADV;
            else begin rk <= rk + 3'd1; r_word <= rt_t[rk + 3'd1]; es <= E_RW0; end
        end
        E_ADV: begin rpos <= rpos + 13'd1; es <= E_IDLE; end
        default: es <= E_IDLE;
        endcase

        // -------------------------------------------------------- the CPU
        // after the voices, so that its write wins a register both touch
        case( st )
        K_IDLE: if( cs ) begin
            if( we ) begin
                if( latch && a_pos ) hpos[a_n] <= setb( hpos[a_n], a_pb, din );
                else begin
                    rf_we = 1'b1;
                    if( a_pos ) cpos[a_n] <= setb( cpos[a_n], a_pb, din );
                end
                if( a_ch ) case( a_off )
                    5'h00, 5'h01, 5'h02: delta[a_n] <= setb( delta[a_n], a_off[1:0], din );
                    5'h03: vol[a_n] <= din;
                    5'h04: rvl[a_n] <= din;
                    5'h06: rdl[a_n][ 7:0] <= din;
                    5'h07: rdl[a_n][15:8] <= din;
                    5'h05: pan[a_n] <= din;
                    5'h08, 5'h09, 5'h0a: lpos[a_n] <= setb( lpos[a_n], 2'(a_off - 5'h08), din );
                    default: ;
                endcase
                if( addr[10:4] == 7'h20 ) begin     // 0x200-0x20f
                    if( addr[0] ) lflag[addr[3:1]] <= din[0];
                    else          ctype[addr[3:1]] <= din;
                end
                case( addr )
                    11'h214: begin
                        for( i=0; i<8; i=i+1 ) if( din[i] ) begin
                            if( latch ) cpos[i] <= hpos[i];
                            if( regupd ) act_n[i] = 1'b1;
                        end
                    end
                    11'h215: if( regupd ) act_n = act_n & ~din;
                    11'h22c: act_n = din;
                    11'h228, 11'h229, 11'h22a, 11'h22b: gvol[addr[1:0]] <= din[6:0];
                    11'h227: begin tstep <= 9'd38 + { 1'b0, din }; tacc <= 24'd0;
                                   t_run <= 1'b1; timer_out <= 1'b0; end
                    11'h22f: begin r22f <= din; if( !din[5] ) timer_out <= 1'b0; end
                    11'h22e: begin rom_addr <= din; cur_ptr <= 17'd0; end
                    default: ;
                endcase
                if( addr == 11'h22d ) begin
                    if( rom_addr == 8'h80 ) begin
                        m_req <= 1'b1; m_we <= 1'b1; m_ram <= 1'b1;
                        m_addr <= { 7'd0, ram_a }; m_wdata <= din;
                        st <= K_MEM;
                    end else ack <= 1'b1;
                    cur_ptr <= cur_ptr + 17'd1;
                end else ack <= 1'b1;
            end else begin
                ra <= addr;
                if( addr == 11'h22d ) begin
                    if( r22f[4] ) begin
                        m_req <= 1'b1; m_we <= 1'b0;
                        m_ram <= rom_addr == 8'h80;
                        m_addr <= rom_addr == 8'h80 ? { 7'd0, ram_a }
                                                    : { rom_addr[4:0], cur_ptr };
                        cur_ptr <= cur_ptr + 17'd1;
                        st <= K_MEM;
                    end else begin dout <= 8'd0; ack <= 1'b1; end
                end else st <= K_RD;          // the register file answers next clock
            end
        end
        K_RD: begin
            if( ra == 11'h22c ) dout <= act;
            else if( ra < 11'h100 && ra[4:0] >= 5'h0c && ra[4:0] <= 5'h0e )
                dout <= cpos[ra[7:5]][8 * 2'(ra[4:0] - 5'h0c) +: 8];
            else dout <= rq;
            ack <= 1'b1; st <= K_IDLE;
        end
        K_MEM: if( m_ack ) begin
            m_req <= 1'b0;
            if( !m_we ) dout <= m_rdata;
            ack <= 1'b1; st <= K_IDLE;
        end
        default: st <= K_IDLE;
        endcase
    end
    act <= act_n;
    // one write port: the CPU's, or the engine's
    if( ss_sel && ss_we && ss_addr < 12'h500 ) regs[ss_addr[10:0]] <= ss_wd[7:0];
    else if( rf_we ) regs[rf_a] <= rf_d;
    // the group volumes are restored from the register file's copy
    if( ss_sel && ss_we && ss_addr[11:2] == 10'h08a ) gvol[ss_addr[1:0]] <= ss_wd[6:0];
    if( ss_sh ) begin
        for( i=0; i<8; i=i+1 ) begin
            { delta[i], vol[i], pan[i], rvl[i], rdl[i], lpos[i], cpos[i], hpos[i], ctype[i] } <= ss_n[144*i +: 144];
            { vpos[i], vpf[i], vval[i], vpval[i] } <= ss_n[1152 + 72*i +: 72];
        end
        { lflag, act, r22f, rom_addr, cur_ptr, tstep, tacc, t_run, timer_out, rpos, out_l, out_r } <= ss_n[1728 +: 149];
        ss_pad <= ss_n[SSC-1 -: SSC-SSW];
        vgv <= 8'd0; pend <= 1'b0;
    end
end

// ---------------------------------------------------------------- save states
// The chip's state other than the register file, as one shift chain of
// whole words: frozen, nothing else moves it, so it is read where it is.
// Each word taken shifts the chain down 16 bits; a save shifts the word
// back in at the top (after the last word the chain is as it was), a load
// shifts the engine's in. No copy is kept: a copy cost an ALM a bit.
localparam SSW = 1877;
localparam SSC = 16 * ((SSW + 15) / 16);
reg  [SSW-1:0] ss_d;
reg  [SSC-SSW-1:0] ss_pad;
wire           ss_v  = ss_sel && ss_addr >= 12'h500;
wire           ss_sh = ss_v && (ss_we || ss_step);
wire [SSC-1:0] ss_c  = { ss_pad, ss_d };
wire [SSC-1:0] ss_n  = { ss_we ? ss_wd : ss_c[15:0], ss_c[SSC-1:16] };
always @* begin
    for( i=0; i<8; i=i+1 ) begin
        ss_d[144*i +: 144]       = { delta[i], vol[i], pan[i], rvl[i], rdl[i], lpos[i], cpos[i], hpos[i], ctype[i] };
        ss_d[1152 + 72*i +: 72]  = { vpos[i], vpf[i], vval[i], vpval[i] };
    end
    ss_d[1728 +: 149] = { lflag, act, r22f, rom_addr, cur_ptr, tstep, tacc, t_run, timer_out, rpos, out_l, out_r };
end
reg  [15:0] ss_vrd;
reg         ss_rf;                       // the read was of the register file
always @(posedge clk) begin
    ss_rf  <= ss_sel && ss_addr < 12'h500;
    ss_vrd <= ss_v ? ss_c[15:0] : 16'd0;
end
assign ss_rd = ss_rf ? { 8'd0, rq } : ss_vrd;

endmodule
