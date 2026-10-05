// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-set constants, from the .mra's mod byte (ioctl index 1), latched during
// the download and static while the game runs.
//
// The SDRAM image (rtl/memory/gx_sdram_top.sv): maincpu packed at 0, then the
// k056832 region with its 5-byte rows spread to 8 at tile_base, the k055673
// region likewise at obj_base, sound after (Phase 3). The bases and the
// four-byte part sizes (region bytes / 5 * 4) are what scripts/build_mra.py
// derives from each set's ROM_START -- `python scripts/build_mra.py --cfg`
// prints this table, and every build of an .mra checks its set's arm against
// the ROM_START, so the two cannot drift apart silently.
//
// The video constants are MAME's (konamigx.cpp machine configs and
// konamigx_v.cpp): the tilemap layer offsets (common_init: the same
// -2, 0, 2, 3 for every set; tilemode 1, tbyahhoo/mtwinbee, only changes how
// MAME marks tilemaps dirty) and the mixer priority mode
// (konamigx_mixer_primode).

// The decode, combinational; gx_board_cfg below registers it.
module gx_board_cfg_c (
    input       [7:0] game,
    output reg [25:0] tile_base,
    output reg [25:0] obj_base,
    output reg [23:0] tile_size4,   // k056832 four-byte part
    output reg [23:0] obj_size4,    // k055673 four-byte part
    output reg [23:0] snd_pcm,      // the K054539 sample area (the region, to 1 MB)
    output reg signed [7:0] offs_x [4],
    output reg signed [7:0] offs_y [4],
    output reg  [3:0] primode,
    output reg  [1:0] tile_bpp,     // K056832 set_config depth: 0 BPP_5, 1 BPP_6, 2 BPP_8
    output reg  [1:0] obj_layout,   // K055673 set_config layout: 0 GX, 1 RNG, 2 GX6, 3 LE2
    output reg  [1:0] obj_pri_raw,  // the priority from the raw attribute: 1 dragoonj_, 2 salmndr2_sprite_callback
    output reg  [9:0] vis_x0,       // K053252 set_offsets x: the window's first bitmap column
    output reg  [8:0] vis_w,        // the visible width (MAME's from the CRTC: 288, or 384)
    output reg  [9:0] obj_hadj,     // K055673 set_config dx less daiskiss's -26, signed
    output reg        esc_gen,      // the ESC's run command calls generate_sprites
    output reg [23:0] esc_src,
    output reg  [8:0] esc_count,
    output reg        esc_copy,     // konamigx_esc_alert mode 0: copy esc_count sprites from esc_src
    output reg        prot4,        // gameDefs special 7: type4_prot_w at 0xcc0000 in place of the ESC
    output reg        esc_sal2,     // konamigx_esc_alert mode 1 (sal2_esc)
    output reg        tile_rb66,    // gameDefs readback BPP66: k_6bpp_rom_long_r at 0xd00000
    output reg        guns,         // gameDefs special 1: the LE2 light guns at 0xd44000
    output reg        orient_fy,    // ORIENTATION_FLIP_Y (le2u, le2j): the sprite plane mirrored, gun Y reversed
    output reg        fj_dma,       // gameDefs special 9: fantjour_dma_install (fantjour, fantjoura)
    // the 056734 (docs/ESC.md): the set has the chip, and its constants
    output reg        esc_chip,
    output reg [15:0] esc_s10,
    output reg  [3:0] esc_s11n,
    output reg [31:0] esc_xor,
    output reg [63:0] esc_lanes     // [4k+3:4k]: the stored lane that is canonical lane k
);

