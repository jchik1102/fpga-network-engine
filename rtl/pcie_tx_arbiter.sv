module pcie_tx_arbiter(
 input logic clk,rst,
 input logic [3:0] s_valid,output logic [3:0] s_ready,
 input logic [31:0] s_data[0:3],input logic [3:0] s_sop,s_eop,
 output logic tx_valid,input logic tx_ready,output logic [31:0] tx_data,output logic tx_sop,tx_eop,
 output logic busy
);
 logic locked;logic [1:0] owner,choice;
 always_comb begin
   choice=s_valid[0]?2'd0:s_valid[1]?2'd1:s_valid[2]?2'd2:2'd3;
   if(locked) choice=owner;
   tx_valid=s_valid[choice];tx_data=s_data[choice];tx_sop=s_sop[choice];tx_eop=s_eop[choice];
   s_ready=0;s_ready[choice]=tx_ready;
   busy=locked;
 end
 always_ff @(posedge clk) begin
   if(rst) begin locked<=0;owner<=0;end
   else if(tx_valid && tx_ready) begin
     if(tx_eop) locked<=0;else begin locked<=1;owner<=choice;end
   end else if(tx_valid && !locked) begin
     locked<=1;owner<=choice;
   end
 end
endmodule
