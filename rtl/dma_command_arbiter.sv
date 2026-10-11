module dma_command_arbiter(
 input logic clk,rst,
 input logic [1:0] c_rd_valid,output logic [1:0] c_rd_ready,input logic [31:0] c_rd_address[0:1],input logic [7:0] c_rd_bytes[0:1],
 output logic [1:0] c_rd_done,output logic [1:0] c_rd_status[0:1],output logic [1023:0] c_rd_data[0:1],
 input logic [1:0] c_wr_valid,output logic [1:0] c_wr_ready,input logic [31:0] c_wr_address[0:1],input logic [7:0] c_wr_bytes[0:1],input logic [1023:0] c_wr_data[0:1],
 output logic [1:0] c_wr_done,output logic [1:0] c_wr_status[0:1],
 output logic rd_valid,input logic rd_ready,output logic [31:0] rd_address,output logic [7:0] rd_bytes,
 input logic rd_done,input logic [1:0] rd_status,input logic [1023:0] rd_data,
 output logic wr_valid,input logic wr_ready,output logic [31:0] wr_address,output logic [7:0] wr_bytes,output logic [1023:0] wr_data,
 input logic wr_done,input logic [1:0] wr_status,
 output logic busy,output logic read_owner,write_owner
);
 logic read_busy,write_busy,read_turn,write_turn,read_choice,write_choice;
 logic read_offered,write_offered,read_selected,write_selected;
 always_comb begin
   read_choice=read_offered?read_selected:(c_rd_valid[read_turn]?read_turn:!read_turn);
   write_choice=write_offered?write_selected:(c_wr_valid[write_turn]?write_turn:!write_turn);
   rd_valid=!read_busy && c_rd_valid[read_choice];rd_address=c_rd_address[read_choice];rd_bytes=c_rd_bytes[read_choice];
   wr_valid=!write_busy && c_wr_valid[write_choice];wr_address=c_wr_address[write_choice];wr_bytes=c_wr_bytes[write_choice];wr_data=c_wr_data[write_choice];
   c_rd_ready=0;c_wr_ready=0;c_rd_done=0;c_wr_done=0;
   if(!read_busy) c_rd_ready[read_choice]=rd_ready;
   if(!write_busy) c_wr_ready[write_choice]=wr_ready;
   if(read_busy) c_rd_done[read_owner]=rd_done;
   if(write_busy) c_wr_done[write_owner]=wr_done;
   for(integer i=0;i<2;i++) begin c_rd_status[i]=rd_status;c_rd_data[i]=rd_data;c_wr_status[i]=wr_status;end
   busy=read_busy || write_busy || read_offered || write_offered;
 end
 always_ff @(posedge clk) begin
   if(rst) begin read_busy<=0;write_busy<=0;read_turn<=0;write_turn<=0;read_owner<=0;write_owner<=0;read_offered<=0;write_offered<=0;read_selected<=0;write_selected<=0;end
   else begin
     if(rd_valid) begin read_offered<=1;read_selected<=read_choice;end
     if(wr_valid) begin write_offered<=1;write_selected<=write_choice;end
     if(rd_valid && rd_ready) begin read_busy<=1;read_owner<=read_choice;read_offered<=0;end
     if(wr_valid && wr_ready) begin write_busy<=1;write_owner<=write_choice;write_offered<=0;end
     if(read_busy && rd_done) begin read_busy<=0;read_turn<=!read_owner;end
     if(write_busy && wr_done) begin write_busy<=0;write_turn<=!write_owner;end
   end
 end
endmodule
