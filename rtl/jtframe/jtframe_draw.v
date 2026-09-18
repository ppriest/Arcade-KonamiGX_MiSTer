/* SPDX-FileCopyrightText: 2026 Jose Tejada Gomez
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Date: 18-12-2022 */
/* Modified for Arcade-KonamiGX_MiSTer on 2026-09-18 (GPL-3.0 section 5(a)).
 * BPP parameter (4 or 5 bits per pixel); FIRST_PX parameter.
 * Lines changed are marked [GX]; the unmodified file is kept beside this
 * one as *_upstream_reference, and the reasons are in PROVENANCE.md. */

// Draws one line of a 16x16 tile
// It could be extended to 32x32 easily

module jtframe_draw#( parameter
    AW       =  9,    // Buffer with
    CW       = 12,    // code width
    PW       =  8,    // pixel width (lower four bits come from ROM)
    ZW       =  6,    // zoom step width
    ZI       =  ZW-1, // integer part of the zoom, use for enlarging. ZI=ZW-1=no enlarging
    ZENLARGE =  0,    // enable zoom enlarging
    SWAPH    =  0,    // swaps the two horizontal halves of the tile
    KEEP_OLD =  0,    // slows down drawing to be compatible with jtframe_obj_buffer's KEEP_OLD parameter
    BPP      =  4,    // [GX] bits per pixel, 4 or 5: one plane per byte of rom_data
    FIRST_PX =  0     // [GX] 1: when reducing, write only the first source pixel that
                      // lands on each buffer address, as MAME samples (x * step) >> 19;
                      // 0: write them all (the buffer keeps the last)
)(
    input               rst,
    input               clk,

    input               draw,
    output reg          busy,
    input    [CW-1:0]   code,
    input    [AW-1:0]   xpos,
    input      [ 3:0]   ysub,
    input      [ 1:0]   trunc, // 00=no trunc, 10 = 8 pixels, 11 = 4 pixels

    // optional zoom, keep at zero for no zoom
    input    [ZW-1:0]   hzoom,
    input               hz_keep, // set to 0 on the first tile of a multi-tile
                                 // sprite, 1 for the rest of the tiles
    input               hflip,
    input               vflip,
    input  [PW-BPP-1:0] pal,

    output     [CW+6:2] rom_addr, // HVVVV format
    output reg          rom_cs,
    input               rom_ok,
    input  [8*BPP-1:0]  rom_data, // leftmost pixel in LSB
                                  // one plane per byte

    output reg [AW-1:0] buf_addr,
    output              buf_we,
    output     [PW-1:0] buf_din
);

localparam [ZW-1:0] HZONE = { {ZW-1{1'b0}},1'b1} << ZI;

reg [8*BPP-1:0] pxl_data;
reg             rom_lsb;
reg      [ 3:0] cnt;
wire     [ 3:0] ysubf;
wire [BPP-1:0]  pxl;
reg    [ZW-1:0] hz_cnt, nx_hz;
wire  [ZW-1:ZI] hzint;
reg             cen=0, moveon, readon, no_zoom;
reg             new_addr;   // [GX] FIRST_PX: no pixel written at buf_addr yet

assign ysubf   = ysub^{4{vflip}};
assign buf_din = { pal, pxl };
// [GX] one bit from each byte: bit 7 of each (hflip) or bit 0, MSB plane first
genvar gb;
generate for (gb = 0; gb < BPP; gb = gb + 1) begin : g_pxl
    assign pxl[gb] = hflip ? pxl_data[8*gb+7] : pxl_data[8*gb];
end endgenerate

assign rom_addr = { code, rom_lsb^SWAPH[0], ysubf[3:0] };
assign buf_we   = busy & ~cnt[3] & (FIRST_PX==0 || new_addr);
assign hzint    = hz_cnt[ZW-1:ZI];

always @* begin
    if( ZENLARGE==1 ) begin
        readon = hzint >= 1; // tile pixels read (reduce)
        moveon = hzint <= 1; // buffer moves (enlarge)
        nx_hz = readon ? hz_cnt - HZONE : hz_cnt;
        if( moveon  ) nx_hz = nx_hz + hzoom;
        if( no_zoom ) {moveon, readon} = 2'b11;
    end else begin
        readon = 1;
        { moveon, nx_hz } = {1'b1, hz_cnt}-{1'b0,hzoom};
    end
end

always @(posedge clk) cen <= ~cen;

always @(posedge clk) begin
    if( rst ) begin
        rom_cs   <= 0;
        buf_addr <= 0;
        pxl_data <= 0;
        busy     <= 0;
        cnt      <= 0;
        hz_cnt   <= 0;
        no_zoom  <= 0;
    end else begin
        if( !busy ) begin
            if( draw ) begin
                rom_lsb <= hflip;
                rom_cs  <= 1;
                busy    <= 1;
                cnt     <= 8;
                no_zoom <= hzoom == HZONE || hzoom == 0; // zoom=0 is not valid. Makes counts keep going and busy stays forever. Check simpsons/scene 32
                new_addr <= 1;
                if( !hz_keep ) begin
                    hz_cnt   <= ZENLARGE==1 ? hzoom : {ZW{1'b1}};
                    buf_addr <= xpos;
                end
            end
        end else if(KEEP_OLD==0 || cen || cnt[3] ) begin
            // cen is required when old buffer data must be preserved but it
            // slows down the process. That wait is not needed while cnt[3]
            // is high, so it can be used to gain back some time
            if( rom_ok && rom_cs && cnt[3]) begin
                pxl_data <= rom_data;
                cnt[3]   <= 0;
                if( rom_lsb^hflip ) begin
                    rom_cs <= 0;
                end else begin
                    rom_cs <= 1;
                end
            end
            if( !cnt[3] ) begin
                hz_cnt   <= nx_hz;
                if( readon ) begin
                    cnt      <= cnt+1'd1;
                    pxl_data <= hflip ? pxl_data << 1 : pxl_data >> 1;
                end
                if( moveon ) buf_addr <= buf_addr+1'd1;
                new_addr <= moveon;
                rom_lsb  <= ~hflip;
                if( cnt[2:0]==7 && !rom_cs && readon ) busy <= 0; // 16 pixels
                if( cnt[2:0]==7 && trunc==2'b10      ) busy <= 0; //  8 pixels
                if( cnt[1:0]==3 && trunc==2'b11      ) busy <= 0; //  4 pixels
            end
        end
    end
end

endmodule
