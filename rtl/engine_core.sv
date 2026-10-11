module engine_core(
 input logic clk,rst,
 input logic [31:0] s_data,input logic [3:0] s_keep,input logic s_valid,s_last,output logic s_ready,
 output logic [31:0] m_data,output logic [3:0] m_keep,output logic m_valid,m_last,input logic m_ready,
 input logic [31:0] s_awaddr,input logic s_awvalid,output logic s_awready,
 input logic [31:0] s_wdata,input logic [3:0] s_wstrb,input logic s_wvalid,output logic s_wready,
 output logic [1:0] s_bresp,output logic s_bvalid,input logic s_bready,
 input logic [31:0] s_araddr,input logic s_arvalid,output logic s_arready,
 output logic [31:0] s_rdata,output logic [1:0] s_rresp,output logic s_rvalid,input logic s_rready,
 output logic rd_valid,input logic rd_ready,output logic [31:0] rd_address,output logic [7:0] rd_bytes,
 input logic rd_done,input logic [1:0] rd_status,input logic [1023:0] rd_data,
 output logic wr_valid,input logic wr_ready,output logic [31:0] wr_address,output logic [7:0] wr_bytes,output logic [1023:0] wr_data,
 input logic wr_done,input logic [1:0] wr_status,
 output logic irq,notification_rearm,quiescent,running,
 output logic [63:0] tick
);
 logic aborting,abort_done,idle_all,queues_empty,flush,admit;
 logic [31:0] epoch;
 logic [63:0] drop_count[0:5];
 logic [7:0] claim,commit,fault,claim_ready,reserved,halted;
 logic [3:0] fault_code[0:7],capture_fault_code[0:3],replay_fault_code[0:3];
 logic [31:0] sq_base[0:7],cq_base[0:7],sq_producer[0:7],sq_consumer[0:7],cq_producer[0:7],cq_consumer[0:7];
 logic [31:0] c_sq_base[0:3],c_cq_base[0:3],c_sq_consumer[0:3],c_cq_producer[0:3];
 logic [31:0] r_sq_base[0:3],r_cq_base[0:3],r_sq_consumer[0:3],r_cq_producer[0:3];
 logic fixed_mode,drop_on_full;logic [1:0] default_queue;
 logic [63:0] replay_start,replay_origin,replay_interval,queue_delay[0:3];
 logic [31:0] loss_seed;logic [32:0] loss_threshold;
 logic [4:0] rule_control[0:7];
 logic [31:0] rule_src[0:7],rule_src_mask[0:7],rule_dst[0:7],rule_dst_mask[0:7],rule_ports[0:7];
 logic [2:0] occupancy[0:3];logic [1:0] head_slot[0:3];logic [15:0] head_length[0:3];
 logic [63:0] head_tick[0:3];logic [4:0] head_aux[0:3];
 logic release_valid;logic [1:0] release_queue,read_queue,read_slot;logic [8:0] read_word;logic [31:0] read_data;
 logic ingress_busy,event_valid;logic [2:0] event_drop;logic [1:0] event_queue,event_slot;
 logic [15:0] event_length;logic [63:0] event_tick;logic [4:0] event_aux;
 logic [3:0] capture_claim,capture_commit,capture_fault,replay_claim,replay_commit,replay_fault;
 logic capture_busy,replay_busy,staging_busy,arbiter_busy,unused_read_owner,unused_write_owner;
 logic local_write_valid;logic [1:0] local_write_queue;logic [8:0] local_write_word;logic [31:0] local_write_data;logic [3:0] local_write_keep;
 logic stage_valid,stage_lost;logic [1:0] stage_queue;logic [15:0] stage_length;logic [63:0] stage_due;
 logic [3:0] stage_ready,occupied,finished,release_head;logic [63:0] departure_tick[0:3];
 logic [1:0] c_rd_valid,c_rd_ready,c_rd_done,c_wr_valid,c_wr_ready,c_wr_done;
 logic [31:0] c_rd_address[0:1],c_wr_address[0:1];logic [7:0] c_rd_bytes[0:1],c_wr_bytes[0:1];
 logic [1:0] c_rd_status[0:1],c_wr_status[0:1];logic [1023:0] c_rd_data[0:1],c_wr_data[0:1];
 always_ff @(posedge clk) if(rst) tick<=0;else tick<=tick+1'b1;
 always_comb begin
   admit=running && !aborting;
   idle_all=!ingress_busy && !capture_busy && !replay_busy && !staging_busy && !arbiter_busy;
   queues_empty=occupied==0;
   for(integer q=0;q<4;q++) if(occupancy[q]!=0) queues_empty=0;
   flush=aborting && idle_all;
   quiescent=!running && idle_all && queues_empty;
   abort_done=idle_all && queues_empty;
   claim={replay_claim,capture_claim};commit={replay_commit,capture_commit};fault={replay_fault,capture_fault};
   for(integer q=0;q<4;q++) begin
     fault_code[q]=capture_fault_code[q];fault_code[q+4]=replay_fault_code[q];
     c_sq_base[q]=sq_base[q];c_cq_base[q]=cq_base[q];c_sq_consumer[q]=sq_consumer[q];c_cq_producer[q]=cq_producer[q];
     r_sq_base[q]=sq_base[q+4];r_cq_base[q]=cq_base[q+4];r_sq_consumer[q]=sq_consumer[q+4];r_cq_producer[q]=cq_producer[q+4];
   end
 end
 engine_control control(.clk(clk),.rst(rst),.tick(tick),.quiescent(quiescent),.abort_done(abort_done),.drop_count(drop_count),
   .claim(claim),.commit(commit),.fault(fault),.fault_code(fault_code),.claim_ready(claim_ready),.reserved(reserved),.halted(halted),
   .sq_base(sq_base),.cq_base(cq_base),.sq_producer(sq_producer),.sq_consumer(sq_consumer),.cq_producer(cq_producer),.cq_consumer(cq_consumer),
   .running(running),.aborting(aborting),.irq(irq),.notification_rearm(notification_rearm),.epoch(epoch),
   .fixed_mode(fixed_mode),.drop_on_full(drop_on_full),.default_queue(default_queue),
   .replay_start(replay_start),.replay_origin(replay_origin),.replay_interval(replay_interval),.queue_delay(queue_delay),
   .loss_seed(loss_seed),.loss_threshold(loss_threshold),.rule_control(rule_control),
   .rule_src(rule_src),.rule_src_mask(rule_src_mask),.rule_dst(rule_dst),.rule_dst_mask(rule_dst_mask),.rule_ports(rule_ports),
   .s_awaddr(s_awaddr),.s_awvalid(s_awvalid),.s_awready(s_awready),.s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wvalid(s_wvalid),.s_wready(s_wready),
   .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),.s_araddr(s_araddr),.s_arvalid(s_arvalid),.s_arready(s_arready),
   .s_rdata(s_rdata),.s_rresp(s_rresp),.s_rvalid(s_rvalid),.s_rready(s_rready));
 capture_ingress ingress(clk,rst,admit,drop_on_full,aborting,tick,s_data,s_keep,s_valid,s_last,s_ready,default_queue,
   rule_control,rule_src,rule_src_mask,rule_dst,rule_dst_mask,rule_ports,occupancy,head_slot,head_length,head_tick,head_aux,
   release_valid,release_queue,read_queue,read_slot,read_word,read_data,ingress_busy,
   event_valid,event_drop,event_queue,event_slot,event_length,event_tick,event_aux,drop_count,flush);
 capture_dma capture(.clk(clk),.rst(rst),.abort_discard(aborting),.epoch(epoch),.claim_ready(claim_ready[3:0]),
   .sq_base(c_sq_base),.cq_base(c_cq_base),.sq_consumer(c_sq_consumer),.cq_producer(c_cq_producer),
   .occupancy(occupancy),.head_slot(head_slot),.head_length(head_length),.head_tick(head_tick),.head_aux(head_aux),
   .claim(capture_claim),.commit(capture_commit),.fault(capture_fault),.fault_code(capture_fault_code),
   .release_valid(release_valid),.release_queue(release_queue),.read_queue(read_queue),.read_slot(read_slot),
   .read_word(read_word),.read_data(read_data),.busy(capture_busy),
   .rd_valid(c_rd_valid[0]),.rd_ready(c_rd_ready[0]),.rd_address(c_rd_address[0]),.rd_bytes(c_rd_bytes[0]),
   .rd_done(c_rd_done[0]),.rd_status(c_rd_status[0]),.rd_data(c_rd_data[0]),
   .wr_valid(c_wr_valid[0]),.wr_ready(c_wr_ready[0]),.wr_address(c_wr_address[0]),.wr_bytes(c_wr_bytes[0]),.wr_data(c_wr_data[0]),
   .wr_done(c_wr_done[0]),.wr_status(c_wr_status[0]));
 replay_dma replay(.clk(clk),.rst(rst),.abort_discard(aborting),.running(running),.epoch(epoch),.claim_ready(claim_ready[7:4]),
   .sq_base(r_sq_base),.cq_base(r_cq_base),.sq_consumer(r_sq_consumer),.cq_producer(r_cq_producer),
   .fixed_mode(fixed_mode),.replay_start(replay_start),.replay_origin(replay_origin),.replay_interval(replay_interval),.queue_delay(queue_delay),
   .loss_seed(loss_seed),.loss_threshold(loss_threshold),
   .claim(replay_claim),.commit(replay_commit),.fault(replay_fault),.fault_code(replay_fault_code),
   .local_write_valid(local_write_valid),.local_write_queue(local_write_queue),.local_write_word(local_write_word),
   .local_write_data(local_write_data),.local_write_keep(local_write_keep),
   .stage_valid(stage_valid),.stage_queue(stage_queue),.stage_length(stage_length),.stage_due(stage_due),.stage_lost(stage_lost),
   .stage_ready(stage_ready),.finished(finished),.departure_tick(departure_tick),.release_head(release_head),.busy(replay_busy),
   .rd_valid(c_rd_valid[1]),.rd_ready(c_rd_ready[1]),.rd_address(c_rd_address[1]),.rd_bytes(c_rd_bytes[1]),
   .rd_done(c_rd_done[1]),.rd_status(c_rd_status[1]),.rd_data(c_rd_data[1]),
   .wr_valid(c_wr_valid[1]),.wr_ready(c_wr_ready[1]),.wr_address(c_wr_address[1]),.wr_bytes(c_wr_bytes[1]),.wr_data(c_wr_data[1]),
   .wr_done(c_wr_done[1]),.wr_status(c_wr_status[1]));
 replay_staging staging(.clk(clk),.rst(rst),.abort_discard(aborting),.tick(tick),
   .write_valid(local_write_valid),.write_queue(local_write_queue),.write_word(local_write_word),.write_data(local_write_data),.write_keep(local_write_keep),
   .stage_valid(stage_valid),.stage_queue(stage_queue),.stage_length(stage_length),.stage_due(stage_due),.stage_lost(stage_lost),
   .stage_ready(stage_ready),.occupied(occupied),.finished(finished),.departure_tick(departure_tick),.release_head(release_head),
   .m_data(m_data),.m_keep(m_keep),.m_valid(m_valid),.m_last(m_last),.m_ready(m_ready),.busy(staging_busy));
 dma_command_arbiter arbiter(.clk(clk),.rst(rst),
   .c_rd_valid(c_rd_valid),.c_rd_ready(c_rd_ready),.c_rd_address(c_rd_address),.c_rd_bytes(c_rd_bytes),
   .c_rd_done(c_rd_done),.c_rd_status(c_rd_status),.c_rd_data(c_rd_data),
   .c_wr_valid(c_wr_valid),.c_wr_ready(c_wr_ready),.c_wr_address(c_wr_address),.c_wr_bytes(c_wr_bytes),.c_wr_data(c_wr_data),
   .c_wr_done(c_wr_done),.c_wr_status(c_wr_status),
   .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_address(rd_address),.rd_bytes(rd_bytes),.rd_done(rd_done),.rd_status(rd_status),.rd_data(rd_data),
   .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_address(wr_address),.wr_bytes(wr_bytes),.wr_data(wr_data),.wr_done(wr_done),.wr_status(wr_status),
   .busy(arbiter_busy),.read_owner(unused_read_owner),.write_owner(unused_write_owner));
