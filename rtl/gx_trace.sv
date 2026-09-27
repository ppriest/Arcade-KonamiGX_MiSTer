// SPDX-License-Identifier: GPL-3.0-or-later
//
// A trace ring in DDR3: 64-bit records, written as they come, for the HPS
// to read back (scripts/snd_trace.py, python3 mmap of /dev/mem on the
// MiSTer; read() of /dev/mem refuses addresses outside Linux's RAM).
//
// Layout, byte addresses from BASE (0x34000000: above the ROM image the
// fast loader reads at 0x30000000-0x32000000, and screen_rotate_two's
// buffers at 0x24000000):
//   +0        header { 16'hC0DE, dropped[15:0], written[31:0] }: the
//             records in DDR so far, rewritten every 256 of them and once
//             more when tracing stops, after the last record
//   +0x1000   record i at +0x1000 + 8 * (i mod 2^23): 64 MB, the newest
//             2^23 records
//
// The bus is shared with screen_rotate_two, which pulses its writes
// without waiting for DDRAM_BUSY (as MiSTer's screen_rotate does): a record
// is only put on the bus in a clock the rotator is not writing, and the
// mux in KonamiGX.sv gives the rotator any clock it does. A record is
// accepted when DDRAM_BUSY is low in such a clock. Records arriving while
// the FIFO is full are counted, not kept.
//
// enable rising restarts the ring at record 0; falling drains the FIFO
// and writes the header, so its count is final.

module gx_trace #(
    parameter [28:0] BASE = 29'h0680_0000    // 0x34000000 >> 3
) (
    input             clk,
    input             rst,
    input             enable,

    input             valid,
    input      [63:0] data,

    output            active,        // this needs the bus: mux it in
    output reg        DDRAM_WE,
    output reg [28:0] DDRAM_ADDR,
    output reg [63:0] DDRAM_DIN,
    input             DDRAM_BUSY,
    input             other_we       // the rotator is writing this clock
);

// ---------------------------------------------------------------- FIFO
localparam FW = 9;
reg  [FW:0] wp, rp;
wire        full  = (wp[FW-1:0] == rp[FW-1:0]) && (wp[FW] != rp[FW]);
wire        empty = wp == rp;
wire [63:0] fq;
wire        push = enable && valid && !full;

gx_sdpram #(.AW(FW), .DW(64)) u_fifo ( .clk, .we(push), .wa(wp[FW-1:0]), .d(data),
                                        .ra(rp[FW-1:0]), .q(fq) );

// ---------------------------------------------------------------- writes
reg         en_d, running, stopping, hdr_due;
reg  [31:0] written;
reg  [15:0] dropped;
reg         pend, have;         // a record popped: at fq next clock; then in hold
reg  [63:0] hold;
wire        drained = empty && !pend && !have;
wire        hdr_now = hdr_due || (stopping && drained);

always @(posedge clk) begin
    en_d <= enable;
    if( rst ) begin
        wp <= 0; rp <= 0; written <= 0; dropped <= 0;
        running <= 0; stopping <= 0; hdr_due <= 0;
        DDRAM_WE <= 0; pend <= 0; have <= 0;
    end else begin
        if( enable && !en_d ) begin
            wp <= 0; rp <= 0; written <= 0; dropped <= 0;
            running <= 1; stopping <= 0;
        end
        if( !enable && en_d ) stopping <= 1;
        if( push ) wp <= wp + 1'd1;
        else if( enable && valid && full && dropped != 16'hffff ) dropped <= dropped + 1'd1;

        if( pend ) begin hold <= fq; pend <= 0; have <= 1; end

        if( DDRAM_WE ) begin
            // presented; taken when the bus is ours and free
            if( !DDRAM_BUSY && !other_we ) begin
                DDRAM_WE <= 0;
                if( DDRAM_ADDR == BASE ) begin
                    hdr_due <= 0;
                    if( stopping ) begin running <= 0; stopping <= 0; end
                end else begin
                    written <= written + 1'd1;
                    if( written[7:0] == 8'hff ) hdr_due <= 1;
                end
            end
        end else if( running && !other_we ) begin
            if( hdr_now ) begin
                DDRAM_WE   <= 1;
                DDRAM_ADDR <= BASE;
                DDRAM_DIN  <= { 16'hC0DE, dropped, written };
            end else if( have ) begin
                DDRAM_WE   <= 1;
                DDRAM_ADDR <= BASE + 29'd512 + { 6'd0, written[22:0] };
                DDRAM_DIN  <= hold;
                have       <= 0;
            end
        end
        if( !empty && !pend && !have ) begin
            rp   <= rp + 1'd1;
            pend <= 1;
        end
    end
end

assign active = running;

endmodule
