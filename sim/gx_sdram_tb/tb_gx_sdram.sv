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

module tb_gx_sdram;

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

reg  [25:0] tile_base, obj_base;
reg  [23:0] tile_size4, obj_size4;
reg         cpu_cs = 0, tile_cs = 0, obj_cs = 0;
reg  [19:0] cpu_addr = 0, obj_addr = 0;
reg  [20:0] tile_addr = 0;
wire        cpu_ok, tile_ok, obj_ok;
wire [63:0] cpu_data;
wire [39:0] tile_data, obj_data;

gx_sdram_top dut (
    .clk, .clk_mem, .reset, .init(~pll_locked),
    .SDRAM_A, .SDRAM_DQ, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS,
    .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CKE, .SDRAM_CLK,
    .ioctl_download, .ioctl_index, .ioctl_wr, .ioctl_addr, .ioctl_dout, .ioctl_wait,
    .tile_base, .obj_base, .tile_size4, .obj_size4,
    .cpu_cs, .cpu_addr, .cpu_ok, .cpu_data,
    .tile_cs, .tile_addr, .tile_ok, .tile_data,
    .obj_cs, .obj_addr, .obj_ok, .obj_data
);

sdram_chip_model_wide u_chip (
    .clk(SDRAM_CLK), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS
);

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
localparam int MAXB = 1 << 24, MAXR = 1 << 15;
reg   [7:0] stream [0:MAXB-1];
reg  [27:0] run_s [0:255], run_n [0:255], run_o [0:255];
int         nruns = 0;
reg  [19:0] cpu_a [0:MAXR-1];   reg [63:0] cpu_d [0:MAXR-1];   int ncpu = 0;
reg  [23:0] tile_a [0:MAXR-1];  reg [39:0] tile_d [0:MAXR-1];  int ntile = 0;
reg  [23:0] obj_a [0:MAXR-1];   reg [39:0] obj_d [0:MAXR-1];   int nobj = 0;

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

task automatic read_cpu(input [19:0] a, output [63:0] d);
    @(posedge clk); cpu_addr <= a; cpu_cs <= 1;
    do @(posedge clk); while (!cpu_ok);
    d = cpu_data; cpu_cs <= 0;
endtask

task automatic read_tile(input [20:0] a, output [39:0] d);
    @(posedge clk); tile_addr <= a; tile_cs <= 1;
    do @(posedge clk); while (!tile_ok);
    d = tile_data; tile_cs <= 0;
endtask

// cs held across reads: only the address moves
task automatic read_obj_held(input [19:0] a, output [39:0] d);
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
    while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, w) == 2) begin tile_a[ntile] = a; tile_d[ntile] = w; ntile++; end
    $fclose(fd);
    fd = $fopen({D, "obj.hex"}, "r");
    while (!$feof(fd)) if ($fscanf(fd, "%h %h\n", a, w) == 2) begin obj_a[nobj] = a; obj_d[nobj] = w; nobj++; end
    $fclose(fd);
    fd = $fopen({D, "cfg.hex"}, "r");
    void'($fscanf(fd, "%h\n%h\n%h\n%h\n", tile_base, obj_base, tile_size4, obj_size4));
    $fclose(fd);
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

    // the CPU's granules of the packed image
    for (k = 0; k < ncpu; k++) begin
        read_cpu(cpu_a[k], got);
        checked++;
        if (got !== cpu_d[k]) begin
            if (badc < 5) $display("  cpu granule %05x: got %016x want %016x", cpu_a[k], got, cpu_d[k]);
            bad++; badc++;
        end
    end
    $display("  cpu     %0d granules checked", ncpu);

    // tile rows, cs dropped between reads
    for (k = 0; k < ntile; k++) begin
        read_tile(tile_a[k][20:0], got40);
        checked++;
        if (got40 !== tile_d[k]) begin
            if (badt < 8) $display("  tile row %06x: got %010x want %010x", tile_a[k], got40, tile_d[k]);
            bad++; badt++;
        end
    end
    $display("  tiles   %0d rows checked", ntile);

    // sprite half-rows, cs held
    for (k = 0; k < nobj; k++) begin
        read_obj_held(obj_a[k][19:0], got40);
        checked++;
        if (got40 !== obj_d[k]) begin
            if (bado < 8) $display("  sprite half-row %06x: got %010x want %010x", obj_a[k], got40, obj_d[k]);
            bad++; bado++;
        end
    end
    @(posedge clk); obj_cs <= 0;
    $display("  sprites %0d half-rows checked", nobj);

    $display("  total checked %0d, mismatches %0d (cpu %0d, tiles %0d, sprites %0d)", checked, bad, badc, badt, bado);
    if (checked == 0 || bad != 0) $display("FAIL: %0d readbacks disagree with MAME's images", bad);
    else $display("PASS: every region reads back as MAME's image");
    $finish;
end

endmodule
