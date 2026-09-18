// SPDX-License-Identifier: GPL-3.0-or-later
//
// TG68K.C booting a Konami GX program ROM, logging every bus access in the
// same format as scripts/mame/boottrace.lua, so the two can be diffed.
// Phase 0 exit criterion 2 (docs/ROADMAP.md).
//
//     python scripts/build_rom_image.py daiskiss maincpu
//     python scripts/mame_boot_trace.py daiskiss 3000000
//     python scripts/compare_boot_trace.py replay daiskiss
//     scripts/run_sim.sh gx_boot_tb +GAME=daiskiss +N=200000
//     python scripts/compare_boot_trace.py compare daiskiss
//
// WHAT IS MODELLED, AND WHY SO LITTLE
//
// MAME's boot trace for daiskiss shows that for its first three million
// accesses the BIOS reads nothing but ROM, writes nothing but video and I/O
// registers, makes exactly two I/O reads (0xD5A000 and 0xD5E000), and never
// touches work RAM or the stack. So this bench is the CPU, the 8 MB ROM image,
// a sink for writes, and a replay of MAME's own I/O read values -- nothing
// else. That keeps the diff about the CPU (WORKFLOW section 12): a mismatch
// here cannot be a peripheral model, because there are none.
//
// Any read that is neither ROM nor answered by the replay is REPORTED, not
// guessed at. When a longer trace reaches work RAM, add a RAM model then.
//
// THE BUS
//
// TG68KdotC_Kernel is instantiated directly, not through TG68K.vhd, with the
// generics Arcade-Psikyo_MiSTer runs it at (rtl/cpu/tg68k/PROVENANCE.md). Its
// bus is 16 bits wide. A 32-bit 68020 access becomes two word accesses, which
// is also how MAME's tap reports them -- two halves of one aligned dword, masks
// FFFF0000 then 0000FFFF.
//
// The CPU is stalled only by clkena_in, and `ready` is a LEVEL (LESSONS_LEARNED,
// "DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU").
// Every access takes the same two-cycle handshake the real wrapper will use:
// the access is seen, then ready rises and the CPU advances. Memory here is
// ideal, so this measures nothing about speed -- CPI is criterion 3, measured
// separately.
//
// INTERRUPTS are not driven. None is taken in the window this bench covers
// (the BIOS never touches the stack, so no exception frame was ever pushed).
// When a longer window needs them, replay them by position the way the MS32
// bench does (WORKFLOW section 12), not by time.

