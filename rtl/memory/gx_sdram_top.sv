// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every ROM the core reads at runtime, on the one SDRAM chip, through
// sdram.sv's three fixed-priority ports (port 0 preempts 1, 1 preempts 2):
//   port 0  tile and sprite graphics    (arbiter, 2 clients: the line-time
//                                         deadlines, docs/ROADMAP.md)
//   port 1  sound                        (Phase 3)
//   port 2  CPU ROM cache, ROM download
//
// The image, byte addresses; the bases are per set (rtl/gx_board_cfg.sv,
// which scripts/build_mra.py generates and checks, so every .mra loads to
// the offsets its set's arm says):
//   0            the CPU's ROM window packed: the BIOS (0x000000-0x01ffff),
//                then program and data (0x200000-0x7fffff) moved down by
//                0x1e0000
//   tile_base    tile graphics, 8 bytes a row (5 used)
//   obj_base     sprite graphics, 8 bytes a half-row (5 used)
//   snd_base     the sound board: its program (0x40000), the K054539
//                samples (0x400000), the K054539s' RAM (2 x 32 KB) and the
//                TMS57002's (256 KB), the last two written at runtime; in
//                the Type 3/4 build (GX_T34) the sound 68000's RAM (64 KB) after
//
// Both graphics regions are 5 bytes a row in MAME's image (4 bpp in two
// word ROMs, the fifth plane in a byte ROM), and the .mra carries each as
// MAME's k055673 region is laid out: the four-byte part, then the one-byte
// part (build_mra.py rearranges the k056832 region the same way). On the
// way in they are spread to 8 bytes a row so that a row is one granule:
// stream byte s of the four-byte part goes to (s/4)*8 + s%4, byte s of the
// one-byte part to s*8 + 4. That is 8/5 the space: daiskiss's 5 MB of each
// becomes 8 MB, and the three regions fill 24 MB of the 32 MB module. A set
// whose graphics do not fit needs the rows packed and fetched as two
// granules, which is a change here and in gx_rom_port only.
//
// The four-byte part's size is per set too.
//
// Clocks: clk_mem (96 MHz) for the controller, the arbiter and the download;
// the clients are in clk (48 MHz), crossed in gx_rom_port.

