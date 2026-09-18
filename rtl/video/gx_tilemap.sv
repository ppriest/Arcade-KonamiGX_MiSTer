// SPDX-License-Identifier: GPL-3.0-or-later
//
// Konami GX tilemaps: the K054156 register file and the K056832 tile fetch,
// as a line renderer. Four layers, 16 VRAM pages, 5 bpp.
//
// WRITTEN FROM THE SOFTWARE MODEL, NOT PORTED. scripts/render_model.py
// layer_fields() is the specification and scripts/check_gx_tilemap.py the
// test: sim/gx_tilemap_tb renders captured frames and every pixel's colour
// field and pixel value must equal the model's. jotego's jt05415x (vendored
// beside this in k056832/) was the planned base and is not used here, because
// (1) it addresses 4 VRAM pages, as Moo Mesa's 24 KB of SRAM does, where GX
// uses all 16 -- daiskiss puts layer C at page row 2 and layer B at page
// column 2; (2) it outputs tile-ROM addresses, the pixel path being in each
// game's own video module; (3) its register outputs keep 11/12 bits of the
// scroll registers, where MAME uses all 16 and the two differ whenever a
// layer is not a power of two tall (rowspan 3, 768 rows).
//
// OUTPUT, per layer per pixel: { colour[5:0], pixel[4:0] }. The K055555 adds
// the palette base (PALBASE_A..D << 6); pixel 0 is transparent.
//
// COORDINATES are MAME's bitmap coordinates: a line is rendered for bitmap
// row line_y, for bitmap columns 24..311 (set_visarea(24, 24+288-1, ...)).
// Mapping the K053252's counters onto those is the video top level's job.
//
// NOT HANDLED, and flagged on `unsupported` rather than drawn wrong: line and
// row scroll (m_regs[5] mode != 3), screen flip (m_regs[0] bits 4-5), colour
// depths other than 5 bpp.
//
// ONE LINE BUFFER PAIR: line_start renders into one half and flips which half
// rd_x reads, so the previous line is readable while the next renders.

module gx_tilemap (
    input               clk,
    input               rst,

    // K054156 registers, 0xd40000-0xd4003f: word_w, big-endian byte enables
    input               reg_we,
    input        [4:0]  reg_addr,
    input       [15:0]  reg_din,
    input        [1:0]  reg_be,          // [1] = bits 15:8, [0] = bits 7:0

    // GX tile bank registers, 0xd44000-0xd44007 (m_gx_tilebanks)
    input               tbank_we,
    input        [2:0]  tbank_addr,
    input        [7:0]  tbank_din,

    // VRAM, by word: { page[3:0], word[11:0] }. Word 2t of a page is tile
    // t's attribute, word 2t+1 its code. A read is a vram_rd strobe; the
    // word is on vram_dout two clock edges later and stays there.
    input               vram_we,
    input               vram_rd,
    input       [15:0]  vram_addr,
    input       [15:0]  vram_din,
    input        [1:0]  vram_be,
    output reg  [15:0]  vram_dout,

    // per-game K056832 set_layer_offs(layer, x, y)
    input  signed [7:0] offs_x [4],
    input  signed [7:0] offs_y [4],

    // render
    input               line_start,
    input        [9:0]  line_y,
    output              busy,
    output reg          unsupported,

    // tile ROM, one 5-byte pixel row per address: row = code * 8 + y
    output reg  [23:0]  rom_addr,
    output reg          rom_cs,
    input               rom_ok,
    input       [39:0]  rom_data,

    // line buffer read: bitmap column 24 + rd_x, one cycle latency
    input        [8:0]  rd_x,
    output      [10:0]  rd_pix [4]
);

localparam [9:0] VIS_X0 = 10'd24;
localparam [8:0] VIS_W  = 9'd288;

// ------------------------------------------------------------ registers ---
reg [15:0] regs [32];
(* ramstyle = "logic" *) reg [ 7:0] tbank [8];   // read combinationally

always @(posedge clk) begin
    if (reg_we) begin
        if (reg_be[1]) regs[reg_addr][15:8] <= reg_din[15:8];
        if (reg_be[0]) regs[reg_addr][ 7:0] <= reg_din[ 7:0];
    end
    if (tbank_we) tbank[tbank_addr] <= tbank_din;
