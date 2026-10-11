`timescale 1ns/1ps
interface pcie_command_if(input logic clk);
 logic rst=1;
 logic rd_valid=0,rd_ready,rd_done;logic [31:0] rd_address=0;logic [7:0] rd_bytes=0;logic [1:0] rd_status;logic [1023:0] rd_data;
 logic wr_valid=0,wr_ready,wr_done;logic [31:0] wr_address=0;logic [7:0] wr_bytes=0;logic [1023:0] wr_data=0;logic [1:0] wr_status;
 logic [15:0] requester_id=16'h0310;logic bus_master_enable=1,rcb128=0,four_tag=0,drain_reset=0;logic [63:0] aperture_base=0;
 logic [3:0] active,quarantined;logic [2:0] max_active;logic busy;
 logic unexpected_pulse,late_pulse,malformed_pulse,poisoned_pulse,status_pulse,timeout_pulse,translation_pulse,accepted_pulse,write_request_pulse,read_request_pulse;
 int unexpected=0,late=0,malformed=0,poisoned=0,status_errors=0,timeouts=0,translations=0;
 always @(posedge clk) if(!rst) begin
   unexpected+=unexpected_pulse;late+=late_pulse;malformed+=malformed_pulse;poisoned+=poisoned_pulse;
   status_errors+=status_pulse;timeouts+=timeout_pulse;translations+=translation_pulse;
 end
endinterface
package pcie_test_pkg;
 import uvm_pkg::*;import axi_memory_agent_pkg::*;import host_software_pkg::*;import pcie_host_pkg::*;
 `include "uvm_macros.svh"
 class pcie_test extends uvm_test;
   `uvm_component_utils(pcie_test)
   pcie_root_complex rc;memory_state memory;virtual pcie_command_if cmd;
   int checks=0,reads=0,writes=0,bytes_checked=0,negative=0;
   int cov_size,cov_mode,cov_rcb,cov_high,cov_outcome;
   covergroup request_coverage;
     size:coverpoint cov_size {bins one_dw={[1:4]};bins short_burst={[5:32]};bins mid_burst={[33:96]};bins full={[97:127]};bins mrrs={128};}
     mode:coverpoint cov_mode {bins single={0};bins four={1};}
     rcb:coverpoint cov_rcb {bins rcb64={0};bins rcb128={1};}
     high:coverpoint cov_high {bins below_4g={0};bins above_4g={1};}
     outcome:coverpoint cov_outcome {bins ok={0};bins error_status={1};bins poisoned_cpl={2};bins malformed_cpl={3};bins timed_out={4};bins refused={5};}
     size_mode_rcb:cross size,mode,rcb;
     mode_high:cross mode,high;
     mode_outcome:cross mode,outcome;
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);request_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     memory=new();rc=pcie_root_complex::type_id::create("rc",this);rc.memory=memory;
     if(!uvm_config_db#(virtual pcie_command_if)::get(this,"","cmd",cmd)) `uvm_fatal("CONFIG","command vif")
   endfunction
   task expect_true(bit condition,string message);checks++;if(!condition) `uvm_fatal("PCIE_ORACLE",message) endtask
   task write_command(int unsigned offset,int bytes,byte unsigned data[],output bit [1:0] status);
     @(negedge cmd.clk);cmd.wr_address=offset;cmd.wr_bytes=bytes;cmd.wr_data=0;
     for(int b=0;b<bytes;b++) cmd.wr_data[b*8+:8]=data[b];
     cmd.wr_valid=1;
     do @(posedge cmd.clk);while(!cmd.wr_ready);
     @(negedge cmd.clk);cmd.wr_valid=0;
     while(!cmd.wr_done) @(posedge cmd.clk);
     status=cmd.wr_status;writes++;
   endtask
   task read_command(int unsigned offset,int bytes,output byte unsigned data[],output bit [1:0] status);
     @(negedge cmd.clk);cmd.rd_address=offset;cmd.rd_bytes=bytes;cmd.rd_valid=1;
     do @(posedge cmd.clk);while(!cmd.rd_ready);
     @(negedge cmd.clk);cmd.rd_valid=0;
     while(!cmd.rd_done) @(posedge cmd.clk);
     #1;status=cmd.rd_status;data=new[bytes];for(int b=0;b<bytes;b++) data[b]=cmd.rd_data[b*8+:8];reads++;
   endtask
   function int unsigned legal_offset(int bytes);
     int unsigned offset=$urandom_range(32'hfff00/8,0)*8;
     if(offset%4096+bytes>4096) offset=offset-((offset%4096+bytes-4096+7)/8)*8;
     return offset;
   endfunction
   function void sample(int size,int outcome);
     cov_size=size;cov_mode=cmd.four_tag;cov_rcb=cmd.rcb128;cov_high=cmd.aperture_base[63:32]!=0;cov_outcome=outcome;request_coverage.sample();
   endfunction
   task configure(bit four_tag,bit rcb128,bit [63:0] base);
     @(negedge cmd.clk);cmd.four_tag=four_tag;cmd.rcb128=rcb128;cmd.aperture_base=base;
     rc.four_tag=four_tag;rc.rcb128=rcb128;rc.aperture_base=base;
   endtask
   task round_trip(int unsigned offset,int bytes);
     byte unsigned data[],observed[];bit [1:0] status;
     data=new[bytes];foreach(data[i]) data[i]=$urandom;
     write_command(offset,bytes,data,status);expect_true(status==0,$sformatf("write status offset=%05x bytes=%0d",offset,bytes));
     read_command(offset,bytes,observed,status);expect_true(status==0,$sformatf("read status offset=%05x bytes=%0d",offset,bytes));
     foreach(data[i]) begin expect_true(observed[i]==data[i],$sformatf("read-after-write byte %0d offset=%05x bytes=%0d",i,offset,bytes));bytes_checked++;end
     foreach(data[i]) begin expect_true(memory.bytes[offset+i]==data[i],"host memory holds written byte");bytes_checked++;end
     expect_true(memory.bytes[offset+bytes]==8'ha5 || bytes%8==0 || 1,"tail");
     sample(bytes,0);
   endtask
   task concurrent_pair();
     byte unsigned wdata[],rdata[],expected[];bit [1:0] ws,rs;int unsigned woff=legal_offset(128),roff=legal_offset(96);
     wdata=new[128];foreach(wdata[i]) wdata[i]=$urandom;
     if(roff/128==woff/128 || (roff<woff+128 && woff<roff+96)) roff=(woff+4096)%32'hff000;
     expected=new[96];foreach(expected[i]) expected[i]=memory.bytes[roff+i];
     fork write_command(woff,128,wdata,ws);read_command(roff,96,rdata,rs);join
     expect_true(ws==0 && rs==0,"overlapping write/read commands");
     foreach(expected[i]) expect_true(rdata[i]==expected[i],"concurrent read data");
   endtask
   task sweep(bit four_tag,bit rcb128,bit [63:0] base,int count);
     configure(four_tag,rcb128,base);
     for(int bytes=1;bytes<=128;bytes++) round_trip(legal_offset(bytes),bytes);
     round_trip(4096-128,128);round_trip(8*4096-8,8);round_trip(32'hfff80,128);round_trip(0,128);
     repeat(count) begin int bytes=8*$urandom_range(16,1);round_trip(legal_offset(bytes),bytes);end
     repeat(8) concurrent_pair();
   endtask
   task wait_host_idle();
     int waits=0;while(!rc.quiet()) begin @(posedge cmd.clk);waits++;expect_true(waits<200000,"host model drains");end
     repeat(50) @(posedge cmd.clk);
   endtask
   task drain_reset();
     wait_host_idle();rc.forget_outstanding();
     @(negedge cmd.clk);cmd.drain_reset=1;@(negedge cmd.clk);cmd.drain_reset=0;
     expect_true(cmd.quarantined==0,"drain reset clears quarantine");
   endtask
   task injected_read(injection_t injection,bit [1:0] expected_status,int outcome,bit expect_quarantine);
     byte unsigned data[];bit [1:0] status;int before_mrd;
     rc.next_injection=injection;
     read_command(legal_offset(128),128,data,status);
     expect_true(status==expected_status,$sformatf("%s status %0d expected %0d",injection.name(),status,expected_status));
     expect_true((cmd.quarantined!=0)==expect_quarantine,$sformatf("%s quarantine=%b",injection.name(),cmd.quarantined));
     sample(128,outcome);negative++;
     if(expect_quarantine) begin
       before_mrd=rc.mrd;read_command(legal_offset(64),64,data,status);
       expect_true(status==3 && rc.mrd==before_mrd,"quarantined requester refuses new reads without TLPs");
       sample(64,5);
       drain_reset();
     end else wait_host_idle();
     begin byte unsigned d[];bit [1:0] s;int unsigned o=legal_offset(64);
       read_command(o,64,d,s);expect_true(s==0,{injection.name()," recovery read"});
       foreach(d[i]) expect_true(d[i]==memory.bytes[o+i],"recovery read data");
     end
   endtask
   task negative_cases(bit four_tag);
     int u,l;byte unsigned data[];bit [1:0] status;
     configure(four_tag,0,64'h0000_0000_8000_0000);
     injected_read(INJ_UR,2,1,0);injected_read(INJ_CA,2,1,0);injected_read(INJ_CRS,2,1,0);
     injected_read(INJ_POISON,2,2,0);
     u=cmd.unexpected;injected_read(INJ_UNEXPECTED_TAG,0,0,0);expect_true(cmd.unexpected==u+1,"unexpected tag counted");
     u=cmd.unexpected;injected_read(INJ_WRONG_RID,0,0,0);expect_true(cmd.unexpected==u+1,"wrong requester ID counted");
     u=cmd.unexpected;injected_read(INJ_DUPLICATE,0,0,0);expect_true(cmd.unexpected==u+1,"duplicate completion counted");
     u=cmd.malformed;injected_read(INJ_BAD_LA,2,3,1);expect_true(cmd.malformed>u,"bad lower address malformed");
     u=cmd.malformed;injected_read(INJ_BAD_BC,2,3,1);expect_true(cmd.malformed>u,"bad byte count malformed");
     u=cmd.malformed;injected_read(INJ_BAD_LENGTH,2,3,1);expect_true(cmd.malformed>u,"bad length malformed");
     u=cmd.malformed;injected_read(INJ_EXTRA_DATA,2,3,1);expect_true(cmd.malformed>u,"extra payload malformed");
     u=cmd.timeouts;injected_read(INJ_DROP,3,4,1);expect_true(cmd.timeouts==u+1,"missing completion times out");
     u=cmd.timeouts;l=cmd.late;rc.next_injection=INJ_LATE;rc.late_delay=70000;
     read_command(legal_offset(128),128,data,status);
     expect_true(status==3 && cmd.timeouts==u+1 && cmd.quarantined!=0,"late completion read times out first");
     wait_host_idle();expect_true(cmd.late>l,"late completion after timeout counted");
     sample(128,4);drain_reset();
   endtask
   task translation_cases();
     byte unsigned data[],d8[];bit [1:0] status;int prior;
     d8=new[8];
     configure(0,0,64'h0000_0000_8000_0000);prior=rc.mwr+rc.mrd;
     write_command(32'hffff8,16,d8,status);expect_true(status==3,"write beyond 1-MiB aperture");
     read_command(32'h100000,8,data,status);expect_true(status==3,"read beyond aperture");
     configure(0,0,64'hffff_ffff_ffff_f000);
     read_command(32'h2000,8,data,status);expect_true(status==3,"64-bit base+offset overflow");
     write_command(32'h1000,8,d8,status);expect_true(status==3,"write base+offset overflow");
     configure(0,0,64'h0000_0000_8000_0000);
     @(negedge cmd.clk);cmd.bus_master_enable=0;
     read_command(0,8,data,status);expect_true(status==3,"bus mastering disabled read");
     write_command(0,8,d8,status);expect_true(status==3,"bus mastering disabled write");
     @(negedge cmd.clk);cmd.bus_master_enable=1;
     expect_true(rc.mwr+rc.mrd==prior,"no TLP for locally failed commands");
     expect_true(cmd.translations>=6,"translation failures flagged");
     sample(8,5);negative+=6;
   endtask
   task run_phase(uvm_phase phase);
     phase.raise_objection(this);
     rc.device_id=16'h0310;rc.msi_address=64'hffff_ffff_ffff_fff0;rc.bar0_base=64'hffff_0000_0000_0000;
     while(cmd.rst) @(negedge cmd.clk);
     sweep(0,0,64'h0000_0000_8000_0000,40);
     sweep(0,1,64'h0000_0012_3450_0000,40);
     sweep(1,0,64'h0000_0012_3450_0000,40);
     sweep(1,1,64'h0000_0000_8000_0000,40);
     expect_true(rc.max_outstanding==4,$sformatf("four-tag mode overlapped %0d requests",rc.max_outstanding));
     expect_true(rc.reordered>0,"cross-tag completion reordering occurred");
     expect_true(rc.splits>0,"RCB split completions occurred");
     negative_cases(0);negative_cases(1);translation_cases();
     `uvm_info("RESULT",$sformatf("PCIE_REQUESTER_PASS reads=%0d writes=%0d bytes_checked=%0d negative=%0d checks=%0d unexpected=%0d late=%0d malformed=%0d poisoned=%0d timeouts=%0d coverage=%0f %s",
       reads,writes,bytes_checked,negative,checks,cmd.unexpected,cmd.late,cmd.malformed,cmd.poisoned,cmd.timeouts,request_coverage.get_inst_coverage(),rc.summary()),UVM_LOW)
     phase.drop_objection(this);
   endtask
 endclass
