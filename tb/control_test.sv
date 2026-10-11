`timescale 1ns/1ps
interface control_test_if(input logic clk);
 logic rst=1,quiescent=1,abort_done=0;
 logic [63:0] tick=0,drop_count[0:5];
 logic [7:0] claim=0,commit=0,fault=0,claim_ready,reserved,halted;
 logic [3:0] fault_code[0:7];
 logic [31:0] sq_base[0:7],cq_base[0:7],sq_producer[0:7],sq_consumer[0:7],cq_producer[0:7],cq_consumer[0:7];
 logic running,aborting,irq,notification_rearm;logic [31:0] epoch;
endinterface
package control_test_pkg;
 import uvm_pkg::*;import axil_agent_pkg::*;
 `include "uvm_macros.svh"
 class control_test extends uvm_test;
   `uvm_component_utils(control_test)
   virtual control_test_if control;virtual axil_if bus;
   axil_agent host;engine_reg_block registers;axil_reg_adapter adapter;
   int checks=0,claims=0,commits=0,rejected=0;
   bit [31:0] published[8],consumed[8],completed[8],acknowledged[8];bit active[8],stopped[8];
   int cov_ring,cov_action;
   covergroup ring_coverage;
     ring_index:coverpoint cov_ring {bins ring[]={[0:7]};}
     action:coverpoint cov_action {bins claim={0};bins completion={1};bins full={2};bins counter_wrap={3};bins recovery={4};}
     ring_action:cross ring_index,action;
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);ring_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual control_test_if)::get(this,"","control",control)) `uvm_fatal("CONFIG","control vif")
     if(!uvm_config_db#(virtual axil_if)::get(this,"","bus",bus)) `uvm_fatal("CONFIG","bus vif")
     host=axil_agent::type_id::create("host",this);registers=new();registers.build();adapter=new();
   endfunction
   function void connect_phase(uvm_phase phase);registers.default_map.set_sequencer(host.sequencer,adapter);registers.default_map.set_auto_predict(1);endfunction
   task expect_true(bit condition,string message);checks++;if(!condition) `uvm_fatal("ORACLE",message) endtask
   function int rb(int r);return (r<4?'h400:'h800)+(r%4)*64;endfunction
   task write_word(int address,bit [31:0] value,bit [3:0] strobes=15,bit [1:0] expected=0);
     axil_sequence seq=new();seq.transaction=new();
     if(!seq.transaction.randomize()) `uvm_fatal("RANDOM","AXIL delay generation")
     seq.transaction.write=1;seq.transaction.address=address;seq.transaction.data=value;seq.transaction.strobe=strobes;
     seq.start(host.sequencer);expect_true(seq.transaction.response==expected,$sformatf("write response address=%x got=%0d expected=%0d",address,seq.transaction.response,expected));
     if(expected!=0) rejected++;
   endtask
   task read_word(int address,bit [31:0] value,bit [1:0] expected=0);
     axil_sequence seq=new();seq.transaction=new();
     if(!seq.transaction.randomize()) `uvm_fatal("RANDOM","AXIL read delay")
     seq.transaction.write=0;seq.transaction.address=address;
     seq.start(host.sequencer);expect_true(seq.transaction.response==expected,$sformatf("read response address=%x",address));
     expect_true(seq.transaction.data==value,$sformatf("read value address=%x got=%x expected=%x",address,seq.transaction.data,value));
   endtask
   task ledger_check();
     for(int r=0;r<8;r++) begin
       expect_true(control.sq_producer[r]==published[r] && control.sq_consumer[r]==consumed[r],$sformatf("SQ ledger ring %0d",r));
       expect_true(control.cq_producer[r]==completed[r] && control.cq_consumer[r]==acknowledged[r],$sformatf("CQ ledger ring %0d",r));
       expect_true(control.reserved[r]==active[r] && control.halted[r]==stopped[r],"ownership reservation/halt");
       expect_true(control.claim_ready[r]==(!stopped[r] && !active[r] && published[r]!=consumed[r] && (completed[r]-acknowledged[r])<64),"claim credit");
     end
   endtask
   task publish(int r,bit [31:0] value);
     write_word(rb(r)+8,value);published[r]=value;ledger_check();
   endtask
   task acknowledge(int r,bit [31:0] value);
     write_word(rb(r)+20,value);acknowledged[r]=value;ledger_check();
   endtask
   task claim_one(int r);
     expect_true(!active[r] && published[r]!=consumed[r] && completed[r]-acknowledged[r]<64,"test tried illegal claim");
     @(negedge control.clk);control.claim=1<<r;@(negedge control.clk);control.claim=0;
     active[r]=1;consumed[r]++;claims++;cov_ring=r;cov_action=0;ring_coverage.sample();ledger_check();
   endtask
   task complete_one(int r);
     expect_true(active[r],"test completion lacks owner");
     @(negedge control.clk);control.commit=1<<r;@(negedge control.clk);control.commit=0;
     active[r]=0;completed[r]++;commits++;cov_ring=r;cov_action=1;ring_coverage.sample();ledger_check();
   endtask
   task recover(int r);
     write_word(rb(r)+28,1);stopped[r]=0;published[r]=consumed[r];cov_ring=r;cov_action=4;ring_coverage.sample();ledger_check();
   endtask
   task racing_write(int address,int value,bit [7:0] new_commit,bit [7:0] new_fault);
     int waits=0;
     @(negedge bus.clk);bus.awaddr=address;bus.wdata=value;bus.wstrb=15;bus.awvalid=1;bus.wvalid=1;
     @(posedge bus.clk);expect_true(bus.awready && bus.wready,"race write channels idle");
     @(negedge bus.clk);bus.awvalid=0;bus.wvalid=0;
     @(negedge bus.clk);control.commit=new_commit;control.fault=new_fault;
     @(negedge bus.clk);control.commit=0;control.fault=0;bus.bready=1;
     do begin @(posedge bus.clk);waits++;end while(!bus.bvalid && waits<4);
     expect_true(bus.bvalid && bus.bresp==0 && waits==1,"racing write accepted at the documented latency");
     @(negedge bus.clk);bus.bready=0;
   endtask
   task run_phase(uvm_phase phase);
     uvm_status_e status;uvm_reg_data_t value;bit [31:0] merged;
     phase.raise_objection(this);wait(!control.rst);
     registers.identity.read(status,value);expect_true(status==UVM_IS_OK && value==32'h4e455431,"RAL ID");
     registers.seed.write(status,32'h13579bdf);expect_true(status==UVM_IS_OK,"RAL seed write");
     registers.seed.mirror(status,UVM_CHECK);expect_true(status==UVM_IS_OK,"RAL seed mirror");
     ledger_check();read_word('hc,2);
     for(int r=0;r<8;r++) begin read_word(rb(r),'h10000+r*2048);read_word(rb(r)+4,'h14000+r*2048);end
     merged=32'h13579bdf;
     for(int s=0;s<16;s++) begin
       for(int b=0;b<4;b++) if((s>>b)&1) merged[b*8+:8]=8'hc0+s+b;
       write_word('h120,{8'(8'hc3+s),8'(8'hc2+s),8'(8'hc1+s),8'(8'hc0+s)},s[3:0]);read_word('h120,merged);
     end
     write_word(0,0,15,2);write_word(1,0,15,2);write_word('h218,0,15,2);write_word('h4000,0,15,2);
     read_word(1,0,2);read_word(8,0,2);read_word('h1000,0,2);
     write_word('h100,2,15,2);write_word('h104,8,15,2);write_word('h200,32,15,2);write_word('h20,512,15,2);
     write_word('h128,1,15);write_word('h124,1,15,2);write_word('h128,0);write_word('h124,123);write_word('h128,1,15,2);
     write_word('h400,'h1f000,15,2);write_word('h400,'h14000,15,2);write_word('h400,'h10001,15,2);write_word('h400,'h40000,15,2);
     write_word('h400,'h20000);read_word('h400,'h20000);write_word('h400,'h10000);
     control.tick=64'h12345678fffffff0;for(int d=0;d<6;d++) control.drop_count[d]=64'h9876543200000000+d;
     write_word('h40,1);control.tick=64'h1234567900000010;for(int d=0;d<6;d++) control.drop_count[d]=d;
     read_word('h48,'hfffffff0);read_word('h4c,'h12345678);
     for(int d=0;d<6;d++) begin read_word('hc00+d*8,d);read_word('hc04+d*8,'h98765432);end
     write_word(8,1);control.quiescent=0;read_word('hc,1);
     write_word('h120,0,15,2);write_word('h200,1,15,2);write_word('h400,'h20000,15,2);write_word(8,1,15,2);
     write_word('h120,0,0);read_word('h120,merged);
     write_word('h20,511);write_word(8,2);read_word('hc,0);write_word('h120,0,15,2);
     control.quiescent=1;write_word('h120,0);
     for(int r=0;r<8;r++) begin
       publish(r,32);write_word(rb(r)+8,33,15,2);write_word(rb(r)+8,31,15,2);write_word(rb(r)+8,32,1,2);
       for(int n=0;n<64;n++) begin
         if(n==32) publish(r,64);
         claim_one(r);complete_one(r);
       end
       publish(r,65);expect_true(!control.claim_ready[r],"full CQ blocks claim");cov_ring=r;cov_action=2;ring_coverage.sample();
       write_word(rb(r)+20,65,15,2);write_word(rb(r)+20,32'hffffffff,15,2);write_word(rb(r)+20,1,1,2);
       @(negedge control.clk);control.claim=1<<r;@(negedge control.clk);control.claim=0;ledger_check();
       acknowledge(r,64);claim_one(r);complete_one(r);acknowledge(r,65);
       write_word(rb(r)+32,32'hfffffffc);published[r]='hfffffffc;consumed[r]='hfffffffc;completed[r]='hfffffffc;acknowledged[r]='hfffffffc;
       publish(r,4);for(int n=0;n<8;n++) begin claim_one(r);complete_one(r);end
       acknowledge(r,4);cov_ring=r;cov_action=3;ring_coverage.sample();
       publish(r,6);claim_one(r);
       @(negedge control.clk);control.fault_code[r]=3;control.fault=1<<r;@(negedge control.clk);control.fault=0;
       stopped[r]=1;active[r]=0;ledger_check();expect_true(control.irq,"fault IRQ");
       recover(r);acknowledge(r,completed[r]);write_word(rb(r)+32,0);published[r]=0;consumed[r]=0;completed[r]=0;acknowledged[r]=0;
     end
     read_word('h30,3);read_word('h38,0);read_word('h3c,4);write_word('h34,1);read_word('h30,0);
     write_word('h28,255);expect_true(!control.irq,"all CQ events cleared");
     publish(0,1);claim_one(0);racing_write('h28,1,1,0);active[0]=0;completed[0]++;
     acknowledge(0,1);read_word('h24,1);expect_true(control.irq,"hardware set wins W1C");write_word('h28,1);expect_true(!control.irq,"event clear after consume");
     publish(1,1);claim_one(1);control.fault_code[1]=4;racing_write('h34,1,0,2);active[1]=0;stopped[1]=1;
     read_word('h30,4);read_word('h38,1);read_word('h3c,0);ledger_check();
     publish(2,2);claim_one(2);write_word(8,1);control.quiescent=0;write_word(8,4);read_word('hc,4);
     write_word(8,4,15,2);expect_true(control.reserved[2],"abort cannot cancel accepted work before drain");
     control.abort_done=1;repeat(3) @(negedge control.clk);expect_true(control.epoch==0 && control.aborting,"no epoch advance before quiescence");
     control.quiescent=1;@(negedge control.clk);control.abort_done=0;active[2]=0;
     read_word('h10,1);read_word('hc,2);ledger_check();recover(1);recover(2);
     `uvm_info("RESULT",$sformatf("CONTROL_PASS checks=%0d claims=%0d commits=%0d rejected=%0d ring_coverage=%0f bus_coverage=%0f",checks,claims,commits,rejected,ring_coverage.get_inst_coverage(),host.monitor.bus_coverage.get_inst_coverage()),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module control_tb;
 import uvm_pkg::*;import control_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 control_test_if control(clk);axil_if bus(clk);
 logic fixed_mode,drop_on_full;logic [1:0] default_queue;
 logic [63:0] replay_start,replay_origin,replay_interval,queue_delay[0:3];logic [31:0] loss_seed;logic [32:0] loss_threshold;
 logic [4:0] rule_control[0:7];logic [31:0] rule_src[0:7],rule_src_mask[0:7],rule_dst[0:7],rule_dst_mask[0:7],rule_ports[0:7];
 assign bus.rst=control.rst;always @(posedge clk) if(control.rst) bus.tick<=0;else bus.tick<=bus.tick+1;
 engine_control dut(.clk(clk),.rst(control.rst),.tick(control.tick),.quiescent(control.quiescent),.abort_done(control.abort_done),.drop_count(control.drop_count),
 .claim(control.claim),.commit(control.commit),.fault(control.fault),.fault_code(control.fault_code),.claim_ready(control.claim_ready),.reserved(control.reserved),.halted(control.halted),
 .sq_base(control.sq_base),.cq_base(control.cq_base),.sq_producer(control.sq_producer),.sq_consumer(control.sq_consumer),.cq_producer(control.cq_producer),.cq_consumer(control.cq_consumer),
 .running(control.running),.aborting(control.aborting),.irq(control.irq),.notification_rearm(control.notification_rearm),.epoch(control.epoch),
 .fixed_mode(fixed_mode),.drop_on_full(drop_on_full),.default_queue(default_queue),.replay_start(replay_start),.replay_origin(replay_origin),.replay_interval(replay_interval),.queue_delay(queue_delay),
 .loss_seed(loss_seed),.loss_threshold(loss_threshold),.rule_control(rule_control),.rule_src(rule_src),.rule_src_mask(rule_src_mask),.rule_dst(rule_dst),.rule_dst_mask(rule_dst_mask),.rule_ports(rule_ports),
 .s_awaddr(bus.awaddr),.s_awvalid(bus.awvalid),.s_awready(bus.awready),.s_wdata(bus.wdata),.s_wstrb(bus.wstrb),.s_wvalid(bus.wvalid),.s_wready(bus.wready),.s_bresp(bus.bresp),.s_bvalid(bus.bvalid),.s_bready(bus.bready),
 .s_araddr(bus.araddr),.s_arvalid(bus.arvalid),.s_arready(bus.arready),.s_rdata(bus.rdata),.s_rresp(bus.rresp),.s_rvalid(bus.rvalid),.s_rready(bus.rready));
 initial begin
   for(int d=0;d<6;d++) control.drop_count[d]=0;for(int r=0;r<8;r++) control.fault_code[r]=0;
   uvm_config_db#(virtual control_test_if)::set(null,"uvm_test_top","control",control);
   uvm_config_db#(virtual axil_if)::set(null,"uvm_test_top","bus",bus);uvm_config_db#(virtual axil_if)::set(null,"uvm_test_top.host.*","vif",bus);
   fork begin repeat(5) @(negedge clk);control.rst=0;end join_none
   run_test("control_test");
 end
 initial begin #20000000;$fatal(1,"WATCHDOG control");end
 assert property(@(posedge clk) disable iff(control.rst) bus.bvalid&&!bus.bready |=> bus.bvalid&&$stable(bus.bresp)) else $fatal(1,"control B stability");
 assert property(@(posedge clk) disable iff(control.rst) bus.rvalid&&!bus.rready |=> bus.rvalid&&$stable({bus.rresp,bus.rdata})) else $fatal(1,"control R stability");
 for(genvar r=0;r<8;r++) begin
   assert property(@(posedge clk) disable iff(control.rst) control.sq_producer[r]-control.sq_consumer[r]<=32) else $fatal(1,"SQ capacity");
   assert property(@(posedge clk) disable iff(control.rst) control.cq_producer[r]-control.cq_consumer[r]+control.reserved[r]<=64) else $fatal(1,"CQ reservation capacity");
 end
endmodule
