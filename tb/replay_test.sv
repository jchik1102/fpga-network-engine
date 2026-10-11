`timescale 1ns/1ps
interface replay_test_if(input logic clk);
 logic rst=1,tick_load=0;logic [63:0] tick=0,tick_value=0;
 logic policy_start=0,policy_ready,policy_done,policy_valid,policy_lost;
 logic fixed_mode=0;logic [63:0] start_tick=0,captured_tick=0,origin_tick=0,interval=0,delay_ticks=0,due_tick;
 logic [31:0] descriptor_sequence=0,seed=0,random_word;logic [1:0] queue_id=0;logic [32:0] threshold=0;
 logic abort_discard=0,write_valid=0,stage_valid=0,stage_lost=0,busy;
 logic [1:0] write_queue=0,stage_queue=0;logic [8:0] write_word=0;logic [31:0] write_data=0;logic [3:0] write_keep=0;
 logic [15:0] stage_length=0;logic [63:0] stage_due=0;
 logic [3:0] stage_ready,occupied,finished,release_head=0;logic [63:0] departure_tick[0:3];
endinterface
package replay_test_pkg;
 import uvm_pkg::*;import stream_agent_pkg::*;
 `include "uvm_macros.svh"
 class replay_test extends uvm_test;
   `uvm_component_utils(replay_test)
   virtual replay_test_if control;virtual stream_if bus;
   stream_sink_agent sink;stream_sink_config configuration;uvm_tlm_analysis_fifo#(stream_frame) observed;
   int policies=0,invalid_policies=0,frames=0,bytes_checked=0,losses=0,checks=0;
   int cov_queue,cov_size,cov_loss,cov_mode,cov_valid;longint unsigned maximum_lateness=0;
   covergroup replay_coverage;
     queue_index:coverpoint cov_queue {bins queue[]={[0:3]};}
     length_class:coverpoint cov_size {bins short_frame={[60:64]};bins middle_frame={[65:512]};bins long_frame={[513:1514]};}
     loss:coverpoint cov_loss {bins sent={0};bins discarded={1};}
     queue_length:cross queue_index,length_class;
     queue_loss:cross queue_index,loss;
   endgroup
   covergroup policy_coverage;
     mode:coverpoint cov_mode {bins original={0};bins fixed_interval={1};}
     valid_horizon:coverpoint cov_valid {bins rejected={0};bins legal={1};}
     mode_horizon:cross mode,valid_horizon;
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);replay_coverage=new();policy_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual replay_test_if)::get(this,"","control",control)) `uvm_fatal("CONFIG","replay vif")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","bus",bus)) `uvm_fatal("CONFIG","replay bus")
     configuration=new();uvm_config_db#(stream_sink_config)::set(this,"sink.*","config",configuration);
     sink=stream_sink_agent::type_id::create("sink",this);observed=new("observed",this);
   endfunction
   function void connect_phase(uvm_phase phase);sink.monitor.accepted.connect(observed.analysis_export);endfunction
   task expect_true(bit condition,string message);checks++;if(!condition) `uvm_fatal("ORACLE",message) endtask
   function byte unsigned pattern(int frame_id,int offset);return (frame_id*53+offset*17+(offset/256)*11)&255;endfunction
   task check_policies();
     int fd,count,scanned,mode,q,legal,expected_lost;bit [63:0] start_tick,captured,origin,interval,delay_ticks,expected_due;
     bit [31:0] seq,seed,word_value;bit [32:0] threshold;
     fd=$fopen("policy.txt","r");expect_true(fd!=0,"policy fixture open");scanned=$fscanf(fd,"%d",count);expect_true(scanned==1,"policy header");
     repeat(count) begin
       scanned=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h",mode,start_tick,captured,origin,interval,delay_ticks,seq,seed,q,threshold,legal,expected_due,word_value,expected_lost);
       expect_true(scanned==14,"complete policy row");
       @(negedge control.clk);expect_true(control.policy_ready,"policy idle");
       control.fixed_mode=mode;control.start_tick=start_tick;control.captured_tick=captured;control.origin_tick=origin;control.interval=interval;control.delay_ticks=delay_ticks;
       control.descriptor_sequence=seq;control.seed=seed;control.queue_id=q;control.threshold=threshold;control.policy_start=1;
       @(negedge control.clk);control.policy_start=0;
       while(!control.policy_done) @(negedge control.clk);
       expect_true(control.policy_valid==legal,$sformatf("policy horizon row %0d",policies));
       expect_true(control.random_word==word_value,$sformatf("loss hash row %0d got=%x expected=%x",policies,control.random_word,word_value));
       expect_true(control.policy_lost==expected_lost,"loss threshold endpoint");
       if(legal) expect_true(control.due_tick==expected_due,"absolute due arithmetic");else invalid_policies++;
       cov_mode=mode;cov_valid=legal;policy_coverage.sample();policies++;
     end
     $fclose(fd);
   endtask
   task set_tick(bit [63:0] value);
     @(negedge control.clk);control.tick_value=value;control.tick_load=1;@(negedge control.clk);control.tick_load=0;
   endtask
   task stage(int q,int frame_id,int length,bit [63:0] due,bit lost_frame=0);
     expect_true(control.stage_ready[q],"head slot free before fill");
     if(!lost_frame) for(int word_index=0;word_index<(length+3)/4;word_index++) begin
       @(negedge control.clk);control.write_valid=1;control.write_queue=q;control.write_word=word_index;control.write_keep=0;control.write_data=0;
       for(int b=0;b<4;b++) if(word_index*4+b<length) begin control.write_data[b*8+:8]=pattern(frame_id,word_index*4+b);control.write_keep[b]=1;end
     end
     @(negedge control.clk);control.write_valid=0;control.stage_valid=1;control.stage_queue=q;control.stage_length=length;control.stage_due=due;control.stage_lost=lost_frame;
     @(negedge control.clk);control.stage_valid=0;
     expect_true(!control.stage_ready[q],"published head owns slot");
   endtask
   task check_frame(stream_frame frame,int q,int frame_id,int length,bit [63:0] due,bit metadata=1);
     longint unsigned late_ticks;
     expect_true(frame.words.size()==(length+3)/4,"replay frame word extent");
     foreach(frame.words[w]) begin
       expect_true(frame.keeps[w]==(w==(length+3)/4-1 && length%4 ? ((1<<(length%4))-1):15),"replay final byte mask");
       expect_true(frame.lasts[w]==(w==(length+3)/4-1),"replay TLAST exact");
       for(int b=0;b<4;b++) if(w*4+b<length) begin expect_true(frame.words[w][b*8+:8]==pattern(frame_id,w*4+b),$sformatf("replay byte frame=%0d byte=%0d",frame_id,w*4+b));bytes_checked++;end
     end
     late_ticks=frame.first_tick-due;expect_true(late_ticks<64'h8000000000000000,"no early departure");
     expect_true(late_ticks<20000,"bounded positive scheduling lateness");if(late_ticks>maximum_lateness) maximum_lateness=late_ticks;
     // sample after the nba update, not on the tlast edge
     @(negedge control.clk);
     if(metadata) begin expect_true(control.finished[q],"frame finished flag");expect_true(control.departure_tick[q]==frame.first_tick,"departure timestamp from monitor");end
     frames++;
   endtask
   task check_round(int round_id,bit skew);
     int length[4],sizes[4]='{60,61,127,1514};bit lost_head[4];bit [63:0] due[4],base_due;
     stream_frame frame;
     base_due=control.tick+3000;
     for(int q=0;q<4;q++) begin
       length[q]=sizes[(round_id+q)%4];lost_head[q]=(round_id%4==q && round_id<8);
       due[q]=base_due+((skew && q==0)?6000:0);
       stage(q,round_id*4+q,length[q],due[q],lost_head[q]);
     end
     for(int i=0;i<4;i++) begin
       int q=skew?(i+1)%4:i;
       if(lost_head[q]) begin
         while(!control.finished[q]) @(negedge control.clk);
         expect_true(control.departure_tick[q]==due[q],"LOST completion carries intended due tick");losses++;
       end else begin observed.get(frame);check_frame(frame,q,round_id*4+q,length[q],due[q]);end
       cov_queue=q;cov_size=length[q];cov_loss=lost_head[q];replay_coverage.sample();
     end
     expect_true(observed.used()==0,"no extra output for lost heads");
     @(negedge control.clk);control.release_head=15;@(negedge control.clk);control.release_head=0;
     expect_true(control.occupied==0,"completion releases heads");
   endtask
   task run_phase(uvm_phase phase);
     stream_frame frame;bit [63:0] due;
     phase.raise_objection(this);wait(!control.rst);
     check_policies();set_tick(64'hfffffffffffff800);
     for(int round_id=0;round_id<16;round_id++) check_round(round_id,0);
     check_round(16,1);
     stage(2,100,60,control.tick+10000);@(negedge control.clk);control.abort_discard=1;
     repeat(4) @(negedge control.clk);expect_true(control.occupied==0 && !control.busy && observed.used()==0,"abort future head");control.abort_discard=0;
     configuration.force_stall=1;repeat(12) @(negedge control.clk);
     due=control.tick;stage(1,101,1514,due);
     wait(bus.valid);@(negedge control.clk);control.abort_discard=1;
     repeat(8) begin @(negedge control.clk);expect_true(bus.valid,"abort preserves offered beat");end
     configuration.force_stall=0;observed.get(frame);check_frame(frame,1,101,1514,due,0);
     repeat(4) @(negedge control.clk);expect_true(!control.busy && control.occupied==0,"abort drains started frame");control.abort_discard=0;
     for(int g=0;g<8;g++) expect_true(sink.driver.gap_seen[g]>0,"random sink stall diversity");
     `uvm_info("RESULT",$sformatf("REPLAY_PASS policies=%0d invalid_horizons=%0d frames=%0d lost=%0d checked_bytes=%0d max_lateness=%0d coverage=%0f policy_coverage=%0f",policies,invalid_policies,frames,losses,bytes_checked,maximum_lateness,replay_coverage.get_inst_coverage(),policy_coverage.get_inst_coverage()),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module replay_tb;
 import uvm_pkg::*;import replay_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 replay_test_if control(clk);stream_if bus(clk);
 assign bus.rst=control.rst;assign bus.tick=control.tick;
 always @(posedge clk) if(control.rst) control.tick<=0;else if(control.tick_load) control.tick<=control.tick_value;else control.tick<=control.tick+1'b1;
 replay_policy policy(.clk(clk),.rst(control.rst),.start(control.policy_start),.ready(control.policy_ready),.fixed_mode(control.fixed_mode),
 .start_tick(control.start_tick),.captured_tick(control.captured_tick),.origin_tick(control.origin_tick),.interval(control.interval),.delay_ticks(control.delay_ticks),
 .descriptor_sequence(control.descriptor_sequence),.seed(control.seed),.queue_id(control.queue_id),.threshold(control.threshold),
 .done(control.policy_done),.valid(control.policy_valid),.lost(control.policy_lost),.due_tick(control.due_tick),.random_word(control.random_word));
 replay_staging staging(.clk(clk),.rst(control.rst),.abort_discard(control.abort_discard),.tick(control.tick),
 .write_valid(control.write_valid),.write_queue(control.write_queue),.write_word(control.write_word),.write_data(control.write_data),.write_keep(control.write_keep),
 .stage_valid(control.stage_valid),.stage_queue(control.stage_queue),.stage_length(control.stage_length),.stage_due(control.stage_due),.stage_lost(control.stage_lost),
 .stage_ready(control.stage_ready),.occupied(control.occupied),.finished(control.finished),.departure_tick(control.departure_tick),.release_head(control.release_head),
 .m_data(bus.data),.m_keep(bus.keep),.m_valid(bus.valid),.m_last(bus.last),.m_ready(bus.ready),.busy(control.busy));
 initial begin
   uvm_config_db#(virtual replay_test_if)::set(null,"uvm_test_top","control",control);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","bus",bus);uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.sink.*","vif",bus);
   fork begin repeat(5) @(negedge clk);control.rst=0;end join_none
   run_test("replay_test");
 end
 initial begin #20000000;$fatal(1,"WATCHDOG replay");end
 assert property(@(posedge clk) disable iff(control.rst) bus.valid&&!bus.ready |=> bus.valid&&$stable({bus.data,bus.keep,bus.last})) else $fatal(1,"replay stable stalled beat");
 assert property(@(posedge clk) disable iff(control.rst) (control.finished&~control.occupied)==0) else $fatal(1,"finished replay ownership");
endmodule