always @* begin
    offs_y = '{ 8'sd0, 8'sd0, 8'sd0, 8'sd0 };
    offs_x = '{ -8'sd2, 8'sd0, 8'sd2, 8'sd3 };
    primode = 4'd0;
    tile_bpp = 2'd0;
    obj_layout = 2'd0;
    obj_pri_raw = 2'd0;
    vis_x0 = 10'd24;
    vis_w = 9'd288;
    // konamigx.cpp gameDefs' special and the *_esc callbacks: daiskiss_esc and
    // tbyahhoo_esc walk 0x100 entries from 0xc00000, sexyparo_esc 0xfc from
    // 0xc00604; gokuparo, fantjour(a), crzcross and puzldama have none
    // (m_esc_cb null: the command only sets ESTATE_END and raises IRQ 4)
    esc_gen = 1'b0; esc_src = 24'hc00000; esc_count = 9'h100; esc_copy = 1'b0;
    prot4 = 1'b0; esc_sal2 = 1'b0; tile_rb66 = 1'b0; guns = 1'b0; orient_fy = 1'b0; fj_dma = 1'b0;
    // the K055673's x offset: konamigx() -26 (daiskiss, tbyahhoo, mtwinbee),
    // gokuparo() -46 (gokuparo, fantjour, fantjoura, crzcross, puzldama),
    // sexyparo() -42. The 056734's sprite programs put x 20 further right than
    // MAME's C (docs/ESC.md), so the sets whose program builds the list take
    // 20 less: daiskiss, tbyahhoo and mtwinbee land on gokuparo()'s -46.
    case( game )
        8'd0, 8'd6, 8'd7,
        8'd1, 8'd2, 8'd3, 8'd4, 8'd5, 8'd10, 8'd11, 8'd12, 8'd20, 8'd21: obj_hadj = -10'sd20;   // + tokkae, tkmmpzdm (konamigx_6bpp: -46), le2 (-46)
        8'd8, 8'd9:                   obj_hadj = -10'sd36;
        8'd13, 8'd14,                                         // dragoonj(): -53
        8'd15, 8'd16, 8'd17:          obj_hadj = -10'sd27;   // winspike(): -53
        8'd18, 8'd19:                 obj_hadj = -10'sd22;   // salmndr2(): -48
        default:                      obj_hadj = 10'd0;
    endcase
    case( game )
        8'd0, 8'd6, 8'd7: esc_gen = 1'b1;                                          // daiskiss, mtwinbee, tbyahhoo
        8'd8, 8'd9:       begin esc_gen = 1'b1; esc_src = 24'hc00604; esc_count = 9'h0fc; end   // sexyparo(a)
        // dragoonj_esc: konamigx_esc_alert(m_workram, 0x5c00, 0x100, 0)
        8'd13, 8'd14:     begin esc_gen = 1'b1; esc_copy = 1'b1; esc_src = 24'hc17000; end
        // tkmmpzdm_esc: konamigx_esc_alert(m_workram, 0x0142, 0x100, 0), dwords
        8'd11:            begin esc_gen = 1'b1; esc_copy = 1'b1; esc_src = 24'hc00508; end
        8'd15, 8'd16, 8'd17: prot4 = 1'b1;                                          // winspike(a/j)
        8'd3, 8'd4:       fj_dma = 1'b1;                                              // fantjour(a)
        // sal2_esc: konamigx_esc_alert(m_workram, 0x1c8c, 0x172, 1)
        8'd18, 8'd19:     begin esc_gen = 1'b1; esc_sal2 = 1'b1; esc_src = 24'hc07230; esc_count = 9'h172; end
        default: ;
    endcase
    // the 056734: every set whose ROM carries its kernel (0x200A6C); clones use
    // their parent's chip (the kernel and program checksums pass with its key)
    esc_chip = 1'b0; esc_s10 = 16'd0; esc_s11n = 4'd0; esc_xor = 32'd0; esc_lanes = 64'd0;
    case( game )
        8'd0:                   begin esc_chip = 1'b1; esc_s10 = 16'h89EE; esc_s11n = 4'hD; esc_xor = 32'h39556CC0; esc_lanes = 64'hB854D2E7F3A601C9; end   // daiskiss
        8'd1, 8'd2:             begin esc_chip = 1'b1; esc_s10 = 16'h5D32; esc_s11n = 4'h3; esc_xor = 32'h91C2C6FB; esc_lanes = 64'hF10ED73A65249C8B; end   // crzcross, puzldama
        8'd3, 8'd4, 8'd5:       begin esc_chip = 1'b1; esc_s10 = 16'h8D8C; esc_s11n = 4'h3; esc_xor = 32'h2C3EA1C4; esc_lanes = 64'h24AC58167039EDBF; end   // fantjour, fantjoura, gokuparo
        8'd6, 8'd7:             begin esc_chip = 1'b1; esc_s10 = 16'h0424; esc_s11n = 4'hA; esc_xor = 32'hDE78B8AE; esc_lanes = 64'h97E60A851BD32C4F; end   // mtwinbee, tbyahhoo
        8'd8, 8'd9:             begin esc_chip = 1'b1; esc_s10 = 16'h896A; esc_s11n = 4'hE; esc_xor = 32'h1886AE1D; esc_lanes = 64'hFEDCBA9876543210; end   // sexyparo, sexyparoa
        8'd10:                  begin esc_chip = 1'b1; esc_s10 = 16'h9E8E; esc_s11n = 4'hB; esc_xor = 32'h6BFBB5B9; esc_lanes = 64'h17FE43B8A50D962C; end   // tokkae
        8'd11:                  begin esc_chip = 1'b1; esc_s10 = 16'h4924; esc_s11n = 4'hC; esc_xor = 32'h88600EF4; esc_lanes = 64'h4CA873FB602D15E9; end   // tkmmpzdm
        8'd13, 8'd14:           begin esc_chip = 1'b1; esc_s10 = 16'h5963; esc_s11n = 4'hB; esc_xor = 32'h049DB8E5; esc_lanes = 64'hA2CB1F05D68E3974; end   // dragoona, dragoonj
        8'd18, 8'd19:           begin esc_chip = 1'b1; esc_s10 = 16'h1EC6; esc_s11n = 4'hA; esc_xor = 32'hB3F135B3; esc_lanes = 64'hBD53C0196FEA4287; end   // salmndr2, salmndr2a
        default: ;
    endcase
    case( game )
        // ---- generated by scripts/build_mra.py --cfg: begin
        8'd0:  begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h200000; end  // daiskiss
        8'd1:  begin tile_base = 26'h0200000; obj_base = 26'h1200000; tile_size4 = 24'h800000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // crzcross
        8'd2:  begin tile_base = 26'h0200000; obj_base = 26'h1200000; tile_size4 = 24'h800000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // puzldama
        8'd3:  begin tile_base = 26'h0200000; obj_base = 26'h0c00000; tile_size4 = 24'h4ccccc; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // fantjour
        8'd4:  begin tile_base = 26'h0200000; obj_base = 26'h0c00000; tile_size4 = 24'h4ccccc; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // fantjoura
        8'd5:  begin tile_base = 26'h0200000; obj_base = 26'h0c00000; tile_size4 = 24'h4ccccc; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // gokuparo
        8'd6:  begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // mtwinbee
        8'd7:  begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // tbyahhoo
        8'd8:  begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // sexyparo
        8'd9:  begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // sexyparoa
        8'd10: begin tile_base = 26'h0200000; obj_base = 26'h0900000; tile_size4 = 24'h355554; obj_size4 = 24'h800000; snd_pcm = 24'h400000; end  // tokkae
        8'd11: begin tile_base = 26'h0200000; obj_base = 26'h0900000; tile_size4 = 24'h355554; obj_size4 = 24'h800000; snd_pcm = 24'h400000; end  // tkmmpzdm
        8'd12: begin tile_base = 26'h0100000; obj_base = 26'h0900000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // le2
        8'd13: begin tile_base = 26'h0500000; obj_base = 26'h0c00000; tile_size4 = 24'h333330; obj_size4 = 24'h800000; snd_pcm = 24'h200000; end  // dragoona
        8'd14: begin tile_base = 26'h0500000; obj_base = 26'h0c00000; tile_size4 = 24'h333330; obj_size4 = 24'h800000; snd_pcm = 24'h200000; end  // dragoonj
        8'd15: begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h800000; snd_pcm = 24'h400000; end  // winspike
        8'd16: begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h800000; snd_pcm = 24'h400000; end  // winspikea
        8'd17: begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h800000; snd_pcm = 24'h400000; end  // winspikej
        8'd18: begin tile_base = 26'h0200000; obj_base = 26'h0d00000; tile_size4 = 24'h555554; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // salmndr2
        8'd19: begin tile_base = 26'h0200000; obj_base = 26'h0d00000; tile_size4 = 24'h555554; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // salmndr2a
        8'd20: begin tile_base = 26'h0100000; obj_base = 26'h0900000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // le2u
        8'd21: begin tile_base = 26'h0100000; obj_base = 26'h0900000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end  // le2j
        // ---- generated: end
        default: begin tile_base = 26'h0200000; obj_base = 26'h0a00000; tile_size4 = 24'h400000; obj_size4 = 24'h400000; snd_pcm = 24'h400000; end
    endcase
    case( game )
        8'd0:        primode = 4'd4;                                   // daiskiss
        8'd1, 8'd2:  primode = 4'd5;                                   // crzcross, puzldama
        8'd10, 8'd11: begin primode = 4'd5; tile_bpp = 2'd1; end         // tokkae, tkmmpzdm: konamigx_6bpp
        // le2: K056832 BPP_8, K055673 LAYOUT_LE2, konamigx_mixer_primode(-1)
        8'd12:        begin primode = 4'hf; tile_bpp = 2'd2; obj_layout = 2'd3; guns = 1'b1; end
        8'd20, 8'd21: begin primode = 4'hf; tile_bpp = 2'd2; obj_layout = 2'd3; guns = 1'b1; orient_fy = 1'b1; end  // le2u, le2j
        // dragoona/j: K055673 LAYOUT_RNG and dragoonj_sprite_callback, the
        // K053252 at offset 24 + 16 and 384 wide (8 MHz dots), every layer
        // one right (VIDEO_START dragoonj)
        8'd13, 8'd14: begin obj_layout = 2'd1; obj_pri_raw = 2'd1; vis_x0 = 10'd40; vis_w = 9'd384;
                            offs_x = '{ -8'sd1, 8'sd1, 8'sd3, 8'sd4 }; end
        // winspike(a/j): BPP_8, LAYOUT_LE2, the K053252 at 24 + 15, 384 wide
        8'd15, 8'd16, 8'd17: begin tile_bpp = 2'd2; obj_layout = 2'd3; vis_x0 = 10'd39; vis_w = 9'd384; end
        // salmndr2(a): BPP_6, LAYOUT_GX6, salmndr2_sprite_callback, readback BPP66
        8'd18, 8'd19: begin tile_bpp = 2'd1; obj_layout = 2'd2; obj_pri_raw = 2'd2; tile_rb66 = 1'b1; end
        default: ;
    endcase
