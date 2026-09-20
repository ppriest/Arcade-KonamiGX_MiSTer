// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GX main board (rtl/gx_main.sv) running daiskiss from reset, traced the
// way scripts/mame/systrace.lua traces MAME: every write (CPU and ESC), every
// read in 0xd00000-0xdfffff, and "# frame N" at each vblank. Compared with
// MAME's trace by scripts/check_gx_main.py. Run from the repository root:
//
//     python scripts/mame_sys_trace.py daiskiss 400
//     python scripts/check_gx_main.py daiskiss 400
//
// Given: the program ROM image (build_rom_image.py maincpu), the two graphics
// ROM images the video benches use, the EEPROM image pinned in
// debug/<set>-nvram, MAME's input port values, and MAME's own replies from
// the sound CPU through the K056800 -- replayed in order per register, the
// way the sound side stands in until it exists (Phase 3).
//
// Runs on Verilator (TG68K.C as GHDL's Verilog conversion, scripts/tg68k_verilog.sh)
// or ModelSim (the VHDL itself): check_gx_main.py --sim.
//
// Under Verilator the clock comes from sim/gx_main_tb/main.cpp (GX_CPP_CLOCK):
// A --timing build cannot be saved, and main.cpp saves
// (+SAVE=file +SAVE_AT=frame) and restores (+RESTORE=file) one. After a
// restore, `reopen` is high for the first clock: the trace is reopened for
// appending and the run's plusargs are read again -- everything else,
// including the ROM images and the sound replies, comes from the snapshot.

`timescale 1ns/1ps

// clk_cpu is the kernel's 24 MHz, clk / 2 with COINCIDENT rising edges, as
// the PLL gives it: both are blocking-assigned in the same time step (or set
// together before one eval in main.cpp), so every process samples pre-edge
// values, as on the board.
`ifdef GX_CPP_CLOCK
module tb_gx_main (
    input             clk,
    input             clk_cpu,
    input             reopen,
    output     [31:0] frame_o
);
`else
module tb_gx_main;
reg clk = 0, clk_cpu = 0, reopen = 0;
always #10.417 clk = ~clk;
always #20.834 clk_cpu = ~clk_cpu;
`endif

localparam string TD = "debug/gx_tilemap_tb/";
localparam string OD = "debug/gx_obj_tb/";
localparam string SD = "debug/gx_main_tb/";   // the inputs check_gx_main.py writes (snd.hex)
string            od = SD;                    // +OUT=<dir/>: this run's trace and pictures
string            set_name = "daiskiss";      // +SET=<name>: its ROM image, EEPROM image and trace name

reg rst = 1;