`default_nettype none

module gx_sdram_top (
    input  wire        clk,           // 48 MHz, the core
    input  wire        clk_mem,       // 96 MHz
    input  wire        reset,         // reset & ~ioctl_download
    input  wire        init,          // ~pll_locked

    output wire [12:0] SDRAM_A,
    inout  wire [15:0] SDRAM_DQ,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire  [1:0] SDRAM_BA,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_CKE,
    output wire        SDRAM_CLK,

    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    input  wire [26:0] tile_base,     // gx_board_cfg: where each region is
    input  wire [26:0] obj_base,
    input  wire [25:0] tile_size4,    // bytes in each region's four-byte part
    input  wire [25:0] obj_size4,
    input  wire  [1:0] tile_bpp,
    input  wire  [1:0] obj_layout,    // K055673: 0 GX, 1 RNG, 2 GX6, 3 LE2 (see the download)      // 0: 5 bpp, 1: 6 bpp (a two-byte second part), 2: 8 bpp (rows as they come)

    // clients, clk: the video benches' ROM model contract (gx_rom_port)
    input  wire        cpu_cs,        // gx_romcache: a granule of the packed image
    input  wire [19:0] cpu_addr,
    output wire        cpu_ok,
    output wire [63:0] cpu_data,

    input  wire        tile_cs,       // gx_tilemap: its rom_addr, a row index
    input  wire [20:0] tile_addr,
    output wire        tile_ok,
    output wire [63:0] tile_data,     // the row's bytes, byte 0 in [63:56]
    input  wire        tile2_cs,      // GX_T34: gx_tilemap's second client
    input  wire [20:0] tile2_addr,
    output wire        tile2_ok,
    output wire [63:0] tile2_data,

    input  wire        obj_cs,        // gx_obj: its rom_addr, a half-row index ([4:0] within a tile)
    input  wire [22:0] obj_addr,      // half-row: 8M of them in Rushing Heroes' 64 MB spread
    input  wire        obj_pf_cs,     // and the half-row it will ask for next
    input  wire [22:0] obj_pf_addr,

    // the CPU reading graphics ROM back through the chips' own windows
    // (0xd00000, 0xd4a000): an absolute granule of the image, on the chip
    // port nothing else uses
    input  wire        gfx_cs,
    input  wire [23:0] gfx_addr,
    output wire        gfx_ok,
    output wire [63:0] gfx_data,

    // the sound board (gx_sound): reads of its program, the samples and the
    // K054539s' RAM, and byte writes of that RAM, on the same chip port
    input  wire        snd_cs,
    input  wire [23:0] snd_addr,
    output wire        snd_ok,
    output wire [63:0] snd_data,
    input  wire        snd_inval,
    input  wire        snd_wreq,
    input  wire [26:0] snd_waddr,
    input  wire [15:0] snd_wdata,
    input  wire        snd_we16,
    output wire        snd_wbusy,
    input  wire [23:0] snd_pcm,       // the sample area's size: the sound RAMs follow it
    // the TMS57002's RAM, granules from snd_base + 0x50000 + snd_pcm; inval after
    // each of its writes
    input  wire        dsp_cs,
    input  wire [14:0] dsp_addr,
    output wire        dsp_ok,
    output wire [63:0] dsp_data,
    input  wire        dsp_inval,
    // the K054539s' voices and reverb: granules from the sample region
    // (snd_base + 0x40000) on, their RAM after it
    input  wire        pcm_cs,
    input  wire [20:0] pcm_addr,
    output wire        pcm_ok,
    output wire [63:0] pcm_data,
    input  wire        pcm_inval,
    // GX_T34: the sound 68000's RAM, 64 KB, granules from snd_base + 0x90000
    // + snd_pcm (after the DSP's); inval after each of its writes
    input  wire        sram_cs,
    input  wire [12:0] sram_addr,
    output wire        sram_ok,
    output wire [63:0] sram_data,
    input  wire        sram_inval,
    // GX_T34: the K053936's map (psmap_base, granules) and tiles (psac_base,
    // granules, four clients: gx_psac), on the graphics port; byte 0 in [63:56]
    input  wire [26:0] psac_base,
    input  wire [26:0] psmap_base,
    input  wire        psm_cs,
    input  wire [15:0] psm_addr,
    output wire        psm_ok,
    output wire [63:0] psm_data,
    input  wire [ 3:0] pst_cs,
    input  wire [71:0] pst_addr,      // client k at [18k +: 18]
    output wire [ 3:0] pst_ok,
    output wire [255:0] pst_data,     // client k at [64k +: 64]
    output wire        obj_ok,
    output wire [63:0] obj_data,      // the half-row's bytes, byte 0 in [63:56]

    // the SDRAM's use, per frame (the line-time probe's companion): latched
    // as lvbl falls, clk_mem cycles each, saturating at 2^24-1:
    // { CPU port busy, sound RAM writes, sound RAM reads, samples, DSP RAM,
    //   sound program, psac wait, sprite wait, tile wait, sound port busy,
    //   graphics port busy }: a client's count is the cycles its request is up
    input  wire        lvbl,
    output reg [263:0] dbg_bw
);

localparam logic [26:0] BASE_MAINCPU = 27'h000_0000;

// ------------------------------------------------------------ download
// The stream address to the SDRAM address: the graphics regions spread.
// A region's stream is 5/8 of its spread, so it ends before the next base.
//
// Two register stages: the ioctl byte is registered (stage 1), the address
// transform and the fits check work from that, and their result is
// registered again (stage 2). One stage failed timing at 96 MHz by 0.18 ns
// once the tile spread had a case per bit depth (build 50).
logic [26:0] io_addr_q;
logic        io_wr_q, io_dl_q;
logic [15:0] io_index_q;
logic  [7:0] io_dout_q;
always_ff @(posedge clk_mem) begin
    io_addr_q  <= ioctl_addr;
    io_wr_q    <= ioctl_wr;
    io_dl_q    <= ioctl_download;
    io_index_q <= ioctl_index;
    io_dout_q  <= ioctl_dout;
end
wire [26:0] s       = io_addr_q;
// The sound board's ROMs follow the sprite region's spread, stored as they
// come (the stream address is the SDRAM address): the sound CPU's program
// at snd_base, the K054539 samples after it. Without the upper bound the
// sprite transform claimed everything above obj_base and would have spread
// them too.
wire [26:0] snd_base = obj_base + { obj_size4, 1'b0 };
wire        in_tile = s >= tile_base && s < obj_base;
wire        in_obj  = s >= obj_base  && s < snd_base;
wire [26:0] base    = in_tile ? tile_base : obj_base;
wire [25:0] size4   = in_tile ? tile_size4 : obj_size4;
wire [26:0] off     = s - base;
wire [26:0] off1    = off - { 1'd0, size4 };                 // within the one-byte part
// The tile region's second part is one byte a row at 5 bpp (TILE_BYTE) and
// two at 6 bpp (TILE_BYTES2, bytes 4-5 of the row); at 8 bpp the .mra carries
// the rows whole, eight bytes each, so they are stored as they come.
//
// The sprite region by K055673 layout: GX a four-byte part and a one-byte
// part, as the tiles at 5 bpp; GX6 a four-byte part and a two-byte part
// (build_mra splits the three _48_WORD ROMs so), as the tiles at 6 bpp; RNG
// (4 bytes a half-row, two a granule) and LE2 (8 bytes a half-row) as they
// come, obj_size4 then being half the region so that snd_base still follows
// it.
wire        two1    = in_tile ? tile_bpp == 2'd1 : obj_layout == 2'd2;
wire        verb    = in_tile ? tile_bpp == 2'd2 : obj_layout[0];   // RNG, LE2
wire [26:0] spread  = verb ? s :
                      off < { 1'd0, size4 } ? base + { off[25:2], 3'b000 } + { 25'd0, off[1:0] } :
                      two1                  ? base + { off1[24:1], 3'b000 } + 27'd4 + { 26'd0, off1[0] }
                                            : base + { off1[23:0], 3'b000 } + 27'd4;
wire [26:0] dl_addr_c = (in_tile || in_obj) ? spread : io_addr_q;

// A region's one-byte part is spread eight times as wide as the stream that
// carries it, and the .mra pads each region to its nominal size -- so once
// the real bytes are done, the padding keeps driving the address eight bytes
// at a time, straight past the region and off the end of the chip, which
// wraps to 0. On crzcross that is 0x440000 bytes of zeros landing on byte 4
// of every granule of the image, over and over: the BIOS's 51c8 became 00c8
// and the CPU died on an illegal instruction at 0x264 before a frame was
// drawn (docs/ROADMAP.md).
//
// A write is kept only where it lands inside the region it belongs to. The
// padding is zeros, so nothing real is lost -- the region's own data spreads
// exactly up to the next base.
wire        dl_fits = !(in_tile || in_obj) ? 1'b1
                    : in_tile              ? spread <  obj_base && spread >= tile_base
                                           : spread <  snd_base && spread >= obj_base;

// registered (timing), with the strobe and data delayed alongside
logic [26:0] dl_addr_q;
logic        dl_wr_q, dl_dl_q;
logic [15:0] dl_index_q;
logic  [7:0] dl_dout_q;
always_ff @(posedge clk_mem) begin
    dl_addr_q  <= dl_addr_c;
    dl_wr_q    <= io_wr_q && dl_fits;
    dl_dl_q    <= io_dl_q;
    dl_index_q <= io_index_q;
    dl_dout_q  <= io_dout_q;
end

wire        dl_req, dl_we16, dl_busy, dl_wait;
wire [26:0] dl_addr;
wire [15:0] dl_data;
// the bytes in the pipeline registers count too, so a byte pushed on the
// clock after another's is held off (the HPS is slower; a bench need not be)
assign ioctl_wait = dl_wait | ioctl_wr | io_wr_q | dl_wr_q;

sdram_download u_dl (
    .clk(clk_mem), .reset(reset),
    .ioctl_download(dl_dl_q), .ioctl_index(dl_index_q),
    .ioctl_wr(dl_wr_q), .ioctl_addr(dl_addr_q), .ioctl_dout(dl_dout_q),
    .ioctl_wait(dl_wait),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
    .dl_we16(dl_we16), .dl_busy(dl_busy)
);

// ------------------------------------------------------------ the chip
logic [26:1] p_addr [0:2];
logic        p_wrl  [0:2], p_wrh [0:2], p_req [0:2];
logic [15:0] p_din  [0:2];
wire  [63:0] p_dout [0:2];
wire         p_ack  [0:2];
wire         p_dbl0;                    // port 0's double read (the sprite port, DBL)
wire  [63:0] p_dout0b;

sdram u_sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
    .init(init), .clk(clk_mem),
    .addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]),
    .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]), .dbl0(p_dbl0), .dout0b(p_dout0b),
    .addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]), .din1(p_din[1]),
    .dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
    .addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]), .din2(p_din[2]),
    .dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2])
);

// ------------------------------------------------------------ port 1: the
// graphics ROM readback. The game checksums its own ROMs through the
// K056832 and K055673 windows, and a read there is rare -- once a boot --
// so it gets the port the tile and sprite drawing do not use, and never
// waits behind them.
`ifdef GX_T34
localparam int N1 = 5;
`else
localparam int N1 = 4;
`endif
wire [N1-1:0]    arb1_req, arb1_valid;
wire [27*N1-1:0] arb1_addr;
wire [63:0] arb1_rdata;