endmodule

module engine_axi(
 input logic clk,rst,
 input logic [31:0] s_data,input logic [3:0] s_keep,input logic s_valid,s_last,output logic s_ready,
 output logic [31:0] m_data,output logic [3:0] m_keep,output logic m_valid,m_last,input logic m_ready,
 input logic [31:0] s_awaddr,input logic s_awvalid,output logic s_awready,
 input logic [31:0] s_wdata,input logic [3:0] s_wstrb,input logic s_wvalid,output logic s_wready,
 output logic [1:0] s_bresp,output logic s_bvalid,input logic s_bready,
 input logic [31:0] s_araddr,input logic s_arvalid,output logic s_arready,
 output logic [31:0] s_rdata,output logic [1:0] s_rresp,output logic s_rvalid,input logic s_rready,
 output logic [31:0] m_awaddr,output logic [7:0] m_awlen,output logic [2:0] m_awsize,
 output logic [1:0] m_awburst,output logic m_awvalid,input logic m_awready,
 output logic [63:0] m_wdata,output logic [7:0] m_wstrb,output logic m_wlast,m_wvalid,input logic m_wready,
 input logic [1:0] m_bresp,input logic m_bvalid,output logic m_bready,
 output logic [31:0] m_araddr,output logic [7:0] m_arlen,output logic [2:0] m_arsize,
 output logic [1:0] m_arburst,output logic m_arvalid,input logic m_arready,
 input logic [63:0] m_rdata,input logic [1:0] m_rresp,input logic m_rlast,m_rvalid,output logic m_rready,
 output logic irq,quiescent,running,output logic [63:0] tick
);
 logic rd_valid,rd_ready,rd_done,wr_valid,wr_ready,wr_done,unused_rearm;
 logic [31:0] rd_address,wr_address;logic [7:0] rd_bytes,wr_bytes;logic [1:0] rd_status,wr_status;logic [1023:0] rd_data,wr_data;
 engine_core core(.clk(clk),.rst(rst),.s_data(s_data),.s_keep(s_keep),.s_valid(s_valid),.s_last(s_last),.s_ready(s_ready),
   .m_data(m_data),.m_keep(m_keep),.m_valid(m_valid),.m_last(m_last),.m_ready(m_ready),
   .s_awaddr(s_awaddr),.s_awvalid(s_awvalid),.s_awready(s_awready),.s_wdata(s_wdata),.s_wstrb(s_wstrb),.s_wvalid(s_wvalid),.s_wready(s_wready),
   .s_bresp(s_bresp),.s_bvalid(s_bvalid),.s_bready(s_bready),.s_araddr(s_araddr),.s_arvalid(s_arvalid),.s_arready(s_arready),
   .s_rdata(s_rdata),.s_rresp(s_rresp),.s_rvalid(s_rvalid),.s_rready(s_rready),
   .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_address(rd_address),.rd_bytes(rd_bytes),.rd_done(rd_done),.rd_status(rd_status),.rd_data(rd_data),
   .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_address(wr_address),.wr_bytes(wr_bytes),.wr_data(wr_data),.wr_done(wr_done),.wr_status(wr_status),
   .irq(irq),.notification_rearm(unused_rearm),.quiescent(quiescent),.running(running),.tick(tick));
 axi_burst_master master(clk,rst,rd_valid,rd_ready,rd_address,rd_bytes,rd_done,rd_status,rd_data,
   wr_valid,wr_ready,wr_address,wr_bytes,wr_data,wr_done,wr_status,
   m_awaddr,m_awlen,m_awsize,m_awburst,m_awvalid,m_awready,m_wdata,m_wstrb,m_wlast,m_wvalid,m_wready,m_bresp,m_bvalid,m_bready,
   m_araddr,m_arlen,m_arsize,m_arburst,m_arvalid,m_arready,m_rdata,m_rresp,m_rlast,m_rvalid,m_rready);
endmodule
