// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// A module's internal registers, as the save-state engine sees them.
//
// `d` is the live registers packed into one vector. On `snap` they are
// copied into a shadow, which the engine reads 16 bits at a time; for a
// load the engine writes the shadow and pulses `commit`, and the owner
// copies `q` back into its registers (each always block that owns some of
// them does its own part, on the same pulse). Capturing at one instant and
// reading at leisure is what makes the snapshot consistent: the board keeps
// running while the engine walks it.
//
// The state bus: `sel` is this module's, `addr` the 16-bit chunk, `rd`
// valid the clock after (zero when not selected, so the bus is an OR).

module gx_ss_vec #(
    parameter W = 16                        // bits of state
) (
    input               clk,
    input               snap,
    input      [W-1:0]  d,
    output reg [W-1:0]  q,

    input               sel,
    input      [ 9:0]   addr,
    input               we,
    input      [15:0]   wd,
    output reg [15:0]   rd
);

localparam N = (W + 15) / 16;

wire [16*N-1:0] qx = {{(16*N-W){1'b0}}, q};
reg  [16*N-1:0] nx;
integer i;

always @* begin
    nx = qx;
    for (i = 0; i < N; i = i + 1)
        if (addr == i) nx[16*i +: 16] = wd;
end

always @(posedge clk) begin
    if (snap) q <= d;
    else if (sel && we) q <= nx[W-1:0];
    rd <= 16'd0;
    for (i = 0; i < N; i = i + 1)
        if (sel && addr == i) rd <= qx[16*i +: 16];
end

endmodule
