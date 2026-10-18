module replay_staging(
 input logic clk,rst,abort_discard,input logic [63:0] tick,
 input logic write_valid,input logic [1:0] write_queue,input logic [8:0] write_word,
 input logic [31:0] write_data,input logic [3:0] write_keep,
 input logic stage_valid,input logic [1:0] stage_queue,input logic [15:0] stage_length,
 input logic [63:0] stage_due,input logic stage_lost,
 output logic [3:0] stage_ready,occupied,finished,
 output logic [63:0] departure_tick[0:3],
 input logic [3:0] release_head,
 output logic [31:0] m_data,output logic [3:0] m_keep,output logic m_valid,m_last,input logic m_ready,
 output logic busy
);
 logic [31:0] ram_data;logic [8:0] read_word;
 logic [15:0] lengths[0:3];logic [63:0] dues[0:3];logic [3:0] losses;
 logic [1:0] rr,selected,choice;logic choose;
 logic [8:0] word_index;logic started;logic [63:0] wait_time[0:3];
 // new head starts ineligible so a stale compare can never depart early
 logic [3:0] eligible_q;
 typedef enum logic [1:0] {IDLE,ADDRESS,SEND} state_t;
 state_t state;
 // one 2048x8 ram per byte lane, each the plain simple dual-port template
 // that quartus (M9K) and vivado (block ram) both infer; write_keep picks the
 // lanes. vivado turned the earlier packed byte-enable array into registers.
 genvar b;
 generate for(b=0;b<4;b=b+1) begin:lane
   (* ramstyle="M9K" *) logic [7:0] memory[0:2047];
   logic [7:0] q;
   always_ff @(posedge clk) begin
     if(write_valid && write_keep[b]) memory[{write_queue,write_word}]<=write_data[8*b+:8];
     q<=memory[{selected,read_word}];
   end
 end endgenerate
 assign ram_data={lane[3].q,lane[2].q,lane[1].q,lane[0].q};
 always_comb begin
   stage_ready=~occupied;busy=state!=IDLE;
   // look-ahead read: ram output only advances on a handshake
   read_word=(state==SEND && m_ready)?word_index+1'b1:word_index;
   choose=0;choice=rr;
   for(integer q=0;q<4;q++) wait_time[q]=tick-dues[q];
   for(integer k=0;k<4;k++)
     if(!choose && occupied[(rr+k)%4] && !finished[(rr+k)%4] && eligible_q[(rr+k)%4]) begin choose=1;choice=(rr+k)%4;end
   m_valid=state==SEND;
   m_data=ram_data;
   m_last=({7'b0,word_index}+1)*4>=lengths[selected];
   m_keep=(m_last && lengths[selected][1:0]!=0)?(4'hf>>(4-lengths[selected][1:0])):4'hf;
 end
 always_ff @(posedge clk) begin
`ifdef MUTATION_EARLY_DEPARTURE
   for(integer q=0;q<4;q++) eligible_q[q]<=1'b1;
`else
   for(integer q=0;q<4;q++) eligible_q[q]<=!wait_time[q][63];
`endif
   if(stage_valid) eligible_q[stage_queue]<=0;
   if(rst) begin
     eligible_q<=0;occupied<=0;finished<=0;losses<=0;rr<=0;selected<=0;word_index<=0;started<=0;state<=IDLE;
     for(integer q=0;q<4;q++) begin lengths[q]<=0;dues[q]<=0;departure_tick[q]<=0;end
   end else begin
     for(integer q=0;q<4;q++) if(release_head[q]) begin occupied[q]<=0;finished[q]<=0;end
     if(stage_valid && stage_ready[stage_queue] && !abort_discard) begin
       occupied[stage_queue]<=1;finished[stage_queue]<=0;lengths[stage_queue]<=stage_length;dues[stage_queue]<=stage_due;losses[stage_queue]<=stage_lost;
     end
     case(state)
       IDLE:if(choose && !abort_discard) begin
         if(losses[choice]) begin finished[choice]<=1;departure_tick[choice]<=dues[choice];rr<=choice+1'b1;end
         else begin selected<=choice;word_index<=0;started<=0;state<=ADDRESS;end
       end
       ADDRESS:state<=SEND;
       SEND:if(m_valid && m_ready) begin
         if(!started) begin departure_tick[selected]<=tick;started<=1;end
         if(m_last) begin finished[selected]<=1;rr<=selected+1'b1;state<=IDLE;started<=0;end
         else word_index<=word_index+1'b1;
       end
       default:state<=IDLE;
     endcase
     if(abort_discard && state==IDLE) begin occupied<=0;finished<=0;end
     if(abort_discard && state!=IDLE && !started && state!=SEND) begin state<=IDLE;end
   end
 end
endmodule
