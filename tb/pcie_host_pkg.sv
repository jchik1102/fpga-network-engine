`timescale 1ns/1ps
// ordering is deliberately weak: only device reads flush posted writes
package pcie_host_pkg;
 import uvm_pkg::*;import axi_memory_agent_pkg::*;import host_software_pkg::*;
 `include "uvm_macros.svh"

 class tlp_packet extends uvm_object;
   `uvm_object_utils(tlp_packet)
   bit [31:0] dw[$];longint unsigned arrival;int request_order;
   function new(string name="tlp_packet");super.new(name);endfunction
   function bit [2:0] fmt();return dw[0][31:29];endfunction
   function bit [4:0] kind();return dw[0][28:24];endfunction
   function int length();return dw[0][9:0]==0?1024:dw[0][9:0];endfunction
   function bit with_data();return dw[0][30];endfunction
   function int header_dw();return dw[0][29]?4:3;endfunction
   function bit is_memory();return dw[0][28:24]==5'b00000;endfunction
   function bit is_completion();return dw[0][28:24]==5'b01010;endfunction
   function bit [63:0] address();return dw[0][29]?{dw[2],dw[3][31:2],2'b00}:{32'b0,dw[2][31:2],2'b00};endfunction
   function bit [15:0] request_id();return dw[1][31:16];endfunction
   function bit [7:0] request_tag();return dw[1][15:8];endfunction
   function bit [3:0] first_be();return dw[1][3:0];endfunction
   function bit [3:0] last_be();return dw[1][7:4];endfunction
   function bit [2:0] cpl_status();return dw[1][15:13];endfunction
   function bit [11:0] byte_count();return dw[1][11:0];endfunction
   function bit [15:0] completer_id();return dw[1][31:16];endfunction
   function bit [15:0] cpl_requester();return dw[2][31:16];endfunction
   function bit [7:0] cpl_tag();return dw[2][15:8];endfunction
   function bit [6:0] lower_address();return dw[2][6:0];endfunction
   function byte unsigned payload(int k);return dw[header_dw()+k/4][31-8*(k%4)-:8];endfunction
   function string describe();
     return $sformatf("fmt=%0b type=%05b len=%0d dw0=%08x dw1=%08x dw2=%08x",fmt(),kind(),length(),dw[0],dw[1],dw[2]);
   endfunction
 endclass

 function automatic tlp_packet make_request(bit write,bit [63:0] address,int dwords,bit [3:0] first,bit [3:0] last,
   bit [15:0] requester,bit [7:0] tag,bit [31:0] values[$]);
   tlp_packet t=new();bit four=address[63:32]!=0;
   t.dw.push_back({1'b0,write,four,5'b00000,14'b0,dwords[9:0]});
   t.dw.push_back({requester,tag,last,first});
   if(four) begin t.dw.push_back(address[63:32]);t.dw.push_back({address[31:2],2'b00});end
   else t.dw.push_back({address[31:2],2'b00});
   foreach(values[i]) t.dw.push_back({values[i][7:0],values[i][15:8],values[i][23:16],values[i][31:24]});
   return t;
 endfunction
 function automatic tlp_packet make_completion(bit [2:0] status,bit [15:0] completer,bit [15:0] requester,bit [7:0] tag,
   bit [11:0] count,bit [6:0] lower,byte unsigned data[$],bit poisoned);
   tlp_packet t=new();int words=(data.size()+3)/4;
   t.dw.push_back({1'b0,data.size()>0,1'b0,5'b01010,8'b0,1'b0,poisoned,2'b0,2'b0,data.size()>0?words[9:0]:10'd0});
   t.dw.push_back({completer,status,1'b0,count});
   t.dw.push_back({requester,tag,1'b0,lower});
   for(int w=0;w<words;w++) begin
     bit [31:0] v=0;for(int b=0;b<4;b++) if(4*w+b<data.size()) v[31-8*b-:8]=data[4*w+b];
     t.dw.push_back(v);
   end
   return t;
 endfunction

 typedef enum {INJ_NONE,INJ_POISON,INJ_BAD_LA,INJ_BAD_BC,INJ_BAD_LENGTH,INJ_EXTRA_DATA,INJ_DROP,INJ_LATE,INJ_DUPLICATE,
   INJ_UNEXPECTED_TAG,INJ_WRONG_RID,INJ_CA,INJ_UR,INJ_CRS} injection_t;

 class scheduled_tlp;tlp_packet packet;longint unsigned release_time;int tag;bit device_completion;bit final_for_tag;endclass

 class pcie_root_complex extends uvm_component;
   `uvm_component_utils(pcie_root_complex)
   virtual tlp_if rx,tx;
   memory_state memory;
   bit [63:0] aperture_base,bar0_base,msi_address;bit [15:0] msi_data,device_id,root_id=16'h0008;
   bit rcb128,four_tag,msi_masked,expect_quiet;
   int max_write_delay=240,max_completion_delay=80,tx_stall_max=3,rx_gap_max=2;
   bit read_error_enable;int unsigned read_error_offset;
   bit fence_trigger_enable,fence_error_armed;int unsigned fence_trigger_offset;
   injection_t next_injection=INJ_NONE;int late_delay=70000;bit allow_bad_requests;
   int mwr=0,mrd=0,msi=0,device_cpl=0,host_cpl=0,bar_requests=0,header_dw=0,payload_dw=0,useful_bytes=0;
   int splits=0,reordered=0,max_outstanding=0,duplicates_sent=0,late_sent=0;
   longint unsigned visibility_total=0,visibility_max=0;int visibility_samples=0;
   longint unsigned now=0;
   bit outstanding[bit [7:0]];int tag_order[bit [7:0]];int request_counter=0,last_completed_order=-1;
   tlp_packet inbound[$];longint unsigned apply_at[$];longint unsigned last_apply=0;bit rx_driving;
   scheduled_tlp scheduled[$];mailbox#(tlp_packet) to_device;
   tlp_packet bar_completion[bit [7:0]];
   function new(string name,uvm_component parent);super.new(name,parent);to_device=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual tlp_if)::get(this,"","rx",rx)) `uvm_fatal("CONFIG","rx tlp vif")
     if(!uvm_config_db#(virtual tlp_if)::get(this,"","tx",tx)) `uvm_fatal("CONFIG","tx tlp vif")
   endfunction
   function void expect_true(bit condition,string message);if(!condition) `uvm_fatal("PCIE_HOST",message) endfunction
   function int unsigned random_below(int unsigned limit);return limit==0?0:$urandom_range(limit-1,0);endfunction
   task receive_tx();
     tlp_packet t;int expected;
     tx.ready<=0;
     forever begin
       @(negedge tx.clk);tx.ready<=random_below(4)!=0 || tx_stall_max==0;
       @(posedge tx.clk);
       if(!tx.rst && tx.valid && tx.ready) begin
         if(t==null) begin expect_true(tx.sop,"device TLP starts with SOP");t=new();t.arrival=now;end
         else expect_true(!tx.sop,"device SOP inside TLP");
         t.dw.push_back(tx.data);
         if(t.dw.size()==1) expected=(tx.data[29]?4:3)+(tx.data[30]?(tx.data[9:0]==0?1024:tx.data[9:0]):0);
         if(tx.eop) begin
           expect_true(t.dw.size()==expected,$sformatf("device EOP at DW %0d, header implies %0d: %s",t.dw.size(),expected,t.describe()));
           accept_device_tlp(t);t=null;
         end else expect_true(t.dw.size()<expected,"device TLP longer than its header");
       end
     end
   endtask
   function void check_request(tlp_packet t);
     int n=t.length();bit [63:0] a=t.address();
     expect_true(t.dw[0][23:10]==0,$sformatf("device request reserved/TC/attr/EP/TD bits zero: %s",t.describe()));
     expect_true(t.request_id()==device_id,"device requester ID");
     expect_true(t.header_dw()==4 ? a[63:32]!=0 : 1,"4DW request only above 4 GiB");
     expect_true(n>=1 && n<=32,"request length within MPS/MRRS 128 bytes");
     expect_true(a[11:0]+4*n<=4096,"request does not cross a 4-KiB boundary");
     if(n==1) expect_true(t.last_be()==0 && t.first_be()!=0,"1-DW byte enables");
     else begin
       expect_true(t.first_be() inside {4'b1111,4'b1110,4'b1100,4'b1000} && t.last_be() inside {4'b0001,4'b0011,4'b0111,4'b1111},"contiguous multi-DW byte enables");
     end
   endfunction
   function int enabled_bytes(tlp_packet t);
     int n=t.length(),count=0;bit [3:0] first=t.first_be(),last=t.last_be();
     if(n==1) begin for(int b=0;b<4;b++) count+=first[b];return count;end
     for(int b=0;b<4;b++) count+=first[b]+last[b];
     return count+4*(n-2);
   endfunction
   function int leading_disabled(tlp_packet t);
     bit [3:0] first=t.first_be();for(int b=0;b<4;b++) if(first[b]) return b;return 0;
   endfunction
   task accept_device_tlp(tlp_packet t);
     header_dw+=t.header_dw();payload_dw+=t.with_data()?t.length():0;
     if(t.is_completion()) begin
       expect_true(t.completer_id()==device_id && t.cpl_requester()==root_id,"BAR completion IDs");
       expect_true(!bar_completion.exists(t.cpl_tag()),"single BAR completion per tag");
       bar_completion[t.cpl_tag()]=t;host_cpl++;
       return;
     end
     expect_true(t.is_memory(),$sformatf("device TLP type must be MRd/MWr: %s",t.describe()));
     if(t.with_data()) begin
       if(t.address()==msi_address) begin
         expect_true(t.length()==1 && t.first_be()==4'hf && t.last_be()==0 && t.dw[0][23:10]==0 && t.request_id()==device_id,"MSI write format");
         expect_true(!msi_masked,"MSI emitted while masked");
       end else check_request(t);
       mwr++;
       begin longint unsigned when=now+random_below(max_write_delay+1);if(when<last_apply) when=last_apply;last_apply=when;apply_at.push_back(when);end
       inbound.push_back(t);
     end else begin
       check_request(t);
       expect_true(four_tag ? t.request_tag()<4 : t.request_tag()==0,$sformatf("read tag %0d legal for mode",t.request_tag()));
       expect_true(!outstanding.exists(t.request_tag()),$sformatf("device reused tag %0d before its completions were delivered",t.request_tag()));
       outstanding[t.request_tag()]=1;tag_order[t.request_tag()]=request_counter++;
       if(outstanding.num()>max_outstanding) max_outstanding=outstanding.num();
       mrd++;apply_at.push_back(now);inbound.push_back(t);
     end
   endtask
   task process_inbound();
     forever begin
       @(posedge tx.clk);
       while(inbound.size()>0 && apply_at[0]<=now) begin
         tlp_packet t=inbound.pop_front();longint unsigned when=apply_at.pop_front();
         if(t.with_data()) apply_write(t);else serve_read(t);
       end
     end
   endtask
   task apply_write(tlp_packet t);
     bit [63:0] a=t.address();int lead=leading_disabled(t),count=enabled_bytes(t);
     longint unsigned latency=now-t.arrival;
     visibility_total+=latency;visibility_samples++;if(latency>visibility_max) visibility_max=latency;
     if(a==msi_address) begin
       bit [31:0] value={t.payload(3),t.payload(2),t.payload(1),t.payload(0)};
       expect_true(value=={16'b0,msi_data},$sformatf("MSI data %08x",value));msi++;return;
     end
     begin
       bit [64:0] offset={1'b0,a}-{1'b0,aperture_base};
       expect_true(!offset[64] && offset+lead+count<=64'h100000,$sformatf("device write %016x outside host aperture",a));
       for(int k=0;k<count;k++) begin
         int unsigned o=offset[31:0]+lead+k;memory.bytes[o]=t.payload(lead+k);useful_bytes++;
         if(memory.observer!=null) memory.observer.device_write(o,t.payload(lead+k));
         if(fence_trigger_enable && o==fence_trigger_offset) fence_error_armed=1;
       end
     end
   endtask
   // all locals at task scope, xsim 2025.2 crashes otherwise
   task serve_read(tlp_packet t);
     bit [63:0] a,cursor,boundary;int lead,count,remaining,chunk,rcb;bit [7:0] tag;bit [64:0] offset;
     longint unsigned when;int unsigned start;injection_t injection;bit unsupported,final_piece;
     byte unsigned data[$],none[$],filler[$];tlp_packet c,u;
     a=t.address();lead=leading_disabled(t);count=enabled_bytes(t);tag=t.request_tag();
     offset={1'b0,a}-{1'b0,aperture_base};when=now+random_below(max_completion_delay+1);
     start=offset[31:0]+lead;cursor=a+lead;remaining=count;injection=next_injection;rcb=rcb128?128:64;
     unsupported=offset[64] || offset+lead+count>64'h100000;
     filler.delete();for(int k=1;k<=4;k++) filler.push_back(k);
     if(!unsupported && read_error_enable && read_error_offset>=start && read_error_offset<start+count) injection=INJ_UR;
     if(!unsupported && fence_error_armed && start==32'h1f000) begin injection=INJ_UR;fence_error_armed=0;end
     if(unsupported) begin expect_true(allow_bad_requests,"device read outside aperture");injection=INJ_UR;end
     next_injection=INJ_NONE;
     if(injection==INJ_UR || injection==INJ_CA || injection==INJ_CRS) begin
       none.delete();
       c=make_completion(injection==INJ_UR?3'b001:injection==INJ_CA?3'b100:3'b010,root_id,device_id,tag,count,cursor[6:0],none,0);
       schedule(c,when,tag,1,1);
       return;
     end
     if(injection==INJ_DROP) return;
     while(remaining>0) begin
       chunk=remaining;data.delete();
       if(random_below(2)) begin
         boundary=(cursor/rcb+1)*rcb;
         while(boundary<cursor+remaining && random_below(3)==0) boundary+=rcb;
         if(boundary<cursor+remaining) chunk=boundary-cursor;
       end
       final_piece=chunk==remaining;
       for(int k=0;k<cursor[1:0];k++) data.push_back(0);
       for(int k=0;k<chunk;k++) data.push_back(memory.bytes[start+(count-remaining)+k]);
       c=make_completion(3'b000,root_id,device_id,tag,remaining,cursor[6:0],data,0);
       if(!final_piece) splits++;
       if(injection==INJ_POISON) begin c.dw[0][14]=1;injection=INJ_NONE;end
       if(injection==INJ_BAD_LA) begin c.dw[2][6:0]=c.dw[2][6:0]+4;injection=INJ_NONE;end
       if(injection==INJ_BAD_BC) begin c.dw[1][11:0]=c.dw[1][11:0]+4;injection=INJ_NONE;end
       if(injection==INJ_BAD_LENGTH) begin c.dw[0][9:0]=c.dw[0][9:0]+1;injection=INJ_NONE;end
       if(injection==INJ_EXTRA_DATA) begin c.dw.push_back(32'hdeadbeef);injection=INJ_NONE;end
       if(injection==INJ_LATE) when+=late_delay;
       schedule(c,when,tag,1,final_piece);
       if(injection==INJ_DUPLICATE && final_piece) begin schedule(c,when+200+random_below(50),-1,0,0);duplicates_sent++;end
       if(injection==INJ_UNEXPECTED_TAG && final_piece) begin
         u=make_completion(3'b000,root_id,device_id,8'd9,4,0,filler,0);schedule(u,when,-1,0,0);
       end
       if(injection==INJ_WRONG_RID && final_piece) begin
         u=make_completion(3'b000,root_id,device_id^16'h0101,tag,4,0,filler,0);schedule(u,when,-1,0,0);
       end
       if(injection==INJ_LATE && final_piece) late_sent++;
       when+=1+random_below(max_completion_delay/2+1);cursor+=chunk;remaining-=chunk;
     end
   endtask
   function void schedule(tlp_packet t,longint unsigned when,int tag,bit device_completion,bit final_for_tag);
     scheduled_tlp s=new();s.packet=t;s.release_time=when;s.tag=tag;s.device_completion=device_completion;s.final_for_tag=final_for_tag;
     scheduled.push_back(s);
   endfunction
   task release_completions();
     forever begin
       @(posedge tx.clk);
       for(int i=0;i<scheduled.size();i++) if(scheduled[i].release_time<=now) begin
         scheduled_tlp s=scheduled[i];scheduled.delete(i);i--;
         if(s.tag>=0) begin
           if(s.final_for_tag) begin
             if(tag_order[s.tag]<last_completed_order) reordered++;
             if(tag_order[s.tag]>last_completed_order) last_completed_order=tag_order[s.tag];
             outstanding.delete(s.tag);
           end
           device_cpl++;
         end
         to_device.put(s.packet);
       end
     end
   endtask
   task drive_rx();
     tlp_packet t;
     rx.valid<=0;rx.sop<=0;rx.eop<=0;rx.data<=0;
     forever begin
       to_device.get(t);rx_driving=1;
       foreach(t.dw[i]) begin
         repeat(random_below(rx_gap_max+1)) @(negedge rx.clk);
         @(negedge rx.clk);rx.data<=t.dw[i];rx.sop<=i==0;rx.eop<=i==t.dw.size()-1;rx.valid<=1;
         do @(posedge rx.clk);while(!rx.ready);
         @(negedge rx.clk);rx.valid<=0;
       end
       rx_driving=0;
     end
   endtask
   function bit quiet();return scheduled.size()==0 && inbound.size()==0 && to_device.num()==0 && !rx_driving;endfunction
   function void forget_outstanding();
     outstanding.delete();
     for(int i=scheduled.size()-1;i>=0;i--) if(scheduled[i].device_completion) scheduled.delete(i);
   endfunction
   task run_phase(uvm_phase phase);
     fork
       forever begin @(posedge tx.clk);now++;end
       receive_tx();process_inbound();release_completions();drive_rx();
     join
   endtask
   function string summary();
     return $sformatf("mwr=%0d mrd=%0d msi=%0d device_cpl=%0d bar_requests=%0d bar_cpl=%0d header_dw=%0d payload_dw=%0d splits=%0d reordered=%0d max_outstanding_tags=%0d visibility_max=%0d visibility_mean=%0d",
       mwr,mrd,msi,device_cpl,bar_requests,host_cpl,header_dw,payload_dw,splits,reordered,max_outstanding,visibility_max,
       visibility_samples?visibility_total/visibility_samples:0);
   endfunction
 endclass

 class bar_register_port extends register_port;
   pcie_root_complex rc;bit [7:0] next_tag=0;semaphore lock;
   function new(pcie_root_complex root);rc=root;lock=new(1);endfunction
   task raw_write(bit [31:0] offset,bit [31:0] data,bit [3:0] strobe);
     bit [31:0] values[$];values.push_back(data);
     rc.to_device.put(make_request(1,rc.bar0_base+offset,1,strobe,0,rc.root_id,8'h00,values));rc.bar_requests++;
   endtask
   task raw_read(bit [31:0] offset,output bit [31:0] data,output bit [1:0] response);
     bit [31:0] none[$];bit [7:0] tag=next_tag;tlp_packet c;int waits=0;
     next_tag=next_tag+1;
     rc.to_device.put(make_request(0,rc.bar0_base+offset,1,4'hf,0,rc.root_id,tag,none));rc.bar_requests++;
     while(!rc.bar_completion.exists(tag)) begin @(posedge rc.tx.clk);waits++;if(waits>100000) `uvm_fatal("PCIE_HOST","BAR read completion timeout") end
     c=rc.bar_completion[tag];rc.bar_completion.delete(tag);
     if(c.cpl_status()==0) begin
       if(c.length()!=1 || !c.with_data() || c.byte_count()!=4 || c.lower_address()!=offset[6:0]) `uvm_fatal("PCIE_HOST",{"BAR CplD fields: ",c.describe()})
       data={c.payload(3),c.payload(2),c.payload(1),c.payload(0)};response=0;
     end else begin
       if(c.with_data()) `uvm_fatal("PCIE_HOST","error completion carries data")
       data=0;response=(c.cpl_status()==3'b100)?2'd2:2'd3;
     end
   endtask
   virtual task write(bit [31:0] address,bit [31:0] data,bit [3:0] strobe,output bit [1:0] response);
     bit [31:0] flags;bit [1:0] r;
     lock.get();
     raw_write(address,data,strobe);
     raw_read('h1014,flags,r);
     response=flags[6]?2:0;
     if(flags[6]) raw_write('h1018,32'h40,4'hf);
     lock.put();
   endtask
   virtual task read(bit [31:0] address,output bit [31:0] data,output bit [1:0] response);
     lock.get();raw_read(address,data,response);lock.put();
   endtask
 endclass

 class pcie_platform extends host_platform;
   pcie_root_complex rc;virtual engine_side_if side;virtual stream_if input_bus,output_bus;int msi_consumed=0;
   virtual task wait_cycles(int cycles);repeat(cycles) @(posedge side.clk);endtask
   virtual task wait_interrupt(int timeout,output bit seen);
     seen=0;for(int i=0;i<timeout && !seen;i++) begin @(negedge side.clk);if(rc.msi>msi_consumed) begin msi_consumed=rc.msi;seen=1;end end
   endtask
   virtual function bit input_active();return input_bus.valid;endfunction
   virtual function bit output_active();return output_bus.valid;endfunction
   virtual function bit output_idle();return !output_bus.valid;endfunction
   virtual function void set_read_error(bit enable,int unsigned address);rc.read_error_enable=enable;rc.read_error_offset=address;endfunction
   virtual function void set_write_error(bit enable,int unsigned address);rc.fence_trigger_enable=enable;rc.fence_trigger_offset=address;if(!enable) rc.fence_error_armed=0;endfunction
   virtual function string name();return "PCIe";endfunction
   virtual function bit transport_registers();return 1;endfunction
   virtual function bit synchronous_write_errors();return 0;endfunction
   virtual function int completion_fault_code();return 4;endfunction
 endclass
endpackage
