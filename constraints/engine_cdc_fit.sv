// synthesis only: engine_axi with its packet input on a separate clock.
// The packet stream arrives on clk_pkt (registered once there), crosses into
// the engine clock through rtl/stream_cdc_fifo.sv, and enters the unchanged
// engine_axi_fit wrapper (which registers every engine port on clk).
module engine_axi_cdc_fit(
 input logic clk,rst,
 input logic clk_pkt,pkt_rst,
 input logic [31:0] pkt_data,input logic [3:0] pkt_keep,input logic pkt_valid,pkt_last,output logic pkt_ready,
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
 // packet-clock domain: register the inputs and the ready output
 logic pkt_rst_r,pkt_valid_r,pkt_last_r,pkt_ready_w;logic [31:0] pkt_data_r;logic [3:0] pkt_keep_r;
 always_ff @(posedge clk_pkt) begin
   pkt_rst_r<=pkt_rst;pkt_data_r<=pkt_data;pkt_keep_r<=pkt_keep;pkt_valid_r<=pkt_valid;pkt_last_r<=pkt_last;
   pkt_ready<=pkt_ready_w;
 end
 // engine-clock reset for the FIFO's read side
 logic rst_r;
 always_ff @(posedge clk) rst_r<=rst;

 logic [36:0] fifo_data;logic fifo_valid,fifo_ready;
 stream_cdc_fifo #(.WIDTH(37),.ADDR(4)) crossing(
   .s_clk(clk_pkt),.s_rst(pkt_rst_r),.s_data({pkt_last_r,pkt_keep_r,pkt_data_r}),.s_valid(pkt_valid_r),.s_ready(pkt_ready_w),
   .m_clk(clk),.m_rst(rst_r),.m_data(fifo_data),.m_valid(fifo_valid),.m_ready(fifo_ready));

 engine_axi_fit engine(.clk(clk),.rst(rst),
   .s_data(fifo_data[31:0]),.s_keep(fifo_data[35:32]),.s_valid(fifo_valid),.s_last(fifo_data[36]),.s_ready(fifo_ready),
   .m_data,.m_keep,.m_valid,.m_last,.m_ready,
   .s_awaddr,.s_awvalid,.s_awready,.s_wdata,.s_wstrb,.s_wvalid,.s_wready,.s_bresp,.s_bvalid,.s_bready,
   .s_araddr,.s_arvalid,.s_arready,.s_rdata,.s_rresp,.s_rvalid,.s_rready,
   .m_awaddr,.m_awlen,.m_awsize,.m_awburst,.m_awvalid,.m_awready,.m_wdata,.m_wstrb,.m_wlast,.m_wvalid,.m_wready,
   .m_bresp,.m_bvalid,.m_bready,.m_araddr,.m_arlen,.m_arsize,.m_arburst,.m_arvalid,.m_arready,
   .m_rdata,.m_rresp,.m_rlast,.m_rvalid,.m_rready,.irq,.quiescent,.running,.tick);
endmodule
