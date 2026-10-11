module capture_ingress #(
 parameter integer FRAME_TIMEOUT=65536
)(
 input logic clk,rst,
 input logic admit,drop_on_full,abort_discard,
 input logic [63:0] tick,
 input logic [31:0] s_data,
 input logic [3:0] s_keep,
 input logic s_valid,s_last,
 output logic s_ready,
 input logic [1:0] default_queue,
 input logic [4:0] rule_control [0:7],
 input logic [31:0] rule_src [0:7],rule_src_mask [0:7],rule_dst [0:7],rule_dst_mask [0:7],rule_ports [0:7],
 output logic [2:0] occupancy [0:3],
 output logic [1:0] head_slot [0:3],
 output logic [15:0] head_length [0:3],
 output logic [63:0] head_tick [0:3],
 output logic [4:0] head_aux [0:3],
 input logic release_valid,
 input logic [1:0] release_queue,
 input logic [1:0] read_queue,read_slot,
 input logic [8:0] read_word,
 output logic [31:0] read_data,
 output logic busy,
 output logic event_valid,
 output logic [2:0] event_drop,
 output logic [1:0] event_queue,event_slot,
 output logic [15:0] event_length,
 output logic [63:0] event_tick,
 output logic [4:0] event_aux,
 output logic [63:0] drop_count [0:5],
 input logic flush
);
 typedef enum logic [1:0] {IDLE,RECEIVE,CLASSIFY,COMMIT} state_t;
 state_t state;
 logic [1:0] tail [0:3],reserved_slot[0:3];
 logic [3:0] free_mask,reserved_mask,write_mask;
 logic [511:0] header;
 logic [15:0] length;
 logic [9:0] word_index;
 logic mask_error,timeout_error,aborted;
 logic [31:0] age;
 logic [63:0] capture_tick;
 logic [2:0] parsed_drop,class_drop;
 logic parsed_valid,class_valid;
 logic [1:0] parsed_queue,class_queue;
 logic [3:0] parsed_rule,class_rule;
 logic [31:0] unused_src,unused_dst;
 logic [15:0] unused_sp,unused_dp;
 logic [31:0] bank_data [0:3];
 logic [1:0] read_queue_d;
 logic [15:0] slot_length [0:3][0:3];
 logic [63:0] slot_tick [0:3][0:3];
 logic [4:0] slot_aux [0:3][0:3];
 logic accepted,enqueue;
 logic [2:0] valid_bytes;
 always_comb begin
   for(integer q=0;q<4;q=q+1) begin
     free_mask[q]=occupancy[q]<4;
     head_length[q]=slot_length[q][head_slot[q]];
     head_tick[q]=slot_tick[q][head_slot[q]];
     head_aux[q]=slot_aux[q][head_slot[q]];
   end
   s_ready=(state==RECEIVE) || (state==IDLE && admit && (drop_on_full || (&free_mask)));
   accepted=s_valid && s_ready;
   valid_bytes={2'b0,s_keep[0]}+{2'b0,s_keep[1]}+{2'b0,s_keep[2]}+{2'b0,s_keep[3]};
   busy=state!=IDLE;
   write_mask=(state==IDLE)?free_mask:reserved_mask;
   enqueue=state==COMMIT && parsed_drop==0 && !aborted && !abort_discard;
   read_data=bank_data[read_queue_d];
 end
 packet_classifier classifier(header,length,mask_error,timeout_error,reserved_mask,default_queue,
   rule_control,rule_src,rule_src_mask,rule_dst,rule_dst_mask,rule_ports,
   class_drop,class_valid,class_queue,class_rule,unused_src,unused_dst,unused_sp,unused_dp);
 genvar gq;
 generate for(gq=0;gq<4;gq=gq+1) begin: banks
   (* ramstyle="M9K" *) logic [31:0] mem[0:2047];
   wire [10:0] write_address=(state==IDLE)?{tail[gq],9'b0}:{reserved_slot[gq],word_index[8:0]};
   always_ff @(posedge clk) begin
     if(accepted && write_mask[gq] && (state==IDLE || (length<1514 && !timeout_error && !aborted)))
       mem[write_address]<=s_data;
     bank_data[gq]<=mem[{read_slot,read_word}];
   end
 end endgenerate
 always_ff @(posedge clk) begin
   read_queue_d<=read_queue;
   if(rst) begin
     state<=IDLE; header<=0; length<=0; word_index<=0; reserved_mask<=0;
     mask_error<=0; timeout_error<=0; aborted<=0; age<=0; capture_tick<=0;
     parsed_drop<=0; parsed_valid<=0; parsed_queue<=0; parsed_rule<=0;
     event_valid<=0; event_drop<=0; event_queue<=0; event_slot<=0; event_length<=0; event_tick<=0; event_aux<=0;
     for(integer q=0;q<4;q=q+1) begin
       occupancy[q]<=0; head_slot[q]<=0; tail[q]<=0; reserved_slot[q]<=0;
       for(integer s=0;s<4;s=s+1) begin slot_length[q][s]<=0; slot_tick[q][s]<=0; slot_aux[q][s]<=0; end
     end
     for(integer k=0;k<6;k=k+1) drop_count[k]<=0;
   end else begin
     event_valid<=0;
     for(integer q=0;q<4;q=q+1) begin
       if(flush) begin occupancy[q]<=0; head_slot[q]<=0; tail[q]<=0; end else
       case({enqueue && parsed_queue==q,release_valid && release_queue==q && occupancy[q]!=0})
         2'b10: occupancy[q]<=occupancy[q]+1'b1;
         2'b01: occupancy[q]<=occupancy[q]-1'b1;
         default: occupancy[q]<=occupancy[q];
       endcase
       if(!flush && release_valid && release_queue==q && occupancy[q]!=0) head_slot[q]<=head_slot[q]+1'b1;
     end
     if(state==RECEIVE) begin
       if(age<FRAME_TIMEOUT) age<=age+1'b1;
       if(age>=FRAME_TIMEOUT-1) timeout_error<=1;
       if(abort_discard) aborted<=1;
     end
     if(accepted) begin
       if(state==IDLE) begin
         header<=0; header[31:0]<=s_data; length<=valid_bytes; word_index<=1;
         reserved_mask<=free_mask; capture_tick<=tick; age<=1; timeout_error<=0; aborted<=abort_discard;
         mask_error<=(!s_last && s_keep!=15) || !(s_keep==1 || s_keep==3 || s_keep==7 || s_keep==15);
         for(integer q=0;q<4;q=q+1) reserved_slot[q]<=tail[q];
       end else begin
         if(word_index<16) header[word_index*32 +: 32]<=s_data;
         if(word_index<512) word_index<=word_index+1'b1;
         if(length<65531) length<=length+valid_bytes; else length<=65535;
         if((!s_last && s_keep!=15) || !(s_keep==1 || s_keep==3 || s_keep==7 || s_keep==15)) mask_error<=1;
       end
       if(s_last) state<=CLASSIFY; else state<=RECEIVE;
     end
     if(state==CLASSIFY) begin
       parsed_drop<=class_drop; parsed_valid<=class_valid; parsed_queue<=class_queue; parsed_rule<=class_rule; state<=COMMIT;
     end
     if(state==COMMIT) begin
       event_valid<=!aborted && !abort_discard;
       event_drop<=parsed_drop; event_queue<=parsed_queue; event_slot<=reserved_slot[parsed_queue];
       event_length<=length; event_tick<=capture_tick; event_aux<={parsed_valid,parsed_rule};
       if(enqueue) begin
         slot_length[parsed_queue][reserved_slot[parsed_queue]]<=length;
         slot_tick[parsed_queue][reserved_slot[parsed_queue]]<=capture_tick;
         slot_aux[parsed_queue][reserved_slot[parsed_queue]]<={parsed_valid,parsed_rule};
         tail[parsed_queue]<=tail[parsed_queue]+1'b1;
       end
       if(!aborted && !abort_discard && parsed_drop!=0) drop_count[parsed_drop-1'b1]<=drop_count[parsed_drop-1'b1]+1'b1;
       state<=IDLE;
     end
   end
 end
endmodule
