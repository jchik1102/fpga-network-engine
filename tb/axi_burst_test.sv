`timescale 1ns/1ps
interface burst_test_if(input logic clk);
 logic rst=1;
 logic rd_valid=0,rd_ready,rd_done,wr_valid=0,wr_ready,wr_done;
 logic [31:0] rd_address=0,wr_address=0;
 logic [7:0] rd_bytes=0,wr_bytes=0;
 logic [1:0] rd_status,wr_status;
 logic [1023:0] rd_data,wr_data=0;
endinterface
package axi_burst_test_pkg;
 import uvm_pkg::*;import axi_memory_agent_pkg::*;
 `include "uvm_macros.svh"
 class axi_burst_test extends uvm_test;
   `uvm_component_utils(axi_burst_test)
   virtual burst_test_if command;
   virtual axi_memory_if bus;
   memory_state memory;
   axi_memory_agent host;
   int byte_checks=0,transactions=0,overlaps=0;
   int cov_beats,cov_tail,cov_resp;
   covergroup transfer_coverage;
     beats: coverpoint cov_beats {bins count[]={[1:16]};}
     tail: coverpoint cov_tail {bins count[]={[1:8]};}
     response: coverpoint cov_resp {bins ok={0};bins slave_error={2};bins decode_error={3};}
     beats_tail: cross beats,tail;
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);transfer_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual burst_test_if)::get(this,"","command",command)) `uvm_fatal("CONFIG","burst command")
     if(!uvm_config_db#(virtual axi_memory_if)::get(this,"","bus",bus)) `uvm_fatal("CONFIG","burst bus")
     memory=new();uvm_config_db#(memory_state)::set(this,"host.*","memory",memory);
     host=axi_memory_agent::type_id::create("host",this);
   endfunction
   task expect_true(bit condition,string message);if(!condition) `uvm_fatal("ORACLE",message) endtask
   function byte unsigned pattern(int address,int salt);return ((address*29)^(address>>4)^salt)&255;endfunction
   task write_command(int address,int size,int salt,bit [1:0] expected_status=0);
     @(negedge command.clk);while(!command.wr_ready) @(negedge command.clk);
     command.wr_address=address;command.wr_bytes=size;
     for(int i=0;i<128;i++) command.wr_data[i*8 +:8]=pattern(address+i,salt);
     command.wr_valid=1;
     @(negedge command.clk);command.wr_valid=0;
     while(!command.wr_done) @(negedge command.clk);
     expect_true(command.wr_status==expected_status,"write response");transactions++;
   endtask
   task read_command(int address,int size,int salt,bit untouched=0,bit [1:0] expected_status=0);
     @(negedge command.clk);while(!command.rd_ready) @(negedge command.clk);
     command.rd_address=address;command.rd_bytes=size;command.rd_valid=1;
     @(negedge command.clk);command.rd_valid=0;
     while(!command.rd_done) @(negedge command.clk);
     expect_true(command.rd_status==expected_status,"read response");
     if(expected_status==0) for(int i=0;i<size;i++) begin
       expect_true(command.rd_data[i*8 +:8]==(untouched?8'ha5:pattern(address+i,salt)), $sformatf("read byte address=%x i=%0d",address,i));byte_checks++;
     end
     transactions++;
   endtask
   task run_phase(uvm_phase phase);
     int address,size;
     phase.raise_objection(this);wait(!command.rst);
     fork
       begin
         forever begin @(posedge bus.clk);if(command.rd_ready==0 && command.wr_ready==0) overlaps++;end
       end
     join_none
     for(int n=1;n<=128;n++) begin
       address=32'h40000+n*256;size=n;
       fork
         write_command(address,size,n);
         read_command(32'h1000,size,0,1);
       join
       read_command(address,size,n);
       for(int i=0;i<size;i++) begin expect_true(memory.bytes[address+i]==pattern(address+i,n),"host write byte");byte_checks++;end
       expect_true(memory.bytes[address-1]==8'ha5 && memory.bytes[address+size]==8'ha5,"write guard");
       cov_beats=(size+7)/8;cov_tail=(size-1)%8+1;cov_resp=0;transfer_coverage.sample();
     end
     write_command(32'h50ff8,8,9);read_command(32'h50ff8,8,9);
     memory.write_error_enable=1;memory.write_error_address=32'h60000;memory.error_response=2;
     write_command(32'h60000,17,9,2);memory.write_error_enable=0;
     cov_resp=2;transfer_coverage.sample();
     memory.read_error_enable=1;memory.read_error_address=32'h60008;
     read_command(32'h60000,17,9,0,2);
     memory.error_response=3;read_command(32'h60000,17,9,0,3);
     cov_resp=3;transfer_coverage.sample();memory.read_error_enable=0;
     write_command(32'h60001,8,0,3);write_command(32'h60ff8,9,0,3);write_command(32'h60000,0,0,3);
     read_command(32'h60001,8,0,0,3);read_command(32'h60ff8,9,0,0,3);read_command(32'h60000,0,0,0,3);
     expect_true(overlaps>0,"no independent read/write overlap observed");
     expect_true(host.monitor.aw_count==host.monitor.b_count,"uncompleted writes");
     `uvm_info("RESULT",$sformatf("AXI_BURST_PASS transactions=%0d byte_checks=%0d overlap_cycles=%0d coverage=%0f",transactions,byte_checks,overlaps,transfer_coverage.get_inst_coverage()),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module axi_burst_tb;
 import uvm_pkg::*;import axi_burst_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 burst_test_if command(clk);axi_memory_if bus(clk);
 assign bus.rst=command.rst;
 always @(posedge clk) if(command.rst) bus.tick<=0;else bus.tick<=bus.tick+1;
 axi_burst_master dut(clk,command.rst,
 command.rd_valid,command.rd_ready,command.rd_address,command.rd_bytes,command.rd_done,command.rd_status,command.rd_data,
 command.wr_valid,command.wr_ready,command.wr_address,command.wr_bytes,command.wr_data,command.wr_done,command.wr_status,
 bus.awaddr,bus.awlen,bus.awsize,bus.awburst,bus.awvalid,bus.awready,
 bus.wdata,bus.wstrb,bus.wlast,bus.wvalid,bus.wready,bus.bresp,bus.bvalid,bus.bready,
 bus.araddr,bus.arlen,bus.arsize,bus.arburst,bus.arvalid,bus.arready,
 bus.rdata,bus.rresp,bus.rlast,bus.rvalid,bus.rready);
 initial begin
   uvm_config_db#(virtual burst_test_if)::set(null,"uvm_test_top","command",command);
   uvm_config_db#(virtual axi_memory_if)::set(null,"uvm_test_top","bus",bus);
   uvm_config_db#(virtual axi_memory_if)::set(null,"uvm_test_top.host.*","vif",bus);
   fork begin repeat(5) @(negedge clk);command.rst=0;end join_none
   run_test("axi_burst_test");
 end
 initial begin #20000000;$fatal(1,"WATCHDOG AXI burst");end
 assert property(@(posedge clk) disable iff(command.rst) bus.awvalid&&!bus.awready |=> bus.awvalid&&$stable({bus.awaddr,bus.awlen,bus.awsize,bus.awburst})) else $fatal(1,"AW stability");
 assert property(@(posedge clk) disable iff(command.rst) bus.wvalid&&!bus.wready |=> bus.wvalid&&$stable({bus.wdata,bus.wstrb,bus.wlast})) else $fatal(1,"W stability");
 assert property(@(posedge clk) disable iff(command.rst) bus.arvalid&&!bus.arready |=> bus.arvalid&&$stable({bus.araddr,bus.arlen,bus.arsize,bus.arburst})) else $fatal(1,"AR stability");
 assert property(@(posedge clk) disable iff(command.rst) bus.rvalid&&!bus.rready |=> bus.rvalid&&$stable({bus.rdata,bus.rresp,bus.rlast})) else $fatal(1,"R stability");
 assert property(@(posedge clk) disable iff(command.rst) bus.bvalid&&!bus.bready |=> bus.bvalid&&$stable(bus.bresp)) else $fatal(1,"B stability");
endmodule
