// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers II's light guns, as konamigx.cpp reads them
// (le2_gun_H_r / le2_gun_V_r at 0xd44000 / 0xd44004, gameDefs special 1):
//
//   X = v * 290 / 255 + 20,  Y = v * 224 / 255, and Y >= 0xdf reads as 0
//   ("make off the bottom reload too")
//
// with v the 0-255 position MAME's LIGHTGUN port gives across the screen.
// The division is exact as (n * 32897) >> 23 for every n = v * 290 or
// v * 224 (checked for all 256 v).
//
// Each player's v is a held position, moved as Arcade-Seta_MiSTer moves
// Zombie Raid's guns:
//   the left stick   absolutely, past a dead zone of 8: -127..127 across
//                    the screen, which is what Sinden and GUN4IR guns present
//   the d-pad        two units a frame while held
//   the mouse        relatively, for the player the OSD gives it; its left
//                    button is the trigger and its right a reload
// The stick's mode, per player: Auto (a stick pushed to 96 or more on an
// axis moves that axis as the d-pad does -- arcade sticks on gamepad
// encoders; below that, absolute), Aim (always absolute) or D-pad (any
// deflection moves as the d-pad).
//
// Reload (button 2, or the mouse's right button) is a shot off the screen:
// while it is held Y reads 0 and the trigger is down.
//
// The crosshair, an OSD option, marks v on the picture the same way MAME
// draws its crosshair: v / 256 of the visible width and height.

module gx_guns (
    input             clk,
    input             rst,         // the guns to the centre
    input      [31:0] joy0,        // joystick_0/1: right, left, down, up, B1, B2 from bit 0
    input      [31:0] joy1,
    input      [15:0] ana0,        // joystick_l_analog_0: { Y, X }, signed
    input      [15:0] ana1,
    input      [24:0] mouse,       // hps_io's ps2_mouse: bit 24 toggles a packet, Y positive up
    input       [1:0] mode0,       // the stick: 0 Auto, 1 Aim, 2 D-pad
    input       [1:0] mode1,
    input       [1:0] ms_who,      // the mouse: 0 P1, 1 P2, 2 off
    input             yrev,        // le2u/le2j: LIGHT*_Y PORT_REVERSE
    output reg [31:0] gun_h,       // 0xd44000: { P1 X, P2 X }
    output reg [31:0] gun_v,       // 0xd44004: { P1 Y, P2 Y }
    output reg  [1:0] trig,        // { P2, P1 } trigger, the reload's included

    // the crosshair
    input             show,
    input             pxl_cen,
    input             lhbl,
    input             lvbl,
    input       [8:0] vis_w,
    input      [23:0] rgb_in,
    output reg [23:0] rgb_out
);

// the inputs, registered here: hps_io drives them from clk_sys, 96 MHz from
// the same PLL as clk
reg  [31:0] j [0:1];
reg  [15:0] a [0:1];
reg  [24:0] ms;
reg         ms_t, lvbl_l;
always @(posedge clk) begin
    j[0] <= joy0; j[1] <= joy1; a[0] <= ana0; a[1] <= ana1;
    ms <= mouse; ms_t <= ms[24]; lvbl_l <= lvbl;
end
wire       ms_ev  = ms[24] ^ ms_t;
wire       frame  = lvbl_l && !lvbl;
wire [1:0] ms_sel = { ms_who == 2'd1, ms_who == 2'd0 };
wire [1:0] mode [0:1];
assign mode[0] = mode0; assign mode[1] = mode1;

localparam [7:0] DEAD = 8'd8;       // below this the axis is at rest
localparam [7:0] FULL = 8'd96;      // at or above it, Auto moves as the d-pad

function [7:0] mag( input [7:0] v );                // of a signed byte
    mag = v[7] ? 8'd0 - v : v;
