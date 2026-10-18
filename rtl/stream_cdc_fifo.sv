// Asynchronous FIFO for a ready/valid stream crossing between two unrelated
// clocks (Gray-code pointers, after Cummings, "Simulation and Synthesis
// Techniques for Asynchronous FIFO Design").
//
// Each side keeps a binary pointer one bit wider than the address and a Gray
// copy of it. Only the Gray pointers cross domains, each through a two-flop
// synchronizer; because a Gray pointer changes one bit per increment, the
// receiving side samples either the old or the new value, never a mix. The
// write side compares its pointer with the synchronized read pointer (full);
// the read side compares with the synchronized write pointer (empty). Both
// views lag the other side, so full and empty can only be pessimistic: the
// FIFO never overflows or underflows. The read port is first-word-fall-through.
//
// Resets are synchronous to their own clocks and must be asserted together
// (a system reset), so both sides start empty.
module stream_cdc_fifo #(
  parameter int WIDTH = 37,     // {last, keep[3:0], data[31:0]} for the 32-bit packet stream
  parameter int ADDR = 4        // 2**ADDR entries
)(
  input  logic             s_clk, s_rst,
  input  logic [WIDTH-1:0] s_data,
  input  logic             s_valid,
  output logic             s_ready,
  input  logic             m_clk, m_rst,
  output logic [WIDTH-1:0] m_data,
  output logic             m_valid,
  input  logic             m_ready
);
  localparam int DEPTH = 1 << ADDR;

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR:0] w_bin, w_gray, r_bin, r_gray;
  // Synchronizer stages: the other side's Gray pointer, two flops deep. The
  // attributes mark them for Quartus's metastability analysis and, with
  // ASYNC_REG, keep Vivado from separating or optimizing the two flops.
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS", ASYNC_REG = "TRUE" *) logic [ADDR:0] w_sync1, w_sync2;
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS", ASYNC_REG = "TRUE" *) logic [ADDR:0] r_sync1, r_sync2;

  function automatic logic [ADDR:0] to_gray(input logic [ADDR:0] b);
    return b ^ (b >> 1);
  endfunction

  // ------------------------------------------------------------ write side
  wire [ADDR:0] w_bin_next = w_bin + 1'b1;
  // Full when the write pointer is a whole lap ahead of the synchronized read
  // pointer: in Gray code, the top two bits differ and the rest are equal.
  wire full = w_gray == {~r_sync2[ADDR:ADDR-1], r_sync2[ADDR-2:0]};
  assign s_ready = !s_rst && !full;

  always_ff @(posedge s_clk) begin
    if (s_rst) begin
      w_bin <= '0; w_gray <= '0; r_sync1 <= '0; r_sync2 <= '0;
    end else begin
      r_sync1 <= r_gray; r_sync2 <= r_sync1;
      if (s_valid && s_ready) begin
        mem[w_bin[ADDR-1:0]] <= s_data;
        w_bin <= w_bin_next;
        w_gray <= to_gray(w_bin_next);
      end
    end
  end

  // ------------------------------------------------------------- read side
  wire [ADDR:0] r_bin_next = r_bin + 1'b1;
  wire empty = r_gray == w_sync2;
  assign m_valid = !m_rst && !empty;
  assign m_data = mem[r_bin[ADDR-1:0]];

  always_ff @(posedge m_clk) begin
    if (m_rst) begin
      r_bin <= '0; r_gray <= '0; w_sync1 <= '0; w_sync2 <= '0;
    end else begin
      w_sync1 <= w_gray; w_sync2 <= w_sync1;
      if (m_valid && m_ready) begin
        r_bin <= r_bin_next;
        r_gray <= to_gray(r_bin_next);
      end
    end
  end
endmodule
