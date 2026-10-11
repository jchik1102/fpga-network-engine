module replay_dma(
 input logic clk,rst,abort_discard,running,
 input logic [31:0] epoch,input logic [3:0] claim_ready,
 input logic [31:0] sq_base[0:3],cq_base[0:3],sq_consumer[0:3],cq_producer[0:3],
 input logic fixed_mode,input logic [63:0] replay_start,replay_origin,replay_interval,queue_delay[0:3],
 input logic [31:0] loss_seed,input logic [32:0] loss_threshold,
 output logic [3:0] claim,commit,fault,output logic [3:0] fault_code[0:3],
 output logic local_write_valid,output logic [1:0] local_write_queue,output logic [8:0] local_write_word,
 output logic [31:0] local_write_data,output logic [3:0] local_write_keep,
 output logic stage_valid,output logic [1:0] stage_queue,output logic [15:0] stage_length,
 output logic [63:0] stage_due,output logic stage_lost,
 input logic [3:0] stage_ready,finished,input logic [63:0] departure_tick[0:3],
 output logic [3:0] release_head,output logic busy,
 output logic rd_valid,input logic rd_ready,output logic [31:0] rd_address,output logic [7:0] rd_bytes,
 input logic rd_done,input logic [1:0] rd_status,input logic [1023:0] rd_data,
 output logic wr_valid,input logic wr_ready,output logic [31:0] wr_address,output logic [7:0] wr_bytes,output logic [1023:0] wr_data,
 input logic wr_done,input logic [1:0] wr_status
);
 typedef enum logic [3:0] {IDLE,DESC_REQUEST,DESC_WAIT,CHECK,VALIDATE,POLICY_WAIT,SG_START,SG_WAIT,STAGE,
   CQ_REQUEST,CQ_WAIT,CQ_FENCE,CQ_FENCE_WAIT,PUBLISH,FAILED} state_t;
 logic descriptor_valid_q;
 state_t state;
 logic [1:0] claim_rr,write_rr,selected,claim_choice,write_choice;logic claim_any,write_any;
 logic [3:0] pending;
 logic [63:0] pending_cookie[0:3];logic [31:0] pending_sequence[0:3],pending_epoch[0:3];
 logic [15:0] pending_length[0:3];logic [3:0] pending_lost;
 logic [31:0] sequence_saved,epoch_saved,descriptor_address,completion_address;
 logic [511:0] descriptor;logic descriptor_valid;
 logic [63:0] cookie,captured_tick,record_tick;logic [15:0] frame_length,record_length;
 logic [2:0] segment_count;logic [31:0] segment_address[0:3];logic [15:0] segment_length[0:3];
 logic [7:0] record_status;logic [3:0] failure_code;logic record_pending;
 logic policy_start,policy_ready,policy_done,policy_valid,policy_lost;logic [63:0] policy_due;logic [31:0] unused_word;
 logic sg_ready,sg_done,sg_start,sg_rd_valid,sg_rd_ready,unused_wr_valid;logic [1:0] sg_status;
 logic [31:0] sg_rd_address,unused_wr_address;logic [7:0] sg_rd_bytes,unused_wr_bytes;logic [1023:0] unused_wr_data;
 logic [8:0] unused_local_read;
 descriptor_validator validator(descriptor,1'b1,sequence_saved,epoch_saved,16'd0,descriptor_valid,cookie,captured_tick,frame_length,segment_count,segment_address,segment_length);
 replay_policy policy(.clk(clk),.rst(rst),.start(policy_start),.ready(policy_ready),.fixed_mode(fixed_mode),
   .start_tick(replay_start),.captured_tick(captured_tick),.origin_tick(replay_origin),.interval(replay_interval),.delay_ticks(queue_delay[selected]),
   .descriptor_sequence(sequence_saved),.seed(loss_seed),.queue_id(selected),.threshold(loss_threshold),
   .done(policy_done),.valid(policy_valid),.lost(policy_lost),.due_tick(policy_due),.random_word(unused_word));
 sg_transfer gather(.clk(clk),.rst(rst),.start(sg_start),.ready(sg_ready),.to_host(1'b0),.packet_length(frame_length),.segment_count(segment_count),.segment_address(segment_address),.segment_length(segment_length),
   .done(sg_done),.status(sg_status),.local_read_word(unused_local_read),.local_read_data(32'b0),.local_write_valid(local_write_valid),.local_write_word(local_write_word),.local_write_data(local_write_data),.local_write_keep(local_write_keep),
   .rd_valid(sg_rd_valid),.rd_ready(sg_rd_ready),.rd_address(sg_rd_address),.rd_bytes(sg_rd_bytes),.rd_done(rd_done && state==SG_WAIT),.rd_status(rd_status),.rd_data(rd_data),
   .wr_valid(unused_wr_valid),.wr_ready(1'b0),.wr_address(unused_wr_address),.wr_bytes(unused_wr_bytes),.wr_data(unused_wr_data),.wr_done(1'b0),.wr_status(2'b0),.abort_transfer(abort_discard));
 always_comb begin
   claim_any=0;claim_choice=claim_rr;write_any=0;write_choice=write_rr;
   for(integer k=0;k<4;k++) begin
`ifdef MUTATION_EARLY_COMPLETION
     if(!write_any && pending[(write_rr+k)%4]) begin write_any=1;write_choice=(write_rr+k)%4;end
`else
     if(!write_any && pending[(write_rr+k)%4] && finished[(write_rr+k)%4]) begin write_any=1;write_choice=(write_rr+k)%4;end
`endif
     if(!claim_any && claim_ready[(claim_rr+k)%4] && stage_ready[(claim_rr+k)%4] && !pending[(claim_rr+k)%4]) begin claim_any=1;claim_choice=(claim_rr+k)%4;end
   end
   claim=0;commit=0;fault=0;release_head=0;
   for(integer q=0;q<4;q++) fault_code[q]=failure_code;
   if(state==IDLE && !write_any && claim_any && running && !abort_discard) claim[claim_choice]=1;
   if(state==PUBLISH && !abort_discard) begin commit[selected]=1;if(record_pending) release_head[selected]=1;end
   if(state==FAILED) begin fault[selected]=1;if(record_pending) release_head[selected]=1;end
   busy=state!=IDLE;
   local_write_queue=selected;
   policy_start=state==VALIDATE && descriptor_valid_q && !abort_discard;
   sg_start=state==SG_START && !abort_discard;
   sg_rd_ready=state==SG_WAIT && rd_ready;
   stage_valid=state==STAGE && !abort_discard;stage_queue=selected;stage_length=frame_length;stage_due=policy_due;stage_lost=policy_lost;
   rd_valid=state==DESC_REQUEST || state==CQ_FENCE || (state==SG_WAIT && sg_rd_valid);
   rd_address=state==DESC_REQUEST?descriptor_address:state==SG_WAIT?sg_rd_address:32'h1f000;
   rd_bytes=state==DESC_REQUEST?8'd64:state==SG_WAIT?sg_rd_bytes:8'd8;
   wr_valid=state==CQ_REQUEST;wr_address=completion_address;wr_bytes=32;
   wr_data=0;
   wr_data[63:0]=record_pending?pending_cookie[selected]:cookie;
   wr_data[95:64]=sequence_saved;wr_data[127:96]=epoch_saved;
   wr_data[191:128]=record_tick;wr_data[207:192]=record_length;
   wr_data[215:208]=record_status;wr_data[223:216]={6'b0,selected};
 end
 always_ff @(posedge clk) begin
   descriptor_valid_q<=descriptor_valid;
   if(rst) begin
     state<=IDLE;claim_rr<=0;write_rr<=0;selected<=0;pending<=0;pending_lost<=0;sequence_saved<=0;epoch_saved<=0;
     descriptor_address<=0;completion_address<=0;descriptor<=0;record_tick<=0;record_length<=0;record_status<=0;failure_code<=0;record_pending<=0;
     for(integer q=0;q<4;q++) begin pending_cookie[q]<=0;pending_sequence[q]<=0;pending_epoch[q]<=0;pending_length[q]<=0;end
   end else begin
     case(state)
       IDLE:if(abort_discard) pending<=0;
         else if(write_any) begin
           selected<=write_choice;write_rr<=write_choice+1'b1;record_pending<=1;
           sequence_saved<=pending_sequence[write_choice];epoch_saved<=pending_epoch[write_choice];
           record_tick<=departure_tick[write_choice];record_length<=pending_length[write_choice];record_status<=pending_lost[write_choice]?2:0;
           completion_address<={cq_base[write_choice][31:11],cq_producer[write_choice][5:0],5'b0};state<=CQ_REQUEST;
         end else if(claim_any && running) begin
           selected<=claim_choice;claim_rr<=claim_choice+1'b1;record_pending<=0;
           sequence_saved<=sq_consumer[claim_choice];epoch_saved<=epoch;
           descriptor_address<={sq_base[claim_choice][31:11],sq_consumer[claim_choice][4:0],6'b0};
           completion_address<={cq_base[claim_choice][31:11],cq_producer[claim_choice][5:0],5'b0};state<=DESC_REQUEST;
         end
       DESC_REQUEST:if(rd_ready) state<=DESC_WAIT;
       DESC_WAIT:if(rd_done) begin
         if(rd_status!=0) begin failure_code<=1;state<=FAILED;end
         else if(abort_discard) state<=IDLE;
         else begin descriptor<=rd_data[511:0];state<=CHECK;end
       end
       CHECK:state<=abort_discard?IDLE:VALIDATE;
       VALIDATE:if(abort_discard) state<=IDLE;
         else if(!descriptor_valid_q) begin record_tick<=0;record_length<=0;record_status<=3;state<=CQ_REQUEST;end
         else state<=POLICY_WAIT;
       POLICY_WAIT:if(policy_done) begin
         if(abort_discard) state<=IDLE;
         else if(!policy_valid) begin record_tick<=0;record_length<=0;record_status<=3;state<=CQ_REQUEST;end
         else if(policy_lost) state<=STAGE;
         else state<=SG_START;
       end
       SG_START:if(abort_discard) state<=IDLE;else if(sg_ready) state<=SG_WAIT;
       SG_WAIT:if(sg_done) begin
         if(abort_discard || sg_status==1) state<=IDLE;
         else if(sg_status!=0) begin record_tick<=0;record_length<=0;record_status<=4;state<=CQ_REQUEST;end
         else state<=STAGE;
       end
       STAGE:begin
         if(!abort_discard) begin
           pending[selected]<=1;pending_lost[selected]<=policy_lost;pending_cookie[selected]<=cookie;
           pending_sequence[selected]<=sequence_saved;pending_epoch[selected]<=epoch_saved;pending_length[selected]<=frame_length;
         end
         state<=IDLE;
       end
       CQ_REQUEST:if(wr_ready) state<=CQ_WAIT;
       CQ_WAIT:if(wr_done) begin
         if(wr_status!=0) begin failure_code<=3;state<=FAILED;end
         else if(abort_discard) state<=IDLE;else state<=CQ_FENCE;
       end
       CQ_FENCE:if(rd_ready) state<=CQ_FENCE_WAIT;
       CQ_FENCE_WAIT:if(rd_done) begin
         if(rd_status!=0) begin failure_code<=4;state<=FAILED;end
         else if(abort_discard) state<=IDLE;else state<=PUBLISH;
       end
       PUBLISH:begin if(record_pending) pending[selected]<=0;state<=IDLE;end
       FAILED:begin if(record_pending) pending[selected]<=0;state<=IDLE;end
       default:state<=IDLE;
     endcase
   end
 end
endmodule
