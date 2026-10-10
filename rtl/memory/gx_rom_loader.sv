// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fast ROM load. With address="0x30000000" on the .mra's index-0 ROM the HPS
// writes the image into DDR3 and the download carries no ioctl_wr; this reads
// it back a granule at a time (ddram_phy) and presents it as the byte
// download would -- ioctl_wr with an address and a byte, held off by
// ioctl_wait -- so the SDRAM side (gx_sdram_top's row spreading, the byte
// pairing in sdram_download) is the path the byte download already proved.
// The core is in reset throughout (KonamiGX.sv).
//
// The idea and ddram_phy are the sibling cores' (Arcade-Seta_MiSTer's
// rom_loader.sv, from Arcade-Fuuki_MiSTer via Arcade-Psikyo_MiSTer); this
// module is written for this core's byte-level transform.

module gx_rom_loader (
    input             clk,
    input             reset,

    input      [27:0] length,       // bytes to copy
    input             start,        // pulse
    output            busy,

    output            ddr_req,
    output     [27:0] ddr_addr,     // byte offset from 0x30000000
    input             ddr_busy,
    input             ddr_valid,
    input      [63:0] ddr_rdata,

    output reg        wr,           // one byte, as ioctl_wr
    output reg [26:0] addr,
    output reg  [7:0] dout,
    input             wait_in       // ioctl_wait
);

localparam [2:0] L_IDLE = 0, L_RD = 1, L_RDWAIT = 2, L_BYTE = 3, L_GAP = 4;
reg  [2:0]  st = L_IDLE;
reg  [27:0] gaddr;                  // granule-aligned
reg  [63:0] gran;
reg  [2:0]  k;                      // byte within the granule

assign busy     = st != L_IDLE;
assign ddr_req  = st == L_RD;
assign ddr_addr = gaddr;

always @(posedge clk or posedge reset) begin
    if( reset ) begin
        st <= L_IDLE; wr <= 0;
    end else begin
        wr <= 0;
        case( st )
            L_IDLE: if( start ) begin gaddr <= 0; st <= L_RD; end
            // hold the request until ddram_phy has taken it: it accepts only
            // while DDRAM_BUSY is low, so "phy not busy" is not "accepted"
            // (Seta's rom_loader moves on at !ddr_busy and can lose it)
            L_RD: if( ddr_valid ) begin gran <= ddr_rdata; k <= 0; st <= L_BYTE; end
                  else if( ddr_busy ) st <= L_RDWAIT;
            L_RDWAIT: if( ddr_valid ) begin gran <= ddr_rdata; k <= 0; st <= L_BYTE; end
            // one byte when the download side is free; the next only after
            // ioctl_wait has had a clock to rise (as hps_io paces ioctl_wr)
            L_BYTE: if( !wait_in ) begin
                wr   <= 1;
                addr <= { gaddr[26:3], k };          // all 27 bits: Rushing Heroes' image ends at 82 MB
                dout <= gran[{ k, 3'b000 } +: 8];     // little-endian: byte k at bits 8k
                st   <= L_GAP;
            end
            L_GAP: begin
                if( k != 3'd7 ) begin k <= k + 1'd1; st <= L_BYTE; end
                else if( gaddr + 28'd8 >= length ) st <= L_IDLE;
                else begin gaddr <= gaddr + 28'd8; st <= L_RD; end
            end
            default: st <= L_IDLE;
        endcase
    end
end

endmodule