sdram_arbiter #(.N(N1)) u_arb1 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[1]), .port_wrl(p_wrl[1]), .port_wrh(p_wrh[1]),
    .port_din(p_din[1]), .port_dout(p_dout[1]),
    .port_req(p_req[1]), .port_ack(p_ack[1]),
    .c_req(arb1_req), .c_addr(arb1_addr), .c_valid(arb1_valid), .c_rdata(arb1_rdata),
    .c_dbl('0), .c_rdata2(), .port_dout2(64'd0), .port_dbl(),
    // the arbiter's write path, idle on this port since the download uses
    // port 2, carries the sound board's RAM writes
    .dl_req(snd_wreq), .dl_addr(snd_waddr), .dl_data(snd_wdata), .dl_we16(snd_we16),
    .dl_busy(snd_wbusy)
);

gx_rom_port #(.AW(24)) u_gfx (
    .clk, .clk_mem, .rst(reset),
    .cs(gfx_cs), .addr(gfx_addr), .ok(gfx_ok), .data(gfx_data),
    .hint_cs(1'b0), .hint_addr(24'd0), .halfsel(1'b0), .inval(1'b0),
    .base(27'd0),
    .c_req(arb1_req[0]), .c_addr(arb1_addr[26:0]), .c_valid(arb1_valid[0]), .c_rdata(arb1_rdata), .c_dbl(), .c_rdata2(64'd0)
);

gx_rom_port #(.AW(24)) u_snd (
    .clk, .clk_mem, .rst(reset),
    .cs(snd_cs), .addr(snd_addr), .ok(snd_ok), .data(snd_data),
    .hint_cs(1'b0), .hint_addr(24'd0), .halfsel(1'b0), .inval(snd_inval),
    .base(27'd0),
    .c_req(arb1_req[1]), .c_addr(arb1_addr[53:27]), .c_valid(arb1_valid[1]), .c_rdata(arb1_rdata), .c_dbl(), .c_rdata2(64'd0)
);

gx_rom_port #(.AW(15)) u_dsp (
    .clk, .clk_mem, .rst(reset),
    .cs(dsp_cs), .addr(dsp_addr), .ok(dsp_ok), .data(dsp_data),
    .hint_cs(1'b0), .hint_addr(15'd0), .halfsel(1'b0), .inval(dsp_inval),
    .base(snd_base + 27'h050000 + { 3'd0, snd_pcm }),
    .c_req(arb1_req[2]), .c_addr(arb1_addr[80:54]), .c_valid(arb1_valid[2]), .c_rdata(arb1_rdata), .c_dbl(), .c_rdata2(64'd0)
);

// the voices keep a granule per channel themselves (gx_k054539), so one here
gx_rom_port #(.AW(21), .NS(1)) u_pcm (
    .clk, .clk_mem, .rst(reset),
    .cs(pcm_cs), .addr(pcm_addr), .ok(pcm_ok), .data(pcm_data),
    .hint_cs(1'b0), .hint_addr(21'd0), .halfsel(1'b0), .inval(pcm_inval),
    .base(snd_base + 27'h040000),
    .c_req(arb1_req[3]), .c_addr(arb1_addr[107:81]), .c_valid(arb1_valid[3]), .c_rdata(arb1_rdata), .c_dbl(), .c_rdata2(64'd0)
);

`ifdef GX_T34
gx_rom_port #(.AW(13)) u_sram (
    .clk, .clk_mem, .rst(reset),
    .cs(sram_cs), .addr(sram_addr), .ok(sram_ok), .data(sram_data),
    .hint_cs(1'b0), .hint_addr(13'd0), .halfsel(1'b0), .inval(sram_inval),
    .base(snd_base + 27'h090000 + { 3'd0, snd_pcm }),
    .c_req(arb1_req[4]), .c_addr(arb1_addr[134:108]), .c_valid(arb1_valid[4]), .c_rdata(arb1_rdata), .c_dbl(), .c_rdata2(64'd0)
);
`else
assign sram_ok   = 1'b0;
assign sram_data = 64'd0;
`endif

// ------------------------------------------------------------ port 0: graphics
`ifdef GX_T34
localparam int N0 = 8;              // the second tile client, the K053936's map and four tile clients
`else
localparam int N0 = 2;
`endif
wire [N0-1:0]    arb0_req, arb0_valid;
wire [27*N0-1:0] arb0_addr;
wire [63:0] arb0_rdata, arb0_rdata2;
wire [N0-1:0]    arb0_dbl;
wire [63:0] tile_g, obj_g;

// ------------------------------------------------------------ use, per frame
// A port is busy from its request to the chip's acknowledge (req != ack); a
// client waits while its request to the graphics arbiter is up.
function automatic [23:0] sat24( input [23:0] v ); sat24 = &v ? v : v + 24'd1; endfunction
reg  [23:0] bw_g, bw_c, bw_t, bw_o, bw_p, bw_sp, bw_dsp, bw_pcm, bw_sr, bw_sw, bw_cpu;
reg  [ 1:0] bw_vbl;
`ifdef GX_T34
wire        bw_tw = arb0_req[0] | arb0_req[2];      // the tilemap's two clients
wire        bw_pw = |arb0_req[N0-1:3];              // the K053936's map and tiles
wire        bw_srr = arb1_req[4];                   // the sound 68000's RAM (SDRAM in this build)
`else
wire        bw_tw = arb0_req[0];
wire        bw_pw = 1'b0;
wire        bw_srr = 1'b0;
`endif
always_ff @(posedge clk_mem) begin
    bw_vbl <= { bw_vbl[0], lvbl };
    if( bw_vbl == 2'b10 ) begin
        dbg_bw <= { bw_cpu, bw_sw, bw_sr, bw_pcm, bw_dsp, bw_sp, bw_p, bw_o, bw_t, bw_c, bw_g };
        bw_g <= 0; bw_c <= 0; bw_t <= 0; bw_o <= 0; bw_p <= 0;
        bw_sp <= 0; bw_dsp <= 0; bw_pcm <= 0; bw_sr <= 0; bw_sw <= 0; bw_cpu <= 0;
    end else begin
        if( p_req[0] != p_ack[0] ) bw_g <= sat24(bw_g);
        if( p_req[1] != p_ack[1] ) bw_c <= sat24(bw_c);
        if( bw_tw ) bw_t <= sat24(bw_t);
        if( arb0_req[1] ) bw_o <= sat24(bw_o);
        if( bw_pw ) bw_p <= sat24(bw_p);
        if( arb1_req[1] ) bw_sp  <= sat24(bw_sp);
        if( arb1_req[2] ) bw_dsp <= sat24(bw_dsp);
        if( arb1_req[3] ) bw_pcm <= sat24(bw_pcm);
        if( bw_srr )      bw_sr  <= sat24(bw_sr);
        if( snd_wreq )    bw_sw  <= sat24(bw_sw);
        if( p_req[2] != p_ack[2] ) bw_cpu <= sat24(bw_cpu);
    end
end

// the tiles and sprites first: they have the line's deadline and one fetch
// in flight each; the K053936's clients take what they leave
`ifdef GX_T34
localparam int HI0 = 3;             // the tiles (two clients) and the sprites
`else
localparam int HI0 = 2;
`endif
sdram_arbiter #(.N(N0), .HI(HI0)) u_arb0 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[0]), .port_wrl(p_wrl[0]), .port_wrh(p_wrh[0]),
    .port_din(p_din[0]), .port_dout(p_dout[0]),
    .port_req(p_req[0]), .port_ack(p_ack[0]),
    .c_req(arb0_req), .c_addr(arb0_addr),
    .c_valid(arb0_valid), .c_rdata(arb0_rdata),
    .c_dbl(arb0_dbl), .c_rdata2(arb0_rdata2), .port_dout2(p_dout0b), .port_dbl(p_dbl0),
    .dl_req(1'b0), .dl_addr(27'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
);

gx_rom_port #(.AW(21)) u_tile (
    .clk, .clk_mem, .rst(reset),
    .cs(tile_cs), .addr(tile_addr), .ok(tile_ok), .data(tile_g),
    .hint_cs(1'b0), .hint_addr(21'd0), .halfsel(1'b0), .inval(1'b0),
    .base(tile_base),
    .c_req(arb0_req[0]), .c_addr(arb0_addr[26:0]), .c_valid(arb0_valid[0]), .c_rdata(arb0_rdata), .c_dbl(arb0_dbl[0]), .c_rdata2(arb0_rdata2)
);
gx_rom_port #(.AW(23), .PAIR(1), .DBL(1)) u_obj (
    .clk, .clk_mem, .rst(reset),
    .cs(obj_cs), .addr(obj_addr), .ok(obj_ok), .data(obj_g),
    .hint_cs(obj_pf_cs), .hint_addr(obj_pf_addr), .inval(1'b0), .halfsel(obj_layout == 2'd1),
    .base(obj_base),
    .c_req(arb0_req[1]), .c_addr(arb0_addr[53:27]), .c_valid(arb0_valid[1]), .c_rdata(arb0_rdata), .c_dbl(arb0_dbl[1]), .c_rdata2(arb0_rdata2)
);
`ifdef GX_T34
// the K053936: byte 0 to [63:56], as gx_psac takes it
function automatic [63:0] bswap( input [63:0] g );
    bswap = { g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56] };
endfunction
wire [63:0] psm_g;
wire [63:0] pst_g [4];
gx_rom_port #(.AW(16)) u_psm (
    .clk, .clk_mem, .rst(reset),
    .cs(psm_cs), .addr(psm_addr), .ok(psm_ok), .data(psm_g),
    .hint_cs(1'b0), .hint_addr(16'd0), .halfsel(1'b0), .inval(1'b0),
    .base(psmap_base),
    .c_req(arb0_req[3]), .c_addr(arb0_addr[107:81]), .c_valid(arb0_valid[3]), .c_rdata(arb0_rdata), .c_dbl(arb0_dbl[3]), .c_rdata2(arb0_rdata2)
);
assign psm_data = bswap(psm_g);
wire [63:0] tile2_g;
gx_rom_port #(.AW(21)) u_tile2 (
    .clk, .clk_mem, .rst(reset),
    .cs(tile2_cs), .addr(tile2_addr), .ok(tile2_ok), .data(tile2_g),
    .hint_cs(1'b0), .hint_addr(21'd0), .halfsel(1'b0), .inval(1'b0),
    .base(tile_base),
    .c_req(arb0_req[2]), .c_addr(arb0_addr[80:54]), .c_valid(arb0_valid[2]), .c_rdata(arb0_rdata), .c_dbl(arb0_dbl[2]), .c_rdata2(arb0_rdata2)
);
assign tile2_data = bswap(tile2_g);
genvar gk;
generate for( gk = 0; gk < 4; gk++ ) begin : g_pst
    gx_rom_port #(.AW(18)) u_pst (
        .clk, .clk_mem, .rst(reset),
        .cs(pst_cs[gk]), .addr(pst_addr[18*gk +: 18]), .ok(pst_ok[gk]), .data(pst_g[gk]),
        .hint_cs(1'b0), .hint_addr(18'd0), .halfsel(1'b0), .inval(1'b0),
        .base(psac_base),
        .c_req(arb0_req[4+gk]), .c_addr(arb0_addr[27*(4+gk) +: 27]), .c_valid(arb0_valid[4+gk]),
        .c_rdata(arb0_rdata), .c_dbl(arb0_dbl[4+gk]), .c_rdata2(arb0_rdata2)
    );
    assign pst_data[64*gk +: 64] = bswap(pst_g[gk]);
end endgenerate
`else
assign psm_ok = 1'b0;   assign psm_data = 64'd0;
assign tile2_ok = 1'b0; assign tile2_data = 64'd0;
assign pst_ok = 4'd0;   assign pst_data = 256'd0;
`endif

// a row's five bytes, in the order the benches' rom.hex holds them
assign tile_data = { tile_g[7:0], tile_g[15:8], tile_g[23:16], tile_g[31:24],
                      tile_g[39:32], tile_g[47:40], tile_g[55:48], tile_g[63:56] };
assign obj_data  = { obj_g[7:0],  obj_g[15:8],  obj_g[23:16],  obj_g[31:24],
                      obj_g[39:32], obj_g[47:40], obj_g[55:48], obj_g[63:56] };

// ------------------------------------------------------------ port 2: CPU, download
wire [0:0]  arb2_req, arb2_valid;
wire [26:0] arb2_addr;
wire [63:0] arb2_rdata;

sdram_arbiter #(.N(1)) u_arb2 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[2]), .port_wrl(p_wrl[2]), .port_wrh(p_wrh[2]),
    .port_din(p_din[2]), .port_dout(p_dout[2]),
    .port_req(p_req[2]), .port_ack(p_ack[2]),
    .c_req(arb2_req), .c_addr(arb2_addr),
    .c_valid(arb2_valid), .c_rdata(arb2_rdata),
    .c_dbl(1'b0), .c_rdata2(), .port_dout2(64'd0), .port_dbl(),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
);

gx_rom_port #(.AW(20)) u_cpu (
    .clk, .clk_mem, .rst(reset),
    .cs(cpu_cs), .addr(cpu_addr), .ok(cpu_ok), .data(cpu_data),
    .hint_cs(1'b0), .hint_addr(20'd0), .halfsel(1'b0), .inval(1'b0),
    .base(BASE_MAINCPU),
    .c_req(arb2_req[0]), .c_addr(arb2_addr), .c_valid(arb2_valid[0]), .c_rdata(arb2_rdata), .c_dbl(), .c_rdata2(64'd0)
);

endmodule

`default_nettype wire
