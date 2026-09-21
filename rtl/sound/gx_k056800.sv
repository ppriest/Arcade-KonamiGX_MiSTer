// SPDX-License-Identifier: GPL-3.0-or-later
//
// K056800, the sound mailbox: MAME's k056800.cpp, register for register.
//
//   host (main CPU, 0xd52000, a byte in the high half of each word)
//     write 0-3   host_to_snd[r]
//     write 4-6   front/rear volume, mute: no effect here
//     write 7     the sound interrupt: pending, and IRQ 1 if enabled
//     read  0-1   snd_to_host[r]
//     read  2     volume busy: 0
//   sound (sound CPU, 0x400000, a byte in the low half of each word)
//     write 0-1   snd_to_host[r]
//     write 4     bit 0: interrupt enable. Enabling raises a pending one;
//                 clearing it acknowledges and drops the line
//     read  0-3   host_to_snd[r]
//
// It replaces gx_snd_stub's stand-in replies, which were built from
// Daisu-Kiss's power-on test alone (docs/ROADMAP.md, Phase 3a).

module gx_k056800 (
    input            clk,
    input            rst,

    input            h_wr,
    input            h_rd,
    input      [2:0] h_addr,
    input      [7:0] h_din,
    output reg [7:0] h_dout,

    input            s_wr,
    input            s_rd,
    input      [2:0] s_addr,
    input      [7:0] s_din,
    output reg [7:0] s_dout,

    output reg       irq,           // the sound CPU's IRQ 1
    // { host_to_snd 0-3, snd_to_host 0-1, int_en, int_pend }, for a probe
    output    [49:0] dbg
);

reg [7:0] h2s [0:3];
reg [7:0] s2h [0:1];
reg       int_en, int_pend;
assign dbg = { h2s[0], h2s[1], h2s[2], h2s[3], s2h[0], s2h[1], int_en, int_pend };

integer i;
always @(posedge clk) begin
    if( rst ) begin
        for( i=0; i<4; i=i+1 ) h2s[i] <= 8'd0;
        s2h[0] <= 8'd0; s2h[1] <= 8'd0;
        int_en <= 1'b0; int_pend <= 1'b0; irq <= 1'b0;
    end else begin
        if( h_wr ) begin
            if( h_addr[2] == 1'b0 ) h2s[h_addr[1:0]] <= h_din;
            if( h_addr == 3'd7 && int_en ) begin int_pend <= 1'b1; irq <= 1'b1; end
        end
        if( s_wr ) begin
            if( s_addr[2:1] == 2'd0 ) s2h[s_addr[0]] <= s_din;
            if( s_addr == 3'd4 ) begin
                int_en <= s_din[0];
                if( s_din[0] ) begin
                    if( int_pend ) irq <= 1'b1;
                end else begin
                    int_pend <= 1'b0; irq <= 1'b0;
                end
            end
        end
    end
end

// reads answer the clock after, as the access units expect
always @(posedge clk) begin
    if( h_rd ) h_dout <= h_addr[2:1] == 2'd0 ? s2h[h_addr[0]] : 8'd0;
    if( s_rd ) s_dout <= s_addr[2] ? 8'd0 : h2s[s_addr[1:0]];
end

endmodule
