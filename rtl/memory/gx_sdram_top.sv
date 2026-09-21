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
//                TMS57002's (256 KB), the last two written at runtime
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

    input  wire [25:0] tile_base,     // gx_board_cfg: where each region is
    input  wire [25:0] obj_base,
    input  wire [23:0] tile_size4,    // bytes in each region's four-byte part
    input  wire [23:0] obj_size4,

    // clients, clk: the video benches' ROM model contract (gx_rom_port)
    input  wire        cpu_cs,        // gx_romcache: a granule of the packed image
    input  wire [19:0] cpu_addr,
    output wire        cpu_ok,
    output wire [63:0] cpu_data,

    input  wire        tile_cs,       // gx_tilemap: its rom_addr, a row index
    input  wire [20:0] tile_addr,
    output wire        tile_ok,
    output wire [39:0] tile_data,

    input  wire        obj_cs,        // gx_obj: its rom_addr, a half-row index ([4:0] within a tile)
    input  wire [19:0] obj_addr,
    input  wire        obj_pf_cs,     // and the half-row it will ask for next
    input  wire [19:0] obj_pf_addr,

    // the CPU reading graphics ROM back through the chips' own windows
    // (0xd00000, 0xd4a000): an absolute granule of the image, on the chip
    // port nothing else uses
    input  wire        gfx_cs,
    input  wire [22:0] gfx_addr,
    output wire        gfx_ok,
    output wire [63:0] gfx_data,

    // the sound board (gx_sound): reads of its program, the samples and the
    // K054539s' RAM, and byte writes of that RAM, on the same chip port
    input  wire        snd_cs,
    input  wire [22:0] snd_addr,
    output wire        snd_ok,
    output wire [63:0] snd_data,
    input  wire        snd_inval,
    input  wire        snd_wreq,
    input  wire [25:0] snd_waddr,
    input  wire [15:0] snd_wdata,
    input  wire        snd_we16,
    output wire        snd_wbusy,
    // the TMS57002's RAM, granules from snd_base + 0x450000; inval after
    // each of its writes
    input  wire        dsp_cs,
    input  wire [14:0] dsp_addr,
    output wire        dsp_ok,
    output wire [63:0] dsp_data,
    input  wire        dsp_inval,
    output wire        obj_ok,
    output wire [39:0] obj_data
);

localparam logic [25:0] BASE_MAINCPU = 26'h000_0000;

// ------------------------------------------------------------ download
// The stream address to the SDRAM address: the graphics regions spread.
// A region's stream is 5/8 of its spread, so it ends before the next base.
wire [25:0] s       = ioctl_addr[25:0];
// The sound board's ROMs follow the sprite region's spread, stored as they
// come (the stream address is the SDRAM address): the sound CPU's program
// at snd_base, the K054539 samples after it. Without the upper bound the
// sprite transform claimed everything above obj_base and would have spread
// them too.
wire [25:0] snd_base = obj_base + { 1'b0, obj_size4, 1'b0 };
wire        in_tile = s >= tile_base && s < obj_base;
wire        in_obj  = s >= obj_base  && s < snd_base;
wire [25:0] base    = in_tile ? tile_base : obj_base;
wire [23:0] size4   = in_tile ? tile_size4 : obj_size4;
wire [25:0] off     = s - base;
wire [25:0] off1    = off - { 2'd0, size4 };                 // within the one-byte part
wire [25:0] spread  = off < { 2'd0, size4 } ? base + { off[24:2], 3'b000 } + { 24'd0, off[1:0] }
                                            : base + { off1[22:0], 3'b000 } + 26'd4;
wire [26:0] dl_addr_c = (in_tile || in_obj) ? { 1'b0, spread } : ioctl_addr;

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
    dl_wr_q    <= ioctl_wr && dl_fits;
    dl_dl_q    <= ioctl_download;
    dl_index_q <= ioctl_index;
    dl_dout_q  <= ioctl_dout;
end

wire        dl_req, dl_we16, dl_busy, dl_wait;
wire [25:0] dl_addr;
wire [15:0] dl_data;
// the byte in the pipeline register counts too, so a byte pushed on the
// clock after another's is held off (the HPS is slower; a bench need not be)
assign ioctl_wait = dl_wait | ioctl_wr | dl_wr_q;

sdram_download u_dl (
    .clk(clk_mem), .reset(reset),
    .ioctl_download(dl_dl_q), .ioctl_index(dl_index_q),
    .ioctl_wr(dl_wr_q), .ioctl_addr(dl_addr_q), .ioctl_dout(dl_dout_q),
    .ioctl_wait(dl_wait),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
    .dl_we16(dl_we16), .dl_busy(dl_busy)
);

// ------------------------------------------------------------ the chip
logic [25:1] p_addr [0:2];
logic        p_wrl  [0:2], p_wrh [0:2], p_req [0:2];
logic [15:0] p_din  [0:2];
wire  [63:0] p_dout [0:2];
wire         p_ack  [0:2];

sdram u_sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
    .init(init), .clk(clk_mem),
    .addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]),
    .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]),
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
wire [2:0]  arb1_req, arb1_valid;
wire [77:0] arb1_addr;
wire [63:0] arb1_rdata;

