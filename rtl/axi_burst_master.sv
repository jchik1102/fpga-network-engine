module axi_burst_master(
 input logic clk,rst,
 input logic rd_valid,output logic rd_ready,input logic [31:0] rd_address,input logic [7:0] rd_bytes,
 output logic rd_done,output logic [1:0] rd_status,output logic [1023:0] rd_data,
 input logic wr_valid,output logic wr_ready,input logic [31:0] wr_address,input logic [7:0] wr_bytes,
 input logic [1023:0] wr_data,output logic wr_done,output logic [1:0] wr_status,
 output logic [31:0] m_awaddr,output logic [7:0] m_awlen,output logic [2:0] m_awsize,
 output logic [1:0] m_awburst,output logic m_awvalid,input logic m_awready,
 output logic [63:0] m_wdata,output logic [7:0] m_wstrb,output logic m_wlast,m_wvalid,input logic m_wready,
 input logic [1:0] m_bresp,input logic m_bvalid,output logic m_bready,
 output logic [31:0] m_araddr,output logic [7:0] m_arlen,output logic [2:0] m_arsize,
 output logic [1:0] m_arburst,output logic m_arvalid,input logic m_arready,
 input logic [63:0] m_rdata,input logic [1:0] m_rresp,input logic m_rlast,m_rvalid,output logic m_rready
);
 logic rd_busy,wr_busy,aw_sent,w_sent,ar_sent;
 logic [4:0] r_index,w_index,r_count,w_count;
 logic [7:0] w_tail;
 logic [1023:0] write_buffer;
 function automatic bad_command(input logic [31:0] address,input logic [7:0] size);
   bad_command=address[2:0]!=0 || size==0 || size>128 || ({1'b0,address[11:0]}+{5'b0,size})>4096;
 endfunction
 always_comb begin
   rd_ready=!rd_busy;wr_ready=!wr_busy;
   m_awsize=3;m_arsize=3;m_awburst=1;m_arburst=1;
   m_awvalid=wr_busy && !aw_sent;
   m_wvalid=wr_busy && !w_sent;
   m_wdata=write_buffer[w_index*64 +:64];
   m_wlast=(w_index==w_count-1'b1);
   m_wstrb=m_wlast?w_tail:8'hff;
   m_bready=wr_busy && aw_sent && w_sent;
   m_arvalid=rd_busy && !ar_sent;
   m_rready=rd_busy && ar_sent;
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     rd_busy<=0;wr_busy<=0;aw_sent<=0;w_sent<=0;ar_sent<=0;
     r_index<=0;w_index<=0;r_count<=0;w_count<=0;w_tail<=0;write_buffer<=0;
     m_awaddr<=0;m_awlen<=0;m_araddr<=0;m_arlen<=0;
     rd_done<=0;wr_done<=0;rd_status<=0;wr_status<=0;rd_data<=0;
   end else begin
     rd_done<=0;wr_done<=0;
     if(rd_valid && rd_ready) begin
       rd_status<=0;rd_data<=0;r_index<=0;ar_sent<=0;
       if(bad_command(rd_address,rd_bytes)) begin rd_status<=3;rd_done<=1;end
       else begin
         rd_busy<=1;m_araddr<=rd_address;
         r_count<=({1'b0,rd_bytes}+9'd7)>>3;m_arlen<=(({1'b0,rd_bytes}+9'd7)>>3)-1'b1;
       end
     end
     if(wr_valid && wr_ready) begin
       wr_status<=0;w_index<=0;aw_sent<=0;w_sent<=0;
       if(bad_command(wr_address,wr_bytes)) begin wr_status<=3;wr_done<=1;end
       else begin
         wr_busy<=1;m_awaddr<=wr_address;write_buffer<=wr_data;
         w_count<=({1'b0,wr_bytes}+9'd7)>>3;m_awlen<=(({1'b0,wr_bytes}+9'd7)>>3)-1'b1;
`ifdef MUTATION_BAD_FINAL_STROBE
         w_tail<=(wr_bytes[2:0]==0)?8'hff:(8'hff>>(7-wr_bytes[2:0]));
`else
         w_tail<=(wr_bytes[2:0]==0)?8'hff:(8'hff>>(8-wr_bytes[2:0]));
`endif
       end
     end
     if(m_arvalid && m_arready) ar_sent<=1;
     if(m_awvalid && m_awready) aw_sent<=1;
     if(m_wvalid && m_wready) begin
       if(m_wlast) w_sent<=1;else w_index<=w_index+1'b1;
     end
     if(m_bvalid && m_bready) begin wr_status<=m_bresp;wr_done<=1;wr_busy<=0;end
     if(m_rvalid && m_rready) begin
       rd_data[r_index*64 +:64]<=m_rdata;
       if(m_rresp!=0) rd_status<=m_rresp;
       if(m_rlast!=(r_index==r_count-1'b1)) rd_status<=3;
       if(m_rlast || r_index==r_count-1'b1) begin rd_done<=1;rd_busy<=0;end
       else r_index<=r_index+1'b1;
     end
   end
 end
endmodule
