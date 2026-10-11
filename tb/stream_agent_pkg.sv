`timescale 1ns/1ps
package stream_agent_pkg;
 import uvm_pkg::*;
 `include "uvm_macros.svh"
 class stream_frame extends uvm_sequence_item;
   `uvm_object_utils(stream_frame)
   bit [31:0] words[];
   bit [3:0] keeps[];
   int gaps[];
   bit lasts[];
   longint unsigned first_tick,last_tick;
   function new(string name="stream_frame"); super.new(name); endfunction
 endclass
 class stream_timing extends uvm_object;
   `uvm_object_utils(stream_timing)
   rand int unsigned gap;
   constraint bounds {gap inside {[0:7]};}
   function new(string name="stream_timing"); super.new(name); endfunction
 endclass
 class stream_driver extends uvm_driver#(stream_frame);
   `uvm_component_utils(stream_driver)
   virtual stream_if vif;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     super.build_phase(phase);
     if(!uvm_config_db#(virtual stream_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","stream vif")
   endfunction
   task run_phase(uvm_phase phase);
     stream_frame frame; int waited;
     vif.valid<=0;
     wait(!vif.rst);
     forever begin
       seq_item_port.get_next_item(frame);
       if(frame.words.size()==0 || frame.keeps.size()!=frame.words.size() || frame.lasts.size()!=frame.words.size() || frame.gaps.size()!=frame.words.size()) `uvm_fatal("STIMULUS","frame arrays")
       foreach(frame.words[i]) begin
         if(frame.gaps[i]>0) begin @(negedge vif.clk); vif.valid<=0; repeat(frame.gaps[i]-1) @(negedge vif.clk); end
         @(negedge vif.clk); vif.data<=frame.words[i]; vif.keep<=frame.keeps[i]; vif.last<=frame.lasts[i]; vif.valid<=1;
         waited=0;
         do begin
           @(posedge vif.clk); waited++;
           if(waited>100000) `uvm_fatal("WATCHDOG","stream source stalled")
         end while(!vif.ready);
       end
       @(negedge vif.clk); vif.valid<=0;
       seq_item_port.item_done();
     end
   endtask
 endclass
 class stream_monitor extends uvm_monitor;
   `uvm_component_utils(stream_monitor)
   virtual stream_if vif;
   uvm_analysis_port#(stream_frame) accepted;
   function new(string name,uvm_component parent);super.new(name,parent);accepted=new("accepted",this);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual stream_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","stream monitor vif")
   endfunction
   task run_phase(uvm_phase phase);
     stream_frame f; bit [31:0] words[$]; bit [3:0] keeps[$]; bit lasts[$]; longint unsigned first_tick;
     forever begin
       @(posedge vif.clk);
       if(vif.rst) begin words.delete(); keeps.delete(); lasts.delete(); end
       else if(vif.valid && vif.ready) begin
         if(words.size()==0) first_tick=vif.tick;
         words.push_back(vif.data); keeps.push_back(vif.keep); lasts.push_back(vif.last);
         if(vif.last) begin
           f=new(); f.words=words; f.keeps=keeps; f.lasts=lasts; f.first_tick=first_tick; f.last_tick=vif.tick;
           accepted.write(f); words.delete(); keeps.delete(); lasts.delete();
         end
       end
     end
   endtask
 endclass
 class stream_agent extends uvm_agent;
   `uvm_component_utils(stream_agent)
   stream_driver driver;
   stream_monitor monitor;
   uvm_sequencer#(stream_frame) sequencer;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     super.build_phase(phase); monitor=stream_monitor::type_id::create("monitor",this);
     if(get_is_active()==UVM_ACTIVE) begin
       driver=stream_driver::type_id::create("driver",this);
       sequencer=new("sequencer",this);
     end
   endfunction
   function void connect_phase(uvm_phase phase);
     if(get_is_active()==UVM_ACTIVE) driver.seq_item_port.connect(sequencer.seq_item_export);
   endfunction
 endclass
 class one_frame_sequence extends uvm_sequence#(stream_frame);
   `uvm_object_utils(one_frame_sequence)
   stream_frame frame;
   function new(string name="one_frame_sequence");super.new(name);endfunction
   task body(); start_item(frame); finish_item(frame); endtask
 endclass
 class stream_sink_config extends uvm_object;
   `uvm_object_utils(stream_sink_config)
   bit force_stall=0,full_rate=0;
   function new(string name="stream_sink_config");super.new(name);endfunction
 endclass
 class stream_sink_driver extends uvm_component;
   `uvm_component_utils(stream_sink_driver)
   virtual stream_if vif;stream_sink_config configuration;
   int gap_seen[8];
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual stream_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","sink vif")
     if(!uvm_config_db#(stream_sink_config)::get(this,"","config",configuration)) configuration=new();
   endfunction
   task run_phase(uvm_phase phase);
     stream_timing timing=new();vif.ready<=0;wait(!vif.rst);
     forever begin
       if(!timing.randomize()) `uvm_fatal("RANDOM","sink stall generation")
       if(timing.gap>7) `uvm_fatal("RANDOM","sink stall constraint")
       gap_seen[timing.gap]++;
       while(configuration.full_rate && !configuration.force_stall) begin vif.ready<=1;@(negedge vif.clk);end
       @(negedge vif.clk);vif.ready<=0;
       repeat(timing.gap) @(negedge vif.clk);
       while(configuration.force_stall) @(negedge vif.clk);
       vif.ready<=1;@(negedge vif.clk);
     end
   endtask
 endclass
 class stream_sink_agent extends uvm_agent;
   `uvm_component_utils(stream_sink_agent)
   stream_sink_driver driver;stream_monitor monitor;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     driver=stream_sink_driver::type_id::create("driver",this);monitor=stream_monitor::type_id::create("monitor",this);
   endfunction
 endclass
endpackage