end

// -------------------------------------------------------------- render ---
// Per layer: SETUP..PREP work out where the line starts in the layer's map,
// then RUN keeps two things going at once -- a fetcher reading one tile at a
// time (VRAM entry, then its pixel row from ROM) into a one-tile buffer, and
// an emitter writing one pixel a cycle from the tile before it. A tile costs
// the fetcher about 5 cycles plus the ROM latency, so with a ROM answering in
// 3 cycles or fewer the emitter never waits after the first tile; beyond
// that the line time is set by the ROM.
typedef enum logic [2:0] { IDLE, SETUP, MOD_Y, FIX_Y, PREP, RUN } state_t;
typedef enum logic [2:0] { F_IDLE, F_VWAIT, F_VDATA, F_RWAIT, F_HOLD } fstate_t;
state_t  st;
fstate_t fst;

wire [15:0] r_ctrl   = regs[0];
wire [15:0] r_flipen = regs[1];
wire [15:0] r_attr   = regs[3];
wire [15:0] r_scroll = regs[5];

reg  [ 1:0] layer;
reg  [ 9:0] y;
reg  [11:0] height;          // rowspan * 256
reg  [11:0] width;           // colspan * 512
reg  [ 1:0] rowstart, colstart;
reg  [19:0] modv;            // |dy - offs_y|, reduced in place
reg         modneg;
reg  [ 2:0] modk;
reg  [11:0] ay, my;
reg  [31:0] scan_q;          // the tile's VRAM entry, captured in F_VWAIT

wire [15:0] l_ysc  = regs[16 + layer];
wire [15:0] l_xsc  = regs[20 + layer];
wire [15:0] l_rows = regs[8 + layer];
wire [15:0] l_cols = regs[12 + layer];

// Attribute decode, selected by m_regs[3] bits 6-7: where the two flip bits
// sit and how the six colour bits are assembled.
reg  [3:0] flips;
reg  [5:0] palm1, palm2;
reg  [1:0] pals2;
always @* begin
    case (r_attr[7:6])
        2'd0:    begin flips = 4'd6; palm1 = 6'h3f; pals2 = 2'd0; palm2 = 6'h00; end
        2'd1:    begin flips = 4'd4; palm1 = 6'h0f; pals2 = 2'd2; palm2 = 6'h30; end
        2'd2:    begin flips = 4'd2; palm1 = 6'h03; pals2 = 2'd2; palm2 = 6'h3c; end
        default: begin flips = 4'd0; palm1 = 6'h00; pals2 = 2'd2; palm2 = 6'h3f; end
    endcase
end

