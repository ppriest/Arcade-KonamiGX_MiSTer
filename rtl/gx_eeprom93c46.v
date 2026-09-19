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
 * NOT MODELLED: the write/erase busy time. MAME's ready() is modelled as
 * always true. Unverified against MAME's timing parameters.
 *
 * The contents are the 128-byte image MAME saves in nvram/<set>/eeprom, big
 * endian words; load_we/load_addr/load_data write it (the ioctl path later).
 */

module gx_eeprom93c46 (
    input             rst,
    input             blank,         // sweep the array to all ones
    input             clk,
    input             cs,
    input             sk,        // CLK
    input             di,
    output            dout,

    output     [63:0] dbg,           // { mem[63], mem[1], mem[0], 6'b0, sweep, locked, st }: the probe
    input             load_we,   // image load, one word
    input      [ 5:0] load_addr,
    input      [15:0] load_data
);

localparam [2:0] S_RESET = 0, S_START = 1, S_CMD = 2, S_READ = 3, S_DATA = 4, S_DONE = 5;

reg  [15:0] mem [0:63];
// Blank (all ones, a new part) while `blank` is high: a sweep writes every
// word, because the array is built as registers whose power-up value the
// fitter may choose (Power-Up Don't Care), and a game whose EEPROM check only
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

assign dout = st == S_READ ? shreg[31] : 1'b1;

wire cs_rise = cs && !cs_l, cs_fall = !cs && cs_l;
wire sk_rise = sk && !sk_l;
wire [7:0] cmd_n = { cmd[6:0], di };

integer i;
always @(posedge clk) begin
    if( blank ) begin
        sweep <= sweep + 6'd1;
        mem[sweep] <= 16'hffff;
    end
    if( load_we ) mem[load_addr] <= load_data;
    if( rst ) begin
        st     <= S_RESET;
        cs_l   <= 0;
        sk_l   <= 0;
        locked <= 1;
    end else begin
        cs_l <= cs;
        sk_l <= sk;
        if( cs_fall ) st <= S_RESET;
        else case( st )
            S_RESET: if( cs_rise ) st <= S_START;
            // MAME ignores a CLK edge at the same moment as the CS rise
            S_START: if( sk_rise && di && !cs_rise ) begin
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
                            if( !locked ) mem[cmd_n[5:0]] <= 16'hffff;
                            st <= locked ? S_RESET : S_DONE;
                        end
                        default: case( cmd_n[5:4] )
                            2'b00: begin locked <= 1; st <= S_DONE; end       // LOCK
                            2'b01: begin shreg <= 0; op <= 2; st <= S_DATA; end // WRITEALL
                            2'b10: begin                                      // ERASEALL
                                if( !locked ) for( i=0; i<64; i=i+1 ) mem[i] <= 16'hffff;
                                st <= locked ? S_RESET : S_DONE;
                            end
                            default: begin locked <= 0; st <= S_DONE; end     // UNLOCK
                        endcase
                    endcase
                end
            end
            S_READ: if( sk_rise ) begin
                nbits <= nbits + 5'd1;
                shreg <= nbits == 5'd0 ? { mem[addr], 16'hffff } : { shreg[30:0], 1'b1 };
            end
            S_DATA: if( sk_rise ) begin
                shreg <= { shreg[30:0], di };
                nbits <= nbits + 5'd1;
                if( nbits == 5'd15 ) begin
                    if( !locked ) begin
                        if( op == 2'd2 ) for( i=0; i<64; i=i+1 ) mem[i] <= { shreg[14:0], di };
                        else mem[addr] <= { shreg[14:0], di };
                    end
                    st <= locked ? S_RESET : S_DONE;
                end
            end
            default: ;          // S_DONE: until CS falls
        endcase
    end
end

assign dbg = { mem[63], mem[1], mem[0], 6'd0, sweep, locked, st };

endmodule