endfunction
// v + d, held to 0..255
function [7:0] step( input [7:0] v, input signed [9:0] d );
    reg signed [10:0] t;
    begin
        t = $signed({ 3'b000, v }) + { d[9], d };
        step = t < 11'sd0 ? 8'd0 : t > 11'sd255 ? 8'd255 : t[7:0];
    end
endfunction

reg  [7:0] vx [0:1];
reg  [7:0] vy [0:1];
reg  [7:0] ax, ay;
reg        sx, sy, lx, ly;
reg  [3:0] dir;                     // up, down, left, right
integer g;
always @(posedge clk) begin
    for( g=0; g<2; g=g+1 ) begin
        ax = a[g][7:0]; ay = a[g][15:8];
        lx = mag(ax) >= DEAD; ly = mag(ay) >= DEAD;
        sx = mode[g] == 2'd2 ? lx : mode[g] == 2'd1 ? 1'b0 : mag(ax) >= FULL;
        sy = mode[g] == 2'd2 ? ly : mode[g] == 2'd1 ? 1'b0 : mag(ay) >= FULL;
        dir = { j[g][3] | (ay[7] & sy), j[g][2] | (!ay[7] & sy),
                j[g][1] | (ax[7] & sx), j[g][0] | (!ax[7] & sx) };
        if( rst ) begin
            vx[g] <= 8'h80; vy[g] <= 8'h80;
        end else if( ms_ev && ms_sel[g] ) begin
            vx[g] <= step( vx[g], $signed({ {2{ms[4]}}, ms[15:8] }) );
            vy[g] <= step( vy[g], -$signed({ {2{ms[5]}}, ms[23:16] }) );
        end else begin
            if( dir[1:0] != 2'b00 ) begin
                if( frame ) vx[g] <= step( vx[g], dir[0] ? 10'sd2 : -10'sd2 );
            end else if( lx ) vx[g] <= ax ^ 8'h80;
            if( dir[3:2] != 2'b00 ) begin
                if( frame ) vy[g] <= step( vy[g], dir[2] ? 10'sd2 : -10'sd2 );
            end else if( ly ) vy[g] <= ay ^ 8'h80;
        end
    end
end

// the reload: button 2, or the mouse's right button for its player
wire [1:0] rld = { j[1][5] | (ms_sel[1] & ms[1]), j[0][5] | (ms_sel[0] & ms[1]) };
always @(posedge clk)
    trig <= { j[1][4] | (ms_sel[1] & ms[0]), j[0][4] | (ms_sel[0] & ms[0]) } | rld;

// v * 290 (or 224), then * 32897 >> 23, a multiply a clock
wire [7:0] vx0 = vx[0], vx1 = vx[1], vy0 = vy[0], vy1 = vy[1];
reg  [16:0] px0, px1, py0, py1;
reg  [33:0] qx0, qx1, qy0, qy1;
reg  [ 1:0] rld1, rld2;
always @(posedge clk) begin
    px0 <= 17'(vx0) * 17'd290; px1 <= 17'(vx1) * 17'd290;
    py0 <= 17'(yrev ? 8'(~vy0) : vy0) * 17'd224; py1 <= 17'(yrev ? 8'(~vy1) : vy1) * 17'd224;
    qx0 <= 34'(px0) * 34'd32897; qx1 <= 34'(px1) * 34'd32897;
    qy0 <= 34'(py0) * 34'd32897; qy1 <= 34'(py1) * 34'd32897;
    rld1 <= rld; rld2 <= rld1;
end

function [15:0] gy( input [33:0] q, input off );
    reg [15:0] y;
    begin y = 16'(q >> 23); gy = off || y >= 16'hdf ? 16'd0 : y; end
endfunction

always @(posedge clk) begin
    gun_h <= { 16'(qx0 >> 23) + 16'd20, 16'(qx1 >> 23) + 16'd20 };
    gun_v <= { gy(qy0, rld2[0]), gy(qy1, rld2[1]) };
end

// ---------------------------------------------------------- crosshair
reg  [8:0] hc, vc;
reg        lhbl_l;
always @(posedge clk) if( pxl_cen ) begin
    lhbl_l <= lhbl;
    if( !lvbl ) vc <= 0;
    else if( lhbl_l && !lhbl ) vc <= vc + 9'd1;
    hc <= lhbl ? hc + 9'd1 : 9'd0;
end

// v / 256 of the window
reg  [8:0] cx0, cy0, cx1, cy1;
always @(posedge clk) begin
    cx0 <= 9'((17'(vx0) * 17'(vis_w)) >> 8); cy0 <= 9'((17'(vy0) * 17'd224) >> 8);
    cx1 <= 9'((17'(vx1) * 17'(vis_w)) >> 8); cy1 <= 9'((17'(vy1) * 17'd224) >> 8);
end

function on_cross( input [8:0] x, input [8:0] y, input [8:0] cx, input [8:0] cy );
    reg [8:0] dx, dy;
    begin
        dx = x >= cx ? x - cx : cx - x;
        dy = y >= cy ? y - cy : cy - y;
        on_cross = (dx == 0 && dy <= 6 && dy >= 2) || (dy == 0 && dx <= 6 && dx >= 2);
    end
endfunction

wire c0 = on_cross( hc, vc, cx0, cy0 );
wire c1 = on_cross( hc, vc, cx1, cy1 );

always @* begin
    rgb_out = rgb_in;
    if( show && lhbl && lvbl ) begin
        if( c0 ) rgb_out = 24'hff2020;
        else if( c1 ) rgb_out = 24'h20ff20;
    end
end

endmodule
