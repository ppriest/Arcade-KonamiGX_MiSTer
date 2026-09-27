// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone synthesis of the three video blocks together -- gx_tilemap,
// gx_obj (jt053246 with the GX changes) and gx_mixer -- on the DE10-nano's
// Cyclone V. Not part of the core. It answers: do their memories become
// block RAM without duplication, what do they cost together, and do they
// close at 48 MHz.
//
// Every input comes from a register loaded by a serial shift chain, the
// blocks are wired to each other as they will be in the core (tilemap and
// sprite pixels into the mixer), and outputs are XOR-reduced into a
// register. Pins are VIRTUAL (see the .qsf).
module gx_video_synth_top (
    input  logic       clk,
    input  logic       rst,
    input  logic       sdi,
    input  logic       ld,
    output logic [7:0] sig
);
    localparam int N = 512;
    logic [N-1:0] sh, r;
    always_ff @(posedge clk) begin
        sh <= { sh[N-2:0], sdi };
        if (ld) r <= sh;
    end

    // ---- tilemap
    logic signed [7:0] offs_x [4], offs_y [4];
    always_comb for (int l = 0; l < 4; l++) begin
        offs_x[l] = r[l*8 +: 8];
        offs_y[l] = r[32 + l*8 +: 8];
    end
    logic [15:0] vram_dout;
    logic        tm_busy, tm_uns, tm_rom_cs;
    logic [23:0] tm_rom_addr;
    logic [10:0] tm_pix [4];

    gx_tilemap u_tm (
        .clk, .rst,
        .reg_we(r[64]), .reg_addr(r[69:65]), .reg_din(r[85:70]), .reg_be(r[87:86]),
        .tbank_we(r[88]), .tbank_addr(r[91:89]), .tbank_din(r[99:92]),
        .vram_we(r[100]), .vram_rd(r[101]), .vram_addr(r[117:102]), .vram_din(r[133:118]),
        .vram_be(r[135:134]), .vram_dout,
        .offs_x, .offs_y,
        .line_start(r[136]), .line_y(r[146:137]), .busy(tm_busy), .unsupported(tm_uns), .dbg_ev(), .blank_skip(1'b1),
        .rom_addr(tm_rom_addr), .rom_cs(tm_rom_cs), .rom_ok(r[147]), .rom_data(r[187:148]),
        .rd_x(r[196:188]), .rd_pix(tm_pix)
    );

    // ---- sprites
    logic [15:0] ram_dout;
    logic [22:0] ob_rom_addr;
    logic        ob_rom_cs, s_valid, h_valid, h_full;
    logic [12:0] s_pen;
    logic [ 7:0] s_pri, s_z, s_idx, h_idx, h_pri, h_z;
    logic [ 1:0] h_code;

    gx_obj u_obj (
        .rst, .clk, .pxl_cen(r[200]), .pxl2_cen(r[201]),
        .hdump(r[210:202]), .vdump(r[219:211]), .voffset(r[229:220]), .hs(r[230]), .lvbl(r[231]),
        .ram_cs(r[232]), .ram_we(r[234:233]), .ram_addr({r[499], r[246:235]}), .ram_din(r[262:247]), .ram_dout,
        .reg_cs(r[263]), .mmr_we(r[264]), .mmr_addr(r[268:265]), .mmr_din(r[284:269]), .mmr_dsn(r[286:285]),
        .k47_we({2{r[287]}}), .k47_addr(r[290:288]), .k47_din(r[306:291]),
        .opri(r[314:307]), .oinprion(r[322:315]), .ocblk(r[330:323]), .wrport2(r[338:331]),
        .primode(r[342:339]), .shadowon(r[345:343]), .shdpri0(r[353:346]), .shdpri1(r[361:354]),
        .shdpri2(r[369:362]), .spri_min(r[377:370]),
        .rom_addr(ob_rom_addr), .rom_cs(ob_rom_cs), .rom_ok(r[378]), .rom_data(r[418:379]),
        .pxl_valid(s_valid), .pxl_pen(s_pen), .pxl_pri(s_pri), .pxl_z(s_z), .pxl_idx(s_idx),
        .shd_valid(h_valid), .shd_full(h_full), .shd_code(h_code), .shd_idx(h_idx),
        .shd_pri(h_pri), .shd_z(h_z), .dma_busy()
    );

    // ---- mixer
    logic [23:0] rgb;
    logic        mx_uns;
    logic [23:0] pal_q;

    gx_mixer u_mix (
        .rst, .clk, .pxl_cen(r[200]),
        .k55_we(r[420]), .k55_addr(r[426:421]), .k55_din(r[434:427]),
        .k338_we({2{r[435]}}), .k338_addr(r[439:436]), .k338_din(r[455:440]), .bg_grad(r[456]),
        .pal_we({r[457], r[497], r[498]}), .pal_addr(r[470:458]), .pal_din(r[494:471]), .pal_q,
        .bx({1'b0, r[210:202]}), .by({1'b0, r[219:211]}),
        .lyr_a(tm_pix[0]), .lyr_b(tm_pix[1]), .lyr_c(tm_pix[2]), .lyr_d(tm_pix[3]),
        .spr_valid(s_valid), .spr_pen(s_pen), .spr_pri(s_pri), .spr_z(s_z), .spr_idx(s_idx),
        .shd_valid(h_valid), .shd_code(h_code), .shd_pri(h_pri), .shd_z(h_z), .shd_idx(h_idx),
        .rgb, .unsupported(mx_uns)
    );

    always_ff @(posedge clk)
        sig <= { ^rgb ^ ^pal_q, ^vram_dout, ^ram_dout, ^tm_rom_addr, ^ob_rom_addr,
                 tm_rom_cs ^ ob_rom_cs, tm_busy, tm_uns ^ mx_uns ^ h_full };
endmodule
