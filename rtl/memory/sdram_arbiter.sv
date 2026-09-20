// N read clients, round-robin, onto one sdram.sv port, plus the ROM download
// write path at absolute priority. Moves 64-bit granules at 8-byte-aligned
// addresses.
//
// A client request is captured on its rising edge, so pulse and held clients
// share the arbiter, and a request arriving while the arbiter is idle is
// picked in the same cycle. c_valid is raised as the chip acknowledges and
// rdata is latched with it: sdram.sv's port outputs share one register.
//
// This drives the chip's port directly. It used to go through sdram_phy,
// which cost a cycle each way; three cycles of the sprite ROM's latency is
// the difference between the sprite scan finishing a line and not
// (docs/ROADMAP.md, sprite drawing time).

module sdram_arbiter #(
	parameter int N = 4
) (
	input  logic clk,
	input  logic reset,

	// sdram.sv port
	output logic [25:1] port_addr,
	output logic        port_wrl,
	output logic        port_wrh,
	output logic [15:0] port_din,
	input  logic [63:0] port_dout,
	output logic        port_req,
	input  logic        port_ack,

	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,     // shared; capture it on your own valid

	// download write path
	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE} state_t;
	state_t st;

	logic [$clog2(N)-1:0] rr_ptr;    // round-robin start point
	logic [$clog2(N)-1:0] serving;

	// set on c_req's rising edge, cleared when served; the edge itself is
	// picked without waiting for the register
	logic [N-1:0] pend, c_req_d, avail;
	assign avail = pend | (c_req & ~c_req_d);

	logic       have_pick;
	logic [$clog2(N)-1:0] pick;

	always_comb begin
		have_pick = 1'b0;
		pick      = rr_ptr;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_ptr) + k) % N;
			if (!have_pick && avail[idx]) begin
				have_pick = 1'b1;
				pick      = $bits(pick)'(idx);
			end
		end
	end

	logic [25:0] pick_addr;
	always_comb begin
		pick_addr = 26'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick)) pick_addr = c_addr[26*k +: 26];
	end

	logic [63:0] rdata_l;
	assign c_rdata = rdata_l;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st       <= S_IDLE;
			port_req <= 1'b0;
			c_valid  <= '0;
			dl_busy  <= 1'b0;
			rr_ptr   <= '0;
			serving  <= '0;
			pend     <= '0;
			c_req_d  <= '0;
		end else begin
			c_valid <= '0;

			// in every state, so a request during service is kept
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			case (st)
			S_IDLE: begin
				if (dl_req) begin
					port_addr <= dl_addr[25:1];
					port_wrl  <= dl_we16 || !dl_addr[0];
					port_wrh  <= dl_we16 ||  dl_addr[0];
					port_din  <= dl_we16 ? dl_data : {dl_data[7:0], dl_data[7:0]};
					port_req  <= ~port_req;
					dl_busy   <= 1'b1;
					st        <= S_WRITE;
				end else if (have_pick) begin
					port_addr <= pick_addr[25:1];
					port_wrl  <= 1'b0;
					port_wrh  <= 1'b0;
					port_req  <= ~port_req;
					serving   <= pick;
					pend      <= (pend | (c_req & ~c_req_d)) & ~(N'(1) << pick);
					st        <= S_READ;
				end
			end

			S_READ: begin
				if (port_ack == port_req) begin
					rdata_l <= port_dout;
					c_valid[serving] <= 1'b1;
					rr_ptr <= (int'(serving) == N-1) ? '0
					                                 : $bits(rr_ptr)'(int'(serving) + 1);
					st     <= S_IDLE;
				end
			end

			S_WRITE: begin
				if (port_ack == port_req) begin
					dl_busy <= 1'b0;
					st      <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
