module engine_pcie(
 input logic clk,rst,
 input logic [31:0] s_data,input logic [3:0] s_keep,input logic s_valid,s_last,output logic s_ready,
 output logic [31:0] m_data,output logic [3:0] m_keep,output logic m_valid,m_last,input logic m_ready,
 input logic [31:0] rx_data,input logic rx_valid,rx_sop,rx_eop,output logic rx_ready,
 output logic [31:0] tx_data,output logic tx_valid,tx_sop,tx_eop,input logic tx_ready,
 input logic [15:0] cfg_requester_id,input logic [63:0] cfg_bar0_base,
 input logic cfg_bus_master_enable,cfg_msi_enable,cfg_msi_mask,cfg_rcb128,
 input logic [63:0] cfg_msi_address,input logic [15:0] cfg_msi_data,
 output logic irq,quiescent,running,output logic [63:0] tick
);
 logic [31:0] awaddr,wdata,araddr,rdata;logic [3:0] wstrb;logic [1:0] bresp,rresp;
 logic awvalid,awready,wvalid,wready,bvalid,bready,arvalid,arready,rvalid,rready,rearm;
 logic rd_valid,rd_ready,rd_done,wr_valid,wr_ready,wr_done;
 logic [31:0] rd_address,wr_address;logic [7:0] rd_bytes,wr_bytes;logic [1:0] rd_status,wr_status;logic [1023:0] rd_data,wr_data;
 logic four_tag,drain_reset,requester_busy,arbiter_busy;logic [63:0] aperture_base;
 logic [3:0] active_tags,quarantined_tags;logic [2:0] max_active;
 logic unexpected_pulse,late_pulse,malformed_pulse,poisoned_pulse,status_pulse,timeout_pulse,translation_pulse;
 logic accepted_pulse,write_request_pulse,read_request_pulse,msi_sent_pulse,bar_write_error_pulse,unsupported_pulse;
 logic msi_pending,msi_armed,core_quiescent;
 logic [3:0] tx_source_valid,tx_source_ready,tx_source_sop,tx_source_eop;logic [31:0] tx_source_data[0:3];
 logic c_valid,c_ready,q_valid,q_ready;
 typedef enum logic [1:0] {ROUTE_CPL,ROUTE_REQ,ROUTE_DROP} route_t;
 route_t route,held_route;logic in_packet;
 always_comb begin
   if(in_packet) route=held_route;
   else if(rx_data[28:24]==5'b01010 && rx_data[31]==1'b0 && rx_data[29]==1'b0) route=ROUTE_CPL;
   else if(rx_data[28:24]==5'b00000 && rx_data[31]==1'b0) route=ROUTE_REQ;
   else route=ROUTE_DROP;
   c_valid=rx_valid && route==ROUTE_CPL;q_valid=rx_valid && route==ROUTE_REQ;
   rx_ready=route==ROUTE_CPL?c_ready:route==ROUTE_REQ?q_ready:1'b1;
   quiescent=core_quiescent && !requester_busy && !arbiter_busy;
 end
 always_ff @(posedge clk) begin
   if(rst) begin in_packet<=0;held_route<=ROUTE_DROP;end
   else if(rx_valid && rx_ready) begin
     if(rx_eop) in_packet<=0;else if(!in_packet) begin in_packet<=1;held_route<=route;end
   end
 end
 engine_core core(.clk(clk),.rst(rst),.s_data(s_data),.s_keep(s_keep),.s_valid(s_valid),.s_last(s_last),.s_ready(s_ready),
   .m_data(m_data),.m_keep(m_keep),.m_valid(m_valid),.m_last(m_last),.m_ready(m_ready),
   .s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),.s_wdata(wdata),.s_wstrb(wstrb),.s_wvalid(wvalid),.s_wready(wready),
   .s_bresp(bresp),.s_bvalid(bvalid),.s_bready(bready),.s_araddr(araddr),.s_arvalid(arvalid),.s_arready(arready),
   .s_rdata(rdata),.s_rresp(rresp),.s_rvalid(rvalid),.s_rready(rready),
   .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_address(rd_address),.rd_bytes(rd_bytes),.rd_done(rd_done),.rd_status(rd_status),.rd_data(rd_data),
   .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_address(wr_address),.wr_bytes(wr_bytes),.wr_data(wr_data),.wr_done(wr_done),.wr_status(wr_status),
   .irq(irq),.notification_rearm(rearm),.quiescent(core_quiescent),.running(running),.tick(tick));
 pcie_requester requester(.clk(clk),.rst(rst),.cfg_requester_id(cfg_requester_id),.cfg_bus_master_enable(cfg_bus_master_enable),.cfg_rcb128(cfg_rcb128),
   .aperture_base(aperture_base),.four_tag(four_tag),.drain_reset(drain_reset),
   .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_address(rd_address),.rd_bytes(rd_bytes),.rd_done(rd_done),.rd_status(rd_status),.rd_data(rd_data),
   .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_address(wr_address),.wr_bytes(wr_bytes),.wr_data(wr_data),.wr_done(wr_done),.wr_status(wr_status),
   .w_valid(tx_source_valid[0]),.w_ready(tx_source_ready[0]),.w_data(tx_source_data[0]),.w_sop(tx_source_sop[0]),.w_eop(tx_source_eop[0]),
   .r_valid(tx_source_valid[3]),.r_ready(tx_source_ready[3]),.r_data(tx_source_data[3]),.r_sop(tx_source_sop[3]),.r_eop(tx_source_eop[3]),
   .c_valid(c_valid),.c_ready(c_ready),.c_data(rx_data),.c_sop(rx_sop),.c_eop(rx_eop),
   .active(active_tags),.quarantined(quarantined_tags),.max_active(max_active),
   .unexpected_pulse(unexpected_pulse),.late_pulse(late_pulse),.malformed_pulse(malformed_pulse),.poisoned_pulse(poisoned_pulse),
   .status_pulse(status_pulse),.timeout_pulse(timeout_pulse),.translation_pulse(translation_pulse),
   .accepted_pulse(accepted_pulse),.write_request_pulse(write_request_pulse),.read_request_pulse(read_request_pulse),.busy(requester_busy));
 pcie_msi msi(.clk(clk),.rst(rst),.irq(irq),.rearm(rearm),.cfg_msi_enable(cfg_msi_enable),.cfg_msi_mask(cfg_msi_mask),
   .cfg_bus_master_enable(cfg_bus_master_enable),.cfg_msi_address(cfg_msi_address),.cfg_msi_data(cfg_msi_data),.cfg_requester_id(cfg_requester_id),
   .t_valid(tx_source_valid[1]),.t_ready(tx_source_ready[1]),.t_data(tx_source_data[1]),.t_sop(tx_source_sop[1]),.t_eop(tx_source_eop[1]),
   .pending(msi_pending),.armed(msi_armed),.sent_pulse(msi_sent_pulse));
 pcie_completer completer(.clk(clk),.rst(rst),.cfg_requester_id(cfg_requester_id),.cfg_bar0_base(cfg_bar0_base),
   .cfg_bus_master_enable(cfg_bus_master_enable),.cfg_msi_enable(cfg_msi_enable),.cfg_msi_mask(cfg_msi_mask),
   .q_valid(q_valid),.q_ready(q_ready),.q_data(rx_data),.q_sop(rx_sop),.q_eop(rx_eop),
   .t_valid(tx_source_valid[2]),.t_ready(tx_source_ready[2]),.t_data(tx_source_data[2]),.t_sop(tx_source_sop[2]),.t_eop(tx_source_eop[2]),
   .m_awaddr(awaddr),.m_awvalid(awvalid),.m_awready(awready),.m_wdata(wdata),.m_wstrb(wstrb),.m_wvalid(wvalid),.m_wready(wready),
   .m_bresp(bresp),.m_bvalid(bvalid),.m_bready(bready),.m_araddr(araddr),.m_arvalid(arvalid),.m_arready(arready),
   .m_rdata(rdata),.m_rresp(rresp),.m_rvalid(rvalid),.m_rready(rready),
   .engine_quiescent(core_quiescent),.requester_busy(requester_busy),.active_tags(active_tags),.quarantined_tags(quarantined_tags),.max_active(max_active),
   .msi_pending(msi_pending),.msi_armed(msi_armed),
   .unexpected_pulse(unexpected_pulse),.late_pulse(late_pulse),.malformed_pulse(malformed_pulse),.poisoned_pulse(poisoned_pulse),
   .status_pulse(status_pulse),.timeout_pulse(timeout_pulse),.translation_pulse(translation_pulse),
   .accepted_pulse(accepted_pulse),.write_request_pulse(write_request_pulse),.read_request_pulse(read_request_pulse),.msi_sent_pulse(msi_sent_pulse),
   .four_tag(four_tag),.aperture_base(aperture_base),.drain_reset(drain_reset),
   .bar_write_error_pulse(bar_write_error_pulse),.unsupported_pulse(unsupported_pulse));
 pcie_tx_arbiter arbiter(.clk(clk),.rst(rst),.s_valid(tx_source_valid),.s_ready(tx_source_ready),.s_data(tx_source_data),
   .s_sop(tx_source_sop),.s_eop(tx_source_eop),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.tx_sop(tx_sop),.tx_eop(tx_eop),.busy(arbiter_busy));
endmodule
