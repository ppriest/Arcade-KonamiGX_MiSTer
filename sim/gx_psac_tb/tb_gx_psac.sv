// gx_psac against scripts/psac2_model.py: scripts/check_gx_psac.py writes
// debug/gx_psac_tb/*.hex from a MAME dump (scripts/mame/psac_dump.lua) and
// compares out.hex, rows 16-239 of 288 { colour, pixel } each, with the
// model, with an SDRAM model (below).
// stats.txt: the clocks each line took.
`timescale 1ns/1ps
module tb_gx_psac;

localparam string DIR = "debug/gx_psac_tb/";
localparam int NS = 4;      // an even number: a fetch fills two

reg clk = 0, rst = 1;
always #10.417 clk = ~clk;

reg  [15:0] regs [16];
reg  [15:0] lc [2048];
reg  [63:0] gfx3 [131072];
reg  [63:0] gfx4 [65536];
reg  [ 7:0] misc [1];
integer     lat;

reg         line_start = 0;
reg  [ 8:0] line_y = 0, rd_x = 0;
wire [ 9:0] rd_pix;
wire        busy, unsupported;
wire [10:0] lc_addr;
reg  [15:0] lc_q;
wire        map_cs;
wire [ 3:0] tile_cs;
wire [15:0] map_addr;
wire [16:0] tile_addr [4];
reg         map_ok = 0;
reg  [ 3:0] tile_ok = 0;
reg  [63:0] map_data, tile_data [4];

gx_psac uut (
    .clk, .rst, .regs, .map_alt(misc[0][4]),
    .lc_addr, .lc_q,
    .line_start, .line_y, .busy, .unsupported,
    .map_cs, .map_addr, .map_ok, .map_data,
    .tile_cs, .tile_addr, .tile_ok, .tile_data,
    .rd_x, .rd_pix
);

always @(posedge clk) lc_q <= lc[lc_addr];

// The SDRAM and its clients (gx_rom_port's contract: cs a level, addr held,
// ok a clock with the granule). Client 0 is the map, 1-4 the tiles. A client
// answers a granule it holds (its last NS fetches and each one's pair, as
// the DBL double read keeps both) the clock after; any other waits for the
// SDRAM, which one access occupies for +OCC=n clocks, and comes back +LAT=n
// clocks after it started. Lower clients start first.
integer occ;
integer busy_n = 0;
reg  [16:0] held [5][NS];
integer     nxt  [5];
integer     cnt  [5];
reg  [16:0] cur  [5];
initial for( int c = 0; c < 5; c++ ) begin nxt[c] = 0; cnt[c] = -1; for( int k = 0; k < NS; k++ ) held[c][k] = '1; end
always @(posedge clk) begin
    reg        cs_c, ok_c;
    reg [16:0] a_c;
    map_ok  <= 0;
    tile_ok <= 0;
    if( busy_n > 0 ) busy_n = busy_n - 1;
    for( int c = 0; c < 5; c++ ) begin
        cs_c = c == 0 ? map_cs : tile_cs[c - 1];
        ok_c = c == 0 ? map_ok : tile_ok[c - 1];
        a_c  = c == 0 ? { 1'b0, map_addr } : tile_addr[c - 1];
        if( !cs_c || ok_c ) cnt[c] = -1;
        else if( cnt[c] < 0 || cur[c] != a_c ) begin
            cur[c] = a_c; cnt[c] = -2;                      // -2: waiting for the SDRAM
            for( int k = 0; k < NS; k++ ) if( held[c][k] == a_c ) cnt[c] = 0;
        end
        if( cs_c && !ok_c && cnt[c] == -2 && busy_n == 0 ) begin
            busy_n = occ; cnt[c] = lat;
        end else if( cs_c && !ok_c && cnt[c] == 0 ) begin
            if( c == 0 ) begin map_ok <= 1; map_data <= gfx4[a_c[15:0]]; end
            else begin tile_ok[c - 1] <= 1; tile_data[c - 1] <= gfx3[a_c]; end
            held[c][nxt[c]] = a_c; held[c][(nxt[c] + 1) % NS] = a_c ^ 17'd1; nxt[c] = (nxt[c] + 2) % NS;
            cnt[c] = -1;
        end else if( cnt[c] > 0 ) cnt[c] = cnt[c] - 1;
    end
end

integer f, fs, worst = 0, bc = 0, passes;
always @(posedge clk) bc <= line_start ? 0 : busy ? bc + 1 : bc;   // the clocks a render takes
// where they go: the map stage waiting on SDRAM, the tile stage's head
// waiting, the FIFO empty, the tile fetches issued
integer mw = 0, hw = 0, fe = 0, tf = 0, mf = 0;
always @(posedge clk) begin
    if( line_start ) begin mw <= 0; hw <= 0; fe <= 0; tf <= 0; mf <= 0; end
    else if( busy ) begin
        if( map_cs ) mw <= mw + 1;
        if( uut.b_run && !uut.f_empty && uut.t_cmp && uut.a_tq != { 1'b1, uut.t_g } ) hw <= hw + 1;
        if( uut.b_run && uut.f_empty ) fe <= fe + 1;
        tf <= tf + $countones(tile_ok);
        if( map_ok ) mf <= mf + 1;
    end
end
initial begin
    if( !$value$plusargs("LAT=%d", lat) ) lat = 12;
    if( !$value$plusargs("OCC=%d", occ) ) occ = 5;
    $readmemh({DIR, "regs.hex"}, regs);
    $readmemh({DIR, "line.hex"}, lc);
    $readmemh({DIR, "gfx3.hex"}, gfx3);
    $readmemh({DIR, "gfx4.hex"}, gfx4);
    $readmemh({DIR, "misc.hex"}, misc);
    repeat (4) @(posedge clk);
    rst <= 0;
    @(posedge clk);
    while( !uut.c_clr[11] ) @(posedge clk);     // the cache's tags cleared
    f  = $fopen({DIR, "out.hex"}, "w");
    fs = $fopen({DIR, "stats.txt"}, "w");
    if( !$value$plusargs("PASSES=%d", passes) ) passes = 1;
    // +PASSES=2: the frame again, the cache warm; out.hex and stats.txt are
    // the last pass's
    for( int pass = 1; pass <= passes; pass++ )
    for( int y = 16; y <= 240; y++ ) begin
        if( y == 16 && pass > 1 ) begin
            $fclose(f); $fclose(fs); worst = 0;
            f  = $fopen({DIR, "out.hex"}, "w");
            fs = $fopen({DIR, "stats.txt"}, "w");
        end
        @(posedge clk);
        line_start <= 1; line_y <= 9'(y);
        @(posedge clk);
        line_start <= 0;
        // the line before is readable while this one renders
        if( y > 16 ) for( int x = 0; x < 288; x++ ) begin
            rd_x <= 9'(x);
            @(posedge clk); @(negedge clk);
            $fwrite(f, "%03x\n", rd_pix);
        end
        @(posedge clk);
        while( busy ) @(posedge clk);
        $fwrite(fs, "%0d %0d map_wait %0d head_wait %0d fifo_empty %0d tile_oks %0d map_oks %0d\n", y, bc, mw, hw, fe, tf, mf);
        if( bc > worst ) worst = bc;
    end
    $fclose(f); $fclose(fs);
    $display("GX_PSAC_DONE worst line %0d clocks%s", worst, unsupported ? " UNSUPPORTED" : "");
    $finish;
end

endmodule