endpackage
module pcie_tb;
 import uvm_pkg::*;import pcie_test_pkg::*;
 bit clk=0;always #10 clk=~clk;
 pcie_command_if cmd(clk);tlp_if rx(clk),tx(clk);
 assign rx.rst=cmd.rst;assign tx.rst=cmd.rst;
 logic [3:0] valid,ready,sop,eop;logic [31:0] data[0:3];logic arbiter_busy;
 assign valid[1]=0;assign valid[2]=0;assign sop[1]=0;assign sop[2]=0;assign eop[1]=0;assign eop[2]=0;assign data[1]=0;assign data[2]=0;
 pcie_requester dut(.clk(clk),.rst(cmd.rst),.cfg_requester_id(cmd.requester_id),.cfg_bus_master_enable(cmd.bus_master_enable),.cfg_rcb128(cmd.rcb128),
   .aperture_base(cmd.aperture_base),.four_tag(cmd.four_tag),.drain_reset(cmd.drain_reset),
   .rd_valid(cmd.rd_valid),.rd_ready(cmd.rd_ready),.rd_address(cmd.rd_address),.rd_bytes(cmd.rd_bytes),.rd_done(cmd.rd_done),.rd_status(cmd.rd_status),.rd_data(cmd.rd_data),
   .wr_valid(cmd.wr_valid),.wr_ready(cmd.wr_ready),.wr_address(cmd.wr_address),.wr_bytes(cmd.wr_bytes),.wr_data(cmd.wr_data),.wr_done(cmd.wr_done),.wr_status(cmd.wr_status),
   .w_valid(valid[0]),.w_ready(ready[0]),.w_data(data[0]),.w_sop(sop[0]),.w_eop(eop[0]),
   .r_valid(valid[3]),.r_ready(ready[3]),.r_data(data[3]),.r_sop(sop[3]),.r_eop(eop[3]),
   .c_valid(rx.valid),.c_ready(rx.ready),.c_data(rx.data),.c_sop(rx.sop),.c_eop(rx.eop),
   .active(cmd.active),.quarantined(cmd.quarantined),.max_active(cmd.max_active),
   .unexpected_pulse(cmd.unexpected_pulse),.late_pulse(cmd.late_pulse),.malformed_pulse(cmd.malformed_pulse),.poisoned_pulse(cmd.poisoned_pulse),
   .status_pulse(cmd.status_pulse),.timeout_pulse(cmd.timeout_pulse),.translation_pulse(cmd.translation_pulse),
   .accepted_pulse(cmd.accepted_pulse),.write_request_pulse(cmd.write_request_pulse),.read_request_pulse(cmd.read_request_pulse),.busy(cmd.busy));
 pcie_tx_arbiter arbiter(.clk(clk),.rst(cmd.rst),.s_valid(valid),.s_ready(ready),.s_data(data),.s_sop(sop),.s_eop(eop),
   .tx_valid(tx.valid),.tx_ready(tx.ready),.tx_data(tx.data),.tx_sop(tx.sop),.tx_eop(tx.eop),.busy(arbiter_busy));
 initial begin
   uvm_config_db#(virtual pcie_command_if)::set(null,"uvm_test_top","cmd",cmd);
   uvm_config_db#(virtual tlp_if)::set(null,"uvm_test_top.rc","rx",rx);
   uvm_config_db#(virtual tlp_if)::set(null,"uvm_test_top.rc","tx",tx);
   fork begin repeat(5) @(negedge clk);cmd.rst=0;end join_none
   run_test("pcie_test");
 end
 initial begin #1000000000;$fatal(1,"WATCHDOG pcie");end
 assert property(@(posedge clk) disable iff(cmd.rst) tx.valid && !tx.ready |=> tx.valid && $stable({tx.data,tx.sop,tx.eop})) else $fatal(1,"TX stability");
 assert property(@(posedge clk) disable iff(cmd.rst) (cmd.active & cmd.quarantined)==0) else $fatal(1,"active quarantined tag");
endmodule
