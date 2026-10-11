`timescale 1ns/1ps
interface sg_test_if(input logic clk);
 logic rst=1,start=0,to_host=0,ready,done;
 logic [1:0] status;
 logic [511:0] descriptor=0;
 logic replay=0,descriptor_valid;
 logic [15:0] packet_length=0,capacity;
 logic [63:0] cookie,captured_tick;
 logic [2:0] segment_count;
 logic [31:0] addresses[0:3];logic [15:0] lengths[0:3];
 logic [8:0] local_read_word,local_write_word;
 logic [31:0] local_read_data,local_write_data;
 logic [3:0] local_write_keep;logic local_write_valid;
 logic [31:0] local_mem[0:511];
 always @(posedge clk) begin
   local_read_data<=local_mem[local_read_word];
   if(local_write_valid) for(int lane=0;lane<4;lane++) if(local_write_keep[lane]) local_mem[local_write_word][lane*8 +:8]<=local_write_data[lane*8 +:8];
 end
endinterface
package sg_test_pkg;
 import uvm_pkg::*;import axi_memory_agent_pkg::*;
 `include "uvm_macros.svh"
 class sg_test extends uvm_test;
   `uvm_component_utils(sg_test)
   virtual sg_test_if command;
   memory_state memory;axi_memory_agent host;
   int cases_checked=0,bytes_checked=0,invalid_cases=0,error_cases=0;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual sg_test_if)::get(this,"","command",command)) `uvm_fatal("CONFIG","sg control")
     memory=new();uvm_config_db#(memory_state)::set(this,"host.*","memory",memory);
     host=axi_memory_agent::type_id::create("host",this);
   endfunction
   task expect_true(bit condition,string message);if(!condition) `uvm_fatal("ORACLE",message) endtask
   function byte unsigned pattern(int offset,int salt);return (offset*37+salt*19+11)&255;endfunction
   task run_phase(uvm_phase phase);
     int fd,count,rc,replay,length,expected_valid,error,n,offset,total;
     int expected_address[0:3],expected_length[0:3];bit [7:0] raw[0:63];
     phase.raise_objection(this);wait(!command.rst);
     fd=$fopen("dma.txt","r");if(!fd) `uvm_fatal("FIXTURE","dma file")
     rc=$fscanf(fd,"%d",count);expect_true(rc==1,"case count");
     for(int c=0;c<count;c++) begin
       rc=$fscanf(fd,"%d %d %d %d",replay,length,expected_valid,error);expect_true(rc==4,"case header");
       for(int b=0;b<64;b++) begin rc=$fscanf(fd,"%h",raw[b]);expect_true(rc==1,"descriptor byte");end
       @(negedge command.clk);command.replay=replay;command.to_host=!replay;command.packet_length=length;
       for(int b=0;b<64;b++) command.descriptor[b*8 +:8]=raw[b];
       @(negedge command.clk);expect_true(command.descriptor_valid==expected_valid,$sformatf("descriptor validity case %0d",c));
       if(!expected_valid) invalid_cases++;
       else begin
         n=raw[26];offset=0;
         for(int s=0;s<n;s++) begin
           expected_address[s]=int'(raw[32+8*s])+(int'(raw[33+8*s])<<8)+(int'(raw[34+8*s])<<16)+(int'(raw[35+8*s])<<24);
           expected_length[s]=int'(raw[36+8*s])+(int'(raw[37+8*s])<<8);
           expect_true(command.addresses[s]==expected_address[s] && command.lengths[s]==expected_length[s],"decoded SG fields");
           for(int b=-8;b<expected_length[s]+8;b++) memory.bytes[expected_address[s]+b]=8'ha5;
           if(replay) for(int b=0;b<expected_length[s];b++) memory.bytes[expected_address[s]+b]=pattern(offset+b,c);
           offset+=expected_length[s];
         end
         for(int word=0;word<512;word++) for(int lane=0;lane<4;lane++) command.local_mem[word][lane*8 +:8]=replay?8'ha5:pattern(word*4+lane,c);
         memory.read_error_enable=replay && error!=0;memory.write_error_enable=!replay && error!=0;
         memory.read_error_address=expected_address[0];memory.write_error_address=expected_address[0];memory.error_response=error;
         @(negedge command.clk);expect_true(command.ready,"SG idle");command.start=1;
         @(negedge command.clk);command.start=0;
         while(!command.done) @(negedge command.clk);
         expect_true(command.status==error,"SG error status");
         if(error) error_cases++;
         else begin
           if(replay) begin
             for(int b=0;b<length;b++) begin expect_true(command.local_mem[b/4][(b%4)*8 +:8]==pattern(b,c),$sformatf("gathered byte case=%0d byte=%0d",c,b));bytes_checked++;end
             expect_true(command.local_mem[length/4][(length%4)*8 +:8]==8'ha5,"local guard");
           end else begin
             total=0;
             for(int s=0;s<n;s++) begin
               for(int b=-8;b<expected_length[s]+8;b++) begin
                 if(b>=0 && b<expected_length[s] && total+b<length)
                   expect_true(memory.bytes[expected_address[s]+b]==pattern(total+b,c),$sformatf("scatter byte case=%0d segment=%0d byte=%0d",c,s,b));
                 else expect_true(memory.bytes[expected_address[s]+b]==8'ha5,"SG guard/capacity suffix");
                 bytes_checked++;
               end
               total+=expected_length[s];
             end
           end
         end
       end
       cases_checked++;
     end
     $fclose(fd);
     `uvm_info("RESULT",$sformatf("SG_PASS cases=%0d invalid=%0d errors=%0d checked_bytes=%0d",cases_checked,invalid_cases,error_cases,bytes_checked),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module sg_tb;
 import uvm_pkg::*;import sg_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 sg_test_if command(clk);axi_memory_if bus(clk);
 logic rd_valid,rd_ready,rd_done,wr_valid,wr_ready,wr_done;
 logic [31:0] rd_address,wr_address;logic [7:0] rd_bytes,wr_bytes;
 logic [1:0] rd_status,wr_status;logic [1023:0] rd_data,wr_data;
 assign bus.rst=command.rst;
 always @(posedge clk) if(command.rst) bus.tick<=0;else bus.tick<=bus.tick+1;
 descriptor_validator validator(command.descriptor,command.replay,32'd7,32'd3,command.packet_length,
   command.descriptor_valid,command.cookie,command.captured_tick,command.capacity,command.segment_count,command.addresses,command.lengths);
 sg_transfer transfer(clk,command.rst,command.start,command.ready,command.to_host,command.packet_length,command.segment_count,command.addresses,command.lengths,
   command.done,command.status,command.local_read_word,command.local_read_data,
   command.local_write_valid,command.local_write_word,command.local_write_data,command.local_write_keep,
   rd_valid,rd_ready,rd_address,rd_bytes,rd_done,rd_status,rd_data,wr_valid,wr_ready,wr_address,wr_bytes,wr_data,wr_done,wr_status,1'b0);
 axi_burst_master master(clk,command.rst,rd_valid,rd_ready,rd_address,rd_bytes,rd_done,rd_status,rd_data,
   wr_valid,wr_ready,wr_address,wr_bytes,wr_data,wr_done,wr_status,
   bus.awaddr,bus.awlen,bus.awsize,bus.awburst,bus.awvalid,bus.awready,bus.wdata,bus.wstrb,bus.wlast,bus.wvalid,bus.wready,bus.bresp,bus.bvalid,bus.bready,
   bus.araddr,bus.arlen,bus.arsize,bus.arburst,bus.arvalid,bus.arready,bus.rdata,bus.rresp,bus.rlast,bus.rvalid,bus.rready);
 initial begin
   uvm_config_db#(virtual sg_test_if)::set(null,"uvm_test_top","command",command);
   uvm_config_db#(virtual axi_memory_if)::set(null,"uvm_test_top.host.*","vif",bus);
   fork begin repeat(5) @(negedge clk);command.rst=0;end join_none
   run_test("sg_test");
 end
 initial begin #20000000;$fatal(1,"WATCHDOG SG");end
endmodule
