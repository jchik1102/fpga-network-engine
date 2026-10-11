module pcie_msi(
 input logic clk,rst,
 input logic irq,rearm,
 input logic cfg_msi_enable,cfg_msi_mask,cfg_bus_master_enable,
 input logic [63:0] cfg_msi_address,input logic [15:0] cfg_msi_data,input logic [15:0] cfg_requester_id,
 output logic t_valid,input logic t_ready,output logic [31:0] t_data,output logic t_sop,t_eop,
 output logic pending,armed,sent_pulse
);
 logic sending,address_64;logic [2:0] beat;logic [63:0] address;logic [15:0] message;
 logic deliverable;
 always_comb begin
   deliverable=cfg_msi_enable && !cfg_msi_mask && cfg_bus_master_enable;
   t_valid=sending;t_sop=beat==0;t_eop=beat==(address_64?3'd4:3'd3);
   case(beat)
     0:t_data={address_64?3'b011:3'b010,5'b00000,14'b0,10'd1};
     1:t_data={cfg_requester_id,8'h00,4'b0000,4'b1111};
     2:t_data=address_64?address[63:32]:{address[31:2],2'b00};
     3:t_data=address_64?{address[31:2],2'b00}:{message[7:0],message[15:8],16'h0000};
     default:t_data={message[7:0],message[15:8],16'h0000};
   endcase
 end
 always_ff @(posedge clk) begin
   if(rst) begin sending<=0;address_64<=0;beat<=0;address<=0;message<=0;pending<=0;armed<=1;sent_pulse<=0;end
   else begin
     sent_pulse<=0;
     if(sending) begin
       if(t_ready) begin
         if(t_eop) begin sending<=0;beat<=0;sent_pulse<=1;end else beat<=beat+1'b1;
       end
     end else if(armed && irq || pending) begin
       if(deliverable) begin
         sending<=1;beat<=0;address<=cfg_msi_address;address_64<=cfg_msi_address[63:32]!=0;message<=cfg_msi_data;
         armed<=0;pending<=0;
       end else if(cfg_msi_enable && armed) begin pending<=1;armed<=0;end
     end
     if(!cfg_msi_enable) pending<=0;
     // re-arm after the capture so a same-cycle event isn't lost
     if(rearm) armed<=1;
   end
 end
endmodule
