module engine_control(
 input logic clk,rst,input logic [63:0] tick,input logic quiescent,abort_done,
 input logic [63:0] drop_count[0:5],
 input logic [7:0] claim,commit,fault,
 input logic [3:0] fault_code[0:7],
 output logic [7:0] claim_ready,reserved,halted,
 output logic [31:0] sq_base[0:7],cq_base[0:7],sq_producer[0:7],sq_consumer[0:7],cq_producer[0:7],cq_consumer[0:7],
 output logic running,aborting,irq,notification_rearm,output logic [31:0] epoch,
 output logic fixed_mode,drop_on_full,output logic [1:0] default_queue,
 output logic [63:0] replay_start,replay_origin,replay_interval,queue_delay[0:3],
 output logic [31:0] loss_seed,output logic [32:0] loss_threshold,
 output logic [4:0] rule_control[0:7],
 output logic [31:0] rule_src[0:7],rule_src_mask[0:7],rule_dst[0:7],rule_dst_mask[0:7],rule_ports[0:7],
 input logic [31:0] s_awaddr,input logic s_awvalid,output logic s_awready,
 input logic [31:0] s_wdata,input logic [3:0] s_wstrb,input logic s_wvalid,output logic s_wready,
 output logic [1:0] s_bresp,output logic s_bvalid,input logic s_bready,
 input logic [31:0] s_araddr,input logic s_arvalid,output logic s_arready,
 output logic [31:0] s_rdata,output logic [1:0] s_rresp,output logic s_rvalid,input logic s_rready
);
 logic aw_held,w_held;logic [31:0] write_address,write_data;logic [3:0] write_strobe;
 logic [8:0] irq_mask,irq_conditions;logic [7:0] events;
 logic [3:0] sticky_fault;logic [2:0] sticky_ring;logic [31:0] sticky_sequence;
 logic [63:0] snapshot_tick,snapshot_drop[0:5];
 logic [31:0] read_value,old_value,candidate,byte_mask,delta,used;
 logic read_valid,write_ok,config_locked,execute_write,full_strobe,fault_clear;
 integer write_ring,write_rule,write_queue;
 typedef enum logic [5:0] {INVALID,COMMAND,IRQ_MASK,IRQ_ACK,FAULT_CLEAR,SNAPSHOT,MODE,DEFAULTS,
 START_LO,START_HI,ORIGIN_LO,ORIGIN_HI,INTERVAL_LO,INTERVAL_HI,SEED,THRESHOLD_LO,THRESHOLD_HI,
 DELAY_LO,DELAY_HI,RULE_CONTROL,RULE_SRC,RULE_SRC_MASK,RULE_DST,RULE_DST_MASK,RULE_PORTS,
 SQ_BASE,CQ_BASE,SQ_DOORBELL,CQ_ACK,RING_RECOVER,COUNTER_ORIGIN} write_kind_t;
 write_kind_t kind;
 write_kind_t d_kind;logic [2:0] d_ring,d_rule;logic [1:0] d_queue;logic [31:0] d_candidate;logic decoded;
 // ar_address holds the AR-handshake address; the master may change s_araddr afterwards.
 logic [31:0] ar_address;logic r_pending;logic [7:0] claim_eligible;
 function automatic logic base_legal(input logic [31:0] value,input integer ring_index,input logic completion_base);
   logic good;
   begin
     good=value[10:0]==0 && value<=32'h3f800 && !(value<32'h1f008 && value+2048>32'h1f000);
     for(integer j=0;j<8;j++) begin
       if((j!=ring_index || completion_base) && value==sq_base[j]) good=0;
       if((j!=ring_index || !completion_base) && value==cq_base[j]) good=0;
     end
     return good;
   end
 endfunction
 always_comb begin
   config_locked=running || !quiescent || aborting;
   for(integer i=0;i<8;i++) begin
     // a reservation counts as a used credit, so a stale value only delays a claim
     claim_ready[i]=claim_eligible[i] && !halted[i] && !reserved[i];
     irq_conditions[i]=events[i] || cq_producer[i]!=cq_consumer[i];
   end
   irq_conditions[8]=sticky_fault!=0;irq=|(irq_conditions&irq_mask);
   s_awready=!aw_held && !s_bvalid;s_wready=!w_held && !s_bvalid;s_arready=!s_rvalid && !r_pending;
   execute_write=decoded && !s_bvalid;
   read_value=0;read_valid=ar_address[1:0]==0;
   case(ar_address)
     'h0000:read_value=32'h4e455431;
     'h0004:read_value=1;
     'h000c:read_value={29'b0,aborting,quiescent,running};
     'h0010:read_value=epoch;
     'h0020:read_value={23'b0,irq_mask};
     'h0024:read_value={23'b0,irq_conditions};
     'h0030:read_value={28'b0,sticky_fault};
     'h0038:read_value={29'b0,sticky_ring};
     'h003c:read_value=sticky_sequence;
     'h0048:read_value=snapshot_tick[31:0];
     'h004c:read_value=snapshot_tick[63:32];
     'h0100:read_value={31'b0,fixed_mode};
     'h0104:read_value={29'b0,drop_on_full,default_queue};
     'h0108:read_value=replay_start[31:0]; 'h010c:read_value=replay_start[63:32];
     'h0110:read_value=replay_origin[31:0]; 'h0114:read_value=replay_origin[63:32];
     'h0118:read_value=replay_interval[31:0]; 'h011c:read_value=replay_interval[63:32];
     'h0120:read_value=loss_seed;
     'h0124:read_value=loss_threshold[31:0]; 'h0128:read_value={31'b0,loss_threshold[32]};
     default:begin
       read_valid=0;
       for(integer q=0;q<4;q++) begin
         if(ar_address==32'h140+q*8) begin read_value=queue_delay[q][31:0];read_valid=1;end
         if(ar_address==32'h144+q*8) begin read_value=queue_delay[q][63:32];read_valid=1;end
       end
       for(integer r=0;r<8;r++) begin
         if(ar_address==32'h200+r*32) begin read_value={27'b0,rule_control[r]};read_valid=1;end
         if(ar_address==32'h204+r*32) begin read_value=rule_src[r];read_valid=1;end
         if(ar_address==32'h208+r*32) begin read_value=rule_src_mask[r];read_valid=1;end
         if(ar_address==32'h20c+r*32) begin read_value=rule_dst[r];read_valid=1;end
         if(ar_address==32'h210+r*32) begin read_value=rule_dst_mask[r];read_valid=1;end
         if(ar_address==32'h214+r*32) begin read_value=rule_ports[r];read_valid=1;end
         if(ar_address==((r<4?32'h400:32'h800)+(r%4)*64)) begin read_value=sq_base[r];read_valid=1;end
         if(ar_address==((r<4?32'h404:32'h804)+(r%4)*64)) begin read_value=cq_base[r];read_valid=1;end
         if(ar_address==((r<4?32'h408:32'h808)+(r%4)*64)) begin read_value=sq_producer[r];read_valid=1;end
         if(ar_address==((r<4?32'h40c:32'h80c)+(r%4)*64)) begin read_value=sq_consumer[r];read_valid=1;end
         if(ar_address==((r<4?32'h410:32'h810)+(r%4)*64)) begin read_value=cq_producer[r];read_valid=1;end
         if(ar_address==((r<4?32'h414:32'h814)+(r%4)*64)) begin read_value=cq_consumer[r];read_valid=1;end
         if(ar_address==((r<4?32'h418:32'h818)+(r%4)*64)) begin read_value={30'b0,halted[r],reserved[r]};read_valid=1;end
       end
       for(integer d=0;d<6;d++) begin
         if(ar_address==32'hc00+d*8) begin read_value=snapshot_drop[d][31:0];read_valid=1;end
         if(ar_address==32'hc04+d*8) begin read_value=snapshot_drop[d][63:32];read_valid=1;end
       end
     end
   endcase
   kind=INVALID;old_value=0;write_ring=0;write_rule=0;write_queue=0;
   case(write_address)
     'h0008:kind=COMMAND;
     'h0020:begin kind=IRQ_MASK;old_value={23'b0,irq_mask};end
     'h0028:kind=IRQ_ACK;
     'h0034:kind=FAULT_CLEAR;
     'h0040:kind=SNAPSHOT;
     'h0100:begin kind=MODE;old_value={31'b0,fixed_mode};end
     'h0104:begin kind=DEFAULTS;old_value={29'b0,drop_on_full,default_queue};end
     'h0108:begin kind=START_LO;old_value=replay_start[31:0];end
     'h010c:begin kind=START_HI;old_value=replay_start[63:32];end
     'h0110:begin kind=ORIGIN_LO;old_value=replay_origin[31:0];end
     'h0114:begin kind=ORIGIN_HI;old_value=replay_origin[63:32];end
     'h0118:begin kind=INTERVAL_LO;old_value=replay_interval[31:0];end
     'h011c:begin kind=INTERVAL_HI;old_value=replay_interval[63:32];end
     'h0120:begin kind=SEED;old_value=loss_seed;end
     'h0124:begin kind=THRESHOLD_LO;old_value=loss_threshold[31:0];end
     'h0128:begin kind=THRESHOLD_HI;old_value={31'b0,loss_threshold[32]};end
     default:begin
       for(integer q=0;q<4;q++) begin
         if(write_address==32'h140+q*8) begin kind=DELAY_LO;write_queue=q;old_value=queue_delay[q][31:0];end
         if(write_address==32'h144+q*8) begin kind=DELAY_HI;write_queue=q;old_value=queue_delay[q][63:32];end
       end
       for(integer r=0;r<8;r++) begin
         if(write_address==32'h200+r*32) begin kind=RULE_CONTROL;write_rule=r;old_value={27'b0,rule_control[r]};end
         if(write_address==32'h204+r*32) begin kind=RULE_SRC;write_rule=r;old_value=rule_src[r];end
         if(write_address==32'h208+r*32) begin kind=RULE_SRC_MASK;write_rule=r;old_value=rule_src_mask[r];end
         if(write_address==32'h20c+r*32) begin kind=RULE_DST;write_rule=r;old_value=rule_dst[r];end
         if(write_address==32'h210+r*32) begin kind=RULE_DST_MASK;write_rule=r;old_value=rule_dst_mask[r];end
         if(write_address==32'h214+r*32) begin kind=RULE_PORTS;write_rule=r;old_value=rule_ports[r];end
         if(write_address==((r<4?32'h400:32'h800)+(r%4)*64)) begin kind=SQ_BASE;write_ring=r;old_value=sq_base[r];end
         if(write_address==((r<4?32'h404:32'h804)+(r%4)*64)) begin kind=CQ_BASE;write_ring=r;old_value=cq_base[r];end
         if(write_address==((r<4?32'h408:32'h808)+(r%4)*64)) begin kind=SQ_DOORBELL;write_ring=r;end
         if(write_address==((r<4?32'h414:32'h814)+(r%4)*64)) begin kind=CQ_ACK;write_ring=r;end
         if(write_address==((r<4?32'h41c:32'h81c)+(r%4)*64)) begin kind=RING_RECOVER;write_ring=r;end
         if(write_address==((r<4?32'h420:32'h820)+(r%4)*64)) begin kind=COUNTER_ORIGIN;write_ring=r;end
       end
     end
   endcase
   for(integer b=0;b<4;b++) byte_mask[b*8+:8]={8{write_strobe[b]}};
   candidate=(old_value&~byte_mask)|(write_data&byte_mask);
   full_strobe=write_strobe==4'hf;delta=0;used=0;
   // an accepted FAULT_CLEAR, the same as write_ok for that kind; computed on
   // its own so the sticky fault registers do not wait for the ring checks
   fault_clear=execute_write && d_kind==FAULT_CLEAR && full_strobe && write_data==1 && !config_locked;
   write_ok=d_kind!=INVALID;
   if(write_strobe!=0) begin
     if(d_kind>=MODE && config_locked && d_kind!=SQ_DOORBELL && d_kind!=CQ_ACK) write_ok=0;
     case(d_kind)
       COMMAND:if(!full_strobe || !(write_data==1 || write_data==2 || write_data==4) ||
         (write_data==1 && config_locked) || (write_data==4 && aborting)) write_ok=0;
       IRQ_MASK:if(d_candidate>511) write_ok=0;
       IRQ_ACK:if(!full_strobe || write_data>255) write_ok=0;
       FAULT_CLEAR:if(!full_strobe || write_data!=1 || config_locked) write_ok=0;
       SNAPSHOT:if(!full_strobe || write_data!=1) write_ok=0;
       MODE:if(d_candidate>1) write_ok=0;
       DEFAULTS:if(d_candidate>7) write_ok=0;
       THRESHOLD_LO:if(loss_threshold[32] && d_candidate!=0) write_ok=0;
       THRESHOLD_HI:if(d_candidate>1 || (d_candidate==1 && loss_threshold[31:0]!=0)) write_ok=0;
       RULE_CONTROL:if(d_candidate>31) write_ok=0;
       SQ_BASE:if(!base_legal(d_candidate,d_ring,0) || reserved[d_ring] || sq_producer[d_ring]!=sq_consumer[d_ring] || cq_producer[d_ring]!=cq_consumer[d_ring]) write_ok=0;
       CQ_BASE:if(!base_legal(d_candidate,d_ring,1) || reserved[d_ring] || sq_producer[d_ring]!=sq_consumer[d_ring] || cq_producer[d_ring]!=cq_consumer[d_ring]) write_ok=0;
       SQ_DOORBELL:begin
         delta=write_data-sq_producer[d_ring];used=sq_producer[d_ring]-sq_consumer[d_ring];
         if(!full_strobe || delta>32-used) write_ok=0;
       end
       CQ_ACK:begin
         delta=write_data-cq_consumer[d_ring];used=cq_producer[d_ring]-cq_consumer[d_ring];
         if(!full_strobe || delta>used) write_ok=0;
       end
       RING_RECOVER:if(!full_strobe || write_data!=1 || reserved[d_ring]) write_ok=0;
       COUNTER_ORIGIN:if(!full_strobe || reserved[d_ring] || sq_producer[d_ring]!=sq_consumer[d_ring] ||
         cq_producer[d_ring]!=cq_consumer[d_ring]) write_ok=0;
       default:begin end
     endcase
   end
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     aw_held<=0;w_held<=0;write_address<=0;write_data<=0;write_strobe<=0;s_bvalid<=0;s_bresp<=0;s_rvalid<=0;s_rresp<=0;s_rdata<=0;
     running<=0;aborting<=0;epoch<=0;irq_mask<=0;events<=0;notification_rearm<=0;
     decoded<=0;d_kind<=INVALID;d_ring<=0;d_rule<=0;d_queue<=0;d_candidate<=0;ar_address<=0;r_pending<=0;claim_eligible<=0;
     sticky_fault<=0;sticky_ring<=0;sticky_sequence<=0;reserved<=0;halted<=0;
     snapshot_tick<=0;fixed_mode<=0;default_queue<=0;drop_on_full<=0;replay_start<=0;replay_origin<=0;replay_interval<=0;loss_seed<=0;loss_threshold<=0;
     for(integer d=0;d<6;d++) snapshot_drop[d]<=0;
     for(integer q=0;q<4;q++) queue_delay[q]<=0;
     for(integer r=0;r<8;r++) begin
       rule_control[r]<=0;rule_src[r]<=0;rule_src_mask[r]<=0;rule_dst[r]<=0;rule_dst_mask[r]<=0;rule_ports[r]<=0;
       sq_base[r]<=32'h10000+r*2048;cq_base[r]<=32'h14000+r*2048;
       sq_producer[r]<=0;sq_consumer[r]<=0;cq_producer[r]<=0;cq_consumer[r]<=0;
     end
   end else begin
     notification_rearm<=0;
     if(s_awvalid && s_awready) begin aw_held<=1;write_address<=s_awaddr;end
     if(s_wvalid && s_wready) begin w_held<=1;write_data<=s_wdata;write_strobe<=s_wstrb;end
     if(s_bvalid && s_bready) s_bvalid<=0;
     if(s_rvalid && s_rready) s_rvalid<=0;
     if(s_arvalid && s_arready) begin ar_address<=s_araddr;r_pending<=1;end
     if(r_pending) begin r_pending<=0;s_rvalid<=1;s_rresp<=read_valid?0:2;s_rdata<=read_valid?read_value:0;end
     if(aw_held && w_held && !decoded && !s_bvalid) begin
       decoded<=1;d_kind<=write_address[1:0]==0?kind:INVALID;d_ring<=write_ring[2:0];d_rule<=write_rule[2:0];
       d_queue<=write_queue[1:0];d_candidate<=candidate;
     end
     for(integer r=0;r<8;r++) claim_eligible[r]<=sq_producer[r]!=sq_consumer[r] && (cq_producer[r]-cq_consumer[r]+reserved[r])<32'd64;
     if(execute_write) begin
       aw_held<=0;w_held<=0;decoded<=0;s_bvalid<=1;s_bresp<=write_ok?0:2;
       if(fault_clear) begin sticky_fault<=0;sticky_ring<=0;sticky_sequence<=0;end
       if(write_ok && write_strobe!=0) case(d_kind)
         COMMAND:case(write_data)
           1:running<=1;
           2:running<=0;
           4:begin running<=0;aborting<=1;end
           default:begin end
         endcase
         IRQ_MASK:irq_mask<=d_candidate[8:0];
         IRQ_ACK:begin events<=events&~write_data[7:0];notification_rearm<=1;end
         SNAPSHOT:begin snapshot_tick<=tick;for(integer d=0;d<6;d++) snapshot_drop[d]<=drop_count[d];end
         MODE:fixed_mode<=d_candidate[0];
         DEFAULTS:begin default_queue<=d_candidate[1:0];drop_on_full<=d_candidate[2];end
         START_LO:replay_start[31:0]<=d_candidate;START_HI:replay_start[63:32]<=d_candidate;
         ORIGIN_LO:replay_origin[31:0]<=d_candidate;ORIGIN_HI:replay_origin[63:32]<=d_candidate;
         INTERVAL_LO:replay_interval[31:0]<=d_candidate;INTERVAL_HI:replay_interval[63:32]<=d_candidate;
         SEED:loss_seed<=d_candidate;
         THRESHOLD_LO:loss_threshold[31:0]<=d_candidate;THRESHOLD_HI:loss_threshold[32]<=d_candidate[0];
         DELAY_LO:queue_delay[d_queue][31:0]<=d_candidate;DELAY_HI:queue_delay[d_queue][63:32]<=d_candidate;
         RULE_CONTROL:rule_control[d_rule]<=d_candidate[4:0];
         RULE_SRC:rule_src[d_rule]<=d_candidate;RULE_SRC_MASK:rule_src_mask[d_rule]<=d_candidate;
         RULE_DST:rule_dst[d_rule]<=d_candidate;RULE_DST_MASK:rule_dst_mask[d_rule]<=d_candidate;RULE_PORTS:rule_ports[d_rule]<=d_candidate;
         SQ_BASE:sq_base[d_ring]<=d_candidate;CQ_BASE:cq_base[d_ring]<=d_candidate;
         SQ_DOORBELL:sq_producer[d_ring]<=write_data;
         CQ_ACK:cq_consumer[d_ring]<=write_data;
         RING_RECOVER:begin halted[d_ring]<=0;sq_producer[d_ring]<=sq_consumer[d_ring];end
         COUNTER_ORIGIN:begin sq_producer[d_ring]<=write_data;sq_consumer[d_ring]<=write_data;cq_producer[d_ring]<=write_data;cq_consumer[d_ring]<=write_data;end
         default:begin end
       endcase
     end
     if(aborting && abort_done && quiescent) begin aborting<=0;epoch<=epoch+1'b1;reserved<=0;end
     for(integer r=0;r<8;r++) begin
       if(claim[r] && claim_ready[r]) begin reserved[r]<=1;sq_consumer[r]<=sq_consumer[r]+1'b1;end
       if(commit[r] && reserved[r] && !fault[r]) begin reserved[r]<=0;cq_producer[r]<=cq_producer[r]+1'b1;events[r]<=1;end
       if(fault[r]) begin halted[r]<=1;reserved[r]<=0;end
     end
     for(integer r=7;r>=0;r--) if(fault[r] && (sticky_fault==0 || fault_clear)) begin
       sticky_fault<=fault_code[r];sticky_ring<=r[2:0];sticky_sequence<=sq_consumer[r]-1'b1;
     end
   end
 end
endmodule
