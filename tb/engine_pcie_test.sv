`timescale 1ns/1ps
package engine_pcie_test_pkg;
 import uvm_pkg::*;import stream_agent_pkg::*;import axi_memory_agent_pkg::*;import host_software_pkg::*;import pcie_host_pkg::*;
 `include "uvm_macros.svh"
 class engine_pcie_test extends uvm_test;
   `uvm_component_utils(engine_pcie_test)
   pcie_root_complex rc;stream_agent source;stream_sink_agent sink;
   uvm_tlm_analysis_fifo#(stream_frame) input_frames,output_frames;
   memory_state memory;stream_sink_config sink_config;engine_host host;pcie_platform platform;bar_register_port port;
   virtual engine_side_if side;virtual pcie_cfg_if cfg;
   bit high_aperture,four_tag,rcb128,high_bar;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     string text;
     memory=new();sink_config=new();uvm_config_db#(stream_sink_config)::set(this,"sink.*","config",sink_config);
     rc=pcie_root_complex::type_id::create("rc",this);rc.memory=memory;
     source=stream_agent::type_id::create("source",this);sink=stream_sink_agent::type_id::create("sink",this);
     input_frames=new("input_frames",this);output_frames=new("output_frames",this);
     platform=new();platform.memory=memory;platform.rc=rc;
     if(!uvm_config_db#(virtual engine_side_if)::get(this,"","side",platform.side)) `uvm_fatal("CONFIG","side vif")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","input_bus",platform.input_bus)) `uvm_fatal("CONFIG","input vif")
     if(!uvm_config_db#(virtual stream_if)::get(this,"","output_bus",platform.output_bus)) `uvm_fatal("CONFIG","output vif")
     if(!uvm_config_db#(virtual pcie_cfg_if)::get(this,"","cfg",cfg)) `uvm_fatal("CONFIG","cfg vif")
     side=platform.side;
     high_aperture=$test$plusargs("HIGH_APERTURE");four_tag=$test$plusargs("FOUR_TAG");rcb128=$test$plusargs("RCB128");high_bar=$test$plusargs("HIGH_BAR");
   endfunction
   function void connect_phase(uvm_phase phase);
     source.monitor.accepted.connect(input_frames.analysis_export);sink.monitor.accepted.connect(output_frames.analysis_export);
   endfunction
   task transport_write(bit [31:0] address,bit [31:0] value);
     bit [1:0] response;port.write(address,value,15,response);
     if(response!=0) `uvm_fatal("PCIE_TEST",$sformatf("transport write %04x rejected",address))
   endtask
   task run_phase(uvm_phase phase);
     string fixture;bit [31:0] value;bit [1:0] response;
     phase.raise_objection(this);
     rc.device_id=16'h0310;rc.aperture_base=high_aperture?64'h0000_0012_3450_0000:64'h0000_0000_8000_0000;
     rc.bar0_base=high_bar?64'h0000_0040_0000_4000:64'h0000_0000_f000_0000;
     rc.msi_address=high_aperture?64'h0000_0001_fee0_0000:64'h0000_0000_fee0_0000;rc.msi_data=16'h4a21;
     rc.rcb128=rcb128;rc.four_tag=four_tag;
     cfg.requester_id=rc.device_id;cfg.bar0_base=rc.bar0_base;cfg.msi_address=rc.msi_address;cfg.msi_data=rc.msi_data;
     cfg.bus_master_enable=1;cfg.msi_enable=1;cfg.msi_mask=0;cfg.rcb128=rcb128;
     while(rc.rx.rst!==1'b0) @(negedge side.clk);
     repeat(4) @(negedge side.clk);
     while(side.quiescent!==1'b1) @(negedge side.clk);
     port=new(rc);
     port.read('h1000,value,response);if(response!=0 || value!='h50434931) `uvm_fatal("PCIE_TEST","transport ID")
     port.write('h1008,'h123,15,response);if(response!=2) `uvm_fatal("PCIE_TEST","unaligned aperture base accepted")
     transport_write('h1008,rc.aperture_base[31:0]);transport_write('h100c,rc.aperture_base[63:32]);
     transport_write('h1004,four_tag);
     port.read('h100c,value,response);if(value!=rc.aperture_base[63:32]) `uvm_fatal("PCIE_TEST","aperture readback")
     host=new("host",0);host.registers=port;host.platform=platform;host.source=source.sequencer;
     host.sink_config=sink_config;host.input_frames=input_frames;host.output_frames=output_frames;
     if(!$value$plusargs("FIXTURE=%s",fixture)) fixture="../engine/engine.txt";
     host.load(fixture);host.run();
     msi_directed();host.close_log();
     port.read('h1014,value,response);
     if(value[8:0]!='h010) `uvm_info("PCIE_TEST",$sformatf("transport sticky flags %03x",value[8:0]),UVM_LOW)
     if(value[1:0]!=0 || value[2] || value[4] || value[5]) `uvm_fatal("PCIE_TEST",$sformatf("unexpected completion faults in sticky %03x",value))
     port.read('h1030,value,response);
     if(four_tag && value<2) `uvm_fatal("PCIE_TEST","four-tag mode never overlapped requests")
     if(four_tag && rc.reordered==0) `uvm_fatal("PCIE_TEST","no cross-tag completion reordering observed")
     `uvm_info("RESULT",{"ENGINE_PCIE_PASS ",host.summary(),$sformatf(" aperture=%016x four_tag=%0d rcb=%0d device_max_tags=%0d ",rc.aperture_base,four_tag,rcb128?128:64,value),rc.summary()},UVM_LOW)
     phase.drop_objection(this);
   endtask
   task expect_msi(int expected,string step);
     host.platform.wait_cycles(3000);
     if(rc.msi!=expected) `uvm_fatal("PCIE_MSI",$sformatf("%s: MSI count %0d expected %0d",step,rc.msi,expected))
   endtask
   task msi_status(bit pending,bit armed,string step);
     bit [31:0] value;bit [1:0] response;port.read('h1010,value,response);
     if(value[2]!==pending || value[5]!==armed) `uvm_fatal("PCIE_MSI",$sformatf("%s: status %08x pending=%0d armed=%0d expected %0d/%0d",step,value,value[2],value[5],pending,armed))
   endtask
   task capture_notify(int index);
     int count=0;
     foreach(host.captures[i]) if(host.captures[i].phase==5) begin
       if(count==index) begin
         host.publish_capture(host.captures[i]);host.doorbells();host.send(host.frames[host.captures[i].frame]);
         host.wait_inputs_observed();
       end
       count++;
     end
     begin bit [31:0] producer;int polls=0;
       host.rd(host.rb(0)+16,producer);
       while(producer-host.cq_consumed[0]<host.expected[0].size()) begin
         polls++;if(polls>5000) `uvm_fatal("PCIE_MSI","notification capture did not commit")
         host.platform.wait_cycles(20);host.rd(host.rb(0)+16,producer);
       end
     end
   endtask
   task msi_directed();
     int base;
     host.wr('h8,1);
     base=rc.msi;msi_status(0,1,"idle armed");
     cfg.msi_mask=1;rc.msi_masked=1;
     capture_notify(0);expect_msi(base,"masked event");msi_status(1,0,"masked event pending");
     rc.msi_masked=0;cfg.msi_mask=0;expect_msi(base+1,"unmask delivers pending");msi_status(0,0,"delivered, not re-armed");
     capture_notify(1);expect_msi(base+1,"continuously asserted IRQ, not re-armed");
     host.wr('h28,0);expect_msi(base+2,"re-arm with IRQ still asserted");
     host.service_ring(0);host.wr('h28,255);expect_msi(base+2,"re-arm after condition cleared");msi_status(0,1,"armed and idle");
     cfg.msi_mask=1;rc.msi_masked=1;capture_notify(2);expect_msi(base+2,"masked third event");msi_status(1,0,"third pending");
     cfg.msi_enable=0;host.platform.wait_cycles(4);msi_status(0,0,"disable clears pending");
     cfg.msi_enable=1;rc.msi_masked=0;cfg.msi_mask=0;expect_msi(base+2,"no message without pending or arming");
     host.wr('h28,0);expect_msi(base+3,"re-arm with unread record");
     host.service_ring(0);host.wr('h28,255);expect_msi(base+3,"final clear");
     if(host.outstanding()!=0) `uvm_fatal("PCIE_MSI","notification records outstanding")
     host.wr('h8,2);host.wait_quiescent("MSI directed");
     `uvm_info("PCIE_TEST",$sformatf("MSI directed checks passed: %0d messages, masked/pending/unmask/re-arm/disable cases",rc.msi-base),UVM_LOW)
   endtask
 endclass
endpackage
interface pcie_cfg_if;
 logic [15:0] requester_id=16'h0310,msi_data=0;logic [63:0] bar0_base=0,msi_address=0;
 logic bus_master_enable=0,msi_enable=0,msi_mask=0,rcb128=0;
endinterface
module engine_pcie_tb;
 import uvm_pkg::*;import engine_pcie_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 logic rst=1;
 stream_if in_bus(clk),out_bus(clk);tlp_if rx(clk),tx(clk);engine_side_if side(clk);pcie_cfg_if cfg();
 assign in_bus.rst=rst;assign out_bus.rst=rst;assign rx.rst=rst;assign tx.rst=rst;
 assign in_bus.tick=side.tick;assign out_bus.tick=side.tick;
 engine_pcie dut(.clk(clk),.rst(rst),
   .s_data(in_bus.data),.s_keep(in_bus.keep),.s_valid(in_bus.valid),.s_last(in_bus.last),.s_ready(in_bus.ready),
   .m_data(out_bus.data),.m_keep(out_bus.keep),.m_valid(out_bus.valid),.m_last(out_bus.last),.m_ready(out_bus.ready),
   .rx_data(rx.data),.rx_valid(rx.valid),.rx_sop(rx.sop),.rx_eop(rx.eop),.rx_ready(rx.ready),
   .tx_data(tx.data),.tx_valid(tx.valid),.tx_sop(tx.sop),.tx_eop(tx.eop),.tx_ready(tx.ready),
   .cfg_requester_id(cfg.requester_id),.cfg_bar0_base(cfg.bar0_base),.cfg_bus_master_enable(cfg.bus_master_enable),
   .cfg_msi_enable(cfg.msi_enable),.cfg_msi_mask(cfg.msi_mask),.cfg_rcb128(cfg.rcb128),.cfg_msi_address(cfg.msi_address),.cfg_msi_data(cfg.msi_data),
   .irq(side.irq),.quiescent(side.quiescent),.running(side.running),.tick(side.tick));
 initial begin
   uvm_config_db#(virtual tlp_if)::set(null,"uvm_test_top.rc","rx",rx);
   uvm_config_db#(virtual tlp_if)::set(null,"uvm_test_top.rc","tx",tx);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.source.*","vif",in_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top.sink.*","vif",out_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","input_bus",in_bus);
   uvm_config_db#(virtual stream_if)::set(null,"uvm_test_top","output_bus",out_bus);
   uvm_config_db#(virtual engine_side_if)::set(null,"uvm_test_top","side",side);
   uvm_config_db#(virtual pcie_cfg_if)::set(null,"uvm_test_top","cfg",cfg);
   fork begin repeat(5) @(negedge clk);rst=0;end join_none
   run_test("engine_pcie_test");
 end
 initial begin #2000000000;$fatal(1,"WATCHDOG engine_pcie");end
 bit trace;initial trace=$test$plusargs("TLP_TRACE");
 always @(posedge clk) if(trace && !rst) begin
   if(rx.valid && rx.ready) $display("%0t RX %08x sop=%0d eop=%0d",$time,rx.data,rx.sop,rx.eop);
   if(tx.valid && tx.ready) $display("%0t TX %08x sop=%0d eop=%0d",$time,tx.data,tx.sop,tx.eop);
 end
 assert property(@(posedge clk) disable iff(rst) tx.valid && !tx.ready |=> tx.valid && $stable({tx.data,tx.sop,tx.eop})) else $fatal(1,"TX TLP stream stability");
 assert property(@(posedge clk) disable iff(rst) out_bus.valid && !out_bus.ready |=> out_bus.valid && $stable({out_bus.data,out_bus.keep,out_bus.last})) else $fatal(1,"output stream stability");
endmodule