wire [15:0] attr    = scan_q[31:16];
wire [15:0] code    = scan_q[15:0];
wire [15:0] attr_sh = attr >> pals2;
wire [ 1:0] t_flip  = attr[flips +: 2] & r_flipen[{layer, 1'b0} +: 2];
wire [ 5:0] t_col   = (attr[5:0] & palm1) | (attr_sh[5:0] & palm2);
wire [20:0] t_code  = { tbank[code[15:13]], code[12:0] };    // type2_tile_callback
wire [ 2:0] t_y     = t_flip[1] ? ~my[2:0] : my[2:0];

// MAME: ay = (dy - offs_y) % height with dy = (int16_t)m_regs[0x10+layer],
// and sx = (dx - offs_x) & (width - 1)
wire signed [16:0] ydiff = $signed({l_ysc[15], l_ysc}) - $signed({{9{offs_y[layer][7]}}, offs_y[layer]});
wire        [15:0] xdiff = l_xsc - {{8{offs_x[layer][7]}}, offs_x[layer]};
wire        [11:0] sx    = xdiff[11:0] & (width - 12'd1);
wire        [11:0] ysum  = {2'd0, y} + ay;
wire        [11:0] xsum  = {2'd0, VIS_X0} + sx;
// my = (y + ay) % height and mx = (24 + sx) % width: each sum is less than
// twice its modulus
wire        [11:0] mx0   = xsum >= width ? xsum - width : xsum;

// fetcher
reg  [11:0] fmx;             // map column of the tile being fetched
reg  [ 5:0] fleft;           // tiles still to fetch on this layer
reg  [ 2:0] ftx;
reg  [ 5:0] fcol;
reg  [ 1:0] fflip;
reg  [39:0] frow;
wire [11:0] fnext = {fmx[11:3], 3'd0} + 12'd8;

// one-tile buffer between fetcher and emitter
reg         nb_valid;
reg  [39:0] nb_row;
reg  [ 5:0] nb_col;
reg  [ 1:0] nb_flip;
reg  [ 2:0] nb_tx;

// emitter
reg         e_valid;
reg  [ 8:0] px;
reg  [ 2:0] tx;
reg  [ 1:0] flip;
reg  [ 5:0] colour;
reg  [39:0] row;

// The pixel at tx of the emitter's row. MAME's bit order is MSB first within
// each byte, and charlayout5's planes are { b4, b3, b1, b2, b0 } (bit
// offsets 32, 24, 8, 16, 0), b0 being the row's first byte.
wire [2:0] bitsel = flip[0] ? tx : ~tx;
wire [7:0] b0 = row[39:32], b1 = row[31:24], b2 = row[23:16], b3 = row[15:8], b4 = row[7:0];
wire [4:0] pixel = { b4[bitsel], b3[bitsel], b1[bitsel], b2[bitsel], b0[bitsel] };

wire last_px  = e_valid && px == VIS_W - 9'd1;
wire tile_end = e_valid && tx == 3'd7 && !last_px;
wire nb_take  = nb_valid && (!e_valid || tile_end);
wire nb_free  = !nb_valid || nb_take;

// ------------------------------------------------------ VRAM, line buffers ---
// VRAM: 16 pages x 2048 tiles x { attr, code }, 1 Mbit, as four byte-lane
// RAMs of 32K x 8. One write port (CPU) and ONE read port, shared: a CPU
// read takes it for a cycle and the fetcher waits. With a second read port
// Quartus 17 duplicated every lane (2 Mbit), and a single packed [3:0][7:0]
// array with byte enables was not inferred at all (276007).
// The CPU writes half an entry, so its two byte enables land on lanes 3:2
// (attribute) or 1:0 (code).
// entry = page * 2048 + tile, page = ((rowstart + my / 256) & 3) * 4
//                                   + ((colstart + mx / 512) & 3)
wire [14:0] tile_addr = { 2'(rowstart + my[9:8]), 2'(colstart + fmx[10:9]), my[7:3], fmx[8:3] };
wire        scan_rd   = st == RUN && fst == F_IDLE && fleft != 6'd0 && !vram_rd;
wire [14:0] rd_addr   = vram_rd ? vram_addr[15:1] : tile_addr;
wire [ 3:0] vram_be4  = vram_addr[0] ? {2'b00, vram_be} : {vram_be, 2'b00};
wire [31:0] ram_q;
reg         cpu_rd_l, cpu_half;

genvar b;
generate for (b = 0; b < 4; b++) begin : g_vram
    gx_sdpram #(.AW(15), .DW(8)) u_lane (
        .clk ( clk ),
        .we  ( vram_we && vram_be4[b] ),
        .wa  ( vram_addr[15:1] ),
        .d   ( (b % 2) ? vram_din[15:8] : vram_din[7:0] ),
        .ra  ( rd_addr ),
        .q   ( ram_q[b*8 +: 8] )
    );
end endgenerate

always @(posedge clk) begin
    cpu_rd_l <= vram_rd;
    cpu_half <= vram_addr[0];
    if (cpu_rd_l) vram_dout <= cpu_half ? ram_q[15:0] : ram_q[31:16];
end

// Line buffers: one RAM per layer, two lines of 512 (288 used).
reg        wr_half;
reg        lb_we;
reg [ 1:0] lb_layer;
reg [ 8:0] lb_px;
reg [10:0] lb_din;

genvar l;
generate for (l = 0; l < 4; l++) begin : g_lbuf
    gx_sdpram #(.AW(10), .DW(11)) u_lbuf (
        .clk ( clk ),
        .we  ( lb_we && lb_layer == l ),
        .wa  ( {wr_half, lb_px} ),
        .d   ( lb_din ),
        .ra  ( {~wr_half, rd_x} ),
        .q   ( rd_pix[l] )
    );
end endgenerate

assign busy = st != IDLE;

always @(posedge clk) begin
    lb_we <= 1'b0;
    if (rst) begin
        st          <= IDLE;
        fst         <= F_IDLE;
        wr_half     <= 1'b0;
        rom_cs      <= 1'b0;
        nb_valid    <= 1'b0;
        e_valid     <= 1'b0;
        fleft       <= 6'd0;
        unsupported <= 1'b0;
    end else case (st)
        IDLE: if (line_start) begin
            wr_half <= ~wr_half;
            y       <= line_y;
            layer   <= 2'd0;
            st      <= SETUP;
            if (r_scroll[7:0] != 8'hff || r_ctrl[5:4] != 2'd0) unsupported <= 1'b1;
        end
        SETUP: begin
            rowstart <= l_rows[4:3];
            colstart <= l_cols[4:3];
            height   <= { 1'b0, {1'b0, l_rows[1:0]} + 3'd1, 8'd0 };
            width    <= { {1'b0, l_cols[1:0]} + 3'd1, 9'd0 };
            modneg   <= ydiff < 0;
            modv     <= ydiff < 0 ? 20'(-ydiff) : 20'(ydiff);
            modk     <= 3'd7;
            st       <= MOD_Y;
        end
        // |dy - offs_y| mod height by restoring subtraction of height << 7..0:
        // |dy - offs_y| < 2^16 <= height << 8, so eight steps reduce it fully
        MOD_Y: begin
            if (modv >= (20'(height) << modk)) modv <= modv - (20'(height) << modk);
            modk <= modk - 3'd1;
            if (modk == 3'd0) st <= FIX_Y;
        end
        FIX_Y: begin
            ay <= (modneg && modv != 0) ? height - modv[11:0] : modv[11:0];
            st <= PREP;
        end
        PREP: begin
            my    <= ysum >= height ? ysum - height : ysum;
            fmx   <= mx0;
            fleft <= 6'((10'(mx0[2:0]) + 10'd295) >> 3);     // tiles the 288 pixels touch
            px    <= 9'd0;
            st    <= RUN;
        end
        RUN: begin
            // ---- fetcher
            case (fst)
                F_IDLE: if (scan_rd) fst <= F_VWAIT;
                F_VWAIT: begin
                    scan_q <= ram_q;
                    fst    <= F_VDATA;
                end
                F_VDATA: begin
                    fflip    <= t_flip;
                    fcol     <= t_col;
                    ftx      <= fmx[2:0];
                    rom_addr <= { t_code, t_y };
                    rom_cs   <= 1'b1;
                    fmx      <= fnext == width ? 12'd0 : fnext;
                    fleft    <= fleft - 6'd1;
                    fst      <= F_RWAIT;
                end
                F_RWAIT: if (rom_ok) begin
                    frow   <= rom_data;
                    rom_cs <= 1'b0;
                    fst    <= F_HOLD;
                end
                F_HOLD: if (nb_free) fst <= F_IDLE;
                default: fst <= F_IDLE;
            endcase

            // ---- buffer
            if (fst == F_HOLD && nb_free) begin
                nb_valid <= 1'b1;
                nb_row   <= frow;
                nb_col   <= fcol;
                nb_flip  <= fflip;
                nb_tx    <= ftx;
            end else if (nb_take) nb_valid <= 1'b0;

            // ---- emitter
            if (e_valid) begin
                lb_we    <= 1'b1;
                lb_layer <= layer;
                lb_px    <= px;
                lb_din   <= { colour, pixel };
                px       <= px + 9'd1;
                tx       <= tx + 3'd1;
            end
            if (nb_take) begin
                e_valid <= 1'b1;
                row     <= nb_row;
                colour  <= nb_col;
                flip    <= nb_flip;
                tx      <= nb_tx;
            end else if (tile_end) e_valid <= 1'b0;

            if (last_px) begin
                e_valid <= 1'b0;
                layer   <= layer + 2'd1;
                st      <= layer == 2'd3 ? IDLE : SETUP;
            end
        end
        default: st <= IDLE;
    endcase
end

`ifdef SIMULATION
// every tile fetched for a layer must have been emitted when it ends
always @(posedge clk) if (st == RUN && last_px && (fleft != 0 || nb_valid || fst != F_IDLE))
    $error("gx_tilemap: layer %0d ended with fetches outstanding", layer);
`endif

endmodule