sdram_arbiter #(.N(3)) u_arb1 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[1]), .port_wrl(p_wrl[1]), .port_wrh(p_wrh[1]),
    .port_din(p_din[1]), .port_dout(p_dout[1]),
    .port_req(p_req[1]), .port_ack(p_ack[1]),
    .c_req(arb1_req), .c_addr(arb1_addr), .c_valid(arb1_valid), .c_rdata(arb1_rdata),
    // the arbiter's write path, idle on this port since the download uses
    // port 2, carries the sound board's RAM writes
    .dl_req(snd_wreq), .dl_addr(snd_waddr), .dl_data(snd_wdata), .dl_we16(snd_we16),
    .dl_busy(snd_wbusy)
);

gx_rom_port #(.AW(23)) u_gfx (
    .clk, .clk_mem, .rst(reset),
    .cs(gfx_cs), .addr(gfx_addr), .ok(gfx_ok), .data(gfx_data),
    .hint_cs(1'b0), .hint_addr(23'd0), .inval(1'b0),
    .base(26'd0),
    .c_req(arb1_req[0]), .c_addr(arb1_addr[25:0]), .c_valid(arb1_valid[0]), .c_rdata(arb1_rdata)
);

gx_rom_port #(.AW(23)) u_snd (
    .clk, .clk_mem, .rst(reset),
    .cs(snd_cs), .addr(snd_addr), .ok(snd_ok), .data(snd_data),
    .hint_cs(1'b0), .hint_addr(23'd0), .inval(snd_inval),
    .base(26'd0),
    .c_req(arb1_req[1]), .c_addr(arb1_addr[51:26]), .c_valid(arb1_valid[1]), .c_rdata(arb1_rdata)
);

gx_rom_port #(.AW(15)) u_dsp (
    .clk, .clk_mem, .rst(reset),
    .cs(dsp_cs), .addr(dsp_addr), .ok(dsp_ok), .data(dsp_data),
    .hint_cs(1'b0), .hint_addr(15'd0), .inval(dsp_inval),
    .base(snd_base + 26'h450000),
    .c_req(arb1_req[2]), .c_addr(arb1_addr[77:52]), .c_valid(arb1_valid[2]), .c_rdata(arb1_rdata)
);

// ------------------------------------------------------------ port 0: graphics
wire [1:0]  arb0_req, arb0_valid;
wire [51:0] arb0_addr;
wire [63:0] arb0_rdata;
wire [63:0] tile_g, obj_g;

sdram_arbiter #(.N(2)) u_arb0 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[0]), .port_wrl(p_wrl[0]), .port_wrh(p_wrh[0]),
    .port_din(p_din[0]), .port_dout(p_dout[0]),
    .port_req(p_req[0]), .port_ack(p_ack[0]),
    .c_req(arb0_req), .c_addr(arb0_addr),
    .c_valid(arb0_valid), .c_rdata(arb0_rdata),
    .dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
);

gx_rom_port #(.AW(21)) u_tile (
    .clk, .clk_mem, .rst(reset),
    .cs(tile_cs), .addr(tile_addr), .ok(tile_ok), .data(tile_g),
    .hint_cs(1'b0), .hint_addr(21'd0), .inval(1'b0),
    .base(tile_base),
    .c_req(arb0_req[0]), .c_addr(arb0_addr[25:0]), .c_valid(arb0_valid[0]), .c_rdata(arb0_rdata)
);
gx_rom_port #(.AW(20), .PAIR(1)) u_obj (
    .clk, .clk_mem, .rst(reset),
    .cs(obj_cs), .addr(obj_addr), .ok(obj_ok), .data(obj_g),
    .hint_cs(obj_pf_cs), .hint_addr(obj_pf_addr), .inval(1'b0),
    .base(obj_base),
    .c_req(arb0_req[1]), .c_addr(arb0_addr[51:26]), .c_valid(arb0_valid[1]), .c_rdata(arb0_rdata)
);
// a row's five bytes, in the order the benches' rom.hex holds them
assign tile_data = { tile_g[7:0], tile_g[15:8], tile_g[23:16], tile_g[31:24], tile_g[39:32] };
assign obj_data  = { obj_g[7:0],  obj_g[15:8],  obj_g[23:16],  obj_g[31:24],  obj_g[39:32]  };

// ------------------------------------------------------------ port 2: CPU, download
wire [0:0]  arb2_req, arb2_valid;
wire [25:0] arb2_addr;
wire [63:0] arb2_rdata;

sdram_arbiter #(.N(1)) u_arb2 (
    .clk(clk_mem), .reset(reset),
    .port_addr(p_addr[2]), .port_wrl(p_wrl[2]), .port_wrh(p_wrh[2]),
    .port_din(p_din[2]), .port_dout(p_dout[2]),
    .port_req(p_req[2]), .port_ack(p_ack[2]),
    .c_req(arb2_req), .c_addr(arb2_addr),
    .c_valid(arb2_valid), .c_rdata(arb2_rdata),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
);

gx_rom_port #(.AW(20)) u_cpu (
    .clk, .clk_mem, .rst(reset),
    .cs(cpu_cs), .addr(cpu_addr), .ok(cpu_ok), .data(cpu_data),
    .hint_cs(1'b0), .hint_addr(20'd0), .inval(1'b0),
    .base(BASE_MAINCPU),
    .c_req(arb2_req[0]), .c_addr(arb2_addr), .c_valid(arb2_valid[0]), .c_rdata(arb2_rdata)
);

endmodule

`default_nettype wire
