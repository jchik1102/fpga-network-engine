// synthesis only: every port registered once so timing is reg-to-reg, never simulated
module engine_axi_fit(
 input logic clk,rst,
 input logic [31:0] s_data,input logic [3:0] s_keep,input logic s_valid,s_last,output logic s_ready,
 output logic [31:0] m_data,output logic [3:0] m_keep,output logic m_valid,m_last,input logic m_ready,
 input logic [31:0] s_awaddr,input logic s_awvalid,output logic s_awready,
 input logic [31:0] s_wdata,input logic [3:0] s_wstrb,input logic s_wvalid,output logic s_wready,
 output logic [1:0] s_bresp,output logic s_bvalid,input logic s_bready,
 input logic [31:0] s_araddr,input logic s_arvalid,output logic s_arready,
 output logic [31:0] s_rdata,output logic [1:0] s_rresp,output logic s_rvalid,input logic s_rready,
 output logic [31:0] m_awaddr,output logic [7:0] m_awlen,output logic [2:0] m_awsize,
 output logic [1:0] m_awburst,output logic m_awvalid,input logic m_awready,
 output logic [63:0] m_wdata,output logic [7:0] m_wstrb,output logic m_wlast,m_wvalid,input logic m_wready,
 input logic [1:0] m_bresp,input logic m_bvalid,output logic m_bready,
 output logic [31:0] m_araddr,output logic [7:0] m_arlen,output logic [2:0] m_arsize,
 output logic [1:0] m_arburst,output logic m_arvalid,input logic m_arready,
 input logic [63:0] m_rdata,input logic [1:0] m_rresp,input logic m_rlast,m_rvalid,output logic m_rready,
 output logic irq,quiescent,running,output logic [63:0] tick
);
 logic rst_r;logic [31:0] s_data_r,s_awaddr_r,s_wdata_r,s_araddr_r;logic [3:0] s_keep_r,s_wstrb_r;
 logic s_valid_r,s_last_r,m_ready_r,s_awvalid_r,s_wvalid_r,s_bready_r,s_arvalid_r,s_rready_r;
 logic m_awready_r,m_wready_r,m_bvalid_r,m_arready_r,m_rlast_r,m_rvalid_r;logic [1:0] m_bresp_r,m_rresp_r;logic [63:0] m_rdata_r;
 logic s_ready_w,m_valid_w,m_last_w,s_awready_w,s_wready_w,s_bvalid_w,s_arready_w,s_rvalid_w;
 logic [31:0] m_data_w,s_rdata_w,m_awaddr_w,m_araddr_w;logic [3:0] m_keep_w;logic [1:0] s_bresp_w,s_rresp_w,m_awburst_w,m_arburst_w;
 logic [7:0] m_awlen_w,m_arlen_w,m_wstrb_w;logic [2:0] m_awsize_w,m_arsize_w;logic m_awvalid_w,m_wlast_w,m_wvalid_w,m_bready_w,m_arvalid_w,m_rready_w;
 logic [63:0] m_wdata_w,tick_w;logic irq_w,quiescent_w,running_w;
 always_ff @(posedge clk) begin
   rst_r<=rst;s_data_r<=s_data;s_keep_r<=s_keep;s_valid_r<=s_valid;s_last_r<=s_last;m_ready_r<=m_ready;
   s_awaddr_r<=s_awaddr;s_awvalid_r<=s_awvalid;s_wdata_r<=s_wdata;s_wstrb_r<=s_wstrb;s_wvalid_r<=s_wvalid;s_bready_r<=s_bready;
   s_araddr_r<=s_araddr;s_arvalid_r<=s_arvalid;s_rready_r<=s_rready;
   m_awready_r<=m_awready;m_wready_r<=m_wready;m_bresp_r<=m_bresp;m_bvalid_r<=m_bvalid;m_arready_r<=m_arready;
   m_rdata_r<=m_rdata;m_rresp_r<=m_rresp;m_rlast_r<=m_rlast;m_rvalid_r<=m_rvalid;
   s_ready<=s_ready_w;m_data<=m_data_w;m_keep<=m_keep_w;m_valid<=m_valid_w;m_last<=m_last_w;
   s_awready<=s_awready_w;s_wready<=s_wready_w;s_bresp<=s_bresp_w;s_bvalid<=s_bvalid_w;s_arready<=s_arready_w;
   s_rdata<=s_rdata_w;s_rresp<=s_rresp_w;s_rvalid<=s_rvalid_w;
   m_awaddr<=m_awaddr_w;m_awlen<=m_awlen_w;m_awsize<=m_awsize_w;m_awburst<=m_awburst_w;m_awvalid<=m_awvalid_w;
   m_wdata<=m_wdata_w;m_wstrb<=m_wstrb_w;m_wlast<=m_wlast_w;m_wvalid<=m_wvalid_w;m_bready<=m_bready_w;
   m_araddr<=m_araddr_w;m_arlen<=m_arlen_w;m_arsize<=m_arsize_w;m_arburst<=m_arburst_w;m_arvalid<=m_arvalid_w;m_rready<=m_rready_w;
   irq<=irq_w;quiescent<=quiescent_w;running<=running_w;tick<=tick_w;
 end
 engine_axi core(.clk(clk),.rst(rst_r),.s_data(s_data_r),.s_keep(s_keep_r),.s_valid(s_valid_r),.s_last(s_last_r),.s_ready(s_ready_w),
   .m_data(m_data_w),.m_keep(m_keep_w),.m_valid(m_valid_w),.m_last(m_last_w),.m_ready(m_ready_r),
   .s_awaddr(s_awaddr_r),.s_awvalid(s_awvalid_r),.s_awready(s_awready_w),.s_wdata(s_wdata_r),.s_wstrb(s_wstrb_r),.s_wvalid(s_wvalid_r),.s_wready(s_wready_w),
   .s_bresp(s_bresp_w),.s_bvalid(s_bvalid_w),.s_bready(s_bready_r),.s_araddr(s_araddr_r),.s_arvalid(s_arvalid_r),.s_arready(s_arready_w),
   .s_rdata(s_rdata_w),.s_rresp(s_rresp_w),.s_rvalid(s_rvalid_w),.s_rready(s_rready_r),
   .m_awaddr(m_awaddr_w),.m_awlen(m_awlen_w),.m_awsize(m_awsize_w),.m_awburst(m_awburst_w),.m_awvalid(m_awvalid_w),.m_awready(m_awready_r),
   .m_wdata(m_wdata_w),.m_wstrb(m_wstrb_w),.m_wlast(m_wlast_w),.m_wvalid(m_wvalid_w),.m_wready(m_wready_r),
   .m_bresp(m_bresp_r),.m_bvalid(m_bvalid_r),.m_bready(m_bready_w),
   .m_araddr(m_araddr_w),.m_arlen(m_arlen_w),.m_arsize(m_arsize_w),.m_arburst(m_arburst_w),.m_arvalid(m_arvalid_w),.m_arready(m_arready_r),
   .m_rdata(m_rdata_r),.m_rresp(m_rresp_r),.m_rlast(m_rlast_r),.m_rvalid(m_rvalid_r),.m_rready(m_rready_w),
   .irq(irq_w),.quiescent(quiescent_w),.running(running_w),.tick(tick_w));
