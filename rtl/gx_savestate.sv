// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// The save-state engine (docs/SAVESTATES.md). One sequencer for both
// directions: it walks rtl/gx_ss_layout.svh's sections, producing the
// image's 16-bit words into the slot (a save) or consuming them from it (a
// load), each through the section's channel.
//
// A save or load starts once the ESC and the sprite DMA are idle. Either
// ends the same way: the CPUs are released when the raster comes back to
// where they were taken, with the snapshot committed there -- for a save
// the snapshot it took, which undoes what the board's latches did while
// the image was written (an interrupt raised meanwhile, say). The game sees
// a save as nothing at all; the picture stalls for the frames it takes. Both CPUs
// are taken (gx_ss_m68k) and held; at the instant both are, the modules'
// registers are snapped (ss_snap), the raster position is recorded and the
// sound chips are frozen. The board otherwise keeps running: the video only
// reads what is being walked.
//
// A load checks the header (magic, version, set) before anything is
// written; a mismatch releases the CPUs untouched. After the last section
// the CPUs stay held until the restored raster reaches the recorded
// position; the shadows are committed (ss_commit) and the CPUs released
// there.
//
// The register copy (section 10) is replayed on a load: each word is written
// back raw into the copy, and those that are chip registers are written to
// the chip as well -- except the K053252's 13-15, which are actions, and the
// write ports, which are in gx_main's latches.

module gx_savestate (
    input             clk,
    input             rst,

    input             save_req,           // pulses
    input             load_req,
    input      [ 7:0] set_id,
    output reg        busy,
    output reg        err,                // the last load's header did not match

    input             esc_busy,
    input             dma_busy,
    input      [ 8:0] vpos,
    input      [ 9:0] hpos,

    // the CPUs (gx_ss_m68k): req and go are held until held and done
    output reg        m_req, m_go,
    input             m_held, m_done,
    output reg [ 4:0] m_bidx,
    output reg        m_bwe,
    output reg [31:0] m_bd,
    input      [31:0] m_bq,
    output reg        s_req, s_go,
    input             s_held, s_done,
    output reg [ 4:0] s_bidx,
    output reg        s_bwe,
    output reg [31:0] s_bd,
    input      [31:0] s_bq,

    output reg        ss_snap,
    output reg        ss_commit,
    output reg        snd_freeze,

    // the state bus
    output reg [ 3:0] ss_sel,
    output reg        ss_en,
    output reg [11:0] ss_addr,
    output reg        ss_we,
    output reg        ss_step,            // a save has taken the word read: chains shift
    output reg [15:0] ss_wd,
    input      [15:0] ss_rd,              // the clock after

    // bus masters: req held until ack
    output reg        mb_req,
    output reg        mb_we,
    output reg [23:1] mb_addr,
    output reg [ 1:0] mb_be,
    output reg [15:0] mb_wd,
    input             mb_ack,
    input      [15:0] mb_rd,
    output reg        sb_req,
    output reg        sb_we,
    output reg [23:1] sb_addr,
    output reg [15:0] sb_wd,
    input             sb_ack,
    input      [15:0] sb_rd,
    output reg        sd_req,
    output reg        sd_we,
    output reg [17:0] sd_addr,
    output reg [15:0] sd_wd,
    input             sd_ack,
    input      [15:0] sd_rd,

    // the slot: a word stream each way
    output reg        sl_start,           // pulse: begin, at the slot's first data word
    output reg        sl_save,            // ...for a save (else a load)
    output reg        sl_wv,              // a word to write
    output reg [15:0] sl_wd,
    input             sl_wready,
    output reg        sl_end,             // pulse: the save is complete, sl_words long
    output reg [31:0] sl_words,
    input             sl_idle,            // the slot side has finished
    input             sl_rv,              // a word read
    input      [15:0] sl_rd,
    output reg        sl_rtake            // ...taken
);

