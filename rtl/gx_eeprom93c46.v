/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 93C46 serial EEPROM, 64 x 16 bits (MAME EEPROM_93C46_16BIT), as MAME's
 * eeprom_serial_base_device / eeprom_serial_93cxx_device behave -- that is
 * the reference the game's boot is compared against, and the game polls DO
 * through the status byte at 0xd5a003.
 *
 *   IN_RESET          until CS rises
 *   WAIT_FOR_START    DO = 1 ("ready"); a rising CLK with DI = 1 starts a command
 *   WAIT_FOR_COMMAND  2 opcode + 6 address bits, on rising CLK
 *   READING_DATA      DO starts at the dummy 0; each rising CLK shifts: the first
 *                     loads the word (MSB first), later ones shift in 1s
 *   WAIT_FOR_DATA     16 data bits on rising CLK, then the write happens
 *   WAIT_FOR_COMPLETION  until CS falls
 *   CS falling always returns to IN_RESET. DO is 1 in every state but
 *   READING_DATA (tristate with a pull-up).
 *
 * Commands (93Cxx decode): 10 READ, 01 WRITE, 11 ERASE, 00 + top address
 * bits 00 LOCK, 01 WRITEALL, 10 ERASEALL, 11 UNLOCK. Writes and erases are
 * refused while locked; the part powers up locked, as MAME's does.
 *
 * BUSY, as MAME's eeprom_base_device: a WRITE, ERASE, WRITEALL or ERASEALL
 * that goes through holds the part busy for MAME's default times (the
 * driver sets none): 1.75 ms, 1 ms, 8 ms and 8 ms. While busy, DO reads 0 in
 * WAIT_FOR_START (MAME's do_read gives ready there) and a start bit is
 * ignored. The model answered ready at once before. This did not fix Dragoon
 * Might's settings save ("EEPROM CHECKSUM ERROR", README known issues).
 *
 * The contents are the 128-byte image MAME saves in nvram/<set>/eeprom, big
 * endian words: load_we/load_addr/load_data write it (the .mra's default
 * image, then the saved .nvm), rd_addr/rd_data read it back for the save,
 * and `written` pulses when a command changes it.
 *
 * The array is a RAM, one write a clock: a WRITEALL or ERASEALL fills it
 * a word a clock (64 clocks of its 8 ms busy time). Reads come a clock after
 * the address: the chip's on port A (its address held from the command),
 * the save's and the save state's on port B.
 */

module gx_eeprom93c46 #(
    parameter CLK_KHZ = 48000       // clk, for the busy times
) (
    input             rst,
    input             blank,         // sweep the array to all ones
    input             clk,
    input             cs,
    input             sk,        // CLK
    input             di,
    output            dout,

    output     [63:0] dbg,           // { 48'b0, 6'b0, sweep, locked, st }: the probe
    input             load_we,   // image load, one word
    input      [ 5:0] load_addr,
    input      [15:0] load_data,
    input      [ 5:0] rd_addr,       // the save's read port
    output     [15:0] rd_data,
    output reg        written,       // a WRITE, ERASE, WRITEALL or ERASEALL changed the array

    // save states (gx_savestate): the 64 words, then the serial state
    input             ss_snap,
    input             ss_commit,
    input             ss_sel,
    input      [11:0] ss_addr,
    input             ss_we,
    input      [15:0] ss_wd,
    output     [15:0] ss_rd
);

localparam [2:0] S_RESET = 0, S_START = 1, S_CMD = 2, S_READ = 3, S_DATA = 4, S_DONE = 5;

// port B: the NVRAM save's, or the save state's (never both at once)
wire [5:0] ra = ss_sel && ss_addr < 12'd64 ? ss_addr[5:0] : rd_addr;
// the array: port A the chip's, written through the mux below; port B read
reg         m_we;
reg  [ 5:0] m_a;
reg  [15:0] m_d;
wire [15:0] m_qa, m_qb;
gx_tdpram #(.AW(6), .DW(16)) u_mem (
    .clk(clk), .we_a(m_we), .a(m_a), .d(m_d), .qa(m_qa), .b(ra), .qb(m_qb)
);
reg         fill;           // WRITEALL / ERASEALL in progress
reg  [ 5:0] fill_n;
reg  [15:0] fill_v;
reg         c_we;           // a single WRITE or ERASE from the command
reg  [ 5:0] c_a;
reg  [15:0] c_d;
// Blank (all ones, a new part) while `blank` is high: a sweep writes every
// word, because the array's power-up contents are not defined (as registers,
// which it once was, the fitter chose them), and a game whose EEPROM check only
// reads failed it on the board while Verilator, which honours an initial
// value, passed. The sweep free-runs while blank is high, so it needs no
// power-up value of its own. The top holds blank from configuration until
// the ROM download starts, and the set's default image (MAME's "eeprom"
// region, ioctl index 2) is loaded during the download; the benches hold
// it through rst and load after.
reg  [5:0]  sweep;
reg  [ 2:0] st;
reg         cs_l, sk_l, locked;
reg  [ 7:0] cmd;
reg  [ 4:0] nbits;
reg  [31:0] shreg;
reg  [ 5:0] addr;
reg  [ 1:0] op;           // 0 read, 1 write, 2 writeall
localparam [19:0] T_WRITE = CLK_KHZ * 1750 / 1000, T_ERASE = CLK_KHZ * 1, T_ALL = CLK_KHZ * 8;
reg  [19:0] busy;         // clocks until ready
wire        ready = busy == 20'd0;

