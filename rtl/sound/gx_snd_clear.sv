// SPDX-License-Identifier: GPL-3.0-or-later
//
// Zeroes the sound board's RAMs in SDRAM on a reset: the two K054539s'
// 32 KB each (MAME's device_reset: memset(m_ram, 0, 0x8000)) and the
// TMS57002's 256 KB (MAME's is zero from the start). On the board SDRAM
// holds whatever it held, and the K054539s' reverb and the DSP's delay
// lines played it back as noise from the moment the chips were enabled;
// the benches, whose memory starts at zero, were silent.
//
// The RAMs are contiguous after the samples (gx_sound: snd_base + 0x40000
// + snd_pcm, 0x50000 bytes). While `hold` is up nothing starts, since the
// layout is not known before the ROM load; after it the words are written
// through the sound board's write path (a word at a time, as gx_sound's
// writes), `busy` meanwhile holds the core in reset, and `inval` then
// drops the granules the read ports hold.

module gx_snd_clear (
    input             clk,
    input             hold,         // the core is being reset or loaded: clear once it is not
    input      [25:0] snd_base,
    input      [23:0] snd_pcm,
    output            busy,
    output reg        inval,
    output reg        w_req,
    output reg [25:0] w_addr,
    input             w_busy
);

localparam [17:0] WORDS = 18'h28000;       // 0x50000 bytes

reg        need = 1'b1;
reg [17:0] n;
reg [ 1:0] st;
assign busy = need;

always @(posedge clk) begin
    inval <= 1'b0;
    if( hold ) begin
        need <= 1'b1; st <= 2'd0; w_req <= 1'b0; n <= 18'd0;
    end else if( need ) case( st )
        2'd0: begin
            w_req  <= 1'b1;
            w_addr <= snd_base + 26'h040000 + { 2'd0, snd_pcm } + { 7'd0, n, 1'b0 };
            st     <= 2'd1;
        end
        2'd1: if( w_busy ) begin w_req <= 1'b0; st <= 2'd2; end    // taken
        2'd2: if( !w_busy ) begin                                    // written
            if( n == WORDS - 18'd1 ) begin need <= 1'b0; inval <= 1'b1; end
            n  <= n + 18'd1;
            st <= 2'd0;
        end
        default: st <= 2'd0;
    endcase
end

endmodule
