// gx_t1_psac4 against scripts/t1_psac4_model.py: one frame drawn from a
// MAME dump (scripts/mame/t1_dump.lua, converted by scripts/check_t1_psac4.py),
// the drawn buffer and line table written out for the script to compare.
// The SDRAM model answers after SLAT clocks; the DDR3 model is busy at
// random and answers reads after RLAT clocks. A second frame is then shown,
// and the pixels the display path gives back for every row are written out
// too.
//   +DIR=<dir>  the converted dump (map.hex, crom.hex, hrom.hex, lc.hex,
//               lr.hex, lk.hex, regs.hex) and where out.hex/shown.hex go
// regs.hex: K053936 0, 1, 6, 7; the 056540's register 0 (high, low); the
// bank; K053936 14; the golf flag; register 0 for golf's second y origin.
// Golf alternates the two each frame (K053936 14 bit 7), as Open Golf does.
`timescale 1ns/1ps
module tb_gx_t1_psac4;

localparam SLAT = 14, RLAT = 20, HT = 3072;

reg clk = 0;
always #10 clk = ~clk;

string dir;
initial if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR= missing");

// ---- the state
reg  [63:0] map  [0:16383];
reg  [63:0] crom [0:1048575];
reg  [63:0] hrom [0:786431];
reg  [15:0] lcm  [0:4095];
reg  [15:0] lrm  [0:2047];
reg  [ 7:0] lkm  [0:2047];
reg  [15:0] regs [0:15];
initial begin
    $readmemh({dir, "/map.hex"}, map);
    $readmemh({dir, "/crom.hex"}, crom);
    $readmemh({dir, "/hrom.hex"}, hrom);
    $readmemh({dir, "/lc.hex"}, lcm);
    $readmemh({dir, "/lr.hex"}, lrm);
    $readmemh({dir, "/lk.hex"}, lkm);
    $readmemh({dir, "/regs.hex"}, regs);
end
wire golf = regs[8][0];
// Racin' Force: 289 lines, 255 shown from bitmap row 0; golf 264, 224 from 16
integer VT, VA, VY0;
initial begin #1; VT = golf ? 264 : 289; VA = golf ? 224 : 255; VY0 = golf ? 16 : 0; end

// ---- the raster: frames of VT lines of HT clocks, VA visible
integer hc = 0, vc = 260;
always @(posedge clk) begin
    hc <= hc == HT - 1 ? 0 : hc + 1;
    if (hc == HT - 1) vc <= vc == VT - 1 ? 0 : vc + 1;
end
wire       lvbl = vc < VA;
wire [8:0] by = 9'(vc + VY0);
reg  [9:0] rd_x = 0;
always @(posedge clk) rd_x <= hc < 384 ? 10'(hc + 32) : 10'd0;

// ---- the unit
wire [10:0] lr_addr, lk_addr;
wire [11:0] lc_addr;
reg  [15:0] lr_q, lc_q;
reg  [ 7:0] lk_q;
always @(posedge clk) begin lr_q <= lrm[lr_addr]; lc_q <= lcm[lc_addr]; lk_q <= lkm[lk_addr]; end
wire        m_cs, c_cs, h_cs, p_cs;
wire [13:0] m_addr;
wire [19:0] c_addr, h_addr, p_addr;
reg         m_ok = 0, c_ok = 0, h_ok = 0, p_ok = 0;
reg  [63:0] m_data, c_data, h_data, p_data;
wire        t_valid;
wire [11:0] t_pen;
wire [ 7:0] t_pri;
wire [ 7:0] bc, be;
wire [28:0] addr;
wire [63:0] din;
wire        we, rd;
reg  [63:0] dout;
reg         dready = 0;
reg         busy = 0;
wire [159:0] dbg;
reg         rst = 1;
initial begin repeat (8) @(posedge clk); rst = 0; end

// golf's phase: the frame's parity
reg ph = 0;
always @(posedge clk) if (hc == HT - 1 && vc == VT - 1) ph <= golf && !ph;
gx_t1_psac4 uut (
    .clk, .rst, .golf, .vis_x0(10'd32), .vis_y0(5'(VY0)), .lvbl, .by, .rd_x, .t_valid, .t_pen, .t_pri,
    .ctrl0(regs[0]), .ctrl1(regs[1]), .ctrl6(regs[2]), .ctrl7(regs[3]),
    .ctrl14(ph ? (regs[7] | 16'h0080) : (regs[7] & ~16'h0080)),
    .p4_hi(ph ? regs[9] : regs[4]), .p4_lo(ph ? regs[10] : regs[5]), .brk(regs[6][15:12]),
    .lr_addr, .lr_q, .lc_addr, .lc_q, .lk_addr, .lk_q,
    .m_cs, .m_addr, .m_ok, .m_data, .c_cs, .c_addr, .c_ok, .c_data, .h_cs, .h_addr, .h_ok, .h_data,
    .p_cs, .p_addr, .p_ok, .p_data, .ctl(8'd0),
    .DDRAM_BUSY(busy), .DDRAM_BURSTCNT(bc), .DDRAM_ADDR(addr), .DDRAM_DIN(din), .DDRAM_BE(be),
    .DDRAM_WE(we), .DDRAM_RD(rd), .DDRAM_DOUT(dout), .DDRAM_DOUT_READY(dready), .dbg
);

// ---- SDRAM: a level cs and held address, ok a pulse SLAT clocks on; as
// gx_rom_port, the last NS granules fetched are held and answered in HLAT,
// and with DBL a fetch brings the granule's pair (addr ^ 1) too
localparam HLAT = 2, NS = 4;
localparam bit DBL = 1;
integer mn = 0, cn = 0, hn = 0, pn = 0;
reg [19:0] mh [0:NS-1], ch [0:NS-1], hh [0:NS-1], pfh [0:NS-1];
reg [NS-1:0] mv = 0, cv = 0, hv = 0, pv = 0;
integer mp = 0, cp = 0, hp = 0, pp = 0;
function automatic bit held(input [19:0] a, input [19:0] h [0:NS-1], input [NS-1:0] v);
    held = 0;
    for (int i = 0; i < NS; i++) if (v[i] && h[i] == a) held = 1;
endfunction
always @(posedge clk) begin
    m_ok <= 0; c_ok <= 0; h_ok <= 0;
    if (!m_cs || m_ok) mn <= 0;
    else if (mn == (held(20'(m_addr), mh, mv) ? HLAT : SLAT)) begin
        m_ok <= 1; m_data <= map[m_addr]; mn <= 0;
        if (!held(20'(m_addr), mh, mv)) begin
            mh[mp] <= 20'(m_addr); mv[mp] <= 1;
            if (DBL) begin mh[(mp + 1) % NS] <= 20'(m_addr) ^ 20'd1; mv[(mp + 1) % NS] <= 1; end
            mp <= (mp + (DBL ? 2 : 1)) % NS;
        end
    end else mn <= mn + 1;
    if (!c_cs || c_ok) cn <= 0;
    else if (cn == (held(c_addr, ch, cv) ? HLAT : SLAT)) begin
        c_ok <= 1; c_data <= crom[c_addr]; cn <= 0;
        if (!held(c_addr, ch, cv)) begin
            ch[cp] <= c_addr; cv[cp] <= 1;
            if (DBL) begin ch[(cp + 1) % NS] <= c_addr ^ 20'd1; cv[(cp + 1) % NS] <= 1; end
            cp <= (cp + (DBL ? 2 : 1)) % NS;
        end
    end else cn <= cn + 1;
    if (!h_cs || h_ok) hn <= 0;
    else if (hn == (held(h_addr, hh, hv) ? HLAT : SLAT)) begin
        h_ok <= 1; h_data <= hrom[h_addr]; hn <= 0;
        if (!held(h_addr, hh, hv)) begin
            hh[hp] <= h_addr; hv[hp] <= 1;
            if (DBL) begin hh[(hp + 1) % NS] <= h_addr ^ 20'd1; hv[(hp + 1) % NS] <= 1; end
            hp <= (hp + (DBL ? 2 : 1)) % NS;
        end
    end else hn <= hn + 1;
    p_ok <= 0;
    if (!p_cs || p_ok) pn <= 0;
    else if (pn == (held(p_addr, pfh, pv) ? HLAT : SLAT)) begin
        p_ok <= 1; p_data <= hrom[p_addr]; pn <= 0;
        if (!held(p_addr, pfh, pv)) begin
            pfh[pp] <= p_addr; pv[pp] <= 1;
            if (DBL) begin pfh[(pp + 1) % NS] <= p_addr ^ 20'd1; pv[(pp + 1) % NS] <= 1; end
            pp <= (pp + (DBL ? 2 : 1)) % NS;
        end
    end else pn <= pn + 1;
end

// ---- DDR3: 2 buffers x 256 rows x 128 words, then the LRAM copy, by the address's low 17 bits
reg  [63:0] ddr [0:131071];
initial for (int i = 0; i < 131072; i++) ddr[i] = 64'hdead_beef_dead_beef;   // the store starts as junk
integer seed = 1;
always @(posedge clk) busy <= ($random(seed) & 7) == 0;
integer rq_n = 0, rq_lat = 0, wb_n = 0;
reg  [16:0] rq_a, wb_a;
always @(posedge clk) begin
    dready <= 0;
    if (rd && !busy) begin rq_a <= addr[16:0]; rq_n <= bc; rq_lat <= RLAT; end
    else if (rq_n != 0) begin
        if (rq_lat != 0) rq_lat <= rq_lat - 1;
        else begin dready <= 1; dout <= ddr[rq_a]; rq_a <= rq_a + 1; rq_n <= rq_n - 1; end
    end
    if (we && !busy) begin
        // a burst: the address on its first beat, the rest follow
        reg [16:0] a;
        a = wb_n == 0 ? addr[16:0] : wb_a;
        for (int k = 0; k < 8; k++) if (be[k]) ddr[a][8*k +: 8] <= din[8*k +: 8];
        if (wb_n == 0 && bc > 1) begin wb_n <= bc - 1; wb_a <= addr[16:0] + 1; end
        else if (wb_n != 0) begin wb_n <= wb_n - 1; wb_a <= wb_a + 1; end
    end
end

// ---- run: frames start at a vblank start once the last is finished; the
// third is drawn into a clean buffer (warm-up), and shown from the fourth's
// start to the next vblank start. out.hex is that buffer after it is drawn,
// shown.hex what the display gave for it
integer frames = 0, fd;
reg     drawn_b;
always @(posedge clk) begin
    if (uut.vbs && frames == 4) begin $fclose(fd); $display("T1_PSAC4_DONE"); $finish; end
    if (uut.go) begin
        frames <= frames + 1;
        if (frames == 3) begin
            // the buffer just drawn: fb toggles at this edge, and here it
            // still has its old value
            drawn_b = uut.fb;
            $display("frame 3 drawn: %0d clocks; fetches map %0d CROM %0d HROM %0d; P1 waited %0d, P2/PC %0d; texture fetch outstanding %0d; vblanks missed %0d",
                     dbg[15:0] * 32, dbg[33:16], dbg[51:34], dbg[69:52],
                     dbg[93:70], dbg[117:94], dbg[141:118], dbg[157:151]);
            fd = $fopen({dir, "/out.hex"}, "w");
            for (int y = VY0; y < VY0 + VA; y++)
                for (int w = 0; w < 96; w++)
                    for (int k = 0; k < 4; k++)
                        $fwrite(fd, "%04x\n", ddr[{ drawn_b, 8'(y), 7'(w) }][16*k +: 16]);
            // each parameter's lookup nibble
            for (int l = 0; l < 256; l++) $fwrite(fd, "%x\n", uut.ltab[{ drawn_b, 8'(l) }]);
            $fclose(fd);
            fd = $fopen({dir, "/shown.hex"}, "w");
        end
    end
end
// what the display gives in frame 4 (two clocks after rd_x)
reg [9:0] rx1, rx2;
always @(posedge clk) begin
    rx1 <= rd_x; rx2 <= rx1;
    if (frames == 4 && lvbl && rx2 >= 32 && rx2 < 416)
        $fwrite(fd, "%x %03x %02x\n", t_valid, t_pen, t_pri);
end

endmodule
