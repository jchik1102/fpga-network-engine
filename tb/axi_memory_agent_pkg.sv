`timescale 1ns/1ps
package axi_memory_agent_pkg;
 import uvm_pkg::*;
 `include "uvm_macros.svh"
 virtual class memory_observer;
   pure virtual function void device_write(int unsigned address,byte unsigned value);
 endclass
 class memory_state extends uvm_object;
   `uvm_object_utils(memory_state)
   byte unsigned bytes[];memory_observer observer;
   bit read_error_enable=0,write_error_enable=0;
   int unsigned read_error_address,write_error_address;
   bit [1:0] error_response=2;
   longint unsigned read_beats=0,write_beats=0,useful_writes=0,overlap_cycles=0;
   function new(string name="memory_state");super.new(name);bytes=new[1048576];foreach(bytes[i]) bytes[i]=8'ha5;endfunction
 endclass
 class channel_delay extends uvm_object;
   `uvm_object_utils(channel_delay)
   rand int unsigned cycles;
   constraint bounded {cycles inside {[0:7]};}
   function new(string name="channel_delay");super.new(name);endfunction
 endclass
 class axi_memory_responder extends uvm_component;
   `uvm_component_utils(axi_memory_responder)
   virtual axi_memory_if vif;
   memory_state memory;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual axi_memory_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","memory vif")
     if(!uvm_config_db#(memory_state)::get(this,"","memory",memory)) `uvm_fatal("CONFIG","memory state")
   endfunction
   task delay_channel(channel_delay timing);
     if(!timing.randomize()) `uvm_fatal("RANDOM","channel delay randomization")
     repeat(timing.cycles) @(negedge vif.clk);
   endtask
   task read_channel();
     channel_delay timing=new("read_delay");
     int unsigned address,count;bit [1:0] response;
     forever begin
       delay_channel(timing);@(negedge vif.clk);vif.arready<=1;
       do @(posedge vif.clk);while(!vif.arvalid);
       address=vif.araddr;count=int'(vif.arlen)+1;
       if(vif.arsize!=3 || vif.arburst!=1 || count>16 || address%8 || address/4096!=(address+8*count-1)/4096) `uvm_fatal("AXI_PROTOCOL","illegal AR")
       @(negedge vif.clk);vif.arready<=0;
       for(int beat=0;beat<count;beat++) begin
         delay_channel(timing);@(negedge vif.clk);
         response=(address+beat*8+8>memory.bytes.size())?3:0;
         if(memory.read_error_enable && address+beat*8==memory.read_error_address) response=memory.error_response;
         for(int lane=0;lane<8;lane++) vif.rdata[lane*8 +:8]<=(address+beat*8+lane<memory.bytes.size())?memory.bytes[address+beat*8+lane]:0;
         vif.rresp<=response;vif.rlast<=(beat==count-1);vif.rvalid<=1;
         do @(posedge vif.clk);while(!vif.rready);
         memory.read_beats++;
         @(negedge vif.clk);vif.rvalid<=0;
       end
     end
   endtask
   task write_channel();
     channel_delay aw_timing=new("aw_delay"),w_timing=new("w_delay"),b_timing=new("b_delay");
     int unsigned address,count;
     bit [63:0] data_queue[$];bit [7:0] strobe_queue[$];bit last_queue[$];
     bit [1:0] response;
     forever begin
       data_queue.delete();strobe_queue.delete();last_queue.delete();
       fork
         begin
           delay_channel(aw_timing);@(negedge vif.clk);vif.awready<=1;
           do @(posedge vif.clk);while(!vif.awvalid);
           address=vif.awaddr;count=int'(vif.awlen)+1;
           if(vif.awsize!=3 || vif.awburst!=1 || count>16 || address%8 || address/4096!=(address+8*count-1)/4096) `uvm_fatal("AXI_PROTOCOL","illegal AW")
           @(negedge vif.clk);vif.awready<=0;
         end
         begin
           bit complete=0;
           while(!complete) begin
             delay_channel(w_timing);@(negedge vif.clk);vif.wready<=1;
             do @(posedge vif.clk);while(!vif.wvalid);
             data_queue.push_back(vif.wdata);strobe_queue.push_back(vif.wstrb);last_queue.push_back(vif.wlast);
             complete=vif.wlast;
             if(data_queue.size()>16) `uvm_fatal("AXI_PROTOCOL","missing WLAST")
             @(negedge vif.clk);vif.wready<=0;
           end
         end
       join
       if(data_queue.size()!=count) `uvm_fatal("AXI_PROTOCOL","write beat extent")
       response=(address+count*8>memory.bytes.size())?3:0;
       foreach(data_queue[beat]) begin
         if(last_queue[beat]!=(beat==count-1)) `uvm_fatal("AXI_PROTOCOL","WLAST")
         if(memory.write_error_enable && address+beat*8==memory.write_error_address) response=memory.error_response;
         for(int lane=0;lane<8;lane++) if(strobe_queue[beat][lane] && address+beat*8+lane<memory.bytes.size()) begin
           memory.bytes[address+beat*8+lane]=data_queue[beat][lane*8 +:8]; memory.useful_writes++;
           if(memory.observer!=null) memory.observer.device_write(address+beat*8+lane,data_queue[beat][lane*8 +:8]);
         end
         memory.write_beats++;
       end
       delay_channel(b_timing);@(negedge vif.clk);vif.bresp<=response;vif.bvalid<=1;
       do @(posedge vif.clk);while(!vif.bready);
       @(negedge vif.clk);vif.bvalid<=0;
     end
   endtask
   task run_phase(uvm_phase phase);
     wait(!vif.rst);
     fork read_channel();write_channel();join
   endtask
 endclass
 class axi_memory_monitor extends uvm_monitor;
   `uvm_component_utils(axi_memory_monitor)
   virtual axi_memory_if vif;
   int fd;int aw_count=0,w_count=0,b_count=0,ar_count=0,r_count=0;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual axi_memory_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","monitor vif")
     fd=$fopen("axi_handshakes.txt","w");if(!fd) `uvm_fatal("LOG","AXI monitor log")
   endfunction
   task run_phase(uvm_phase phase);
     forever begin
       @(posedge vif.clk);
       if(!vif.rst) begin
         if(vif.awvalid && vif.awready) begin $fdisplay(fd,"AW %0d %08x %0d",vif.tick,vif.awaddr,vif.awlen+1);aw_count++;end
         if(vif.wvalid && vif.wready) begin $fdisplay(fd,"W %0d %016x %02x %0d",vif.tick,vif.wdata,vif.wstrb,vif.wlast);w_count++;end
         if(vif.bvalid && vif.bready) begin $fdisplay(fd,"B %0d %0d",vif.tick,vif.bresp);b_count++;end
         if(vif.arvalid && vif.arready) begin $fdisplay(fd,"AR %0d %08x %0d",vif.tick,vif.araddr,vif.arlen+1);ar_count++;end
         if(vif.rvalid && vif.rready) begin $fdisplay(fd,"R %0d %016x %0d %0d",vif.tick,vif.rdata,vif.rresp,vif.rlast);r_count++;end
       end
     end
   endtask
   function void final_phase(uvm_phase phase);$fclose(fd);endfunction
 endclass
 class axi_memory_agent extends uvm_agent;
   `uvm_component_utils(axi_memory_agent)
   axi_memory_responder responder;axi_memory_monitor monitor;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     responder=axi_memory_responder::type_id::create("responder",this);
     monitor=axi_memory_monitor::type_id::create("monitor",this);
   endfunction
 endclass
endpackage
