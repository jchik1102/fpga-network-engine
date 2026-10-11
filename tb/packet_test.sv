`timescale 1ns/1ps
interface capture_test_if(input logic clk);
 logic rst=1,admit=0,drop_on_full=1,abort_discard=0;
 logic [63:0] tick=0;
 logic [2:0] occupancy[0:3]; logic [1:0] head_slot[0:3];
 logic [15:0] head_length[0:3]; logic [63:0] head_tick[0:3]; logic [4:0] head_aux[0:3];
 logic release_valid=0; logic [1:0] release_queue=0,read_queue=0,read_slot=0;
 logic [8:0] read_word=0; logic [31:0] read_data;
 logic busy,event_valid; logic [2:0] event_drop; logic [1:0] event_queue,event_slot;
 logic [15:0] event_length; logic [63:0] event_tick; logic [4:0] event_aux;
 logic [63:0] drop_count[0:5]; logic ready;
endinterface
package packet_test_pkg;
 import uvm_pkg::*; import stream_agent_pkg::*;
 `include "uvm_macros.svh"
 class packet_test extends uvm_test;
   `uvm_component_utils(packet_test)
   stream_agent source;
   virtual capture_test_if control;
   virtual stream_if input_stream;
   uvm_tlm_analysis_fifo#(stream_frame) observed;
   int covered_drop,covered_queue,covered_size;
   covergroup packet_coverage;
     option.per_instance=1;
     reason: coverpoint covered_drop {bins reasons[]={[0:6]};}
     queue: coverpoint covered_queue iff(covered_drop==0) {bins queues[]={[0:3]};}
     size: coverpoint covered_size iff(covered_drop==0) {bins short_frame={[60:63]}; bins middle={[64:1513]}; bins max_frame={1514};}
     queue_size: cross queue,size;
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);packet_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual capture_test_if)::get(this,"","control",control)) `uvm_fatal("CONFIG","capture control")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","input_stream",input_stream)) `uvm_fatal("CONFIG","input stream")
     source=stream_agent::type_id::create("source",this); observed=new("observed",this);
   endfunction
   function void connect_phase(uvm_phase phase); source.monitor.accepted.connect(observed.analysis_export);endfunction
   task expect_true(input bit condition,input string message);
     if(!condition) `uvm_fatal("ORACLE",message)
   endtask
   task run_phase(uvm_phase phase);
     int fd,count,action,n,length,drop,supported,q,rule,slot,mode,ready_value,rc,expected_count;
     int expected_drops[0:5]; int packet_count=0,byte_count=0; string fixture;
     stream_frame stimulus,actual; one_frame_sequence txn_sequence;
     phase.raise_objection(this);
     for(int k=0;k<6;k++) expected_drops[k]=0;
     if(!$value$plusargs("FIXTURE=%s",fixture)) fixture="packets.txt";
     fd=$fopen(fixture,"r"); if(!fd) `uvm_fatal("FIXTURE","cannot open")
     rc=$fscanf(fd,"%d",count); expect_true(rc==1,"operation count");
     wait(!control.rst); @(negedge control.clk); control.admit=1;
     repeat(count) begin
       rc=$fscanf(fd,"%d",action); expect_true(rc==1,"action");
       case(action)
       0: begin
         rc=$fscanf(fd,"%d %d %d %d %d %d %d",n,length,drop,supported,q,rule,slot); expect_true(rc==7,"packet header");
         stimulus=new(); stimulus.words=new[n];stimulus.keeps=new[n];stimulus.lasts=new[n];stimulus.gaps=new[n];
         foreach(stimulus.words[i]) begin
           rc=$fscanf(fd,"%h %h %d %d",stimulus.words[i],stimulus.keeps[i],stimulus.lasts[i],stimulus.gaps[i]);expect_true(rc==4,"beat parse");
         end
         txn_sequence=new(); txn_sequence.frame=stimulus;
         fork
           txn_sequence.start(source.sequencer);
           begin
             do @(negedge control.clk); while(!control.event_valid);
             expect_true(control.event_drop==drop,$sformatf("drop packet=%0d expected=%0d actual=%0d",packet_count,drop,control.event_drop));
             expect_true(control.event_length==length,"length");
             if(drop==0) begin
               expect_true(control.event_queue==q && control.event_slot==slot,"queue/slot");
               expect_true(control.event_aux==((supported<<4)|rule),"classification metadata");
             end
           end
         join
         observed.get(actual);
         expect_true(actual.words.size()==n,"monitor beat extent");
         foreach(actual.words[i]) expect_true(actual.words[i]==stimulus.words[i] && actual.keeps[i]==stimulus.keeps[i] && actual.lasts[i]==stimulus.lasts[i],"source/monitor bytes");
         expect_true(control.event_tick==actual.first_tick,"capture timestamp independent handshake");
         if(drop==0) begin
           control.read_queue=q;control.read_slot=slot;
           for(int i=0;i<n;i++) begin
             @(negedge control.clk);control.read_word=i;
             @(negedge control.clk);
             for(int lane=0;lane<4;lane++) if(stimulus.keeps[i][lane]) begin
               expect_true(control.read_data[lane*8 +:8]==stimulus.words[i][lane*8 +:8],$sformatf("stored byte packet=%0d word=%0d lane=%0d",packet_count,i,lane));
               byte_count++;
             end
           end
         end else expected_drops[drop-1]++;
         covered_drop=drop;covered_queue=q;covered_size=length;packet_coverage.sample();packet_count++;
       end
       1: begin
         rc=$fscanf(fd,"%d",q);expect_true(rc==1,"release");
         @(negedge control.clk);control.release_queue=q;control.release_valid=1;
         @(negedge control.clk);control.release_valid=0;
       end
       2: begin
         rc=$fscanf(fd,"%d %d",mode,ready_value);expect_true(rc==2,"mode");
         @(negedge control.clk);control.drop_on_full=mode;
         @(negedge control.clk);expect_true(control.ready==ready_value,"lossless/full admission");
       end
       default: `uvm_fatal("FIXTURE","unknown action")
       endcase
       @(negedge control.clk);
       for(int index=0;index<4;index++) begin
         rc=$fscanf(fd,"%d",expected_count); expect_true(rc==1,"occupancy parse");
         expect_true(control.occupancy[index]==expected_count,$sformatf("occupancy q=%0d expected=%0d got=%0d",index,expected_count,control.occupancy[index]));
       end
     end
     for(int k=0;k<6;k++) expect_true(control.drop_count[k]==expected_drops[k],$sformatf("drop counter %0d",k));
     $fclose(fd);
     `uvm_info("RESULT",$sformatf("PACKET_PASS packets=%0d checked_bytes=%0d coverage=%0f",packet_count,byte_count,packet_coverage.get_inst_coverage()),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module packet_tb;
 import uvm_pkg::*;import packet_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 stream_if stream(clk);capture_test_if control(clk);
 logic [4:0] rules[0:7];
 logic [31:0] src[0:7],smask[0:7],dst[0:7],dmask[0:7],ports[0:7];
 capture_ingress dut(clk,control.rst,control.admit,control.drop_on_full,control.abort_discard,control.tick,
   stream.data,stream.keep,stream.valid,stream.last,stream.ready,2'd3,rules,src,smask,dst,dmask,ports,
   control.occupancy,control.head_slot,control.head_length,control.head_tick,control.head_aux,
   control.release_valid,control.release_queue,control.read_queue,control.read_slot,control.read_word,control.read_data,
   control.busy,control.event_valid,control.event_drop,control.event_queue,control.event_slot,control.event_length,control.event_tick,control.event_aux,control.drop_count,1'b0);
 assign stream.rst=control.rst;assign stream.tick=control.tick;assign control.ready=stream.ready;
 always @(posedge clk) if(control.rst) control.tick<=0;else control.tick<=control.tick+1;
 initial begin
   for(int i=0;i<8;i++) begin rules[i]=0;src[i]=0;smask[i]=0;dst[i]=0;dmask[i]=0;ports[i]=0;end
   rules[0]=5'b10001;ports[0]={16'd5000,16'd0};
   rules[1]=5'b00011;src[1]=32'hc0000200;smask[1]=32'hffffff00;
   rules[2]=5'b01101;ports[2]=0;
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.source.*","vif",stream);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","input_stream",stream);
   uvm_config_db#(virtual capture_test_if)::set(null,"uvm_test_top","control",control);
   fork begin repeat(5) @(negedge clk);control.rst=0;end join_none
   run_test("packet_test");
 end
 initial begin #20000000;$fatal(1,"WATCHDOG packet test");end
 assert property(@(posedge clk) disable iff(control.rst) stream.valid && !stream.ready |=> stream.valid && $stable({stream.data,stream.keep,stream.last})) else $fatal(1,"stream stalled stability");
 generate for(genvar q=0;q<4;q++) begin
   assert property(@(posedge clk) disable iff(control.rst) control.occupancy[q]<=4) else $fatal(1,"queue overflow");
 end endgenerate
endmodule