// ----------------------------------------------------------- program ROM
// gx_main asks for granules of the packed SDRAM image (gx_sdram_top.sv):
// granule g is CPU bytes 8g.. below 0x20000 and 8g + 0x1e0000 above, byte k
// at bits [8k +: 8]. Answered +ROM_WAIT clocks after rom_cs (default 10,
// about what the SDRAM path takes); the cache in gx_main makes a hit one
// wait state. rom_cs drops the clock after rom_ok; !rom_ok keeps that clock
// from answering twice.
localparam int ROM_BYTES = 8 * 1024 * 1024;
byte unsigned rom [0:ROM_BYTES-1];
wire [19:0] rom_addr;
wire        rom_cs;
reg         rom_ok = 0;
reg  [63:0] rom_data;
wire [22:0] rom_byte = rom_addr < 20'h4000 ? { rom_addr, 3'b000 } : { rom_addr, 3'b000 } + 23'h1e0000;
// +ROM_WAIT=n clocks a fetch, plus one on every other fetch unless
// +ROM_JITTER=0: the board's SDRAM answers in an odd number of clocks as
// often as an even one, and a fixed even latency hid a lost-ack fault in the
// ESC's release of the CPU (LESSONS_LEARNED).
int         rom_wait = 10, rom_jitter = 1, rlat = 0;
reg  [7:0]  rom_lfsr = 8'h5a;
always @(posedge clk) begin
    rom_ok <= 0;
    if (!rom_cs) rlat <= 0;
    else if (rlat < rom_wait + (rom_jitter != 0 ? int'(rom_lfsr[0]) : 0)) rlat <= rlat + 1;
    else if (!rom_ok) begin
        rom_ok   <= 1;
        rom_lfsr <= { rom_lfsr[6:0], rom_lfsr[7] ^ rom_lfsr[5] ^ rom_lfsr[4] ^ rom_lfsr[3] };
        for (int k = 0; k < 8; k++) rom_data[8*k +: 8] <= rom[rom_byte + k];
    end
end

// ----------------------------------------------------------- graphics ROMs
reg [39:0] trom_v [1 << 20];
reg [39:0] orom_v [1 << 20];
int        tntiles, ontiles, ROM_LAT = 6;
wire [23:0] tile_rom_addr;  wire tile_rom_cs;  reg tile_rom_ok = 0; reg [39:0] tile_rom_data;
wire [22:0] obj_rom_addr;   wire obj_rom_cs;   reg obj_rom_ok = 0;  reg [39:0] obj_rom_data;
reg [23:0] tlast; int tlat;
always @(posedge clk) begin
    tile_rom_ok <= 1'b0;
    if (!tile_rom_cs) tlat <= 0;
    else if (tlat == 0 || tile_rom_addr != tlast) begin tlast <= tile_rom_addr; tlat <= 1; end
    else if (tlat < ROM_LAT) tlat <= tlat + 1;
    else begin
        tile_rom_ok   <= 1'b1;
        tile_rom_data <= trom_v[((tile_rom_addr >> 3) % tntiles) * 8 + tile_rom_addr[2:0]];
    end
end
// One ok per fetch, as gx_rom_port gives it: a fetch is a new address or cs
// raised again. The model used to repeat ok on every clock once the latency
// had passed, which hid a lost-ok deadlock in the sprite drawer that the
// board showed (gx_obj.v). +OBJ_OK_LEVEL=1 restores the repeat.
reg [22:0] olast; int olat; reg odone = 0; int obj_ok_level = 0;
initial void'($value$plusargs("OBJ_OK_LEVEL=%d", obj_ok_level));
always @(posedge clk) begin
    obj_rom_ok <= 1'b0;
    if (!obj_rom_cs) begin olat <= 0; odone <= 0; end
    else if (olat == 0 || obj_rom_addr != olast) begin olast <= obj_rom_addr; olat <= 1; odone <= 0; end
    else if (olat < ROM_LAT) olat <= olat + 1;
    else if (!odone || obj_ok_level != 0) begin
        odone <= 1;
        obj_rom_ok   <= 1'b1;
        obj_rom_data <= orom_v[(((obj_rom_addr >> 5) % ontiles) << 5) | obj_rom_addr[4:0]];
    end
end

// ----------------------------------------------------------- K056800 replay
// snd.hex: one line per MAME read, "reg value frame", in MAME's order.
// Replayed in order per register -- which holds through the boot -- and from
// RTL frame +SND_TIME_FROM by time: a read in RTL frame f gets the replies
// MAME's CPU got in its frame f + +SND_OFFSET, in order, the last of them
// repeated if the RTL reads more often. The game polls sound status a
// number of times that depends on CPU speed, so order alone drifts.
localparam int MAXR = 1 << 20;
reg  [ 3:0] rp_reg [MAXR];
reg  [ 7:0] rp_val [MAXR];
int         rp_fr  [MAXR];
int         rp_n = 0, snd_time_from = -1, snd_offset = 0;
int         rp_next [16];         // per register: index of the next reply
reg  [ 7:0] rp_last [16];
wire        snd_wr, snd_rd;
wire [ 3:0] snd_addr;
wire [ 7:0] snd_dout;
reg  [ 7:0] snd_din;
int         snd_miss = 0;

// +SND_STUB=1: the core's gx_snd_stub answers instead of MAME's replies
int         snd_stub = 0;
wire [7:0]  stub_dout;
reg         lvbl_st = 1;
always @(posedge clk) lvbl_st <= vid_lvbl;
gx_snd_stub u_stub ( .clk, .rst, .frame(lvbl_st & ~vid_lvbl), .wr(snd_wr), .rd(snd_rd && snd_stub != 0),
                     .addr(snd_addr), .din(snd_dout), .dout(stub_dout) );
wire [7:0]  snd_din_mux = snd_stub != 0 ? stub_dout : snd_din;

always @(posedge clk) if (snd_rd && snd_stub == 0) begin
    int k, target;
    k = rp_next[snd_addr];
    if (snd_time_from >= 0 && frame >= snd_time_from) begin
        target = frame + snd_offset;
        while (k < rp_n && (rp_reg[k] != snd_addr || rp_fr[k] < target)) k++;
        if (k < rp_n && rp_fr[k] == target) begin
            snd_din <= rp_val[k];
            rp_last[snd_addr] <= rp_val[k];
            rp_next[snd_addr] = k + 1;
        end else begin
            snd_din <= rp_last[snd_addr];   // no more replies in that frame
            rp_next[snd_addr] = k;
        end
    end else begin
    while (k < rp_n && rp_reg[k] != snd_addr) k++;
    if (k < rp_n) begin
        snd_din <= rp_val[k];
        rp_last[snd_addr] <= rp_val[k];
        rp_next[snd_addr] = k + 1;
    end else begin
        snd_din <= rp_last[snd_addr];     // MAME's trace ran out: repeat the last reply
        snd_miss++;
    end
    end
end

// ----------------------------------------------------------- DUT
reg        ee_we = 0;
reg  [5:0] ee_a;
reg [15:0] ee_d;
reg  signed [7:0] offs_x [4], offs_y [4];
wire [23:0] rgb, dbg_addr;
wire        vid_lhbl, vid_lvbl, vid_hs, vid_vs, unsupported, dbg_access, dbg_we;
wire [ 1:0] dbg_be;
wire [15:0] dbg_data;

wire [15:0] dbg_rom_hits, dbg_rom_misses;
gx_main dut (
    .rst, .clk, .clk_cpu,
    .rom_addr, .rom_cs, .rom_ok, .rom_data,
    .tile_rom_addr, .tile_rom_cs, .tile_rom_ok, .tile_rom_data,
    .obj_rom_addr, .obj_rom_cs, .obj_rom_ok, .obj_rom_data, .obj_pf_addr(), .obj_pf_cs(),
    .snd_wr, .snd_rd, .snd_addr, .snd_dout, .snd_din(snd_din_mux),
    .inputs(32'hFFFF_FFFF), .coins(8'h7F), .dsw(16'hFEFF), .service(8'hFF),
    .ee_blank(rst), .ee_load_we(ee_we), .ee_load_addr(ee_a), .ee_load_data(ee_d),
    .offs_x, .offs_y, .primode(4'd4),
    // per set, as gx_board_cfg gives them: +ESC_GEN, +ESC_SRC, +ESC_COUNT,
    // +OBJ_HADJ (sexyparo: 0, c00604, fc, -16)
    .obj_hadj(10'(obj_hadj)), .esc_gen(esc_gen[0]), .esc_src(24'(esc_src)), .esc_count(9'(esc_count)),
    .rgb, .vid_lhbl, .vid_lvbl, .vid_hs, .vid_vs, .pxl_cen_o(), .unsupported,
    .dbg_addr, .dbg_access, .dbg_we, .dbg_be, .dbg_data, .dbg_ee(), .dbg_rom_hits, .dbg_rom_misses, .dbg_irq(), .dbg_esc(), .dbg_esc_st(), .dbg_obj(), .dbg_mix(), .dbg_rom(), .peek_t(1'b0), .peek_addr(20'd0), .mem_t(1'b0), .mem_addr(23'd0), .dbg_mem(),
    // the SDRAM layout's tile_base: where the packed CPU image ends
    .rom_top(26'h200000)
);

// ----------------------------------------------------------- trace
// The last column is the CPU's interrupt mask (SR bits 8-10), as MAME's
// trace has it: check_gx_main.py compares each level as its own stream.
// It is read from GHDL's conversion under Verilator; ModelSim cannot see into the
// VHDL and writes 0.
`ifdef VERILATOR
wire [2:0] ipl_mask = dut.u_cpu.flagssr[2:0];
`else
wire [2:0] ipl_mask = 3'd0;
`endif
int junk_from = 0;
int obj_hadj = 0, esc_gen = 1, esc_src = 24'hc00000, esc_count = 'h100;
initial begin
    void'($value$plusargs("OBJ_HADJ=%d", obj_hadj));
    void'($value$plusargs("ESC_GEN=%d", esc_gen));
    void'($value$plusargs("ESC_SRC=%h", esc_src));
    void'($value$plusargs("ESC_COUNT=%h", esc_count));
end

integer ft, seq = 0, frame = 0, frames = 60;
reg     lvbl_l = 1;
`ifdef GX_CPP_CLOCK
assign frame_o = frame;
`endif

always @(posedge clk) if (!rst) begin
    lvbl_l <= vid_lvbl;
    if (dbg_access && (dbg_we || (dbg_addr >= 24'hd00000 && dbg_addr < 24'he00000))) begin
        seq++;
        $fdisplay(ft, "%0d\t%s\t%06X\t%08X\t%08X\t%0d", seq, dbg_we ? "w" : "r",
                  { dbg_addr[23:2], 2'b00 },
                  dbg_addr[1] ? { 16'h0, {8{dbg_be[1]}}, {8{dbg_be[0]}} } : { {8{dbg_be[1]}}, {8{dbg_be[0]}}, 16'h0 },
                  dbg_addr[1] ? { 16'h0, dbg_data } : { dbg_data, 16'h0 }, ipl_mask);
    end
    if (!vid_lvbl && lvbl_l) begin
        frame++;
        $fdisplay(ft, "# frame %0d", frame);
        $fflush(ft);                    // a snapshot taken here keeps the trace whole
        if (frame % 20 == 0) $display("frame %0d  seq %0d  %t", frame, seq, $time);
        if (frame >= frames) begin
            $fdisplay(ft, "# %0d accesses logged", seq);
            $fclose(ft);
            $display("SND replies exhausted %0d times", snd_miss);
            $display("ROM cache: %0d hits, %0d misses (16-bit counters)", dbg_rom_hits, dbg_rom_misses);
            $display("GX_MAIN_DONE");
            $finish;
        end
    end
end

// ----------------------------------------------------------- pictures
// The visible pixels of each frame shown after marker n, one hex RGB per
// line, to shot_<n>.hex: for n in +SHOT_FROM..+SHOT_TO, and for each n
// listed (hex, one a line) in <out>/shot_frames.hex if it exists.
integer fs, shot_from = -1, shot_to = -1, shot_px = 0, shot_n;
reg     shooting = 0, lvbl_s = 1;
reg     shot_want [0:16383];
task automatic read_shot_list;
    int fl;
    reg [13:0] fr_list [0:1023];
    for (int i = 0; i < 16384; i++) shot_want[i] = 0;
    for (int i = 0; i < 1024; i++) fr_list[i] = 0;
    fl = $fopen({od, "shot_frames.hex"}, "r");
    if (fl != 0) begin
        $fclose(fl);
        $readmemh({od, "shot_frames.hex"}, fr_list);
        for (int i = 0; i < 1024; i++) if (fr_list[i] != 0) shot_want[fr_list[i]] = 1;
    end
endtask
always @(posedge clk) if (!rst) begin
    lvbl_s <= vid_lvbl;
    if (vid_lvbl && !lvbl_s && ((frame >= shot_from && frame <= shot_to) || (frame < 16384 && shot_want[frame]))) begin
        fs = $fopen($sformatf("%sshot_%0d.hex", od, frame), "w");
        shooting <= 1; shot_px = 0; shot_n = frame;
    end else if (!vid_lvbl && lvbl_s && shooting) begin
        $fclose(fs); shooting <= 0;
        if (shot_px != 64512) $display("SHOT %0d: %0d visible pixels", shot_n, shot_px);
    end else if (shooting && dut.pxl_cen && vid_lhbl && vid_lvbl) begin
        $fwrite(fs, "%06x\n", rgb); shot_px++;
    end
end

// ----------------------------------------------------------- probes
// +PROBE_FROM=a +PROBE_TO=b: per frame, what the sprite path did -- DMA
// runs, sprites started drawing, sprite pixels out of the line buffer.
// Only under Verilator, which can reach inside the design.
`ifdef VERILATOR
integer probe_from = -1, probe_to = -1, p_dma, p_draw, p_px, p_shd, p_rom, p_ok, p_we, p_pen;
reg     p_dma_l, lvbl_p = 1, p_cs_l;
always @(posedge clk) if (!rst) begin
    lvbl_p  <= vid_lvbl;
    p_dma_l <= dut.u_video.u_obj.dma_bsy;
    p_cs_l  <= obj_rom_cs;
    if (!vid_lvbl && lvbl_p) begin
        if (frame >= probe_from && frame <= probe_to)
            $display("PROBE frame %0d: dma %0d, drawn %0d, rom req %0d ok %0d, buf we %0d pen %0d, obj px %0d, shadow px %0d, objset1 %02x",
                     frame, p_dma, p_draw, p_rom, p_ok, p_we, p_pen, p_px, p_shd, dut.u_video.u_obj.objset1);
        p_dma = 0; p_draw = 0; p_px = 0; p_shd = 0; p_rom = 0; p_ok = 0; p_we = 0; p_pen = 0;
    end else begin
        if (dut.u_video.u_obj.dma_bsy && !p_dma_l) p_dma++;
        if (dut.u_video.u_obj.dr_start) p_draw++;
        if (obj_rom_cs && !p_cs_l) p_rom++;
        if (obj_rom_ok) p_ok++;
        if (dut.u_video.u_obj.u_draw.u_draw.buf_we) begin
            p_we++;
            if (dut.u_video.u_obj.u_draw.u_draw.buf_din[4:0] != 0) p_pen++;
        end
        if (dut.pxl_cen && dut.u_video.u_obj.pxl_valid) p_px++;
        if (dut.pxl_cen && dut.u_video.u_obj.shd_valid) p_shd++;
    end
end

// +PROBE_DUMP=n: in frame n, the first DMA reads and sprite ROM answers
integer probe_dump = -1, pd_dma = 0, pd_rom = 0;
reg     pd_dma_l = 0;
reg [13:1] pd_dma_a;
always @(posedge clk) if (!rst && frame == probe_dump) begin
    pd_dma_l <= dut.u_video.u_obj.dma_bsy;
    pd_dma_a <= dut.u_video.u_obj.dma_addr;
    if (pd_dma_l && pd_dma < 48 && pd_dma_a != dut.u_video.u_obj.dma_addr) begin
        $display("DUMP dma  %04x -> %04x", { pd_dma_a, 1'b0 }, dut.u_video.u_obj.dma_data);
        pd_dma++;
    end
    if (obj_rom_ok && pd_rom < 24) begin
        $display("DUMP rom  %06x -> %010x", olast, obj_rom_data);
        pd_rom++;
    end
end
`endif

// ----------------------------------------------------------- setup
task automatic run_args;
    void'($value$plusargs("OUT=%s", od));
    void'($value$plusargs("SET=%s", set_name));
    read_shot_list();
    void'($value$plusargs("FRAMES=%d", frames));
    void'($value$plusargs("ROM_WAIT=%d", rom_wait));
    void'($value$plusargs("ROM_JITTER=%d", rom_jitter));
    void'($value$plusargs("SND_TIME_FROM=%d", snd_time_from));
    void'($value$plusargs("SND_OFFSET=%d", snd_offset));
    void'($value$plusargs("SND_STUB=%d", snd_stub));
    void'($value$plusargs("SHOT_FROM=%d", shot_from));
    void'($value$plusargs("SHOT_TO=%d", shot_to));
`ifdef VERILATOR
    void'($value$plusargs("PROBE_FROM=%d", probe_from));
    void'($value$plusargs("PROBE_TO=%d", probe_to));
    void'($value$plusargs("PROBE_DUMP=%d", probe_dump));
`endif
endtask

always @(posedge clk) if (reopen) begin
    run_args();                         // this run's OUT before the trace is reopened there
    ft = $fopen({od, set_name, "_rtl_sys.trace"}, "a");
    $display("RESTORED at frame %0d, seq %0d; running to frame %0d", frame, seq, frames);
end

// The EEPROM image, then reset: a clocked sequence, so that the bench needs
// no delays and builds without --timing. The image goes in after rst
// falls (the part blanks itself while rst is high); the game does not touch
// the EEPROM for hundreds of frames.
byte unsigned ee [0:127];
int          setup_n = 0;
always @(posedge clk) if (setup_n < 160) begin
    setup_n <= setup_n + 1;
    if (setup_n == 79) rst <= 0;
    ee_we   <= setup_n >= 84 && setup_n < 148;
    ee_a    <= 6'(setup_n - 84);
    ee_d    <= { ee[2*(setup_n-84)+1], ee[2*(setup_n-84)] };    // MAME stores 16-bit words little-endian
end

initial begin
    integer fd, got, rg, vl, mf;
    run_args();
    if (!$value$plusargs("TNTILES=%d", tntiles)) $fatal(1, "+TNTILES= missing");
    if (!$value$plusargs("ONTILES=%d", ontiles)) $fatal(1, "+ONTILES= missing");
    fd = $fopen({"debug/", set_name, "-rom/maincpu.bin"}, "rb");
    got = $fread(rom, fd); $fclose(fd);
    if (got != ROM_BYTES) $fatal(1, "maincpu.bin: %0d bytes", got);
    // +ROM_JUNK_FROM=<hex CPU address>: what the board holds where the .mra
    // wrote nothing -- MAME's region reads 0 there, the SDRAM whatever was
    // in it. A BIOS that sums the whole window sees the difference.
    if ($value$plusargs("ROM_JUNK_FROM=%h", junk_from))
        for (int i = junk_from; i < ROM_BYTES; i++) rom[i] = 8'(i * 7 + 8'h5a);
    $readmemh({TD, "rom.hex"}, trom_v);
    $readmemh({OD, "rom.hex"}, orom_v);
    fd = $fopen({SD, "snd.hex"}, "r");
    while (!$feof(fd) && rp_n < MAXR)
        if ($fscanf(fd, "%h %h %d\n", rg, vl, mf) == 3) begin
            rp_reg[rp_n] = rg; rp_val[rp_n] = vl; rp_fr[rp_n] = mf; rp_n++;
        end
    $fclose(fd);
    for (int i = 0; i < 16; i++) begin rp_next[i] = 0; rp_last[i] = 8'h00; end
    offs_x = '{ -8'sd2, 8'sd0, 8'sd2, 8'sd3 };
    offs_y = '{ 8'sd0, 8'sd0, 8'sd0, 8'sd0 };
    fd = $fopen({"debug/", set_name, "-nvram/", set_name, "/eeprom"}, "rb");
    got = $fread(ee, fd); $fclose(fd);
    $display("ROM %0d bytes, %0d sound replies, EEPROM %0d bytes", ROM_BYTES, rp_n, got);

    ft = $fopen({od, set_name, "_rtl_sys.trace"}, "w");
    $fdisplay(ft, "# RTL main board: all writes, reads of 0xd00000-0xdfffff");
end

endmodule