endmodule

module engine_pcie_fit(
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
 logic rst_r,s_valid_r,s_last_r,m_ready_r,rx_valid_r,rx_sop_r,rx_eop_r,tx_ready_r;
 logic [31:0] s_data_r,rx_data_r;logic [3:0] s_keep_r;
 logic [15:0] cfg_requester_id_r,cfg_msi_data_r;logic [63:0] cfg_bar0_base_r,cfg_msi_address_r;
 logic cfg_bus_master_enable_r,cfg_msi_enable_r,cfg_msi_mask_r,cfg_rcb128_r;
 logic s_ready_w,m_valid_w,m_last_w,rx_ready_w,tx_valid_w,tx_sop_w,tx_eop_w,irq_w,quiescent_w,running_w;
 logic [31:0] m_data_w,tx_data_w;logic [3:0] m_keep_w;logic [63:0] tick_w;
 always_ff @(posedge clk) begin
   rst_r<=rst;s_data_r<=s_data;s_keep_r<=s_keep;s_valid_r<=s_valid;s_last_r<=s_last;m_ready_r<=m_ready;
   rx_data_r<=rx_data;rx_valid_r<=rx_valid;rx_sop_r<=rx_sop;rx_eop_r<=rx_eop;tx_ready_r<=tx_ready;
   cfg_requester_id_r<=cfg_requester_id;cfg_bar0_base_r<=cfg_bar0_base;cfg_bus_master_enable_r<=cfg_bus_master_enable;
   cfg_msi_enable_r<=cfg_msi_enable;cfg_msi_mask_r<=cfg_msi_mask;cfg_rcb128_r<=cfg_rcb128;cfg_msi_address_r<=cfg_msi_address;cfg_msi_data_r<=cfg_msi_data;
   s_ready<=s_ready_w;m_data<=m_data_w;m_keep<=m_keep_w;m_valid<=m_valid_w;m_last<=m_last_w;rx_ready<=rx_ready_w;
   tx_data<=tx_data_w;tx_valid<=tx_valid_w;tx_sop<=tx_sop_w;tx_eop<=tx_eop_w;
   irq<=irq_w;quiescent<=quiescent_w;running<=running_w;tick<=tick_w;
 end
 engine_pcie core(.clk(clk),.rst(rst_r),.s_data(s_data_r),.s_keep(s_keep_r),.s_valid(s_valid_r),.s_last(s_last_r),.s_ready(s_ready_w),
   .m_data(m_data_w),.m_keep(m_keep_w),.m_valid(m_valid_w),.m_last(m_last_w),.m_ready(m_ready_r),
   .rx_data(rx_data_r),.rx_valid(rx_valid_r),.rx_sop(rx_sop_r),.rx_eop(rx_eop_r),.rx_ready(rx_ready_w),
   .tx_data(tx_data_w),.tx_valid(tx_valid_w),.tx_sop(tx_sop_w),.tx_eop(tx_eop_w),.tx_ready(tx_ready_r),
   .cfg_requester_id(cfg_requester_id_r),.cfg_bar0_base(cfg_bar0_base_r),.cfg_bus_master_enable(cfg_bus_master_enable_r),
   .cfg_msi_enable(cfg_msi_enable_r),.cfg_msi_mask(cfg_msi_mask_r),.cfg_rcb128(cfg_rcb128_r),.cfg_msi_address(cfg_msi_address_r),.cfg_msi_data(cfg_msi_data_r),
   .irq(irq_w),.quiescent(quiescent_w),.running(running_w),.tick(tick_w));
endmodule
