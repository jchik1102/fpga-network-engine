module capture_dma(
 input logic clk,rst,abort_discard,
 input logic [31:0] epoch,input logic [3:0] claim_ready,
 input logic [31:0] sq_base[0:3],cq_base[0:3],sq_consumer[0:3],cq_producer[0:3],
 input logic [2:0] occupancy[0:3],input logic [1:0] head_slot[0:3],
 input logic [15:0] head_length[0:3],input logic [63:0] head_tick[0:3],input logic [4:0] head_aux[0:3],
 output logic [3:0] claim,commit,fault,output logic [3:0] fault_code[0:3],
 output logic release_valid,output logic [1:0] release_queue,read_queue,read_slot,
 output logic [8:0] read_word,input logic [31:0] read_data,output logic busy,
 output logic rd_valid,input logic rd_ready,output logic [31:0] rd_address,output logic [7:0] rd_bytes,
 input logic rd_done,input logic [1:0] rd_status,input logic [1023:0] rd_data,
 output logic wr_valid,input logic wr_ready,output logic [31:0] wr_address,output logic [7:0] wr_bytes,output logic [1023:0] wr_data,
 input logic wr_done,input logic [1:0] wr_status
);
 typedef enum logic [3:0] {IDLE,DESC_REQUEST,DESC_WAIT,CHECK,VALIDATE,SG_START,SG_WAIT,PAYLOAD_FENCE,PAYLOAD_WAIT,CQ_REQUEST,CQ_WAIT,CQ_FENCE,CQ_FENCE_WAIT,PUBLISH,COOLDOWN,FAILED} state_t;
 logic [2:0] occupancy_q[0:3];logic [1:0] head_slot_q[0:3];logic [15:0] head_length_q[0:3];
 logic [63:0] head_tick_q[0:3];logic [4:0] head_aux_q[0:3];logic descriptor_valid_q;
 state_t state;logic [1:0] rr,selected,choice;logic choose;
 logic [31:0] sequence_saved,epoch_saved,descriptor_address,completion_address;
 logic [15:0] packet_length,validated_length;logic [63:0] packet_tick,cookie,unused_tick;logic [4:0] packet_aux;
 logic [511:0] descriptor;logic descriptor_valid,release_packet;
 logic [7:0] completion_status;logic [3:0] failure_code;
 logic [2:0] segment_count;logic [31:0] segment_address[0:3];logic [15:0] segment_length[0:3];
 logic sg_ready,sg_done,sg_start,sg_wr_valid,sg_wr_ready,unused_rd_valid;
 logic [1:0] sg_status;logic [31:0] sg_wr_address,unused_rd_address;logic [7:0] sg_wr_bytes,unused_rd_bytes;logic [1023:0] sg_wr_data;
 logic unused_local_valid;logic [8:0] unused_local_word;logic [31:0] unused_local_data;logic [3:0] unused_local_keep;
 descriptor_validator validator(descriptor,1'b0,sequence_saved,epoch_saved,packet_length,descriptor_valid,cookie,unused_tick,validated_length,segment_count,segment_address,segment_length);
 sg_transfer scatter(.clk(clk),.rst(rst),.start(sg_start),.ready(sg_ready),.to_host(1'b1),.packet_length(packet_length),.segment_count(segment_count),.segment_address(segment_address),.segment_length(segment_length),
 .done(sg_done),.status(sg_status),.local_read_word(read_word),.local_read_data(read_data),.local_write_valid(unused_local_valid),.local_write_word(unused_local_word),.local_write_data(unused_local_data),.local_write_keep(unused_local_keep),
 .rd_valid(unused_rd_valid),.rd_ready(1'b0),.rd_address(unused_rd_address),.rd_bytes(unused_rd_bytes),.rd_done(1'b0),.rd_status(2'b0),.rd_data(1024'b0),
 .wr_valid(sg_wr_valid),.wr_ready(sg_wr_ready),.wr_address(sg_wr_address),.wr_bytes(sg_wr_bytes),.wr_data(sg_wr_data),.wr_done(wr_done && state==SG_WAIT),.wr_status(wr_status),.abort_transfer(abort_discard));
 always_comb begin
   choose=0;choice=rr;
   for(integer k=0;k<4;k++) if(!choose && claim_ready[(rr+k)%4] && occupancy_q[(rr+k)%4]!=0 && occupancy[(rr+k)%4]!=0) begin choose=1;choice=(rr+k)%4;end
   claim=0;commit=0;fault=0;for(integer q=0;q<4;q++) fault_code[q]=failure_code;
   if(state==IDLE && choose && !abort_discard) claim[choice]=1;
   if(state==PUBLISH && !abort_discard) commit[selected]=1;
   if(state==FAILED) fault[selected]=1;
   release_valid=state==PUBLISH && release_packet && !abort_discard;release_queue=selected;read_queue=selected;
   busy=state!=IDLE;sg_start=state==SG_START && !abort_discard;
   rd_valid=state==DESC_REQUEST || state==PAYLOAD_FENCE || state==CQ_FENCE;
   rd_address=state==DESC_REQUEST?descriptor_address:32'h1f000;rd_bytes=state==DESC_REQUEST?64:8;
   wr_valid=state==CQ_REQUEST || (state==SG_WAIT && sg_wr_valid);
   sg_wr_ready=state==SG_WAIT && wr_ready;
   wr_address=state==SG_WAIT?sg_wr_address:completion_address;
   wr_bytes=state==SG_WAIT?sg_wr_bytes:32;
   wr_data=0;
   if(state==SG_WAIT) wr_data=sg_wr_data;
   else begin
     wr_data[63:0]=cookie;wr_data[95:64]=sequence_saved;wr_data[127:96]=epoch_saved;
     wr_data[191:128]=completion_status==3?64'b0:packet_tick;
     wr_data[207:192]=completion_status<2?packet_length:16'b0;
     wr_data[215:208]=completion_status;wr_data[223:216]={6'b0,selected};
     wr_data[255:224]=completion_status<2?{27'b0,packet_aux}:32'b0;
   end
 end
 always_ff @(posedge clk) begin
   for(integer q=0;q<4;q++) begin occupancy_q[q]<=occupancy[q];head_slot_q[q]<=head_slot[q];head_length_q[q]<=head_length[q];head_tick_q[q]<=head_tick[q];head_aux_q[q]<=head_aux[q];end
   descriptor_valid_q<=descriptor_valid;
   if(rst) begin state<=IDLE;rr<=0;selected<=0;read_slot<=0;sequence_saved<=0;epoch_saved<=0;descriptor_address<=0;completion_address<=0;packet_length<=0;packet_tick<=0;packet_aux<=0;descriptor<=0;completion_status<=0;failure_code<=0;release_packet<=0;end
   else case(state)
     IDLE:if(choose && !abort_discard) begin
       selected<=choice;rr<=choice+1'b1;read_slot<=head_slot_q[choice];packet_length<=head_length_q[choice];packet_tick<=head_tick_q[choice];packet_aux<=head_aux_q[choice];
       sequence_saved<=sq_consumer[choice];epoch_saved<=epoch;descriptor_address<={sq_base[choice][31:11],sq_consumer[choice][4:0],6'b0};
       completion_address<={cq_base[choice][31:11],cq_producer[choice][5:0],5'b0};state<=DESC_REQUEST;release_packet<=0;
     end
     DESC_REQUEST:if(rd_ready) state<=DESC_WAIT;
     DESC_WAIT:if(rd_done) begin
       if(rd_status!=0) begin failure_code<=1;state<=FAILED;end
       else if(abort_discard) state<=IDLE;
       else begin descriptor<=rd_data[511:0];state<=CHECK;end
     end
     CHECK:state<=abort_discard?IDLE:VALIDATE;
     VALIDATE:if(abort_discard) state<=IDLE;else if(!descriptor_valid_q) begin completion_status<=3;state<=CQ_REQUEST;end
       else begin completion_status<=packet_aux[4]?0:1;release_packet<=1;state<=SG_START;end
     SG_START:if(abort_discard) state<=IDLE;else if(sg_ready) state<=SG_WAIT;
     SG_WAIT:if(sg_done) begin
       if(abort_discard) state<=IDLE;
       else if(sg_status!=0) begin completion_status<=5;state<=PAYLOAD_FENCE;end
       else state<=PAYLOAD_FENCE;
     end
     PAYLOAD_FENCE:if(rd_ready) state<=PAYLOAD_WAIT;
     PAYLOAD_WAIT:if(rd_done) begin
       if(rd_status!=0) begin failure_code<=2;state<=FAILED;end
       else if(abort_discard) state<=IDLE;else state<=CQ_REQUEST;
     end
     CQ_REQUEST:if(wr_ready) state<=CQ_WAIT;
     CQ_WAIT:if(wr_done) begin
       if(wr_status!=0) begin failure_code<=3;state<=FAILED;end
`ifdef MUTATION_PREMATURE_PUBLICATION
       else if(abort_discard) state<=IDLE;else state<=PUBLISH;
`else
       else if(abort_discard) state<=IDLE;else state<=CQ_FENCE;
`endif
     end
     CQ_FENCE:if(rd_ready) state<=CQ_FENCE_WAIT;
     CQ_FENCE_WAIT:if(rd_done) begin
       if(rd_status!=0) begin failure_code<=4;state<=FAILED;end
       else if(abort_discard) state<=IDLE;else state<=PUBLISH;
     end
     PUBLISH:state<=COOLDOWN;
     COOLDOWN:state<=IDLE;
     FAILED:state<=IDLE;
     default:state<=IDLE;
   endcase
 end
endmodule
