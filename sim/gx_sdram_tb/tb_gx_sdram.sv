// SPDX-License-Identifier: GPL-3.0-or-later
//
// gx_sdram_top with the command-decoding SDRAM chip model: the set's .mra
// stream downloaded through the ioctl port as the HPS delivers it, then
// every region read back through the port the board uses it from and
// compared with MAME's region images. Driven by scripts/check_gx_sdram.py,
// which writes the fixtures in debug/gx_sdram_tb/.
//
// Two clocks as on the board: clk_mem 96 MHz for the controller, the download
// and the arbiter, clk 48 MHz for the clients, edges coincident.
//
// The tile port is read the way gx_tilemap reads (cs dropped after each row)
// and the sprite port the way jtframe_draw reads (cs held, the address
// changing): gx_rom_port serves both.

`timescale 1ns/1ps

module tb_gx_sdram #(
    // -GSD128=1: the 128 MB module (two chips); +HI=<hex> then moves the sprite
    // and sound regions up by that much, so that they are read from the second chip
    parameter bit SD128 = 1'b0
);

localparam string D = "debug/gx_sdram_tb/";

reg clk_mem = 0, clk = 0;
always #5.208  clk_mem = ~clk_mem;
always #10.416 clk     = ~clk;

reg  reset = 1, pll_locked = 0;

// ------------------------------------------------------------ DUT
wire [12:0] SDRAM_A;
wire [15:0] SDRAM_DQ;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

reg         ioctl_download = 0, ioctl_wr = 0;
reg  [15:0] ioctl_index = 0;
reg  [26:0] ioctl_addr = 0;
reg   [7:0] ioctl_dout = 0;
wire        ioctl_wait;

reg  [26:0] tile_base, obj_base;
reg  [23:0] tile_size4, obj_size4;
reg  [ 1:0] tile_bpp = 0, obj_layout = 0;
reg         cpu_cs = 0, tile_cs = 0, obj_cs = 0;
reg         go_hammer = 0;
reg  [19:0] cpu_addr = 0;
reg  [21:0] obj_addr = 0;
reg  [20:0] tile_addr = 0;
wire        cpu_ok, tile_ok, obj_ok;
wire [63:0] cpu_data;
wire [63:0] tile_data, obj_data;

gx_sdram_top dut (
    .clk, .clk_mem, .reset, .init(~pll_locked),
    .SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
    .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,
    .ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
    .tile_base, .obj_base, .tile_size4, .obj_size4, .snd_pcm(24'h400000), .tile_bpp, .obj_layout,
    .cpu_cs, .cpu_addr, .cpu_ok, .cpu_data,
    .tile_cs, .tile_addr, .tile_ok, .tile_data,
    .obj_cs, .obj_addr, .obj_ok, .obj_data,
    .obj_pf_cs(1'b0), .obj_pf_addr(22'd0),
    .gfx_cs, .gfx_addr, .gfx_ok, .gfx_data
);

// the absolute-address port the ROM readback windows use: here it checks the
// sound board's ROMs, which nothing else reads yet
reg         gfx_cs = 0;
reg  [22:0] gfx_addr = 0;
wire        gfx_ok;
wire [63:0] gfx_data;

generate if (SD128) begin : g_128
sdram_chip_model_128 u_chip (
    .clk(SDRAM_CLK), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
);
end else begin : g_32
sdram_chip_model_wide u_chip (
    .clk(SDRAM_CLK), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
);
end endgenerate

// ------------------------------------------------------------ probes
// +TRACE: the first download writes at the download module's output and at
// the controller's port
int trace = 0, tr_n = 0, tr_m = 0;
reg dl_req_l = 0, p_req_l = 0;
always @(posedge clk_mem) begin
    dl_req_l <= dut.dl_req;
    p_req_l  <= dut.p_req[2];
    if (trace && dut.dl_req && !dl_req_l && tr_n < 12) begin
        $display("  dl   addr %07x data %04x we16 %0d", dut.dl_addr, dut.dl_data, dut.dl_we16); tr_n++;
    end
    if (trace && dut.p_req[2] != p_req_l && tr_m < 12) begin
        $display("  port addr %07x wrl %0d wrh %0d din %04x", { dut.p_addr[2], 1'b0 }, dut.p_wrl[2], dut.p_wrh[2], dut.p_din[2]); tr_m++;
    end
end

// ------------------------------------------------------------ fixtures
localparam int MAXB = 1 << 25, MAXR = 1 << 15;   // tokkae streams 17 MB of non-zero runs
reg   [7:0] stream [0:MAXB-1];
reg  [27:0] run_s [0:255], run_n [0:255], run_o [0:255];
int         nruns = 0;
reg  [19:0] cpu_a [0:MAXR-1];   reg [63:0] cpu_d [0:MAXR-1];   int ncpu = 0;
reg  [23:0] tile_a [0:MAXR-1];  reg [63:0] tile_d [0:MAXR-1];  int ntile = 0;
reg  [23:0] obj_a [0:MAXR-1];   reg [63:0] obj_d [0:MAXR-1];   int nobj = 0;
reg  [22:0] snd_a [0:MAXR-1];   reg [63:0] snd_d [0:MAXR-1];   int nsnd = 0;
int  bads = 0;

int bad = 0, checked = 0, badc = 0, badt = 0, bado = 0;

// one byte into the ioctl port, honouring backpressure (no edge between the
// wait and the assignment: sim/sdram_top_tb's lesson in Seta)
task automatic push(input [26:0] a, input [7:0] d);
    while (ioctl_wait) @(posedge clk_mem);
    ioctl_addr <= a; ioctl_dout <= d; ioctl_wr <= 1;
    @(posedge clk_mem);
    ioctl_wr <= 0;
    @(posedge clk_mem);
endtask

// +HAMMER=1: keep the tile and sprite clients asking while the CPU reads,
// as they do on the board (every line, all frame). The chip serves one
// transaction at a time and a port's 64 bits arrive as four 16-bit words, so
// a port that loses the later words under contention shows up here.
int  hammer = 0;
reg  [20:0] ham_t = 0;
reg  [19:0] ham_o = 0;
reg         ham_obj = 1;   // cleared while the latency measurement drives the sprite port
reg         ham_tile = 1;  // and the same for the tile port
initial void'($value$plusargs("HAMMER=%d", hammer));
always @(posedge clk) if (hammer != 0 && go_hammer) begin
    if (ham_tile && (tile_ok || !tile_cs)) begin tile_cs <= 1; ham_t <= ham_t + 21'd1; tile_addr <= ham_t; end
    if (ham_obj && (obj_ok || !obj_cs)) begin obj_cs <= 1; ham_o <= ham_o + 20'd3; obj_addr <= ham_o; end
end

// +LATENCY=1: what a sprite row costs on this memory path. The drawer's
// pattern (jtframe_draw): ask for the row's first half, draw eight pixels in
// eight clocks while the second half is asked for, draw eight more. A half
// that answers within eight clocks is free; anything longer is the stall the
// sprite scan pays on every row, and 234 lines of a frame have about 100
// rows between them.
// c_req to c_valid on the sprite client, in clk_mem cycles: what
// sim/gx_obj_tb's +ROM_LAT_M stands for
int cm_n = 0, cm_sum = 0, cm_max = 0, cm_cnt = 0;
reg cm_run = 0;
always @(posedge clk_mem) begin
    if (dut.u_obj.c_req) begin
        cm_cnt <= cm_cnt + 1;
        if (dut.arb0_valid[1]) begin
            cm_n++; cm_sum += cm_cnt + 1;
            if (cm_cnt + 1 > cm_max) cm_max = cm_cnt + 1;
            cm_cnt <= 0;
        end
    end else cm_cnt <= 0;
end

int  latency = 0;
int  lat_rows = 200;
initial void'($value$plusargs("LATENCY=%d", latency));

int l0_min, l0_max, l0_sum, l1_min, l1_max, l1_sum, stall_sum, row_max;

// the tilemap's own pattern: a row, cs dropped, the next row. It has about
// twenty clocks a row to play with (four layers, eight pixels a fetch), so
// what the sprite port's prefetching does to it matters.
task automatic measure_tile(input string what);
    int k, l, mn, mx, sum;
    mn = 9999; mx = 0; sum = 0;
    for (k = 0; k < lat_rows; k++) begin
        @(posedge clk) begin tile_cs <= 1; tile_addr <= 21'(k * 1031); end
        l = 0;
        do begin @(posedge clk); l++; end while (!tile_ok);
        @(posedge clk) tile_cs <= 0;
        if (l < mn) mn = l;  if (l > mx) mx = l;  sum += l;
    end
    $display("  LATENCY %-20s tile row %0d/%0d/%0d min/avg/max", what, mn, sum / lat_rows, mx);
endtask

task automatic measure_rows(input string what);
    int k, t, l0, l1, row;
    l0_min = 9999; l0_max = 0; l0_sum = 0;
    l1_min = 9999; l1_max = 0; l1_sum = 0;
    stall_sum = 0; row_max = 0;
    for (k = 0; k < lat_rows; k++) begin
        // a row of a tile the scan picked: spread far apart, as consecutive
        // sprites in the list are
        @(posedge clk) begin obj_cs <= 1; obj_addr <= 20'(k * 1031 * 2); end
        l0 = 0;
        do begin @(posedge clk); l0++; end while (!obj_ok);
        @(posedge clk) obj_addr <= 20'(k * 1031 * 2 + 1);
        l1 = 0;
        do begin @(posedge clk); l1++; end while (!obj_ok);
        // the eight clocks of the first half's pixels overlap the second fetch
        row = l0 + 8 + (l1 > 8 ? l1 - 8 : 0) + 8;
        if (l0 < l0_min) l0_min = l0;  if (l0 > l0_max) l0_max = l0;  l0_sum += l0;
        if (l1 < l1_min) l1_min = l1;  if (l1 > l1_max) l1_max = l1;  l1_sum += l1;
        if (row > row_max) row_max = row;
        stall_sum += row;
        @(posedge clk) obj_cs <= 0;
    end
    if (cm_n != 0) $display("  LATENCY %-20s c_req to c_valid %0d clk_mem avg, %0d max, over %0d fetches",
                            what, cm_sum / cm_n, cm_max, cm_n);
    cm_n = 0; cm_sum = 0; cm_max = 0;
    $display("  LATENCY %-20s first half %0d/%0d/%0d min/avg/max, second %0d/%0d/%0d, row avg %0d clk max %0d",
             what, l0_min, l0_sum / lat_rows, l0_max, l1_min, l1_sum / lat_rows, l1_max,
             stall_sum / lat_rows, row_max);
endtask

task automatic read_cpu(input [19:0] a, output [63:0] d);
    @(posedge clk); cpu_addr <= a; cpu_cs <= 1;
    do @(posedge clk); while (!cpu_ok);
    d = cpu_data; cpu_cs <= 0;
endtask

task automatic read_tile(input [20:0] a, output [63:0] d);
    @(posedge clk); tile_addr <= a; tile_cs <= 1;
    do @(posedge clk); while (!tile_ok);
    d = tile_data; tile_cs <= 0;
endtask

// cs held across reads: only the address moves
task automatic read_obj_held(input [21:0] a, output [63:0] d);
    @(posedge clk); obj_addr <= a; obj_cs <= 1;
    do @(posedge clk); while (!obj_ok);
    d = obj_data;
endtask

initial begin
    int fd, k, a; reg [63:0] v; reg [39:0] w; reg [27:0] s, n, o;
    reg [63:0] got; reg [39:0] got40;
    void'($value$plusargs("TRACE=%d", trace));
    $readmemh({D, "stream.hex"}, stream);
    fd = $fopen({D, "runs.hex"}, "r");
    while (!$feof(fd)) if ($fscanf(fd, "%h %h %h\n", s, n, o) == 3) begin run_s[nruns] = s; run_n[nruns] = n; run_o[nruns] = o; nruns++; end
    $fclose(fd);
    fd = $fopen({D, "cpu.hex"}, "r");
    while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, v) == 2) begin cpu_a[ncpu] = a; cpu_d[ncpu] = v; ncpu++; end
    $fclose(fd);
    fd = $fopen({D, "tile.hex"}, "r");
    while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, v) == 2) begin tile_a[ntile] = a; tile_d[ntile] = v; ntile++; end
    $fclose(fd);
    fd = $fopen({D, "snd.hex"}, "r");
    if (fd != 0) begin
        while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, v) == 2) begin snd_a[nsnd] = a; snd_d[nsnd] = v; nsnd++; end
        $fclose(fd);
    end
    fd = $fopen({D, "obj.hex"}, "r");
    while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, v) == 2) begin obj_a[nobj] = a; obj_d[nobj] = v; nobj++; end
    $fclose(fd);
    fd = $fopen({D, "cfg.hex"}, "r");
    void'($fscanf(fd, "%h\n%h\n%h\n%h\n%h\n%h\n", tile_base, obj_base, tile_size4, obj_size4, tile_bpp, obj_layout));
    $fclose(fd);
    begin
        int unsigned hi = 0;
        if ($value$plusargs("HI=%h", hi) && hi != 0) begin
            // the sprite and sound runs, and the base, move up together; the
            // sound readback is left out (its absolute port spans 64 MB)
            for (int r = 0; r < nruns; r++) if (run_s[r] >= obj_base) run_s[r] += hi;
            obj_base += hi;
            nsnd = 0;
        end
    end
    $display("=== gx_sdram_top: %0d stream runs, %0d CPU granules, %0d tile rows, %0d sprite half-rows; bases %07x %07x size4 %06x %06x",
             nruns, ncpu, ntile, nobj, tile_base, obj_base, tile_size4, obj_size4);

    repeat (8) @(posedge clk_mem);
    reset <= 0; pll_locked <= 1;
    repeat (30000) @(posedge clk_mem);            // the controller's power-up sequence

    ioctl_download <= 1; ioctl_index <= 0;
    @(posedge clk_mem);
    for (int r = 0; r < nruns; r++)
        for (k = 0; k < run_n[r]; k++) push(run_s[r] + k, stream[run_o[r] + k]);
    while (ioctl_wait) @(posedge clk_mem);
    repeat (64) @(posedge clk_mem);
    ioctl_download <= 0;
    repeat (64) @(posedge clk_mem);
    $display("  downloaded");

    // the CPU's granules of the packed image, with the other two clients
    // asking as well when +HAMMER=1
    go_hammer <= 1;
    for (k = 0; k < ncpu; k++) begin
        read_cpu(cpu_a[k], got);
        checked++;
        if (got !== cpu_d[k]) begin
            if (badc < 5) $display("  cpu granule %05x: got %016x want %016x", cpu_a[k], got, cpu_d[k]);
            bad++; badc++;
        end
    end
    go_hammer <= 0;
    tile_cs <= 0; obj_cs <= 0;
    repeat (16) @(posedge clk);
    $display("  cpu     %0d granules checked%s", ncpu, hammer != 0 ? " (with tile/sprite traffic)" : "");

    // tile rows, cs dropped between reads
    for (k = 0; k < ntile; k++) begin
        read_tile(tile_a[k][20:0], got);
        checked++;
        if (got !== tile_d[k]) begin
            if (badt < 8) $display("  tile row %06x: got %016x want %016x", tile_a[k], got, tile_d[k]);
            bad++; badt++;
        end
    end
    $display("  tiles   %0d rows checked", ntile);

    // sprite half-rows, cs held
    for (k = 0; k < nobj; k++) begin
        read_obj_held(obj_a[k][21:0], got);
        checked++;
        if (got !== obj_d[k]) begin
            if (bado < 8) $display("  sprite half-row %06x: got %016x want %016x", obj_a[k], got, obj_d[k]);
            bad++; bado++;
        end
    end
    @(posedge clk); obj_cs <= 0;
    $display("  sprites %0d half-rows checked", nobj);

    if (latency != 0) begin
        measure_rows("sprite port alone");
        measure_tile("tile port alone");
        ham_obj <= 0;
        go_hammer <= 1;
        // the tile port only: the CPU reads through its cache, the tilemap
        // reads every line of every frame
        repeat (64) @(posedge clk);
        measure_rows("with tile traffic");
        // now the other way round: the sprite port asking without pause,
        // as it does while a line of sprites is drawn
        ham_obj <= 1; ham_tile <= 0;
        repeat (64) @(posedge clk);
        measure_tile("with sprite traffic");
        go_hammer <= 0; ham_tile <= 1;
        tile_cs <= 0; obj_cs <= 0;
        repeat (16) @(posedge clk);
    end

    // the sound board's ROMs, by absolute granule
    for (k = 0; k < nsnd; k++) begin
        @(posedge clk) begin gfx_addr <= snd_a[k]; gfx_cs <= 1; end
        do @(posedge clk); while (!gfx_ok);
        got = gfx_data;
        @(posedge clk) gfx_cs <= 0;
        @(posedge clk);
        checked++;
        if (got !== snd_d[k]) begin
            if (bads < 8) $display("  sound granule %06x: got %016x want %016x", snd_a[k], got, snd_d[k]);
            bad++; bads++;
        end
    end
    if (nsnd != 0) $display("  sound   %0d granules checked", nsnd);

    $display("  total checked %0d, mismatches %0d (cpu %0d, tiles %0d, sprites %0d, sound %0d)", checked, bad, badc, badt, bado, bads);
    if (checked == 0 || bad != 0) $display("FAIL: %0d readbacks disagree with MAME's images", bad);
    else $display("PASS: every region reads back as MAME's image");
    if (SD128) $display("  chips: writes %0d / %0d, refreshes %0d / %0d",
                        g_128.u_chip.u_c0.writes, g_128.u_chip.u_c1.writes,
                        g_128.u_chip.u_c0.refreshes, g_128.u_chip.u_c1.refreshes);
    $finish;
end

endmodule