`include "gx_ss_layout.svh"

localparam [3:0] E_IDLE = 0, E_TAKE = 1, E_SEC = 2, E_GET = 3, E_PUT = 4, E_SLOT = 5,
                 E_UNUSED = 6, E_SEEK = 7, E_GO = 8, E_WAIT = 9, E_REPLAY = 10,
                 E_DONE = 11;

reg  [3:0]  st, st_ret;
reg         load;
reg  [4:0]  sec;
reg  [31:0] w;                          // word within the section
reg  [31:0] total;
reg  [15:0] word, hi;
reg  [ 8:0] r_v;
reg  [ 9:0] r_h;
reg  [ 2:0] wcnt;
reg         m_dn, s_dn;
reg  [ 1:0] pend;                       // a request queued while busy: 1 save, 2 load
reg  [10:0] fz;                         // clocks since the sound side was frozen
reg  [21:0] sk;                         // clocks spent seeking the raster

wire [58:0] sd   = ss_sec(sec);
wire [2:0]  ch   = sd[58:56];
wire [23:0] base = sd[55:32];
wire [31:0] cnt  = sd[31:0];

// the register copy's word -> the chip register it records, for the replay
reg  [23:0] rp_addr;
reg         rp_ok;
always @* begin
    rp_ok = 1'b1;
    rp_addr = 24'd0;
    if (w < 32'h20)                         rp_addr = 24'hD40000 + {w[22:0], 1'b0};
    else if (w < 32'h24)                    rp_addr = 24'hD44000 + {w[22:0] - 23'h20, 1'b0};
    else if (w < 32'h28)                    rp_ok = 1'b0;
    else if (w < 32'h2C)                    rp_addr = 24'hD48000 + {w[22:0] - 23'h28, 1'b0};
    else if (w < 32'h34)                    rp_addr = 24'hD4A010 + {w[22:0] - 23'h2C, 1'b0};
    else if (w < 32'h44) begin
        rp_addr = 24'hD4C000 + {w[22:0] - 23'h34, 1'b0};
        rp_ok   = w < 32'h41;               // 13-15 are actions
    end
    else if (w < 32'h84)                    rp_addr = 24'hD50000 + {w[22:0] - 23'h44, 1'b0};
    else if (w < 32'hC4)                    rp_ok = 1'b0;   // the K055555's alias, unused
    else if (w < 32'hD4)                    rp_addr = 24'hD80000 + {w[22:0] - 23'hC4, 1'b0};
    else                                    rp_ok = 1'b0;   // write ports: gx_main's latches
end

function automatic [15:0] hdr_word(input [2:0] i);
    case (i)
        3'd0: hdr_word = 16'h4758;          // "GX"
        3'd1: hdr_word = 16'h5353;          // "SS"
        3'd2: hdr_word = SS_VERSION;
        3'd3: hdr_word = {8'd0, set_id};
        3'd4: hdr_word = {7'd0, r_v};
        3'd5: hdr_word = {6'd0, r_h};
        default: hdr_word = 16'd0;
    endcase
endfunction

always @(posedge clk) begin
    ss_snap <= 0; ss_commit <= 0; sl_start <= 0; sl_end <= 0; sl_rtake <= 0; ss_step <= 0;
    sl_wv <= 0;
    if (save_req) pend <= 2'd1;
    if (load_req) pend <= 2'd2;
    if (m_done) m_dn <= 1;
    if (s_done) s_dn <= 1;
    if (rst) begin
        st <= E_IDLE; busy <= 0; err <= 0; pend <= 0;
        m_req <= 0; m_go <= 0; s_req <= 0; s_go <= 0; m_bwe <= 0; s_bwe <= 0;
        mb_req <= 0; sb_req <= 0; sd_req <= 0; ss_we <= 0; ss_en <= 0;
        snd_freeze <= 0;
    end else case (st)
    E_IDLE: if (pend != 0 && !esc_busy && !dma_busy) begin
        load <= pend == 2'd2; pend <= 0;
        busy <= 1; m_req <= 1; s_req <= 1;
        snd_freeze <= 1; fz <= 0;
        st <= E_TAKE;
    end
    // the snapshot: both CPUs held, and a sample period (1000 clocks) since
    // the sound side was frozen, so the K054539s and the DSP have finished
    // the sample they were on
    E_TAKE: if (!fz[10]) fz <= fz + 11'd1;
    else if (m_held && s_held) begin
        m_req <= 0; s_req <= 0;
        ss_snap <= 1;
        r_v <= vpos; r_h <= hpos;
        sec <= 0; w <= 0; total <= 0;
        sl_start <= 1; sl_save <= !load;
        if (load) err <= 0;
        st <= E_SEC;
    end
    // the next word of the section, or the next section
    E_SEC: begin
        m_bwe <= 0; s_bwe <= 0; ss_we <= 0; ss_en <= 0;
        if (w == cnt) begin
            w <= 0;
            if (sec == SS_NSEC - 1) begin st <= load ? E_SEEK : E_SLOT; sk <= 0; end
            else sec <= sec + 5'd1;
        end else st <= E_GET;
        wcnt <= 3'd0;
    end
    // a save: fetch the word from its channel; a load: take it from the slot
    E_GET: if (load) begin
        if (sl_rv) begin
            word <= sl_rd; sl_rtake <= 1; st <= E_PUT; wcnt <= 3'd0;
        end
    end else case (ch)
        SS_HDR: begin word <= hdr_word(w[2:0]); st <= E_PUT; end
        SS_MCPU, SS_SCPU: begin
            m_bidx <= w[5:1]; s_bidx <= w[5:1];
            wcnt <= wcnt + 3'd1;
            if (wcnt == 3'd2) begin
                if (ch == SS_MCPU) word <= w[0] ? m_bq[15:0] : m_bq[31:16];
                else               word <= w[0] ? s_bq[15:0] : s_bq[31:16];
                st <= E_PUT;
            end
        end
        SS_SS: begin
            ss_sel <= base[3:0]; ss_addr <= w[11:0]; ss_en <= 1;
            wcnt <= wcnt + 3'd1;
            if (wcnt == 3'd3) begin word <= ss_rd; ss_step <= 1; st <= E_PUT; end
        end
        SS_MB: begin
            mb_req <= 1; mb_we <= 0; mb_be <= 2'b11; mb_addr <= base[23:1] + w[22:0];
            if (mb_ack) begin mb_req <= 0; word <= mb_rd; st <= E_PUT; end
        end
        SS_SB: begin
            sb_req <= 1; sb_we <= 0; sb_addr <= base[23:1] + w[22:0];
            if (sb_ack) begin sb_req <= 0; word <= sb_rd; st <= E_PUT; end
        end
        default: begin                          // SS_SD
            sd_req <= 1; sd_we <= 0; sd_addr <= base[17:0] + w[17:0];
            if (sd_ack) begin sd_req <= 0; word <= sd_rd; st <= E_PUT; end
        end
    endcase
    // a save: the word to the slot; a load: the word to its channel
    E_PUT: if (!load) begin
        if (sl_wready) begin
            sl_wv <= 1; sl_wd <= word; total <= total + 1;
            w <= w + 1; st <= E_SEC;
        end
    end else case (ch)
        SS_HDR: begin
            if ((w == 0 && word != 16'h4758) || (w == 1 && word != 16'h5353) ||
                (w == 2 && word != SS_VERSION) || (w == 3 && word[7:0] != set_id)) begin
                err <= 1; st <= E_GO;           // nothing written yet: resume as we were
            end else begin
                if (w == 4) r_v <= word[8:0];
                if (w == 5) r_h <= word[9:0];
                w <= w + 1; st <= E_SEC;
            end
        end
        SS_MCPU, SS_SCPU: begin
            if (!w[0]) begin hi <= word; w <= w + 1; st <= E_SEC; end
            else begin
                // two clocks of write strobe
                if (ch == SS_MCPU) begin m_bidx <= w[5:1]; m_bd <= {hi, word}; m_bwe <= 1; end
                else               begin s_bidx <= w[5:1]; s_bd <= {hi, word}; s_bwe <= 1; end
                wcnt <= wcnt + 3'd1;
                if (wcnt == 3'd1) begin w <= w + 1; st <= E_SEC; end
            end
        end
        SS_SS: begin
            ss_sel <= base[3:0]; ss_addr <= w[11:0]; ss_wd <= word; ss_en <= 1;
            ss_we <= wcnt == 3'd0;
            wcnt <= wcnt + 3'd1;
            if (wcnt == 3'd1) begin w <= w + 1; st <= E_SEC; end
        end
        SS_MB: begin
            mb_req <= 1; mb_we <= 1; mb_be <= 2'b11; mb_wd <= word; mb_addr <= base[23:1] + w[22:0];
            if (mb_ack) begin
                mb_req <= 0;
                if (sec == 5'd10 && rp_ok) st <= E_REPLAY;
                else begin w <= w + 1; st <= E_SEC; end
            end
        end
        SS_SB: begin
            sb_req <= 1; sb_we <= 1; sb_wd <= word; sb_addr <= base[23:1] + w[22:0];
            if (sb_ack) begin sb_req <= 0; w <= w + 1; st <= E_SEC; end
        end
        default: begin
            sd_req <= 1; sd_we <= 1; sd_wd <= word; sd_addr <= base[17:0] + w[17:0];
            if (sd_ack) begin sd_req <= 0; w <= w + 1; st <= E_SEC; end
        end
    endcase
    // the register copy's word, written to the chip it records
    E_REPLAY: begin
        mb_req <= 1; mb_we <= 1; mb_be <= 2'b11; mb_wd <= word; mb_addr <= rp_addr[23:1];
        if (mb_ack) begin mb_req <= 0; w <= w + 1; st <= E_SEC; end
    end
    // a save: the slot's control word
    E_SLOT: begin
        sl_end <= 1; sl_words <= total;
        st <= E_WAIT; st_ret <= E_SEEK;
    end
    E_WAIT: if (!sl_end && sl_idle) begin st <= st_ret; sk <= 0; end
    // the latches are committed where they were snapped: their edge
    // detectors then agree with the raster they follow
    // (a raster that never comes round -- registers that are not the
    // set's -- gives up after 2^22 clocks, about 2.8 frames)
    E_SEEK: begin
        sk <= sk + 22'd1;
        if ((vpos == r_v && hpos == r_h) || &sk) begin
            ss_commit <= 1;
            st <= E_GO;
        end
    end
    E_GO: begin
        snd_freeze <= 0;
        m_go <= 1; s_go <= 1; m_dn <= 0; s_dn <= 0;
        st <= E_DONE;
    end
    E_DONE: if (m_dn && s_dn) begin
        m_go <= 0; s_go <= 0; busy <= 0; st <= E_IDLE;
    end
    default: st <= E_IDLE;
    endcase
end

endmodule
