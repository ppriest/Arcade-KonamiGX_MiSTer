// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// gx_savestate's slot in DDR3, where Main_MiSTer finds it (CONF_STR
// "SS3C000000:100000": four slots of 1 MB from 0x3C000000).
//
// A slot is a 64-bit control word -- a counter Main_MiSTer watches (a change
// has it write the slot to the SD card) and the size in 32-bit words after
// it -- then the image, four 16-bit words to each 64-bit DDR3 word, the first
// in bits 15:0. A save streams the words in and, at sl_end, writes the
// control word last. A load streams them out from the slot's second word,
// one 64-bit read ahead.
//
// The DDR3 port is the rotator's (screen_rotate_two, the same clock). While
// this owns it the rotator is shown BUSY: it writes single beats and holds
// a write until it is taken, so the port can change hands on any clock.

module gx_ss_ddr #(
    parameter [27:0] BASE = 28'hC000000          // 0x3C000000, as an offset from 0x30000000
) (
    input             clk,
    input             rst,
    input      [ 1:0] slot,
    input             active,                    // gx_savestate is busy

    // gx_savestate's slot side
    input             sl_start,
    input             sl_save,
    input             sl_wv,
    input      [15:0] sl_wd,
    output            sl_wready,
    input             sl_end,
    input      [31:0] sl_words,
    output            sl_idle,
    output            sl_rv,
    output     [15:0] sl_rd,
    input             sl_rtake,

    output reg        own,                       // the port is this module's
    input             DDRAM_BUSY,
    output     [ 7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    input      [63:0] DDRAM_DOUT,
    input             DDRAM_DOUT_READY,
    output reg        DDRAM_RD,
    output     [63:0] DDRAM_DIN,
    output     [ 7:0] DDRAM_BE,
    output reg        DDRAM_WE
);

localparam [2:0] D_IDLE = 0, D_WFILL = 1, D_WR = 2, D_CTRL = 3, D_RD = 4, D_RWAIT = 5, D_RHAVE = 6;

reg  [ 2:0] st;
reg  [16:0] wa;                  // 64-bit word within the slot
reg  [63:0] buf_d;
reg  [ 7:0] buf_be;
reg  [ 1:0] wi;                  // the next 16-bit word's place in buf_d
reg  [31:0] cnt;                 // the control word's counter
reg         end_p, ctrl_w;

wire [27:0] byte_a = BASE + { 9'd0, slot, 17'd0 } * 28'd8 + { 8'd0, wa, 3'd0 };
assign DDRAM_ADDR     = { 4'b0011, byte_a[27:3] };
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_DIN      = buf_d;
assign DDRAM_BE       = buf_be;

assign sl_wready = st == D_WFILL && !end_p;
assign sl_idle   = st == D_IDLE;
assign sl_rv     = st == D_RHAVE;
assign sl_rd     = buf_d[16 * wi +: 16];

always @(posedge clk) begin
    if (rst) begin
        st <= D_IDLE; own <= 0; DDRAM_RD <= 0; DDRAM_WE <= 0; cnt <= 0; end_p <= 0;
    end else begin
        if (sl_end) end_p <= 1;
        case (st)
        D_IDLE: if (sl_start) begin
            own <= 1; wa <= 17'd1; wi <= 2'd0; buf_be <= 8'd0; end_p <= 0;
            st <= sl_save ? D_WFILL : D_RD;
        end
        // a save: four words to a DDR3 word, then out
        D_WFILL: begin
            if (sl_wv) begin
                buf_d[16 * wi +: 16] <= sl_wd;
                buf_be[2 * wi +: 2]  <= 2'b11;
                wi <= wi + 2'd1;
                if (wi == 2'd3) begin DDRAM_WE <= 1; ctrl_w <= 0; st <= D_WR; end
            end else if (end_p) begin
                if (buf_be != 8'd0) begin DDRAM_WE <= 1; ctrl_w <= 0; st <= D_WR; end
                else st <= D_CTRL;
            end
        end
        D_WR: if (!DDRAM_BUSY) begin
            DDRAM_WE <= 0; buf_be <= 8'd0;
            if (ctrl_w) begin own <= 0; end_p <= 0; st <= D_IDLE; end
            else begin wa <= wa + 17'd1; st <= D_WFILL; end
        end
        // the control word, last: the counter moves, so Main_MiSTer saves it
        D_CTRL: begin
            cnt <= cnt + 32'd1;
            wa <= 17'd0;
            buf_d <= { (sl_words + 32'd1) >> 1, cnt + 32'd1 };
            buf_be <= 8'hFF;
            DDRAM_WE <= 1; ctrl_w <= 1;
            st <= D_WR;
        end
        // a load: a DDR3 word at a time, its four words handed out
        D_RD: if (!DDRAM_BUSY || !DDRAM_RD) begin
            if (DDRAM_RD) begin DDRAM_RD <= 0; st <= D_RWAIT; end
            else DDRAM_RD <= 1;
        end
        D_RWAIT: if (DDRAM_DOUT_READY) begin buf_d <= DDRAM_DOUT; wi <= 2'd0; st <= D_RHAVE; end
        D_RHAVE: begin
            if (sl_rtake) begin
                wi <= wi + 2'd1;
                if (wi == 2'd3) begin wa <= wa + 17'd1; st <= D_RD; end
            end
        end
        default: st <= D_IDLE;
        endcase
        // a load ends when the engine does: give the port back, a read that
        // was asked for and not yet taken dropped with it
        if (!active && (st == D_RD || st == D_RWAIT || st == D_RHAVE)) begin
            st <= D_IDLE; own <= 0; DDRAM_RD <= 0;
        end
    end
end

endmodule