end

endmodule

// The constants, registered: the decode of `game` fed the mixer's shadow
// logic and the download transform in the same clock and failed timing at
// 48 MHz (build 53). `game` is set before the ROM download starts and does
// not change while the set runs.
module gx_board_cfg (
    input             clk,
    input       [7:0] game,
    output reg [25:0] tile_base,
    output reg [25:0] obj_base,
    output reg [23:0] tile_size4,
    output reg [23:0] obj_size4,
    output reg [23:0] snd_pcm,
    output reg signed [7:0] offs_x [4],
    output reg signed [7:0] offs_y [4],
    output reg  [3:0] primode,
    output reg  [1:0] tile_bpp,
    output reg  [1:0] obj_layout,
    output reg  [1:0] obj_pri_raw,
    output reg  [9:0] vis_x0,
    output reg  [8:0] vis_w,
    output reg  [9:0] obj_hadj,
    output reg        esc_gen,
    output reg [23:0] esc_src,
    output reg  [8:0] esc_count,
    output reg        esc_copy,
    output reg        prot4,
    output reg        esc_sal2,
    output reg        tile_rb66,
    output reg        guns,
    output reg        orient_fy,
    output reg        fj_dma,
    output reg        esc_chip,
    output reg [15:0] esc_s10,
    output reg  [3:0] esc_s11n,
    output reg [31:0] esc_xor,
    output reg [63:0] esc_lanes
);