assign dout = st == S_READ ? shreg[31] : st == S_START ? ready : 1'b1;

wire cs_rise = cs && !cs_l, cs_fall = !cs && cs_l;
wire sk_rise = sk && !sk_l;
wire [7:0] cmd_n = { cmd[6:0], di };

assign rd_data = m_qb;

// port A's write, one source a clock
always @* begin
    m_we = 1'b1;
    m_a  = addr;
    m_d  = 16'hffff;
    if( blank )                                   begin m_a = sweep; end
    else if( load_we )                            begin m_a = load_addr; m_d = load_data; end
    else if( ss_sel && ss_we && ss_addr < 12'd64 ) begin m_a = ss_addr[5:0]; m_d = ss_wd; end
    else if( fill )                               begin m_a = fill_n; m_d = fill_v; end
    else if( c_we )                               begin m_a = c_a; m_d = c_d; end
    else                                          m_we = 1'b0;
end

// save states
wire [78:0] ss_q;
wire [15:0] ss_vrd;
reg         ss_m;
always @(posedge clk) ss_m <= ss_sel && ss_addr < 12'd64;
gx_ss_vec #(.W(79)) u_ss (
    .clk(clk), .snap(ss_snap), .d({ st, cs_l, sk_l, locked, cmd, nbits, shreg, addr, op, busy }), .q(ss_q),
    .sel(ss_sel && ss_addr >= 12'd64), .addr(ss_addr[9:0] - 10'd64), .we(ss_we), .wd(ss_wd), .rd(ss_vrd)
);
assign ss_rd = ss_m ? m_qb : ss_vrd;
always @(posedge clk) begin
    written <= 1'b0;
    c_we    <= 1'b0;
    if( !ready ) busy <= busy - 20'd1;
    if( blank ) sweep <= sweep + 6'd1;
    if( fill && !blank && !load_we && !(ss_sel && ss_we && ss_addr < 12'd64) ) begin
        fill_n <= fill_n + 6'd1;
        if( fill_n == 6'd63 ) fill <= 1'b0;
    end
    if( rst ) begin
        fill   <= 0;
        st     <= S_RESET;
        cs_l   <= 0;
        sk_l   <= 0;
        locked <= 1;
        busy   <= 20'd0;
    end else begin
        cs_l <= cs;
        sk_l <= sk;
        if( cs_fall ) st <= S_RESET;
        else case( st )
            S_RESET: if( cs_rise ) st <= S_START;
            // MAME ignores a CLK edge at the same moment as the CS rise
            S_START: if( sk_rise && di && !cs_rise && ready ) begin
                cmd <= 0; nbits <= 0; st <= S_CMD;
            end
            S_CMD: if( sk_rise ) begin
                cmd   <= cmd_n;
                nbits <= nbits + 5'd1;
                if( nbits == 5'd7 ) begin
                    nbits <= 0;
                    addr  <= cmd_n[5:0];
                    case( cmd_n[7:6] )
                        2'b10: begin shreg <= 0; st <= S_READ; end          // READ
                        2'b01: begin shreg <= 0; op <= 1; st <= S_DATA; end // WRITE
                        2'b11: begin                                          // ERASE
                            if( !locked ) begin c_we <= 1'b1; c_a <= cmd_n[5:0]; c_d <= 16'hffff; written <= 1'b1; busy <= T_ERASE; end
                            st <= locked ? S_RESET : S_DONE;
                        end
                        default: case( cmd_n[5:4] )
                            2'b00: begin locked <= 1; st <= S_DONE; end       // LOCK
                            2'b01: begin shreg <= 0; op <= 2; st <= S_DATA; end // WRITEALL
                            2'b10: begin                                      // ERASEALL
                                if( !locked ) begin
                                    fill <= 1'b1; fill_n <= 6'd0; fill_v <= 16'hffff;
                                    written <= 1'b1;
                                    busy    <= T_ALL;
                                end
                                st <= locked ? S_RESET : S_DONE;
                            end
                            default: begin locked <= 0; st <= S_DONE; end     // UNLOCK
                        endcase
                    endcase
                end
            end
            S_READ: if( sk_rise ) begin
                nbits <= nbits + 5'd1;
                shreg <= nbits == 5'd0 ? { m_qa, 16'hffff } : { shreg[30:0], 1'b1 };
            end
            S_DATA: if( sk_rise ) begin
                shreg <= { shreg[30:0], di };
                nbits <= nbits + 5'd1;
                if( nbits == 5'd15 ) begin
                    if( !locked ) begin
                        if( op == 2'd2 ) begin fill <= 1'b1; fill_n <= 6'd0; fill_v <= { shreg[14:0], di }; end
                        else begin c_we <= 1'b1; c_a <= addr; c_d <= { shreg[14:0], di }; end
                        written <= 1'b1;
                        busy    <= op == 2'd2 ? T_ALL : T_WRITE;
                    end
                    st <= locked ? S_RESET : S_DONE;
                end
            end
            default: ;          // S_DONE: until CS falls
        endcase
    end
    if( ss_commit ) { st, cs_l, sk_l, locked, cmd, nbits, shreg, addr, op, busy } <= ss_q;
end

assign dbg = { 48'd0, 6'd0, sweep, locked, st };

endmodule
