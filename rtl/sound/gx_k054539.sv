// SPDX-License-Identifier: GPL-3.0-or-later
//
// K054539 for Phase 3a: what the sound CPU needs of the chip before any
// audio -- its register file, its timer (chip 1's is the sound CPU's IRQ 2)
// and the 0x22d/0x22e port through which the CPU reads the sample ROM and
// reads and writes the chip's own RAM. MAME's k054539.cpp:
//
//   every write lands in the register file, and a read returns it, except:
//   0x227 write  timer period: a square wave of (38 + n) * clock/384/14400
//                Hz, restarted, output low
//   0x22f write  bit 5 clear: output low (the timer only toggles while set)
//   0x22e write  rom_addr = n, pointer = 0
//   0x22d write  rom_addr == 0x80: the byte into the RAM; pointer + 1
//   0x22d read   0x22f bit 4 set: the sample ROM's byte at
//                0x20000 * rom_addr + pointer, or the RAM's when rom_addr is
//                0x80; pointer + 1. Otherwise 0.
//
// The RAM address from the pointer is (p & 0x3fff) | ((p & 0x10000) >> 2),
// 32 KB. Both RAM and ROM are in SDRAM (docs/ROADMAP.md: the block RAM left
// would not hold two chips' RAM with the CPU's), reached through m_*.
//
// Not here yet (3b): the voices, and 0x22c's channel-active bits, which the
// voices set and clear -- here 0x22c reads what was last written.

module gx_k054539 (
    input             clk,          // 48 MHz
    input             rst,

    input             cs,
    input             we,
    input      [10:0] addr,         // 0x000-0x4ff
    input      [ 7:0] din,
    output reg [ 7:0] dout,
    output reg        ack,          // one clock: the access is done

    output reg        timer_out,

    // the 0x22d port's byte, in SDRAM
    output reg        m_req,
    output reg        m_we,
    output reg        m_ram,        // 1: the chip's RAM, 0: the sample ROM
    output reg [21:0] m_addr,       // a byte of that space
    output reg [ 7:0] m_wdata,
    input             m_ack,
    input      [ 7:0] m_rdata
);

// ---------------------------------------------------------------- registers
reg  [7:0] regs [0:2047];
reg  [7:0] rq;
reg  [7:0] r22f, rom_addr;
reg [16:0] cur_ptr;

wire [14:0] ram_a = { cur_ptr[16], cur_ptr[13:0] };   // (p & 0x3fff) | ((p & 0x10000) >> 2)

// ---------------------------------------------------------------- timer
// Toggles every 7,200,000 / (38 + n) clocks of 48 MHz: an accumulator gains
// (38 + n) a clock and toggles each time it passes 7,200,000, which is the
// exact period on average without a divider.
localparam [23:0] TPER = 24'd7_200_000;
reg  [ 8:0] tstep;
reg  [23:0] tacc;
reg         t_run;

typedef enum logic [1:0] { K_IDLE, K_RD, K_MEM } kst_t;
kst_t st;

always @(posedge clk) begin
    ack <= 1'b0;
    rq  <= regs[addr];
    if( rst ) begin
        st <= K_IDLE; m_req <= 1'b0; timer_out <= 1'b0; t_run <= 1'b0;
        tacc <= 24'd0; r22f <= 8'd0; rom_addr <= 8'd0; cur_ptr <= 17'd0;
    end else begin
        // the timer
        if( t_run ) begin
            if( tacc + { 15'd0, tstep } >= TPER ) begin
                tacc <= tacc + { 15'd0, tstep } - TPER;
                if( r22f[5] ) timer_out <= ~timer_out;
            end else tacc <= tacc + { 15'd0, tstep };
        end

        case( st )
        K_IDLE: if( cs ) begin
            if( we ) begin
                regs[addr] <= din;
                case( addr )
                    11'h227: begin tstep <= 9'd38 + { 1'b0, din }; tacc <= 24'd0;
                                   t_run <= 1'b1; timer_out <= 1'b0; end
                    11'h22f: begin r22f <= din; if( !din[5] ) timer_out <= 1'b0; end
                    11'h22e: begin rom_addr <= din; cur_ptr <= 17'd0; end
                    default: ;
                endcase
                if( addr == 11'h22d ) begin
                    if( rom_addr == 8'h80 ) begin
                        m_req <= 1'b1; m_we <= 1'b1; m_ram <= 1'b1;
                        m_addr <= { 7'd0, ram_a }; m_wdata <= din;
                        st <= K_MEM;
                    end else ack <= 1'b1;
                    cur_ptr <= cur_ptr + 17'd1;
                end else ack <= 1'b1;
            end else begin
                if( addr == 11'h22d ) begin
                    if( r22f[4] ) begin
                        m_req <= 1'b1; m_we <= 1'b0;
                        m_ram <= rom_addr == 8'h80;
                        m_addr <= rom_addr == 8'h80 ? { 7'd0, ram_a }
                                                    : { rom_addr[4:0], cur_ptr };
                        cur_ptr <= cur_ptr + 17'd1;
                        st <= K_MEM;
                    end else begin dout <= 8'd0; ack <= 1'b1; end
                end else st <= K_RD;          // the register file answers next clock
            end
        end
        K_RD:  begin dout <= rq; ack <= 1'b1; st <= K_IDLE; end
        K_MEM: if( m_ack ) begin
            m_req <= 1'b0;
            if( !m_we ) dout <= m_rdata;
            ack <= 1'b1; st <= K_IDLE;
        end
        default: st <= K_IDLE;
        endcase
    end
end

endmodule
