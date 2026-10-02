derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# Clocks: one PLL, counters 0..3 = clk_sys 96 MHz, SDRAM_CLK (96 MHz at 180
# degrees), clk_vid 48 MHz, clk_cpu 24 MHz, all at phase 0 except the SDRAM
# pin's. derive_pll_clocks makes them related clocks, so every path between
# the board (clk_vid), the 68EC020 (clk_cpu) and the memory (clk_sys) is
# timed at the two clocks' closest edges: rtl/gx_main.sv's cpu_cen and
# rtl/memory/gx_rom_port.sv are written for related clocks, not for
# asynchronous ones. The exception, below: gx_rom_port's answer, hold only.
# ---------------------------------------------------------------------------

# gx_rom_port's answer (done_t, data_m, data_f) changes only on a clk_sys
# edge midway between two clk_vid edges, so clk_vid has half its period of
# hold on it; the same-edge hold check STA makes cannot happen (it failed on
# four builds where the fitter put done_t and done_s side by side).
# Setup stays timed.
set_false_path -hold -from [get_registers {*|gx_rom_port:*|done_t}]
set_false_path -hold -from [get_registers {*|gx_rom_port:*|data_m[*]}]
set_false_path -hold -from [get_registers {*|gx_rom_port:*|data_f[*]}]

# The game selector is static: the .mra mod byte, latched during the download
set_false_path -from [get_registers {*mod_byte*}]

# ---------------------------------------------------------------------------
# The block below is Arcade-Seta_MiSTer's, unchanged: same controller, same
# PLL counter for the pin, same module on the same board.
# ---------------------------------------------------------------------------
# SDRAM I/O TIMING -- so that STA can SEE the data-capture path at all.
#
# Until this block existed every SDRAM pin was "No input delay ... found" in
# the STA report: the sdram.sv capture registers are packed into the I/O
# cells (FAST_INPUT_REGISTER, sys.tcl), which fixes their location, but the
# pin-to-register setup/hold against the memory's clock was never checked.
# The capture edge at those IOEs moves with whatever global clock network the
# Fitter routes clk_sys over, and that choice changes from build to build.
# Measured consequence: a functionally inert RTL change produced a build on
# which bit 8 of the FIRST beat of every SDRAM read burst read 1 where the
# ROM held 0, in roughly half of samples (scripts/sdram_check.py), while STA
# reported every clock positive. The good and bad builds differed in nothing
# STA was looking at.
#
# CLOCKS. clk_sys is the main PLL's counter 0 (96 MHz). SDRAM_CLK is counter
# 1, the same 96 MHz shifted 180 degrees, wired straight to the pin. The
# memory launches and samples on SDRAM_CLK; the FPGA does both on clk_sys.
#
# NUMBERS ARE ASSUMED, NOT MEASURED, and are variables for that reason. They
# are MT48LC16M16A2 -7E values at CL=2 (tAC 6.0, tOH 2.7, tDS 1.5, tDH 0.8 ns)
# plus a nominal board/pin allowance, because three attempts to fetch the
# datasheet failed. The DE10-nano SDRAM module's actual part and speed grade
# are not recorded anywhere in this repository. Calibrate from the datasheet
# before treating a negative slack here as a hard failure -- until then this
# block is an INSTRUMENT: run quartus_sta on two fits and compare the slack
# on SDRAM_DQ[*], which is what it was written for.
# ---------------------------------------------------------------------------
set sdram_tAC   6.0    ;# memory CLK -> data valid, max
set sdram_tOH   2.7    ;# memory CLK -> data hold, min
set sdram_tDS   1.5    ;# memory input setup
set sdram_tDH   0.8    ;# memory input hold
set sdram_board 0.5    ;# trace + pin, max, each direction
set sdram_board_min 0.1

set sdram_pll_clk [get_clocks {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name sdram_clk_pin -source [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]

# Reads: the memory drives DQ from its clock edge.
set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + $sdram_board}]     [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + $sdram_board_min}] [get_ports {SDRAM_DQ[*]}]

# THE FIRST BEAT IS CAPTURED TWO clk_sys EDGES AFTER THE MEMORY'S LAUNCH EDGE,
# not one. sdram.sv registers the READ command on a clk_sys edge; the memory
# sees it half a period later (SDRAM_CLK is the same 96 MHz at 180 degrees),
# drives the first word CL=2 memory clocks after that, and dq_in captures it
# on the clk_sys edge after the one STA would assume. Measured on the fit this
# was calibrated against: data arrival 28.0 ns against a single-cycle
# requirement of 18.8 (-9.2 ns), against the second edge +0.65 ns. That
# sub-nanosecond margin on beat 0 is the whole reason a capture register
# placed in the fabric, with 5-10 ns of routing in front of it, failed on
# hardware while an I/O-cell register passes. Hold is checked against the
# first edge, as it must be.
set sdram_dq_regs [get_registers {*sdram:u_sdram|dq_in[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs

# Writes and commands: the memory samples on its clock edge.
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}]      $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH + $sdram_board_min}] $sdram_outs

# ---------------------------------------------------------------------------
# DDRAM_CLK is a clock mux in logic (KonamiGX.sv): clk_sys while the ROM
# loader has DDR3, CLK_VIDEO (clk_vid) otherwise, and the rotator is held off
# DDR3 while the loader runs. Without this STA times the loader against the
# sysmem bridge clocked by clk_vid and the rotator against it clocked by
# clk_sys, neither of which can happen; builds failed hold there (-0.387 and
# -0.293 ns on seed 3 of 39185b1). One generated clock per mux input, the two
# physically exclusive, each exclusive of the framework's other clock groups
# (sys_top.sdc's list) and of the other input's domain. The pin is the mux's
# LUT output as Quartus 17 names it.
# ---------------------------------------------------------------------------
set gx_sys_clk {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set gx_vid_clk {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
create_generated_clock -name ddram_ldr -source [get_pins $gx_sys_clk] [get_pins {emu|DDRAM_CLK|combout}]
create_generated_clock -name ddram_rot -add -source [get_pins $gx_vid_clk] [get_pins {emu|DDRAM_CLK|combout}]
set_clock_groups -physically_exclusive -group [get_clocks ddram_ldr] -group [get_clocks ddram_rot]
set_clock_groups -exclusive    -group [get_clocks {ddram_ldr ddram_rot}]    -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]    -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}]    -group [get_clocks { spi_sck}]    -group [get_clocks { hdmi_sck}]    -group [get_clocks { *|h2f_user0_clk}]    -group [get_clocks { FPGA_CLK1_50 }]    -group [get_clocks { FPGA_CLK2_50 }]    -group [get_clocks { FPGA_CLK3_50 }]
set_false_path -from [get_clocks $gx_vid_clk] -to [get_clocks ddram_ldr]
set_false_path -from [get_clocks ddram_ldr]   -to [get_clocks $gx_vid_clk]
set_false_path -from [get_clocks $gx_sys_clk] -to [get_clocks ddram_rot]
set_false_path -from [get_clocks ddram_rot]   -to [get_clocks $gx_sys_clk]