wire [25:0] c_tile_base, c_obj_base;
wire [23:0] c_tile_size4, c_obj_size4, c_snd_pcm, c_esc_src;
wire signed [7:0] c_offs_x [4], c_offs_y [4];
wire  [3:0] c_primode;
wire  [1:0] c_tile_bpp, c_obj_layout;
wire  [1:0] c_obj_pri_raw;
wire        c_esc_gen, c_esc_copy, c_prot4, c_esc_sal2, c_tile_rb66, c_guns, c_orient_fy, c_fj_dma;
wire  [9:0] c_vis_x0, c_obj_hadj;
wire  [8:0] c_vis_w, c_esc_count;
wire        c_esc_chip;
wire [15:0] c_esc_s10;
wire  [3:0] c_esc_s11n;
wire [31:0] c_esc_xor;
wire [63:0] c_esc_lanes;

gx_board_cfg_c u_c ( .game,
    .tile_base(c_tile_base), .obj_base(c_obj_base), .tile_size4(c_tile_size4), .obj_size4(c_obj_size4),
    .snd_pcm(c_snd_pcm), .offs_x(c_offs_x), .offs_y(c_offs_y), .primode(c_primode), .tile_bpp(c_tile_bpp),
    .obj_layout(c_obj_layout), .obj_pri_raw(c_obj_pri_raw), .vis_x0(c_vis_x0), .vis_w(c_vis_w),
    .obj_hadj(c_obj_hadj), .esc_gen(c_esc_gen), .esc_src(c_esc_src), .esc_count(c_esc_count),
    .esc_copy(c_esc_copy), .prot4(c_prot4), .esc_sal2(c_esc_sal2), .tile_rb66(c_tile_rb66), .guns(c_guns), .orient_fy(c_orient_fy), .fj_dma(c_fj_dma),
    .esc_chip(c_esc_chip), .esc_s10(c_esc_s10), .esc_s11n(c_esc_s11n), .esc_xor(c_esc_xor), .esc_lanes(c_esc_lanes) );

always @(posedge clk) begin
    tile_base <= c_tile_base; obj_base <= c_obj_base; tile_size4 <= c_tile_size4; obj_size4 <= c_obj_size4;
    snd_pcm <= c_snd_pcm; offs_x <= c_offs_x; offs_y <= c_offs_y; primode <= c_primode; tile_bpp <= c_tile_bpp;
    obj_layout <= c_obj_layout; obj_pri_raw <= c_obj_pri_raw; vis_x0 <= c_vis_x0; vis_w <= c_vis_w;
    obj_hadj <= c_obj_hadj; esc_gen <= c_esc_gen; esc_src <= c_esc_src; esc_count <= c_esc_count;
    esc_copy <= c_esc_copy; prot4 <= c_prot4; esc_sal2 <= c_esc_sal2; tile_rb66 <= c_tile_rb66; guns <= c_guns; orient_fy <= c_orient_fy; fj_dma <= c_fj_dma;
    esc_chip <= c_esc_chip; esc_s10 <= c_esc_s10; esc_s11n <= c_esc_s11n; esc_xor <= c_esc_xor; esc_lanes <= c_esc_lanes;
end

endmodule
