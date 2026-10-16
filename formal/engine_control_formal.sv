// Formal harness for engine_control: the AXI-Lite slave and the ring counters.
// Every DUT input is left free except for the assumptions below. Properties
// are immediate assertions in clocked blocks (the yosys-slang frontend does not
// support concurrent SVA). Read with: read_slang -D FORMAL.
`ifdef FORMAL
module engine_control_formal(
  input logic clk, rst,
  input logic [63:0] tick, input logic quiescent, abort_done,
  input logic [63:0] drop_count [0:5],
  input logic [7:0] claim, commit, fault,
  input logic [3:0] fault_code [0:7],
  input logic [31:0] s_awaddr, input logic s_awvalid,
  input logic [31:0] s_wdata, input logic [3:0] s_wstrb, input logic s_wvalid,
  input logic s_bready,
  input logic [31:0] s_araddr, input logic s_arvalid,
  input logic s_rready
);
  logic [7:0] claim_ready, reserved, halted;
  logic [31:0] sq_base [0:7], cq_base [0:7], sq_producer [0:7], sq_consumer [0:7], cq_producer [0:7], cq_consumer [0:7];
  logic running, aborting, irq, notification_rearm;
  logic [31:0] epoch;
  logic fixed_mode, drop_on_full;
  logic [1:0] default_queue;
  logic [63:0] replay_start, replay_origin, replay_interval, queue_delay [0:3];
  logic [31:0] loss_seed;
  logic [32:0] loss_threshold;
  logic [4:0] rule_control [0:7];
  logic [31:0] rule_src [0:7], rule_src_mask [0:7], rule_dst [0:7], rule_dst_mask [0:7], rule_ports [0:7];
  logic s_awready, s_wready, s_bvalid, s_arready, s_rvalid;
  logic [1:0] s_bresp, s_rresp;
  logic [31:0] s_rdata;

  engine_control dut(.*);

  // ---------------------------------------------------------------- setup
  logic past_valid = 1'b0;
  always_ff @(posedge clk) past_valid <= 1'b1;
  always_comb if (!past_valid) assume (rst);

  // ------------------------------------------- AXI-Lite master assumptions
  // A master keeps VALID and the payload stable until the handshake. After a
  // handshake the address bus may change freely (AXI allows it).
  always_ff @(posedge clk) if (past_valid && !$past(rst)) begin
    if ($past(s_awvalid && !s_awready)) assume (s_awvalid && $stable(s_awaddr));
    if ($past(s_wvalid && !s_wready)) assume (s_wvalid && $stable(s_wdata) && $stable(s_wstrb));
    if ($past(s_arvalid && !s_arready)) assume (s_arvalid && $stable(s_araddr));
  end

  // ------------------------------------------------ environment assumption
  // engine_core: quiescent = !running && idle_all && queues_empty (engine_core.sv:50)
  // and packets are admitted only while running (admit, engine_core.sv:45).
  // capture_dma claims only for a non-empty queue (capture_dma.sv:34-36) and
  // replay_dma only while running (replay_dma.sv:57). So once the engine has
  // been seen stopped and quiescent, no worker claims a descriptor until RUN.
  // (A weaker "no claim while quiescent" lets quiescent drop with nothing
  // restarted, which the real engine cannot do; claim_eligible is registered,
  // so engine_control alone depends on this.)
  logic stopped_idle;
  always_ff @(posedge clk)
    if (rst) stopped_idle <= 1'b0;
    else if (running) stopped_idle <= 1'b0;
    else if (quiescent) stopped_idle <= 1'b1;
  always_comb if (quiescent || (stopped_idle && !running)) assume (claim == 8'b0);

  // ------------------------------------------------------ request tracking
  logic aw_pend, w_pend, r_pend;
  logic [31:0] ar_addr_cap;
  wire aw_hs = s_awvalid && s_awready, w_hs = s_wvalid && s_wready, b_hs = s_bvalid && s_bready;
  wire ar_hs = s_arvalid && s_arready, r_hs = s_rvalid && s_rready;
  always_ff @(posedge clk) begin
    if (rst) begin aw_pend <= 0; w_pend <= 0; r_pend <= 0; ar_addr_cap <= 0; end
    else begin
      if (aw_hs) aw_pend <= 1; else if (b_hs) aw_pend <= 0;
      if (w_hs) w_pend <= 1; else if (b_hs) w_pend <= 0;
      if (ar_hs) begin r_pend <= 1; ar_addr_cap <= s_araddr; end else if (r_hs) r_pend <= 0;
    end
  end


  // ------------------------------------------------- AXI-Lite slave checks
  always_ff @(posedge clk) if (past_valid && !$past(rst) && !rst) begin
    // Handshake stability: a response stays valid and unchanged until accepted.
    if ($past(s_bvalid && !s_bready)) ap_b_stable: assert (s_bvalid && $stable(s_bresp));
    if ($past(s_rvalid && !s_rready)) ap_r_stable: assert (s_rvalid && $stable(s_rresp) && $stable(s_rdata));
    // Inductive helpers: the request trackers match the slave's ready signals,
    // and the slave's internal handshake state is consistent.
    ap_aw_track: assert (aw_pend == !s_awready);
    ap_w_track: assert (w_pend == !s_wready);
    ap_r_track: assert (r_pend == !s_arready);
    if (s_bvalid) ap_inv_b: assert (!dut.aw_held && !dut.w_held && !dut.decoded);
    if (dut.decoded) ap_inv_decoded: assert (dut.aw_held && dut.w_held);
    if (s_rvalid) ap_inv_r: assert (!dut.r_pending);
    // Exactly one response per request: no response without its request(s),
    // and no new request accepted while one is still unanswered.
    if (s_bvalid) ap_b_has_req: assert (aw_pend && w_pend);
    if (s_rvalid) ap_r_has_req: assert (r_pend);
    if (aw_pend && !b_hs) ap_one_aw: assert (!aw_hs);
    if (w_pend && !b_hs) ap_one_w: assert (!w_hs);
    if (r_pend && !r_hs) ap_one_ar: assert (!ar_hs);
    // Only OKAY (0) or SLVERR (2) responses.
    if (s_bvalid) ap_bresp_legal: assert (s_bresp == 2'd0 || s_bresp == 2'd2);
    if (s_rvalid) ap_rresp_legal: assert (s_rresp == 2'd0 || s_rresp == 2'd2);
    // Read data belongs to the address accepted at the AR handshake.
    if ($rose(s_rvalid) && ar_addr_cap == 32'h0) ap_read_id: assert (s_rresp == 2'd0 && s_rdata == 32'h4e455431);
    if ($rose(s_rvalid) && ar_addr_cap == 32'h408) ap_read_sq_producer0: assert (s_rresp == 2'd0 && s_rdata == $past(sq_producer[0]));
    if ($rose(s_rvalid) && ar_addr_cap == 32'h3ffc) ap_read_unmapped: assert (s_rresp == 2'd2 && s_rdata == 32'h0);
    // A rejected write (SLVERR) has no side effect on write-only state.
    if ($rose(s_bvalid) && s_bresp == 2'd2) begin
      ap_slverr_no_effect: assert ($stable(running) && $stable(fixed_mode) && $stable(drop_on_full) &&
        $stable(default_queue) && $stable(replay_start) && $stable(replay_origin) && $stable(replay_interval) &&
        $stable(loss_seed) && $stable(loss_threshold) && $stable(sq_base[0]) && $stable(cq_base[0]) &&
        $stable(sq_producer[0]) && $stable(cq_consumer[0]) && $stable(rule_control[0]));
    end
  end

  // -------------------------------------------------- ring counter checks
  // Submission rings hold 32 descriptors and completion rings 64 records; the
  // counters are absolute, so occupancy is the 32-bit difference.
  wire claims_blocked = quiescent || (stopped_idle && !running);
  generate for (genvar r = 0; r < 8; r++) begin : rings
    wire [31:0] sq_used = sq_producer[r] - sq_consumer[r];
    wire [31:0] cq_used = cq_producer[r] - cq_consumer[r];
    always_ff @(posedge clk) if (past_valid && !rst) begin
      ap_sq_no_overflow: assert (sq_used <= 32'd32);
      ap_cq_credit: assert ({1'b0, cq_used} + reserved[r] <= 33'd64);
      // Inductive helpers: claim_eligible is one cycle old, but whenever a
      // claim could be taken the current counters still allow it. A commit
      // needs a reservation, which claim_eligible already counted; emptying a
      // submission ring (RING_RECOVER, COUNTER_ORIGIN) needs a quiescent engine.
      if (claim_ready[r]) ap_ready_cq_room: assert (cq_used < 32'd64);
      if (claim_ready[r] && !claims_blocked) ap_ready_sq_nonempty: assert (sq_used != 32'd0);
    end
  end endgenerate

  // ------------------------------------------------------------- covers
  always_ff @(posedge clk) if (past_valid && !rst) begin
    cp_write_ok: cover ($rose(s_bvalid) && s_bresp == 2'd0);
    cp_write_slverr: cover ($rose(s_bvalid) && s_bresp == 2'd2);
    cp_read_ring: cover ($rose(s_rvalid) && ar_addr_cap == 32'h408);
    cp_claim_commit: cover (cq_producer[0] == 32'd1);
  end
endmodule
`endif
