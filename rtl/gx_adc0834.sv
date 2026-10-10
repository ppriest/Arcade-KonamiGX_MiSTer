// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ADC0834 serial A/D converter of the Type 1 board (docs/TYPE1.md):
// Racin' Force's steering (channel 0) and gas pedal (channel 1), from MAME's
// adc083x.cpp. The CPU drives CLK, DI and CS as bits of one port write
// (0xdda000 bits 24-26) and reads DO (0xddc000 bit 24).
//
// One write is MAME's three line callbacks in its field order, CLK, then DI,
// then CS: a CLK edge acts on the DI and CS of before the write.
//
// The conversion is the channel's value as it is: MAME's 5 * v / 255 scaled
// back by 255 / 5 in doubles. Channels 2 and 3 read 0, as MAME's callback.

module gx_adc0834 (
    input            clk,
    input            rst,
    input            we,             // a write of the port
    input      [2:0] d,              // { CS, DI, CLK }
    input      [7:0] ch0,
    input      [7:0] ch1,
    output reg       dout
);

localparam [2:0] S_IDLE = 0, S_START = 1, S_MUX = 2, S_SETTLE = 3, S_MSB = 4, S_SE = 5, S_LSB = 6, S_DONE = 7;

reg  [2:0] st;
reg        cs = 1'b1, clk_l = 1'b0, di = 1'b0;
reg        sgl, odd, sel1;
reg  [1:0] bitn;
reg  [3:0] obit;                     // MSB first 7..0, then LSB first 1..7
reg  [7:0] out;

// conversion(): CH0 + odd + 2 * sel1, differential against its pair unless SGL
function automatic [7:0] chan( input [1:0] n );
    chan = n == 2'd0 ? ch0 : n == 2'd1 ? ch1 : 8'd0;
endfunction
wire [1:0] pos = { sel1, odd };
wire [8:0] diff = { 1'b0, chan(pos) } - (sgl ? 9'd0 : { 1'b0, chan(pos ^ 2'd1) });
wire [7:0] conv = diff[8] ? 8'd0 : diff[7:0];

always @(posedge clk) begin
    if( rst ) begin
        st <= S_IDLE; cs <= 1'b1; clk_l <= 1'b0; di <= 1'b0; dout <= 1'b1;
    end else if( we ) begin
        // clk_write
        if( !cs ) begin
            if( !clk_l && d[0] ) begin
                case( st )
                    S_START: if( di ) begin st <= S_MUX; sgl <= 0; odd <= 0; sel1 <= 0; bitn <= 0; end
                    S_MUX: begin
                        case( bitn )
                            2'd0: if( di ) sgl  <= 1'b1;
                            2'd1: if( di ) odd  <= 1'b1;
                            2'd2: if( di ) sel1 <= 1'b1;
                            default: ;
                        endcase
                        bitn <= bitn + 2'd1;
                        if( bitn == 2'd2 ) st <= S_SETTLE;     // three mux bits on the 0834
                    end
                    S_SE: begin st <= S_LSB; obit <= 4'd1; end
                    default: ;
                endcase
            end
            if( clk_l && !d[0] ) begin
                case( st )
                    S_SETTLE: begin out <= conv; st <= S_MSB; obit <= 4'd7; dout <= 1'b0; end
                    S_MSB: begin
                        dout <= out[obit[2:0]];
                        if( obit == 4'd0 ) st <= S_SE; else obit <= obit - 4'd1;
                    end
                    S_LSB: begin
                        dout <= out[obit[2:0]];
                        if( obit == 4'd7 ) st <= S_DONE; else obit <= obit + 4'd1;
                    end
                    S_DONE: begin st <= S_IDLE; dout <= 1'b0; end
                    default: ;
                endcase
            end
        end
        clk_l <= d[0];
        // di_write
        di <= d[1];
        // cs_write
        if( !cs && d[2] ) begin st <= S_IDLE; dout <= 1'b1; end
        if( cs && !d[2] ) begin st <= S_START; dout <= 1'b1; end
        cs <= d[2];
    end
end

endmodule
