// Formal harness for pcie_requester's tag allocator. The harness keeps its own
// view of which tags are outstanding, from the TLPs on the wire and PCIe rules,
// and checks the requester against it:
//   - no MRd is sent on a tag that is still outstanding;
//   - every completion the requester accepts belongs to an outstanding tag of
//     this requester.
// The open set is updated from the registered status/accepted pulses, one
// cycle after the requester clears the tag; that only makes the no-reuse check
// stricter, because a tag cannot be reissued within three cycles.
// A tag is outstanding from its MRd until a successful completion whose
// byte count covers the rest of the request (the final completion) or a
// completion with an error status. A tag the requester quarantined (timeout or
// malformed completion) stays outstanding until drain_reset, because late
// completions may still arrive. Completion inputs are otherwise unconstrained.
`ifdef FORMAL
module pcie_requester_formal(
  input logic clk, rst,
  input logic [15:0] cfg_requester_id, input logic cfg_bus_master_enable, cfg_rcb128,
  input logic [63:0] aperture_base, input logic four_tag, drain_reset,
  input logic rd_valid, input logic [31:0] rd_address, input logic [7:0] rd_bytes,
  input logic wr_valid, input logic [31:0] wr_address, input logic [7:0] wr_bytes, input logic [1023:0] wr_data,
  input logic w_ready, r_ready,
  input logic c_valid, input logic [31:0] c_data, input logic c_sop, c_eop
);
  logic rd_ready, rd_done, wr_ready, wr_done, w_valid, w_sop, w_eop, r_valid, r_sop, r_eop, c_ready, busy;
  logic [1:0] rd_status, wr_status;
  logic [1023:0] rd_data;
  logic [31:0] w_data, r_data;
  logic [3:0] active, quarantined;
  logic [2:0] max_active;
  logic unexpected_pulse, late_pulse, malformed_pulse, poisoned_pulse, status_pulse, timeout_pulse, translation_pulse;
  logic accepted_pulse, write_request_pulse, read_request_pulse;

  // Short completion timeout so the timeout/quarantine path is reachable in a
  // few steps; the logic is the same for any TIMEOUT.
  pcie_requester #(.TIMEOUT(8)) dut(.*);

  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (rst);
  // Configuration is static while the link is up.
  always_ff @(posedge clk) if (past_valid && !rst) assume ($stable(cfg_requester_id) && $stable(four_tag) && $stable(cfg_rcb128));

  // ------------------------------------------- MRd requests on the r stream
  logic [2:0] r_beat;
  wire r_hs = r_valid && r_ready;
  always_ff @(posedge clk)
    if (rst) r_beat <= 0;
    else if (r_hs) r_beat <= r_eop ? 3'd0 : r_beat + 3'd1;
  wire mrd_tag_beat = r_hs && r_beat == 3'd1;     // header DW1 carries the tag
  wire [1:0] mrd_tag = r_data[9:8];

  // --------------------------------------------- completions on the c stream
  logic [2:0] c_beat;            // 0..2 header DWs, 3 = data
  logic [9:0] h_len; logic [2:0] h_status; logic [11:0] h_bc;
  logic [15:0] h_rid; logic [1:0] h_tag; logic [6:0] h_la;
  logic cpl_done; logic [1:0] cpl_tag; logic cpl_final, cpl_err, cpl_ours;
  wire c_hs = c_valid && c_ready;
  wire [9:0] span_now = {h_len, 2'b00} - {8'b0, h_la[1:0]};
  always_ff @(posedge clk) begin
    if (rst) begin c_beat <= 0; cpl_done <= 0; end
    else begin
      cpl_done <= 0;
      if (c_hs) begin
        case (c_beat)
          3'd0: if (c_sop && !c_eop) begin h_len <= c_data[9:0]; c_beat <= 1; end
          3'd1: begin h_status <= c_data[15:13]; h_bc <= c_data[11:0]; c_beat <= c_eop ? 3'd0 : 3'd2; end
          3'd2: begin h_rid <= c_data[31:16]; h_tag <= c_data[9:8]; h_la <= c_data[6:0]; c_beat <= c_eop ? 3'd0 : 3'd3;
                      if (c_eop) begin cpl_done <= 1; cpl_tag <= c_data[9:8]; cpl_ours <= c_data[31:16] == cfg_requester_id;
                        cpl_err <= h_status != 0; cpl_final <= 1'b0; end end
          default: if (c_eop) begin c_beat <= 0; cpl_done <= 1; cpl_tag <= h_tag; cpl_ours <= h_rid == cfg_requester_id;
                      cpl_err <= h_status != 0; cpl_final <= {10'b0, h_bc} <= {12'b0, span_now}; end
        endcase
      end
    end
  end

  // ------------------------------------------------- outstanding-tag model
  logic [3:0] open;
  always_ff @(posedge clk) begin
    if (rst) open <= 0;
    else begin
      logic [3:0] next;
      next = open;
      // the requester accepted the final completion of the request: the tag is
      // done (a poisoned completion still completes it; only its data is bad)
      if (accepted_pulse && cpl_final && !quarantined[cpl_tag]) next[cpl_tag] = 1'b0;
      // an error-status completion for an active tag ends the request
      if (status_pulse) next[h_tag] = 1'b0;   // tag from the header beat that triggered it
      // drain_reset: quarantined tags may be reused (no completion in flight)
      if (drain_reset) next = next & active;
      if (mrd_tag_beat) next[mrd_tag] = 1'b1;
      open <= next;
    end
  end

  // drain_reset is the system's drain guarantee (README, "Not tested or
  // limited"): no completion is in flight, including one part-way through.
  always_comb if (drain_reset) assume (!c_valid && c_beat == 3'd0);

  // ------------------------------------------- completer assumption
  // A completion carrying our requester ID names a tag that is either fully
  // outstanding (its MRd is on the link) or not active at all. This excludes
  // only a stray completion for a tag whose new MRd is still being sent: the
  // case the README lists as undetectable at the transaction layer, since the
  // requester marks the tag active on the first MRd beat
  // (pcie_requester.sv:150). Foreign IDs, inactive and quarantined (late)
  // tags remain unconstrained.
  always_comb if (c_valid && c_beat == 3'd2 && c_data[31:16] == cfg_requester_id && c_data[15:10] == 0)
    assume (open[c_data[9:8]] || !active[c_data[9:8]]);

  // ------------------------------------------------------------- checks
  always_ff @(posedge clk) if (past_valid && !$past(rst) && !rst) begin
    // No tag is reused while it is outstanding.
    if (mrd_tag_beat) ap_no_tag_reuse: assert (!open[mrd_tag]);
    // TX framing: an MRd that has started (sop accepted) ends with eop before
    // the next one starts.
    if (r_valid && r_sop) ap_mrd_framing: assert (r_beat == 3'd0);
    // Single-tag mode only ever uses tag 0.
    if (mrd_tag_beat && !four_tag) ap_single_tag: assert (mrd_tag == 2'd0);
    // Every completion the requester accepts belongs to an outstanding tag of ours.
    if (accepted_pulse) ap_cpl_matches_open_tag: assert (cpl_done && open[cpl_tag] && cpl_ours);
  end

  always_ff @(posedge clk) if (past_valid && !rst) begin
    cp_two_tags_open: cover (open[0] && open[1]);
    cp_completion_accepted: cover (accepted_pulse);
    cp_quarantine: cover (quarantined != 0);
    cp_reuse_after_completion: cover (mrd_tag_beat && $past(accepted_pulse, 2));
  end
endmodule
`endif
