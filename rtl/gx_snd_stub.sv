// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sound side until Phase 3: the K056800 mailbox with a stand-in for the
// sound program behind it, answering the main program's power-on test of the
// sound board the way daiskiss's own test routine (0x2815a8, disassembled)
// checks it, so that the game gets past its RAM CHECK screen. It is not a
// model of the sound program; it is the smallest thing that passes.
//
// The main CPU writes registers 0-7 (a byte at 0xd52000 + 2n; a write to 7
// is the "command sent" strobe) and reads 8-15 (0xd52010 + 2(n-8)). The
// test, in order:
//   F7 then 55/AA/FF/00 patterns in 0-3: 8 must read back 0 and 9 its
//                complement (ten tries a step; MAME's sound program answers
//                the same)                            -> echo and invert
//   F8:          8's low nibble must CHANGE between two reads spaced ~100 ms
//                (the sound CPU's heartbeat)           -> a frame counter
//   FE:          8 & 0xC0 must become 0xC0 (the self-test running), then 0;
//                then bit i of 9 and bit 0 of 8 are the ten sound-board RAMs,
//                1 = good. The game's first read is ~12 frames after FE,
//                and it waits up to 20 reads (~240 frames) for each
//                transition; MAME's sound program holds C0 for ~230 frames
//                                                       -> C0 for 24 frames,
//                                                          then 8 = 01, 9 = FF
//                                                          until the next command
//                (on the board the results were read later than in the
//                simulation, and a 48-frame limit gave one RAM BAD)
// Outside those phases 8 is the heartbeat with bits 7:6 clear and 9 reads
// FF, as MAME's sound program gives after the test: the game's sound driver
// (0x28a648) keeps sixteen frames of 8's low nibble and, if they are all
// equal, resets the sound CPU (0xd58001 bit 6) and stops feeding its command
// queue -- which the attract sequence waits on. Registers 10-15 read 0,
// which its handshake (a command in 4 or 5, polling 10's busy bits) accepts.

module gx_snd_stub (
    input            clk,
    input            rst,
    input            frame,        // one clock per frame (vblank)
    input            wr,
    input            rd,
    input      [3:0] addr,
    input      [7:0] din,
    output reg [7:0] dout          // valid the clock after rd
);

reg [7:0] mbox [0:7];
reg [7:0] cmd;
reg [3:0] beat;                    // frames, low nibble of 8 after F8
reg [7:0] fe_t;                    // frames since FE
reg [7:0] r8, r9;

always @* begin
    r8 = { 4'd0, beat }; r9 = 8'hff;                 // the heartbeat
    case( cmd )
        8'hf7: begin r8 = mbox[0]; r9 = ~mbox[0]; end    // echo, and the complement
        8'hf8: ;
        8'hfe: begin
            r8 = fe_t < 8'd24 ? 8'hc0 : 8'h01;           // running, then the ten RAMs good
            r9 = fe_t < 8'd24 ? 8'h00 : 8'hff;
        end
        default: ;
    endcase
end

always @(posedge clk) begin
    if( rst ) begin
        dout <= 0; cmd <= 0; beat <= 0; fe_t <= 0;
    end else begin
        if( frame ) begin
            beat <= beat + 1'd1;
            if( fe_t != 8'd255 ) fe_t <= fe_t + 1'd1;
        end
        if( wr && !addr[3] ) mbox[addr[2:0]] <= din;
        if( wr && addr == 4'd7 ) begin           // command strobe: 0 holds the command
            cmd  <= mbox[0];
            fe_t <= 0;
        end
        if( rd ) dout <= addr == 4'd8 ? r8 : addr == 4'd9 ? r9 : 8'h00;
    end
end

endmodule
