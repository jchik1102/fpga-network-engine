module sg_transfer(
 input logic clk,rst,
 input logic start,output logic ready,input logic to_host,
 input logic [15:0] packet_length,input logic [2:0] segment_count,
 input logic [31:0] segment_address[0:3],input logic [15:0] segment_length[0:3],
 output logic done,output logic [1:0] status,
 output logic [8:0] local_read_word,input logic [31:0] local_read_data,
 output logic local_write_valid,output logic [8:0] local_write_word,
 output logic [31:0] local_write_data,output logic [3:0] local_write_keep,
 output logic rd_valid,input logic rd_ready,output logic [31:0] rd_address,output logic [7:0] rd_bytes,
 input logic rd_done,input logic [1:0] rd_status,input logic [1023:0] rd_data,
 output logic wr_valid,input logic wr_ready,output logic [31:0] wr_address,output logic [7:0] wr_bytes,
 output logic [1023:0] wr_data,input logic wr_done,input logic [1:0] wr_status,
 input logic abort_transfer
);
 typedef enum logic [3:0] {IDLE,PLAN,FETCH_ADDRESS,FETCH_WAIT,FETCH_STORE,ISSUE_WRITE,WAIT_WRITE,ISSUE_READ,WAIT_READ,STORE_READ,ADVANCE} state_t;
 state_t state;
 logic direction,cancelled;
 logic [2:0] index;
 logic [31:0] address[0:3];logic [15:0] lengths[0:3];
 logic [15:0] segment_offset,remaining,packet_offset;
 logic [7:0] chunk_bytes;
 logic [5:0] local_index,chunk_words;
 logic [1023:0] read_buffer;
 logic [15:0] amount;
 always_comb begin
   ready=state==IDLE;
   amount=remaining;
   if(amount>lengths[index]-segment_offset) amount=lengths[index]-segment_offset;
   if(amount>128) amount=128;
   if(amount>4096-((address[index]+segment_offset)&32'hfff)) amount=4096-((address[index]+segment_offset)&32'hfff);
   rd_address=address[index]+segment_offset;wr_address=rd_address;rd_bytes=chunk_bytes;wr_bytes=chunk_bytes;
   rd_valid=state==ISSUE_READ;wr_valid=state==ISSUE_WRITE;
`ifdef MUTATION_WRONG_SG_BYTE
   local_read_word=(packet_offset>>2)+local_index+(index!=0);
`else
   local_read_word=(packet_offset>>2)+local_index;
`endif
   local_write_valid=state==STORE_READ && !cancelled && !abort_transfer;
   local_write_word=(packet_offset>>2)+local_index;
   local_write_data=read_buffer[local_index*32 +:32];
   local_write_keep=(local_index==chunk_words-1 && chunk_bytes[1:0]!=0)?(4'hf>>(4-chunk_bytes[1:0])):4'hf;
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     state<=IDLE;direction<=0;cancelled<=0;index<=0;segment_offset<=0;remaining<=0;packet_offset<=0;
     chunk_bytes<=0;local_index<=0;chunk_words<=0;read_buffer<=0;wr_data<=0;done<=0;status<=0;
     for(integer i=0;i<4;i++) begin address[i]<=0;lengths[i]<=0;end
   end else begin
     done<=0;
     case(state)
       IDLE: if(start) begin
         direction<=to_host;cancelled<=0;index<=0;segment_offset<=0;remaining<=packet_length;packet_offset<=0;status<=0;
         for(integer i=0;i<4;i++) begin address[i]<=segment_address[i];lengths[i]<=segment_length[i];end
         if(packet_length==0 || segment_count==0 || segment_count>4) begin status<=3;done<=1;end
         else state<=PLAN;
       end
       PLAN: begin
         chunk_bytes<=amount[7:0];chunk_words<=(amount+3)>>2;local_index<=0;wr_data<=0;
         if(amount==0) begin status<=3;done<=1;state<=IDLE;end
         else if(direction) state<=FETCH_ADDRESS;else state<=ISSUE_READ;
       end
       FETCH_ADDRESS: state<=FETCH_WAIT;
       FETCH_WAIT: state<=FETCH_STORE;
       FETCH_STORE: begin
         wr_data[local_index*32 +:32]<=local_read_data;
         if(local_index==chunk_words-1) state<=ISSUE_WRITE;
         else begin local_index<=local_index+1'b1;state<=FETCH_ADDRESS;end
       end
       ISSUE_WRITE: if(wr_ready) state<=WAIT_WRITE;
       WAIT_WRITE: if(wr_done) begin
         if(wr_status!=0) begin status<=wr_status;done<=1;state<=IDLE;end else state<=ADVANCE;
       end
       ISSUE_READ: if(rd_ready) state<=WAIT_READ;
       WAIT_READ: if(rd_done) begin
         if(rd_status!=0) begin status<=rd_status;done<=1;state<=IDLE;end
         else begin read_buffer<=rd_data;local_index<=0;state<=STORE_READ;end
       end
       STORE_READ: begin
         if(local_index==chunk_words-1) state<=ADVANCE;else local_index<=local_index+1'b1;
       end
       ADVANCE: begin
         remaining<=remaining-chunk_bytes;packet_offset<=packet_offset+chunk_bytes;
         if(remaining==chunk_bytes) begin done<=1;state<=IDLE;end
         else begin
           if(segment_offset+chunk_bytes==lengths[index]) begin index<=index+1'b1;segment_offset<=0;end
           else segment_offset<=segment_offset+chunk_bytes;
           state<=PLAN;
         end
       end
       default: state<=IDLE;
     endcase
     if(state!=IDLE && abort_transfer) cancelled<=1;
     if((cancelled || abort_transfer) && state!=IDLE &&
        state!=ISSUE_WRITE && state!=ISSUE_READ &&
        (state!=WAIT_WRITE || wr_done) && (state!=WAIT_READ || rd_done)) begin
       done<=1;status<=1;state<=IDLE;
     end
   end
 end
endmodule
