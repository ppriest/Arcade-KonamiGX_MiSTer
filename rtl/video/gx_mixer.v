/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Konami GX mixer: the K055555 priority encoder and the K054338 blender, per
 * pixel.
 *
 * WRITTEN FROM THE SOFTWARE MODEL. scripts/render_model.py stage_mix_hw() is
 * the specification, and it reproduces MAME's konamigx_mixer pixel for pixel
 * on every captured frame (docs/ROADMAP.md, Progress). Structure, as the
 * hardware has it rather than as MAME paints:
 *
 *   1. Every source is a candidate with a sort KEY; the smallest key is in
 *      front. The key reproduces konamigx_mixer's draw order exactly:
 *        layer   { pri, 0, 8'd0, layer }           A..D at equal pri: A front
 *        sprite  { pri, 1, z-code, index, 0 }      solid pixel of the line buffer
 *        shadow  { shadow pri, 1, z-code, index, 1 }
 *      so at equal priority a layer is in front of a sprite, and a sprite's
 *      solid pixel in front of a shadow of the same sprite.
 *   2. The top candidate and the one behind it are picked; the background is
 *      always the last.
 *   3. Palette RAM is read for the top, the second and the background.
 *   4. An alpha layer on top is blended over the second at its K054338
 *      level, or added to it (MAME 5c75784's additive draw); the shadow, if
 *      any, shades what is behind its key -- the second before the blend, or
 *      the result after it -- or, for a code SHD PRI SEL puts under
 *      condition 1 or 2, the result where its priority passes against the
 *      topmost source's (see shd_gate). Shadows go through MAME's 15-bit
 *      table arithmetic.
 *
 * LIMITS, flagged on `unsupported` rather than drawn wrong: layer brightness
 * (K55_VBRI), MIXPRI, an alpha layer directly over another alpha layer,
 * external tile mix codes (V INMIX ON != 3 on a layer). One shadow per pixel
 * is what the sprite line buffer supplies (gx_obj_linebuf.v).
 *
 * TIMING: one pixel per pxl_cen, at least 6 clocks apart (GX: 6 at 48 MHz).
 * Inputs are registered on pxl_cen and ranked on the next clock -- ranking
 * straight from the tilemap's line-buffer RAM was the worst path in the
 * standalone fit (rtl/synth_check/gx_video). rgb is the pixel sampled on the
 * previous pxl_cen.
 */

module gx_mixer (
    input             rst,
    input             clk,
    input             pxl_cen,

    // K055555, register n (0..45), and K054338, word n (0..15)
    input             k55_we,
    input      [ 5:0] k55_addr,
    input      [ 7:0] k55_din,
    input      [ 1:0] k338_we,         // byte lanes { 15:8, 7:0 }: the game writes bytes alone
    input      [ 3:0] k338_addr,
    input      [15:0] k338_din,
    input             bg_grad,          // wrport1_0 bit 5: 1 = K055555 gradient
    input             pri_c_le2,        // primode -1 (le2): layer C at PRIINP_3 + 0x20

    // palette RAM, xRGB_888 by pen, one write enable per colour byte; the
    // CPU reads its colour bytes back from here (pal_q, a clock after
    // pal_addr), so the board keeps only the x byte
    input      [ 2:0] pal_we,           // { R, G, B }
    input      [12:0] pal_addr,
    input      [23:0] pal_din,
    output     [23:0] pal_q,
    // the Type 3/4 monitors' palettes (GX_T34, docs/TYPE34.md): a pen a
    // word, xBBBBBGGGGGRRRRR, at { pal3_sub, pal_addr }; the pixels read the
    // one pix_sub picks, in place of the 888 palette, which is left to the CPU
    // as plain RAM (0xd90000)
    // Type 4 (t4): xRGB 888 a pen, R in a third RAM, G and B where Type 3's
    // word is
    input      [ 2:0] pal3_we,          // byte lanes { R (Type 4), 15:8, 7:0 }
    input             pal3_sub,         // the CPU's access: 0 main monitor, 1 sub
    input      [15:0] pal3_din,         // R from bits 7:0
    output     [23:0] pal3_q,           // { R, 15:8, 7:0 }
    input             t4,
    input             pix_sub,          // this frame is the sub monitor's

    // this pixel, in MAME bitmap coordinates
    input      [ 9:0] bx,
    input      [ 9:0] by,               // < 512: the gradient index is 9 bits
    input      [13:0] lyr_a,            // { colour[5:0], pixel[7:0] } from gx_tilemap
    input      [13:0] lyr_b,
    input      [13:0] lyr_c,
    input      [13:0] lyr_d,
    // the K055555's SUB2: the Type 3/4 K053936 (gx_psac), { colour[1:0],
    // pixel[7:0] }; pen 0x1000 + that (gfx_type3), pixel 0 not drawn, no
    // blending (gx_draw_basic_extended_tilemaps_2). 0 where there is none.
    input      [ 9:0] sub2,
    input             spr_valid,        // solid plane of gx_obj
    input      [12:0] spr_pen,
    input      [ 7:0] spr_pri,
    input      [ 7:0] spr_z,
    input      [ 7:0] spr_idx,
    input      [ 1:0] spr_mix,          // gx_obj pxl_mix: the sprite's effect bits, attr[9:8]
    input             spr_mix_on,       // they are its mix code; off: none, as MAME (the benches' +SPR_MIX=0)
    input             shd_valid,        // shadow plane of gx_obj
    input      [ 1:0] shd_code,
    input      [ 7:0] shd_pri,
    input      [ 7:0] shd_z,
    input      [ 7:0] shd_idx,

    output reg [23:0] rgb,
    output reg        unsupported
);

// ------------------------------------------------------------ registers
reg [ 7:0] k55  [0:63];
reg [15:0] k338 [0:15];

always @(posedge clk) begin
    if( k55_we  ) k55[k55_addr]   <= k55_din;
    if( k338_we[1] ) k338[k338_addr][15:8] <= k338_din[15:8];
    if( k338_we[0] ) k338[k338_addr][ 7:0] <= k338_din[ 7:0];
end

wire [7:0] disp   = k55[45];
// a VRAM layer whose VBRI mode picks a BRI3 level below 0xff (not handled)
function lvl_dim( input [1:0] m, input [15:0] r11, input [15:0] r12 );
    lvl_dim = m == 2'd1 ? r11[7:0] != 8'hff : m == 2'd2 ? r12[15:8] != 8'hff :
              m == 2'd3 ? r12[7:0] != 8'hff : 1'b0;
endfunction
wire vbri_dim = lvl_dim(k55[42][1:0], k338[11], k338[12]) || lvl_dim(k55[42][3:2], k338[11], k338[12])
             || lvl_dim(k55[42][5:4], k338[11], k338[12]) || lvl_dim(k55[42][7:6], k338[11], k338[12]);
wire [7:0] vinmix = k55[33];
wire [7:0] vmixon = k55[34];
wire       kill   = k338[15][0];
wire       mixpri = k338[15][1];
wire       noclip = k338[15][5];

// K054338 set_alpha_level with invert_alpha(1): a blend level is 0x1f less
// the register's five bits, expanded to eight, and bit 5 says the layer is
// added rather than blended, which leaves black transparent (Sexy Parodius's
// ink). An added layer's level is the register's own, not inverted: Fantastic
// Journey fades its fire out by stepping it from 8 to 0, which the PCB shows
// as a fade-out; inverted, the fire brightened and then vanished. MAME
// 5c75784 inverts it (docs/MAME_KLUDGES.md).
//
// Returns { add, on, level }: `on` is 0 where nothing is blended (mix code 0,
// or a plain level of 255).
function [9:0] alpha_of( input [1:0] mix, input [15:0] r13, input [15:0] r14 );
    reg [15:0] r;
    reg [ 7:0] mixset;
    reg [ 4:0] lv;
    reg [ 7:0] a;
    reg        add;
    begin
        r      = mix[1] ? r14 : r13;
        mixset = mix[0] ? r[7:0] : r[15:8];
        add    = mixset[5];
        lv     = add ? mixset[4:0] : 5'h1f - mixset[4:0];
        a      = { lv, lv[4:2] };
        alpha_of = { add, mix != 2'd0 && (add || a != 8'd255), a };
    end
endfunction

// ------------------------------------------------------------ stage 0: latch
reg  [ 9:0] bx_r, by_r;
reg  [13:0] lyr [0:3];
reg  [ 9:0] sub2_r;
reg         spr_valid_r, shd_valid_r;
reg  [12:0] spr_pen_r;
reg  [ 7:0] spr_pri_r, spr_z_r, spr_idx_r, shd_pri_r, shd_z_r, shd_idx_r;
reg  [ 1:0] spr_mix_r;
reg  [ 1:0] shd_code_r;

always @(posedge clk) if( pxl_cen ) begin
    bx_r <= bx; by_r <= by;
    lyr[0] <= lyr_a; lyr[1] <= lyr_b; lyr[2] <= lyr_c; lyr[3] <= lyr_d; sub2_r <= sub2;
    spr_valid_r <= spr_valid; spr_pen_r <= spr_pen; spr_pri_r <= spr_pri;
    spr_z_r <= spr_z; spr_idx_r <= spr_idx; spr_mix_r <= spr_mix;
    shd_valid_r <= shd_valid; shd_code_r <= shd_code; shd_pri_r <= shd_pri;
    shd_z_r <= shd_z; shd_idx_r <= shd_idx;
end

// ------------------------------------------------------------ stage 1: rank

localparam KW = 26;   // { pri 8, class 1, z 8, index 8, sub 1 }
localparam [2:0] SRC_A=0, SRC_B=1, SRC_C=2, SRC_D=3, SRC_S=4, SRC_P=5, SRC_BG=7;

reg  [KW-1:0] key [0:5];
reg  [   5:0] cand;
reg  [  12:0] pen [0:5];
reg  [   8:0] lpal [0:3];
reg  [   9:0] alpha [0:3];      // { add, on, level }
reg  [   9:0] alpha4;           // the sprite's
// Type 4's SUB1 (the K053936): its blend level, from the mix code in
// OSBLEND_ENABLES as the K054338 levels the tiles' (not additive)
wire [ 1:0] s1_code  = k55[35][3:2];
wire        s1_blend = t4 && k55[35] != 8'hff && s1_code != 2'd0;
wire [ 7:0] s1_set   = s1_code[0] ? (s1_code[1] ? k338[14][7:0] : k338[13][7:0])
                                  : (s1_code[1] ? k338[14][15:8] : k338[13][15:8]);
wire [ 4:0] s1_l5    = 5'h1f - s1_set[4:0];
wire [ 7:0] s1_lv    = { s1_l5, s1_l5[4:2] };
reg  [KW-1:0] shkey;
reg  [   2:0] t, s;          // top and second source
reg  [KW-1:0] tk, sk;
integer       i;

// the layers' priorities, registered: from registers the CPU writes, and
// the le2 adder in front of the sort was the critical path (build 54)
reg  [   7:0] lpri [0:3];
reg  [   7:0] lpri5;
always @(posedge clk) begin
    lpri5   <= t4 ? k55[16] : k55[17];          // SUB1's PRIINP_9 on Type 4, SUB2's PRIINP_10
    lpri[0] <= k55[7];
    lpri[1] <= k55[10];
    lpri[2] <= pri_c_le2 ? k55[10] + 8'h20 : k55[13];
    lpri[3] <= k55[14];
end

always @* begin
    for( i=0; i<4; i=i+1 ) begin
        key[i]   = { lpri[i], 1'b0, 8'd0, 6'd0, i[1:0], 1'b0 };
        cand[i]  = disp[i] && lyr[i][7:0] != 8'd0;
        // decode_vmixcolor: pal = colour[3:0] | (colour[5:4] & von) << 4 | PALBASE << 6,
        // pen = pal * 16 + pixel (K056832 colour granularity 16)
        lpal[i]  = { k55[23+i][2:0], 6'd0 } | { 3'd0, lyr[i][13:12] & vmixon[2*i +: 2], lyr[i][11:8] };
        pen[i]   = { lpal[i], 4'd0 } + { 5'd0, lyr[i][7:0] };
        // K055555GX_decode_vmixcolor (p.62 7.2.6): the mix code is the
        // tile's colour bits 5:4 that VMIXON does NOT pass to the palette,
        // or VINMIX's where it does -- per tile, from the same bits the
        // palette index drops. MAME computes it and throws it away (the
        // callbacks ignore the return value), drawing every mix-coded tile of
        // a layer with the last one's code instead.
        alpha[i] = alpha_of( (lyr[i][13:12] & ~vmixon[2*i +: 2])
                             | (vinmix[2*i +: 2] & vmixon[2*i +: 2]),
                             k338[13], k338[14] );
    end
    key[4]  = { spr_pri_r, 1'b1, spr_z_r, spr_idx_r, 1'b0 };
    // A sprite's mix code: MAME computes one and never uses it (K055555_MIXSHIFT 16 is past the colour's width), so its
    // sprites are never blended. On: the effect bits, which
    // K053247GX_combine_c18 moves to the mix bits when wrport2 bit 3 is clear.
    // Fantastic Journey's dancer stage covers its gradient with a sprite of
    // effect 1. (The top colour bits instead hid the player's ship.)
    alpha4  = alpha_of( spr_mix_on ? spr_mix_r : 2'd0, k338[13], k338[14] );
    cand[4] = disp[4] && spr_valid_r;
    pen[4]  = spr_pen_r;
    // the K053936: SUB2 (PRIINP_10) on Type 3, ordered as a layer after D
    // (MAME's layer code 5); SUB1 (PRIINP_9, code 4) on Type 4, drawn
    // whatever INPUT_ENABLES says (MAME's rushingheroes_hack), from pen
    // 0x1800 (gfx_type4). Type 4 blends it as gx_draw_basic_extended_
    // tilemaps_1 does: OSBLEND_ENABLES (k55[35]) bits 3:2 are its mix code,
    // unless the register is 0xff; level 0 is not drawn; never additive.
    key[5]  = { lpri5, 1'b0, 8'd0, 8'd4, 1'b0 };
    cand[5] = (t4 || disp[6]) && sub2_r[7:0] != 8'd0 && !(s1_blend && s1_lv == 8'd0);
    pen[5]  = (t4 ? 13'h1800 : 13'h1000) | { 3'd0, sub2_r };
    shkey   = { shd_pri_r, 1'b1, shd_z_r, shd_idx_r, 1'b1 };

    // top and second by smallest key; the background is behind everything
    t = SRC_BG; tk = {KW{1'b1}};
    s = SRC_BG; sk = {KW{1'b1}};
    for( i=0; i<6; i=i+1 ) begin
        if( cand[i] ) begin
            if( key[i] < tk ) begin
                s = t; sk = tk; t = i[2:0]; tk = key[i];
            end else if( key[i] < sk ) begin
                s = i[2:0]; sk = key[i];
            end
        end
    end
end

// the background pen (fill_backcolor: pens + (PALBASE_BG << 9)), gradient
// indexed by bitmap row, or column with K55_CTL_GRADDIR
wire [12:0] bgbase = { k55[0][3:0], 9'd0 };
wire [12:0] bgpen  = !k55[1][1] ? bgbase :
                     !k55[1][0] ? bgbase + { 3'd0, by_r } :
                                  bgbase + { 3'd0, bx_r };
wire [23:0] bgsolid = { k338[0][7:0], k338[1] };

// ------------------------------------------------------------ stages 1-5
reg  [ 2:0] ph;                 // clocks since pxl_cen
reg  [12:0] ra;
wire [23:0] rq, rq888;
reg  [ 2:0] t1, s1;
reg  [12:0] pen_s1, bgpen1;
reg  [ 7:0] a1;
reg         alpha_top, add1, shd_under, shd_over;

// SHD PRI SEL (K055555 p.66 7.2.8), as MAME 5c75784 draws it: a shadow
// code under condition 1 or 2 is applied last, to what is on screen, where
// its priority is above (1) or equal to (2) the priority code the topmost
// screen recorded -- a layer's own, or 0xff where SHD ON keeps shadows off
// it; the solid sprite's; 0xff for the back colour, which is never shaded.
// A layer at alpha level 0 is not drawn, so the one behind it is topmost.
// primode -1 (le2) replaces SHD PRI SEL with 0x3f. Conditions 0 and 3 stay
// in the priority order, as before.
wire [7:0] shd_sel   = pri_c_le2 ? 8'h3f : k55[41];
wire [1:0] shd_cond  = shd_sel[{ shd_code_r, 1'b0 } +: 2];
wire       shd_defer = shd_cond == 2'd1 || shd_cond == 2'd2;
wire       t_unseen  = t < 3'd4 && alpha[t][8] && !alpha[t][9] && alpha[t][7:0] == 8'd0;
wire [2:0] top_src   = t_unseen ? s : t;
reg  [7:0] top_pri;
always @* begin
    case( top_src )
        3'd0, 3'd1, 3'd2, 3'd3: top_pri = k55[40][top_src[1:0]] ? lpri[top_src[1:0]] : 8'hff;
        3'd4:                   top_pri = spr_pri_r;
        3'd5:                   top_pri = lpri5;
        default:                top_pri = 8'hff;
    endcase
end
wire       shd_gate  = top_pri != 8'hff && (shd_cond == 2'd2 ? shd_pri_r == top_pri : shd_pri_r > top_pri);
reg  [ 1:0] code1;
reg  [23:0] ct, cs;
reg         en;

gx_tdpram #(.AW(13), .DW(8)) u_pal_r (
    .clk ( clk ), .we_a ( pal_we[2] ), .a ( pal_addr ), .d ( pal_din[23:16] ), .qa ( pal_q[23:16] ),
    .b ( ra ), .qb ( rq888[23:16] ) );
gx_tdpram #(.AW(13), .DW(8)) u_pal_g (
    .clk ( clk ), .we_a ( pal_we[1] ), .a ( pal_addr ), .d ( pal_din[15:8] ), .qa ( pal_q[15:8] ),
    .b ( ra ), .qb ( rq888[15:8] ) );
gx_tdpram #(.AW(13), .DW(8)) u_pal_b (
    .clk ( clk ), .we_a ( pal_we[0] ), .a ( pal_addr ), .d ( pal_din[7:0] ), .qa ( pal_q[7:0] ),
    .b ( ra ), .qb ( rq888[7:0] ) );
`ifdef GX_T34
wire [15:0] rq3;
wire [ 7:0] rq3r;
gx_tdpram #(.AW(14), .DW(8)) u_pal3_h (
    .clk ( clk ), .we_a ( pal3_we[1] ), .a ( { pal3_sub, pal_addr } ), .d ( pal3_din[15:8] ), .qa ( pal3_q[15:8] ),
    .b ( { pix_sub, ra } ), .qb ( rq3[15:8] ) );
gx_tdpram #(.AW(14), .DW(8)) u_pal3_l (
    .clk ( clk ), .we_a ( pal3_we[0] ), .a ( { pal3_sub, pal_addr } ), .d ( pal3_din[7:0] ), .qa ( pal3_q[7:0] ),
    .b ( { pix_sub, ra } ), .qb ( rq3[7:0] ) );
gx_tdpram #(.AW(14), .DW(8)) u_pal3_r (
    .clk ( clk ), .we_a ( pal3_we[2] ), .a ( { pal3_sub, pal_addr } ), .d ( pal3_din[7:0] ), .qa ( pal3_q[23:16] ),
    .b ( { pix_sub, ra } ), .qb ( rq3r ) );
assign rq = t4 ? { rq3r, rq3 } : { rq3[4:0], rq3[4:2], rq3[9:5], rq3[9:7], rq3[14:10], rq3[14:12] };
`else
assign rq = rq888;
assign pal3_q = 24'd0;
`endif

// MAME's shadow table: the colour is cut to 5 bits a channel, re-expanded
// with pal5bit, and offset by the K054338 delta, clipped unless CLIPSL.
function [7:0] shch( input [7:0] c, input [8:0] d, input nc );
    reg signed [10:0] v;
    begin
        v = $signed({ 3'd0, c[7:3], c[7:5] }) + $signed({ {2{d[8]}}, d });
        shch = nc ? v[7:0] : v < 0 ? 8'd0 : v > 255 ? 8'd255 : v[7:0];
    end
endfunction

function [23:0] shade( input [23:0] c, input [1:0] code );
    reg [8:0] dr, dg, db;
    begin
        dr = k338[2 + 3*code][8:0];
        dg = k338[3 + 3*code][8:0];
        db = k338[4 + 3*code][8:0];
        // set_shadow_dRGB32 clamps the deltas to +/-255
        if( dr == 9'h100 ) dr = 9'h101;
        if( dg == 9'h100 ) dg = 9'h101;
        if( db == 9'h100 ) db = 9'h101;
        // Type 4: update_all_shadows(rushingheroes_hack) sets every shadow
        // to -80 a channel, clipped, whatever the registers say
        if( t4 ) begin dr = 9'h1b0; dg = 9'h1b0; db = 9'h1b0; end
        shade = { shch(c[23:16], dr, noclip && !t4), shch(c[15:8], dg, noclip && !t4), shch(c[7:0], db, noclip && !t4) };
    end
endfunction

// One multiplier for both modes: each is d + (x * a) >> 8, blending with
// x = s - d (the same value as s*a + d*(256-a) >> 8) and adding with x = s,
// where the extra + s makes a level of 255 a full add. Two multipliers a
// channel missed timing by 0.2 ns (build 31).
function [7:0] blendch( input [7:0] d, input [7:0] s, input [7:0] a, input add );
    reg signed [9:0]  x;
    reg signed [18:0] p;
    reg signed [10:0] v;
    begin
        x = add ? $signed({ 2'b00, s }) : $signed({ 2'b00, s }) - $signed({ 2'b00, d });
        p = x * $signed({ 2'b00, a }) + (add ? $signed({ 2'b00, s }) : 19'sd0);
        v = $signed({ 3'b000, d }) + p[18:8];
        blendch = v[10] ? 8'h00 : v[9] || v[8] ? 8'hff : v[7:0];
    end
endfunction

// The background's colour is read last: it is in rq from the clock after
// the next pxl_cen (any pixel of 4 clocks or more: 12 MHz dots are 4), and
// the pixel is finished there, at ph 0, while the next one is ranked.
// The pixel is finished a clock later, at ph 1: at ph 0 the background's
// colour and everything the finish needs are registered (the ranking stage
// replaces t1, s1, a1 ... with the next pixel's on that clock), so the
// palette read does not run through the blend and the shade into rgb in one
// clock (KonamiGXT34 missed setup there). rgb still changes inside the
// pixel's period, before the next pxl_cen samples it.
reg  [23:0] bgq, ctq, csq;
reg  [ 2:0] t1q, s1q;
reg  [ 7:0] a1q;
reg  [ 1:0] code1q;
reg         enq, add1q, atq, soq, suq;
wire [23:0] bgc     = bgq;
wire [23:0] ct_f    = t1q == SRC_BG || !enq ? bgc : ctq;
wire [23:0] cs_f    = s1q == SRC_BG ? bgc : csq;
wire        at_f    = enq && atq;
wire        so_f    = enq && soq;
wire [23:0] cs_eff  = enq && suq ? shade(cs_f, code1q) : cs_f;
wire [23:0] blended = { blendch(cs_eff[23:16], ct_f[23:16], a1q, add1q),
                        blendch(cs_eff[15: 8], ct_f[15: 8], a1q, add1q),
                        blendch(cs_eff[ 7: 0], ct_f[ 7: 0], a1q, add1q) };
wire [23:0] mixed   = at_f ? blended : ct_f;
wire [23:0] final_c = so_f ? shade(mixed, code1q) : mixed;

function [12:0] pen_of( input [2:0] src );
    pen_of = src==SRC_BG ? bgpen : pen[src];
endfunction

always @(posedge clk) begin
    if( rst ) begin
        ph <= 3'd7;
        unsupported <= 0;
        en <= 0;
    end else begin
        if( ph != 3'd7 ) ph <= ph + 3'd1;
        if( pxl_cen ) ph <= 3'd0;
        if( ph == 3'd0 ) begin                        // the previous pixel: its inputs
            bgq <= bg_grad ? rq : bgsolid;
            ctq <= ct; csq <= cs; t1q <= t1; s1q <= s1; a1q <= a1; code1q <= code1;
            enq <= en; add1q <= add1; atq <= alpha_top; soq <= shd_over; suq <= shd_under;
        end
        if( ph == 3'd1 ) rgb <= final_c;              // and its colour
        // the pixel latched on pxl_cen: rank it, then read the palette for
        // the top, the second and the background, one read a clock
        case( ph )
            3'd0: begin
                en   <= disp != 8'd0 && (kill || t4);   // Type 4: MAME's rushingheroes_hack skips K338_CTL_KILL
                t1   <= t;
                s1   <= s;
                a1   <= t < 3'd4 ? alpha[t][7:0] : t == 3'd4 ? alpha4[7:0] : t == 3'd5 && s1_blend ? s1_lv : 8'd255;
                add1 <= t < 3'd4 ? alpha[t][9] : t == 3'd4 && alpha4[9];
                alpha_top <= t < 3'd4 ? alpha[t][8] : t == 3'd4 ? alpha4[8] : t == 3'd5 && s1_blend && s1_lv != 8'd255;
                code1     <= shd_code_r;
                if( shd_defer ) begin
                    // MAME 5c75784 gx_draw_deferred_shadows: over everything,
                    // where the condition holds against the topmost screen
                    shd_over  <= shd_valid_r && disp[4] && shd_gate;
                    shd_under <= 0;
                end else begin
                    shd_over  <= shd_valid_r && disp[4] && shkey < tk;
                    shd_under <= shd_valid_r && disp[4] && t < 3'd4 && alpha[t][8]
                                 && shkey > tk && shkey < sk;
                end
                ra     <= pen_of(t);
                pen_s1 <= pen_of(s);
                bgpen1 <= bgpen;
                // VBRI is flagged only where it picks a level below full (0xff):
                // le2 and tkmmpzdm set it with all three BRI3 levels at 0xff
                if( vbri_dim || mixpri || (t < 3'd4 && alpha[t][8] && s < 3'd4 && alpha[s][8]) )
                    unsupported <= 1;
                // (a layer with VMIXON not 3 takes the per-tile mix path above)
            end
            3'd1: ra <= pen_s1;
            3'd2: begin ra <= bgpen1; ct <= rq; end  // top
            3'd3: cs <= rq;                          // second; the background at ph 0
            default: ;
        endcase
    end
end

endmodule