`timescale 1ns/1ps

module tb_gx_boot;

    // ---- parameters, from plusargs ----
    string  game;
    string  rom_path, replay_path, trace_path;
    integer n_max;

    // ---- clock and reset ----
    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    // ---- ROM: the region image exactly as MAME holds it (big-endian bytes) ----
    localparam int ROM_BYTES = 8 * 1024 * 1024;
    byte unsigned rom [0:ROM_BYTES-1];

    // ---- replay of MAME's non-ROM reads, in MAME's order ----
    localparam int MAX_REPLAY = 65536;
    logic [23:0] rp_addr [0:MAX_REPLAY-1];
    logic [31:0] rp_mask [0:MAX_REPLAY-1];
    logic [31:0] rp_data [0:MAX_REPLAY-1];
    integer      rp_n = 0, rp_i = 0;

    // ---- the CPU ----
    logic [31:0] a32;
    logic [15:0] cpu_din, cpu_dout;
    logic [1:0]  busstate;
    logic        nWr, nUDS, nLDS;
    logic [2:0]  fc;
    logic        cpu_clkena;
    logic [3:0]  cacr;

    TG68KdotC_Kernel #(
        .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
        .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
        .BarrelShifter(0), .MUL_Hardware(1)
    ) u_cpu (
        .clk(clk),
        .nReset(~reset),
        .clkena_in(cpu_clkena),
        .data_in(cpu_din),
        .IPL(3'b111),            // no interrupt: IPL is inverted inside the core
        .IPL_autovector(1'b1),
        .berr(1'b0),
        .CPU(2'b11),             // 68020
        .addr_out(a32),
        .data_write(cpu_dout),
        .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
        .busstate(busstate),
        .longword(),
        .nResetOut(),
        .FC(fc),
        .clr_berr(),
        .skipFetch(),
        .regin_out(), .CACR_out(cacr), .VBR_out()
    );

    // ---- bus handshake ----
    wire mem_needed = (busstate != 2'b01);
    wire is_write   = (busstate == 2'b11);
    logic ready;
    assign cpu_clkena = !mem_needed || ready;

    // 24-bit external address, dword-aligned for the log exactly as MAME's tap
    // reports it; which half of the dword this word access is comes from a32[1].
    wire [23:0] addr24 = a32[23:0];
    wire [23:0] dword  = {addr24[23:2], 2'b00};
    wire [31:0] mask   = addr24[1] ? {16'h0000, {8{~nUDS}}, {8{~nLDS}}}
                                   : {{8{~nUDS}}, {8{~nLDS}}, 16'h0000};
    wire is_rom = (addr24 < 24'h800000);

    function automatic [15:0] rom_word(input [23:0] a);
        rom_word = {rom[{a[23:1], 1'b0}], rom[{a[23:1], 1'b1}]};
    endfunction

    // ---- cycle accounting, for Phase 0 criterion 3 (CPI) ----
    // `steps` counts clocks on which the kernel advanced (clkena_in high):
    // the kernel's own work. `stalls` counts clocks it was held waiting for
    // memory. This bench's memory is ideal apart from the one-clock ready
    // handshake, so steps is the execution floor -- what TG68K.C needs with
    // zero-wait memory -- and a real memory system only adds to it.
    // Marks are the n-th WRITE to one address with one set of lanes, not an
    // access number: after the BIOS the two cores' access counts drift
    // (TG68K.C prefetches), but writes match one for one, so a write is a
    // common point in the program (scripts/mame/mark_time.lua says more).
    //   +MARKADDR=D56000 +MARKMASK=FF000000 +MARKA=31 +MARKB=49
    longint steps = 0, stalls = 0;
    integer mark_a = 0, mark_b = 0, mark_n = 0;
    logic [23:0] mark_addr = 24'hFFFFFF;
    logic [31:0] mark_mask = 32'h0;
    always_ff @(posedge clk)
        if (!reset) begin
            if (cpu_clkena) steps <= steps + 1;
            else            stalls <= stalls + 1;
        end

    // ---- the log ----
    integer fd_trace;
    integer seq = 0;
    integer unmapped = 0, replay_miss = 0;
    logic   finished = 1'b0;

    task automatic log_access(input string rw, input [23:0] a, input [31:0] m, input [31:0] d);
        seq = seq + 1;
        $fdisplay(fd_trace, "%0d\t%s\t%06X\t%08X\t%08X", seq, rw, a, m, d);
        if (rw == "w" && a == mark_addr && m == mark_mask) begin
            mark_n = mark_n + 1;
            if (mark_n == mark_a || mark_n == mark_b)
                $display("MARK write=%0d access=%0d steps=%0d stalls=%0d",
                         mark_n, seq, steps, stalls);
        end
        if (seq >= n_max && !finished) begin
            finished = 1'b1;
            $fdisplay(fd_trace, "# %0d accesses logged, %0d unmapped reads, %0d replay mismatches",
                      seq, unmapped, replay_miss);
            $fclose(fd_trace);
            $display("TRACE %0d accesses -> %s (unmapped %0d, replay mismatches %0d, CACR %h)",
                     seq, trace_path, unmapped, replay_miss, cacr);
            $finish;
        end
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            ready <= 1'b0;
        end else if (cpu_clkena && mem_needed) begin
            ready <= 1'b0;                       // CPU has taken this access
        end else if (mem_needed && !ready) begin
            // Complete the access. Data is presented through cpu_din below for
            // the cycle ready is high, which is the cycle the kernel samples it.
            if (is_write) begin
                log_access("w", dword, mask,
                           addr24[1] ? {16'h0000, cpu_dout} : {cpu_dout, 16'h0000});
            end else if (is_rom) begin
                log_access("r", dword, mask,
                           addr24[1] ? {16'h0000, rom_word(addr24)} : {rom_word(addr24), 16'h0000});
            end else begin
                if (rp_i < rp_n && rp_addr[rp_i] == dword && rp_mask[rp_i] == mask) begin
                    log_access("r", dword, mask, rp_data[rp_i] & mask);
                    rp_i = rp_i + 1;
                end else begin
                    replay_miss = replay_miss + 1;
                    unmapped = unmapped + 1;
                    $display("UNMAPPED/REPLAY-MISS read %06X mask %08X at access %0d (next replay: %06X %08X)",
                             dword, mask, seq + 1,
                             rp_i < rp_n ? rp_addr[rp_i] : 24'hFFFFFF,
                             rp_i < rp_n ? rp_mask[rp_i] : 32'h0);
                    log_access("r", dword, mask, 32'hFFFFFFFF & mask);
                end
            end
            ready <= 1'b1;
        end
    end

    // Read data for the current access, valid while ready is high.
    logic [31:0] rp_cur;
    always_comb begin
        rp_cur = (rp_i > 0) ? rp_data[rp_i - 1] : 32'hFFFFFFFF;
        if (is_rom)
            cpu_din = rom_word(addr24);
        else
            cpu_din = addr24[1] ? rp_cur[15:0] : rp_cur[31:16];
    end

    // ---- setup ----
    initial begin
        integer fd, got, a, m, d;
        if (!$value$plusargs("GAME=%s", game)) game = "daiskiss";
        if (!$value$plusargs("N=%d", n_max)) n_max = 20000;
        if (!$value$plusargs("MARKA=%d", mark_a)) mark_a = 0;
        if (!$value$plusargs("MARKB=%d", mark_b)) mark_b = 0;
        void'($value$plusargs("MARKADDR=%h", mark_addr));
        void'($value$plusargs("MARKMASK=%h", mark_mask));
        rom_path    = {"debug/", game, "-rom/maincpu.bin"};
        replay_path = {"debug/", game, "-boot/", game, "_replay.txt"};
        trace_path  = {"debug/", game, "-boot/", game, "_rtl.trace"};

        fd = $fopen(rom_path, "rb");
        if (fd == 0) begin
            $display("FATAL: cannot open %s -- run scripts/build_rom_image.py %s maincpu", rom_path, game);
            $finish;
        end
        got = $fread(rom, fd);
        $fclose(fd);
        $display("ROM  %0d bytes from %s", got, rom_path);
        if (got != ROM_BYTES) begin
            $display("FATAL: expected %0d bytes", ROM_BYTES);
            $finish;
        end

        fd = $fopen(replay_path, "r");
        if (fd != 0) begin
            while (!$feof(fd) && rp_n < MAX_REPLAY) begin
                if ($fscanf(fd, "%h %h %h\n", a, m, d) == 3) begin
                    rp_addr[rp_n] = a[23:0];
                    rp_mask[rp_n] = m;
                    rp_data[rp_n] = d;
                    rp_n = rp_n + 1;
                end
            end
            $fclose(fd);
        end
        $display("REPLAY %0d I/O reads from %s", rp_n, replay_path);

        fd_trace = $fopen(trace_path, "w");
        $fdisplay(fd_trace, "# TG68K.C bus accesses from reset, in order.");
        $fdisplay(fd_trace, "# seq\trw\taddr\tmask\tdata");

        repeat (8) @(posedge clk);
        reset = 1'b0;
    end

    // Backstop: a CPU that stops making bus accesses must still end the run.
    initial begin
        #(64'd400_000_000);
        $display("TIMEOUT after %0d accesses", seq);
        $fclose(fd_trace);
        $finish;
    end

endmodule
