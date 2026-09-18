// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone Fmax and area for TG68KdotC_Kernel on the DE10-nano's Cyclone V
// (5CSEBA6U23I7, speed grade 7). Phase 0 exit criterion 4, docs/ROADMAP.md.
//
// Not part of the core. It answers one question in isolation: how fast can
// the kernel be CLOCKED, which under clkena_in is the constraint on clk_sys,
// not on the CPU rate (rtl/cpu/tg68k/PROVENANCE.md).
//
// Every kernel input is driven from a register and every output lands in one,
// so each timing path starts and ends on a flop and Quartus reports the
// kernel's own register-to-register Fmax rather than pin delays. Outputs are
// XOR-reduced into a few pins so nothing is optimised away, and pins are
// VIRTUAL (see the .qsf) so the pad ring does not enter the measurement.
//
// The generics are the ones the boot bench and Psikyo run: this measures the
// configuration the core will actually use.
module tg68k_fmax_top (
    input  logic        clk,
    input  logic        reset,
    input  logic [15:0] din,
    input  logic [2:0]  ipl,
    input  logic        clkena,
    output logic [7:0]  sig
);
    logic        r_reset, r_clkena;
    logic [15:0] r_din;
    logic [2:0]  r_ipl;

    logic [31:0] addr;
    logic [15:0] dout;
    logic [1:0]  busstate;
    logic        nWr, nUDS, nLDS, longword;
    logic [2:0]  fc;

    always_ff @(posedge clk) begin
        r_reset  <= reset;
        r_clkena <= clkena;
        r_din    <= din;
        r_ipl    <= ipl;
    end

    TG68KdotC_Kernel #(
        .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
        .MUL_Mode(2), .DIV_Mode(2), .BitField(2),
        .BarrelShifter(0), .MUL_Hardware(1)
    ) u_cpu (
        .clk(clk), .nReset(~r_reset), .clkena_in(r_clkena),
        .data_in(r_din), .IPL(r_ipl), .IPL_autovector(1'b1),
        .berr(1'b0), .CPU(2'b11),
        .addr_out(addr), .data_write(dout),
        .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
        .busstate(busstate), .longword(longword),
        .nResetOut(), .FC(fc), .clr_berr(), .skipFetch(),
        .regin_out(), .CACR_out(), .VBR_out()
    );

    always_ff @(posedge clk)
        sig <= {^addr[31:24], ^addr[23:16], ^addr[15:8], ^addr[7:0],
                ^dout, ^busstate, nWr ^ nUDS ^ nLDS ^ longword, ^fc};
endmodule
