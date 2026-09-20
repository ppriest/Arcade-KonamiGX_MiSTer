// SPDX-License-Identifier: GPL-3.0-or-later
//
// One graphics-ROM client of the SDRAM arbiter, with the clock crossing.
//
// The client side is what the video benches' ROM models give the RTL
// (sim/gx_tilemap_tb, sim/gx_obj_tb): cs is a level and addr is held; ok
// pulses for one clk with data; while cs stays high a new addr starts a new
// fetch, and an addr that changes during a fetch is fetched again with no ok
// for the old one; cs dropped and raised fetches again even at the same
// addr. jtframe_draw keeps cs high across the two halves of a sprite row and
// gx_tilemap drops it after each row, and both are served by this.
//
// clk is 48 MHz and clk_mem 96 MHz from the same PLL at phase 0, so every
// clk edge is a clk_mem edge and the crossings are ordinary timed paths: a
// request toggle goes over, the arbiter is held until c_valid, the granule
// is registered here in clk_mem and a done toggle comes back. Nothing is
// pulsed across, because a one-clk_mem pulse is missed by clk half the time.

module gx_rom_port #(
    parameter AW = 21,              // granule (8-byte) address bits from the client
    // 1: after serving a granule, fetch the other one of its pair while the
    // client is busy with this one. A sprite row is two granules (two halves
    // of 16 pixels) and jtframe_draw asks for them one after the other, so
    // the second one's latency was exposed on every row; the SDRAM's latency
    // is what runs the sprite scan out of line time on the board.
    parameter PAIR = 0
) (
    input             clk,          // the client's, 48 MHz
    input             clk_mem,      // the arbiter's, 96 MHz
    input             rst,

    input             cs,
    input  [AW-1:0]   addr,         // granule address within the region
    output reg        ok,
    output reg [63:0] data,

    input  [25:0]     base,         // the region's byte address in SDRAM
    output reg        c_req,        // arbiter client (clk_mem)
    output reg [25:0] c_addr,
    input             c_valid,
    input  [63:0]     c_rdata
);

// ------------------------------------------------------------ clk
reg          req_t = 0, done_t = 0, done_s = 0, busy = 0, have = 0;
reg [AW-1:0] a_l;                   // the fetch in flight
reg [AW-1:0] h_addr;                // what `data` holds
reg [63:0]   data_m;
wire         done = done_t != done_s;

// the other granule of the pair, fetched ahead and kept until it is asked for
reg          pf_have = 0, pf_seen = 0;
reg [AW-1:0] pf_addr;
reg [63:0]   pf_data;
reg [AW-1:1] pf_pair;

wire hit_have = have    && cs && addr == h_addr;
wire hit_pf   = pf_have && cs && addr == pf_addr;
wire pf_want  = PAIR == 1 && hit_have && !pf_have
                && !(pf_seen && pf_pair == h_addr[AW-1:1]);

always @(posedge clk) begin
    ok     <= 0;
    done_s <= done_t;
    if( rst ) begin
        busy <= 0; have <= 0; pf_have <= 0; pf_seen <= 0;
    end else begin
        if( !cs ) begin have <= 0; pf_have <= 0; pf_seen <= 0; end
        if( busy ) begin
            if( done ) begin
                busy <= 0;
                if( cs && addr == a_l ) begin
                    ok <= 1; data <= data_m; have <= 1; h_addr <= a_l;
                end else if( cs ) begin           // asked for ahead, or changed: keep it
                    pf_have <= 1; pf_addr <= a_l; pf_data <= data_m;
                end
            end
        end else if( cs && !hit_have ) begin
            if( hit_pf ) begin
                ok <= 1; data <= pf_data; have <= 1; h_addr <= pf_addr; pf_have <= 0;
            end else begin
                busy <= 1; a_l <= addr; req_t <= ~req_t; pf_have <= 0;
            end
        end else if( pf_want ) begin
            busy   <= 1; a_l <= { h_addr[AW-1:1], ~h_addr[0] }; req_t <= ~req_t;
            pf_seen <= 1; pf_pair <= h_addr[AW-1:1];
        end
    end
end

// ------------------------------------------------------------ clk_mem
reg  req_s = 0;
wire start = req_t != req_s;

always @(posedge clk_mem) begin
    req_s <= req_t;
    if( rst ) begin
        c_req <= 0;
    end else begin
        if( start ) begin
            c_req  <= 1;
            c_addr <= base + { {(26-AW-3){1'b0}}, a_l, 3'b000 };
        end
        if( c_req && c_valid ) begin
            c_req  <= 0;
            data_m <= c_rdata;
            done_t <= ~done_t;
        end
    end
end

endmodule
