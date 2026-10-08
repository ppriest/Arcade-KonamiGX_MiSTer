// SPDX-License-Identifier: GPL-3.0-or-later
// The 128 MB SDRAM module: two 64 MB chips (13 row, 10 column, 4 bank bits)
// on one bus, SDRAM_nCS low selecting the first and high the second, as
// rtl/memory/sdram/sdram.sv drives it after Arcade-PsikyoSH2_MiSTer's sdram1.sv
// (the module's wiring itself is not checked here). Each chip is
// sdram_chip_model_wide.sv's command decoder with a 10-bit column and a select.
module sdram_chip_model_128 (
	input  logic         clk,
	inout  wire  [15:0] SDRAM_DQ,
	input  logic [12:0] SDRAM_A,
	input  logic  [1:0] SDRAM_BA,
	input  logic         SDRAM_nCS,
	input  logic         SDRAM_nWE,
	input  logic         SDRAM_nRAS,
	input  logic         SDRAM_nCAS
);
	sdram_chip_model_64 #(.SEL(1'b0)) u_c0 (.*);
	sdram_chip_model_64 #(.SEL(1'b1)) u_c1 (.*);
endmodule

module sdram_chip_model_64 #(
	parameter bit SEL = 1'b0     // the SDRAM_nCS level that selects this chip
) (
	input  logic         clk,

	inout  wire  [15:0] SDRAM_DQ,
	input  logic [12:0] SDRAM_A,
	input  logic  [1:0] SDRAM_BA,
	input  logic         SDRAM_nCS,
	input  logic         SDRAM_nWE,
	input  logic         SDRAM_nRAS,
	input  logic         SDRAM_nCAS
);

	localparam logic [2:0] CMD_NOP          = 3'b111;
	localparam logic [2:0] CMD_ACTIVE       = 3'b011;
	localparam logic [2:0] CMD_READ         = 3'b101;
	localparam logic [2:0] CMD_WRITE        = 3'b100;
	localparam logic [2:0] CMD_PRECHARGE    = 3'b010;
	localparam logic [2:0] CMD_AUTO_REFRESH = 3'b001;
	localparam logic [2:0] CMD_LOAD_MODE    = 3'b000;

	wire [2:0] cmd = SDRAM_nCS == SEL ? {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} : CMD_NOP;
	int writes = 0, refreshes = 0;   // for the bench: what reached this chip
	always @(posedge clk) begin
		if (cmd == CMD_WRITE) writes <= writes + 1;
		if (cmd == CMD_AUTO_REFRESH) refreshes <= refreshes + 1;
	end

	// {bank[1:0], row[12:0], col[9:0]}: 32M words, one 64 MB chip
	logic [15:0] mem [0:33554431];

	function automatic int unsigned addr_of(input logic [1:0] bank, input logic [12:0] row, input logic [9:0] col);
		addr_of = {bank, row, col};
	endfunction

	// [GX] four banks, as the chip has and as {bank, row, col} above says: with two,
	// an access above 16 MB (bank 2 or 3) indexed past the array -- ModelSim read
	// the open row as X, so the whole bank collapsed onto one row, while Verilator
	// wrapped the index and agreed with itself.
	logic [12:0] open_row [0:3];
	logic [12:0] mode_reg;
	wire  [2:0] cas_latency_field  = mode_reg[6:4];
	wire  [2:0] burst_length_field = mode_reg[2:0];
	wire  [4:0] burst_words        = 5'd1 << burst_length_field;   // 0=1,1=2,2=4,3=8

	typedef enum logic [1:0] {R_IDLE, R_WAIT_CAS, R_DRIVE} rstate_t;
	rstate_t rstate = R_IDLE;
	int          rcount;
	logic [9:0] rcol;
	logic [1:0] rbank;
	int          rburst_left;

	logic         driving;
	logic [15:0] drive_word;

	assign SDRAM_DQ = driving ? drive_word : 16'bz;

	always_ff @(posedge clk) begin
		int unsigned widx;

		driving <= 1'b0;

		unique case (rstate)
			R_IDLE: ; // started by CMD_READ below
			R_WAIT_CAS: begin
				if (rcount <= 0) begin
					rstate      <= R_DRIVE;
					driving     <= 1'b1;
					widx        = addr_of(rbank, open_row[rbank], rcol);
					drive_word  <= mem[widx];
					rburst_left <= rburst_left - 1;
					rcol        <= rcol + 10'd1;
				end else begin
					rcount <= rcount - 1;
				end
			end
			R_DRIVE: begin
				if (rburst_left > 0) begin
					driving     <= 1'b1;
					widx        = addr_of(rbank, open_row[rbank], rcol);
					drive_word  <= mem[widx];
					rburst_left <= rburst_left - 1;
					rcol        <= rcol + 10'd1;
				end else begin
					rstate <= R_IDLE;
				end
			end
		endcase

		// after the burst in progress: a READ during a burst starts the new one
		// (a read-to-read at the burst's end, sdram.sv's double read, runs on
		// without a gap), so its column and length must win
		unique case (cmd)
			CMD_ACTIVE:    open_row[SDRAM_BA] <= SDRAM_A;
			CMD_LOAD_MODE: mode_reg <= SDRAM_A;
			CMD_WRITE: begin
				widx = addr_of(SDRAM_BA, open_row[SDRAM_BA], SDRAM_A[9:0]);
				if (!SDRAM_A[11]) mem[widx][7:0]  <= SDRAM_DQ[7:0];
				if (!SDRAM_A[12]) mem[widx][15:8] <= SDRAM_DQ[15:8];
			end
			CMD_READ: begin
				rstate      <= R_WAIT_CAS;
				rcount      <= int'(cas_latency_field) - 2;
				rcol        <= SDRAM_A[9:0];
				rbank       <= SDRAM_BA;
				rburst_left <= int'(burst_words);
			end
			default: ; // NOP / PRECHARGE / AUTO_REFRESH: nothing to model
		endcase
	end

endmodule
