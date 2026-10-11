`timescale 1ns/1ps
package engine_axi_test_pkg;
 import uvm_pkg::*;import stream_agent_pkg::*;import axi_memory_agent_pkg::*;import axil_agent_pkg::*;import host_software_pkg::*;
 `include "uvm_macros.svh"
 class axil_register_port extends register_port;
   uvm_sequencer#(axil_transaction) sequencer;
   function new(uvm_sequencer#(axil_transaction) target);sequencer=target;endfunction
   virtual task write(bit [31:0] address,bit [31:0] data,bit [3:0] strobe,output bit [1:0] response);
     axil_sequence s=new();s.transaction=new();if(!s.transaction.randomize()) `uvm_fatal("RANDOM","AXI-Lite timing")
     s.transaction.write=1;s.transaction.address=address;s.transaction.data=data;s.transaction.strobe=strobe;
     s.start(sequencer);response=s.transaction.response;
   endtask
   virtual task read(bit [31:0] address,output bit [31:0] data,output bit [1:0] response);
     axil_sequence s=new();s.transaction=new();if(!s.transaction.randomize()) `uvm_fatal("RANDOM","AXI-Lite timing")
     s.transaction.write=0;s.transaction.address=address;s.start(sequencer);data=s.transaction.data;response=s.transaction.response;
   endtask
 endclass
 class axi_platform extends host_platform;
   virtual engine_side_if side;virtual stream_if input_bus,output_bus;
   virtual task wait_cycles(int cycles);repeat(cycles) @(posedge side.clk);endtask
   virtual task wait_interrupt(int timeout,output bit seen);
     seen=0;for(int i=0;i<timeout && !seen;i++) begin @(negedge side.clk);seen=side.irq;end
   endtask
   virtual function bit input_active();return input_bus.valid;endfunction
   virtual function bit output_active();return output_bus.valid;endfunction
   virtual function bit output_idle();return !output_bus.valid;endfunction
   virtual function void set_read_error(bit enable,int unsigned address);memory.read_error_enable=enable;memory.read_error_address=address;memory.error_response=2;endfunction
   virtual function void set_write_error(bit enable,int unsigned address);memory.write_error_enable=enable;memory.write_error_address=address;memory.error_response=2;endfunction
   virtual function string name();return "AXI";endfunction
   virtual function bit transport_registers();return 0;endfunction
   virtual function bit synchronous_write_errors();return 1;endfunction
   virtual function int completion_fault_code();return 3;endfunction
 endclass
 class engine_axi_test extends uvm_test;
   `uvm_component_utils(engine_axi_test)
   axil_agent regs;axi_memory_agent memory_agent;stream_agent source;stream_sink_agent sink;
   uvm_tlm_analysis_fifo#(stream_frame) input_frames,output_frames;
   memory_state memory;stream_sink_config sink_config;engine_host host;axi_platform platform;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     memory=new();uvm_config_db#(memory_state)::set(this,"memory_agent.*","memory",memory);
     sink_config=new();uvm_config_db#(stream_sink_config)::set(this,"sink.*","config",sink_config);
     regs=axil_agent::type_id::create("regs",this);memory_agent=axi_memory_agent::type_id::create("memory_agent",this);
     source=stream_agent::type_id::create("source",this);sink=stream_sink_agent::type_id::create("sink",this);
     input_frames=new("input_frames",this);output_frames=new("output_frames",this);
     platform=new();platform.memory=memory;
     if(!uvm_config_db#(virtual engine_side_if)::get(this,"","side",platform.side)) `uvm_fatal("CONFIG","side vif")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","input_bus",platform.input_bus)) `uvm_fatal("CONFIG","input vif")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","output_bus",platform.output_bus)) `uvm_fatal("CONFIG","output vif")
   endfunction
   function void connect_phase(uvm_phase phase);
     source.monitor.accepted.connect(input_frames.analysis_export);sink.monitor.accepted.connect(output_frames.analysis_export);
   endfunction
   task run_phase(uvm_phase phase);
     axil_register_port port;string fixture;
     phase.raise_objection(this);
     while(memory_agent.responder.vif.rst) @(negedge platform.side.clk);
     port=new(regs.sequencer);host=new("host");host.registers=port;host.platform=platform;host.source=source.sequencer;
     host.sink_config=sink_config;host.input_frames=input_frames;host.output_frames=output_frames;
     if(!$value$plusargs("FIXTURE=%s",fixture)) fixture="../engine/engine.txt";
     host.load(fixture);host.run();host.close_log();
     `uvm_info("RESULT",{"ENGINE_AXI_PASS ",host.summary(),$sformatf(" read_beats=%0d write_beats=%0d useful_write_bytes=%0d",memory.read_beats,memory.write_beats,memory.useful_writes)},UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module engine_axi_tb;
 import uvm_pkg::*;import engine_axi_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 logic rst=1;
 stream_if in_bus(clk),out_bus(clk);axil_if regs(clk);axi_memory_if mem(clk);engine_side_if side(clk);
 assign in_bus.rst=rst;assign out_bus.rst=rst;assign regs.rst=rst;assign mem.rst=rst;
 assign in_bus.tick=side.tick;assign out_bus.tick=side.tick;assign mem.tick=side.tick;
 engine_axi dut(.clk(clk),.rst(rst),
   .s_data(in_bus.data),.s_keep(in_bus.keep),.s_valid(in_bus.valid),.s_last(in_bus.last),.s_ready(in_bus.ready),
   .m_data(out_bus.data),.m_keep(out_bus.keep),.m_valid(out_bus.valid),.m_last(out_bus.last),.m_ready(out_bus.ready),
   .s_awaddr(regs.awaddr),.s_awvalid(regs.awvalid),.s_awready(regs.awready),.s_wdata(regs.wdata),.s_wstrb(regs.wstrb),.s_wvalid(regs.wvalid),.s_wready(regs.wready),
   .s_bresp(regs.bresp),.s_bvalid(regs.bvalid),.s_bready(regs.bready),.s_araddr(regs.araddr),.s_arvalid(regs.arvalid),.s_arready(regs.arready),
   .s_rdata(regs.rdata),.s_rresp(regs.rresp),.s_rvalid(regs.rvalid),.s_rready(regs.rready),
   .m_awaddr(mem.awaddr),.m_awlen(mem.awlen),.m_awsize(mem.awsize),.m_awburst(mem.awburst),.m_awvalid(mem.awvalid),.m_awready(mem.awready),
   .m_wdata(mem.wdata),.m_wstrb(mem.wstrb),.m_wlast(mem.wlast),.m_wvalid(mem.wvalid),.m_wready(mem.wready),
   .m_bresp(mem.bresp),.m_bvalid(mem.bvalid),.m_bready(mem.bready),
   .m_araddr(mem.araddr),.m_arlen(mem.arlen),.m_arsize(mem.arsize),.m_arburst(mem.arburst),.m_arvalid(mem.arvalid),.m_arready(mem.arready),
   .m_rdata(mem.rdata),.m_rresp(mem.rresp),.m_rlast(mem.rlast),.m_rvalid(mem.rvalid),.m_rready(mem.rready),
   .irq(side.irq),.quiescent(side.quiescent),.running(side.running),.tick(side.tick));
 initial begin
   uvm_config_db#(virtual axil_if)::set(null,"uvm_test_top.regs.*","vif",regs);
   uvm_config_db#(virtual axi_memory_if)::set(null,"uvm_test_top.memory_agent.*","vif",mem);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.source.*","vif",in_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.sink.*","vif",out_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","input_bus",in_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","output_bus",out_bus);
   uvm_config_db#(virtual engine_side_if)::set(null,"uvm_test_top","side",side);
   fork begin repeat(5) @(negedge clk);rst=0;end join_none
   run_test("engine_axi_test");
 end
 initial begin #1000000000;$fatal(1,"WATCHDOG engine_axi");end
 assert property(@(posedge clk) disable iff(rst) mem.awvalid && !mem.awready |=> mem.awvalid && $stable({mem.awaddr,mem.awlen})) else $fatal(1,"AW stability");
 assert property(@(posedge clk) disable iff(rst) mem.wvalid && !mem.wready |=> mem.wvalid && $stable({mem.wdata,mem.wstrb,mem.wlast})) else $fatal(1,"W stability");
 assert property(@(posedge clk) disable iff(rst) mem.arvalid && !mem.arready |=> mem.arvalid && $stable({mem.araddr,mem.arlen})) else $fatal(1,"AR stability");
 assert property(@(posedge clk) disable iff(rst) out_bus.valid && !out_bus.ready |=> out_bus.valid && $stable({out_bus.data,out_bus.keep,out_bus.last})) else $fatal(1,"output stream stability");
 assert property(@(posedge clk) disable iff(rst) regs.bvalid && !regs.bready |=> regs.bvalid && $stable(regs.bresp)) else $fatal(1,"AXI-Lite B stability");
 assert property(@(posedge clk) disable iff(rst) regs.rvalid && !regs.rready |=> regs.rvalid && $stable({regs.rdata,regs.rresp})) else $fatal(1,"AXI-Lite R stability");
 assert property(@(posedge clk) disable iff(rst) mem.awvalid |-> mem.awaddr[2:0]==0 && mem.awlen<16 && mem.awburst==1 && mem.awsize==3) else $fatal(1,"AW legal INCR");
 assert property(@(posedge clk) disable iff(rst) mem.arvalid |-> mem.araddr[2:0]==0 && mem.arlen<16 && mem.arburst==1 && mem.arsize==3) else $fatal(1,"AR legal INCR");
endmodule
