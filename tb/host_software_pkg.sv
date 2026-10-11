`timescale 1ns/1ps
package host_software_pkg;
 import uvm_pkg::*;import stream_agent_pkg::*;import axi_memory_agent_pkg::*;
 `include "uvm_macros.svh"

 virtual class register_port;
   pure virtual task write(bit [31:0] address,bit [31:0] data,bit [3:0] strobe,output bit [1:0] response);
   pure virtual task read(bit [31:0] address,output bit [31:0] data,output bit [1:0] response);
 endclass

 virtual class host_platform;
   memory_state memory;
   pure virtual task wait_cycles(int cycles);
   pure virtual task wait_interrupt(int timeout,output bit seen);
   pure virtual function bit input_active();
   pure virtual function bit output_active();
   pure virtual function bit output_idle();
   pure virtual function void set_read_error(bit enable,int unsigned address);
   pure virtual function void set_write_error(bit enable,int unsigned address);
   pure virtual function string name();
   pure virtual function bit transport_registers();
   pure virtual function bit synchronous_write_errors();
   pure virtual function int completion_fault_code();
 endclass

 class frame_row;
   int id,phase,length,drop,supported,queue,rule;
   stream_frame stimulus;byte unsigned data[];
   bit [63:0] input_tick;bit observed;
 endclass
 class capture_row;
   int phase,queue,frame,kind,nseg,capacity;bit [63:0] cookie;bit [31:0] seqno;
   int unsigned address[4];int length[4];
 endclass
 class replay_row;
   int round,queue,frame,nseg;bit [31:0] seqno;bit lost,read_error;bit [63:0] cookie;
   int unsigned address[4];int length[4];bit [63:0] due;bit [63:0] departure;bit departed;
 endclass
 typedef enum {TICK_ZERO,TICK_CAPTURE,TICK_DEPARTURE,TICK_DUE} tick_kind_t;
 class expected_record;
   bit [63:0] cookie;bit [31:0] seqno,epoch;int status,queue,aux,length;tick_kind_t tick_kind;
   frame_row frame;capture_row capture;replay_row replay;
 endclass
 class owned_range;
   int unsigned low,high;capture_row row;
 endclass

 typedef class engine_host;
 class ownership_observer extends memory_observer;
   engine_host host;
   function new(engine_host owner);host=owner;endfunction
   virtual function void device_write(int unsigned address,byte unsigned value);host.check_device_write(address);endfunction
 endclass

 class engine_host extends uvm_object;
   `uvm_object_utils(engine_host)
   localparam bit [7:0] POISON=8'hee,GUARD=8'ha5;
   register_port registers;host_platform platform;
   uvm_sequencer#(stream_frame) source;stream_sink_config sink_config;
   uvm_tlm_analysis_fifo#(stream_frame) input_frames,output_frames;
   frame_row frames[$];capture_row captures[$];replay_row replays[$];
   bit [31:0] rule_word[8][6];int default_queue;bit [31:0] loss_seed;bit [32:0] loss_threshold;
   bit [63:0] delays[4];bit [63:0] interval;
   bit [31:0] sq_base[8],cq_base[8],sq_producer[8],cq_consumed[8],observed_producer[8],epoch;
   expected_record expected[8][$];replay_row expected_output[4][$];
   owned_range owned[$];int sent[$];
   bit replay_fixed,replay_impair=1;bit [63:0] replay_start,replay_origin;
   bit abort_sent,fault_phase,abort_midframe_input;
   int checks=0,records=0,status_count[6],bytes_checked=0,guards_checked=0,outputs=0,lost_records=0,invalidated=0;
   longint unsigned max_lateness=0,total_lateness=0;int lateness_samples=0;
   longint unsigned first_input_tick=0,last_input_tick=0,captured_bytes=0,compared_capture_bytes=0,output_bytes=0;int log_fd;
   int cov_ring,cov_status,cov_segments,cov_size;
   covergroup record_coverage(bit synchronous_errors);
     ring:coverpoint cov_ring {bins capture[]={[0:3]};bins replay[]={[4:7]};}
     status:coverpoint cov_status {bins ok={0};bins unsupported={1};bins lost={2};bins bad_desc={3};bins read_error={4};bins write_error={5};
       ignore_bins posted_write_transport={synchronous_errors?99:5};}
     segments:coverpoint cov_segments {bins count[]={[1:4]};}
     size:coverpoint cov_size {bins minimum={60};bins short_frame={[61:127]};bins middle_frame={[128:1023]};bins long_frame={[1024:1513]};bins maximum={1514};}
     ring_segments:cross ring,segments;
     capture_status:cross ring,status {ignore_bins replay_capture_only=binsof(ring.replay) && binsof(status) intersect {1,5};
       ignore_bins capture_replay_only=binsof(ring.capture) && binsof(status) intersect {2,4};
       ignore_bins rare=binsof(status) intersect {3,4,5};}
   endgroup
   function new(string name="engine_host",bit synchronous_errors=1);super.new(name);record_coverage=new(synchronous_errors);endfunction

   task expect_true(bit condition,string message);checks++;if(!condition) `uvm_fatal("HOST_ORACLE",message) endtask
   function int rb(int r);return (r<4?'h400:'h800)+(r%4)*64;endfunction

   task wr(bit [31:0] address,bit [31:0] data,bit [1:0] expected_response=0,bit [3:0] strobe=15);
     bit [1:0] response;registers.write(address,data,strobe,response);
     expect_true(response==expected_response,$sformatf("%s register write %04x=%08x response %0d expected %0d",platform.name(),address,data,response,expected_response));
   endtask
   task rd(bit [31:0] address,output bit [31:0] data);
     bit [1:0] response;registers.read(address,data,response);
     expect_true(response==0,$sformatf("register read %04x response %0d",address,response));
   endtask
   task wr64(bit [31:0] address,bit [63:0] value);wr(address,value[31:0]);wr(address+4,value[63:32]);endtask
   function void poke(int unsigned address,byte unsigned value);platform.memory.bytes[address]=value;endfunction
   function byte unsigned peek(int unsigned address);return platform.memory.bytes[address];endfunction
   function void poke_le(int unsigned address,bit [63:0] value,int count);
     for(int i=0;i<count;i++) poke(address+i,value[i*8+:8]);
   endfunction
   function bit [63:0] peek_le(int unsigned address,int count);
     bit [63:0] value=0;for(int i=0;i<count;i++) value[i*8+:8]=peek(address+i);return value;
   endfunction
   task snapshot(output bit [63:0] tick);
     bit [31:0] low,high;wr('h40,1);rd('h48,low);rd('h4c,high);tick={high,low};
   endtask
   task read_drops(output bit [63:0] counts[6]);
     bit [63:0] tick;bit [31:0] low,high;snapshot(tick);
     for(int d=0;d<6;d++) begin rd('hc00+8*d,low);rd('hc04+8*d,high);counts[d]={high,low};end
   endtask
   task wait_quiescent(string context_name);
     bit [31:0] status;int polls=0;
     do begin rd('hc,status);polls++;if(polls>20000) `uvm_fatal("HOST_TIMEOUT",{"quiescence not reached: ",context_name}) platform.wait_cycles(8);end
     while(!(status[1] && !status[2] && !status[0]));
   endtask

   task load(string path);
     int fd,rc,count,nbeats,word_index;string keyword;bit [31:0] word;bit [3:0] keep;int last,gap,unused;
     fd=$fopen(path,"r");expect_true(fd!=0,{"open fixture ",path});
     rc=$fscanf(fd,"%s",keyword);expect_true(rc==1 && keyword=="RULES","RULES section");
     for(int r=0;r<8;r++) for(int k=0;k<6;k++) begin rc=$fscanf(fd,"%h",rule_word[r][k]);expect_true(rc==1,"rule word");end
     rc=$fscanf(fd,"%s %d",keyword,default_queue);expect_true(rc==2 && keyword=="DEFAULT","DEFAULT");
     begin bit [31:0] hi,lo;rc=$fscanf(fd,"%s %h %h %h",keyword,loss_seed,hi,lo);expect_true(rc==4 && keyword=="LOSS","LOSS");loss_threshold={hi[0],lo};end
     rc=$fscanf(fd,"%s %d %d %d %d",keyword,delays[0],delays[1],delays[2],delays[3]);expect_true(rc==5 && keyword=="DELAYS","DELAYS");
     rc=$fscanf(fd,"%s %d",keyword,interval);expect_true(rc==2 && keyword=="INTERVAL","INTERVAL");
     rc=$fscanf(fd,"%s %d",keyword,count);expect_true(rc==2 && keyword=="FRAMES","FRAMES");
     repeat(count) begin
       frame_row f=new();byte unsigned data[$];
       rc=$fscanf(fd,"%d %d %d %d %d %d %d %d",f.id,f.phase,nbeats,f.length,f.drop,f.supported,f.queue,f.rule);expect_true(rc==8,"frame header");
       f.stimulus=new($sformatf("frame%0d",f.id));
       f.stimulus.words=new[nbeats];f.stimulus.keeps=new[nbeats];f.stimulus.lasts=new[nbeats];f.stimulus.gaps=new[nbeats];
       for(int b=0;b<nbeats;b++) begin
         rc=$fscanf(fd,"%h %h %d %d",word,keep,last,gap);expect_true(rc==4,"frame beat");
         f.stimulus.words[b]=word;f.stimulus.keeps[b]=keep;f.stimulus.lasts[b]=last;f.stimulus.gaps[b]=gap;
         for(int lane=0;lane<4;lane++) if(keep[lane]) data.push_back(word[lane*8+:8]);
       end
       f.data=data;expect_true(f.id==frames.size(),"frame order");
       if(f.drop==0) expect_true(data.size()==f.length,"frame byte extent");
       frames.push_back(f);
     end
     rc=$fscanf(fd,"%s %d",keyword,count);expect_true(rc==2 && keyword=="CAPTURE","CAPTURE");
     repeat(count) begin
       capture_row c=new();
       rc=$fscanf(fd,"%d %d %d %d %h %d",c.phase,c.queue,c.frame,c.kind,c.cookie,c.nseg);expect_true(rc==6,"capture row");
       c.capacity=0;for(int s=0;s<4;s++) begin rc=$fscanf(fd,"%h %d",c.address[s],c.length[s]);expect_true(rc==2,"capture segment");if(s<c.nseg) c.capacity+=c.length[s];end
       captures.push_back(c);
     end
     rc=$fscanf(fd,"%s %d",keyword,count);expect_true(rc==2 && keyword=="REPLAY","REPLAY");
     repeat(count) begin
       replay_row p=new();int lost_value,error_value;
       rc=$fscanf(fd,"%d %d %d %d %d %d %h %d",p.round,p.queue,p.frame,p.seqno,lost_value,error_value,p.cookie,p.nseg);expect_true(rc==8,"replay row");
       p.lost=lost_value;p.read_error=error_value;
       for(int s=0;s<4;s++) begin rc=$fscanf(fd,"%h %d",p.address[s],p.length[s]);expect_true(rc==2,"replay segment");end
       replays.push_back(p);
     end
     $fclose(fd);
     `uvm_info("HOST",$sformatf("%s fixture: %0d frames, %0d capture and %0d replay descriptors",platform.name(),frames.size(),captures.size(),replays.size()),UVM_LOW)
   endtask

   function void check_device_write(int unsigned address);
     foreach(owned[i]) if(address>=owned[i].low && address<owned[i].high) return;
     for(int r=0;r<8;r++) if(address>=cq_base[r] && address<cq_base[r]+2048) begin
       int slot=(address-cq_base[r])/32;int unread=observed_producer[r]-cq_consumed[r];
       int distance=(slot-int'(cq_consumed[r]%64)+64)%64;
       if(distance<unread) `uvm_fatal("OWNERSHIP",$sformatf("device overwrote unconsumed CQ record ring=%0d slot=%0d",r,slot))
       return;
     end
     `uvm_fatal("OWNERSHIP",$sformatf("device wrote non-owned host memory address %05x",address))
   endfunction
   function void own(capture_row c);
     for(int s=0;s<c.nseg;s++) begin owned_range o=new();o.low=c.address[s];o.high=c.address[s]+c.length[s];o.row=c;owned.push_back(o);end
   endfunction
   function void release_row(capture_row c);
     for(int i=owned.size()-1;i>=0;i--) if(owned[i].row==c) owned.delete(i);
   endfunction
   function void poison_ring(int r);
     for(int b=0;b<2048;b++) poke(cq_base[r]+b,POISON);
   endfunction

   function void write_descriptor(int r,bit [31:0] seqno,bit [63:0] cookie,bit [31:0] descriptor_epoch,bit [63:0] tick,
     int length,int nseg,int unsigned address[4],int segment_length[4]);
     int unsigned base=sq_base[r]+(seqno%32)*64;
     for(int b=0;b<64;b++) poke(base+b,0);
     poke_le(base,cookie,8);poke_le(base+8,seqno,4);poke_le(base+12,descriptor_epoch,4);poke_le(base+16,tick,8);
     poke_le(base+24,length,2);poke(base+26,nseg);
     for(int s=0;s<nseg;s++) begin poke_le(base+32+8*s,address[s],4);poke_le(base+36+8*s,segment_length[s],2);end
   endfunction
   task publish_capture(capture_row c);
     expected_record e=new();int r=c.queue;frame_row f=frames[c.frame];
     c.seqno=sq_producer[r];
     write_descriptor(r,c.seqno,c.cookie,c.kind==1?epoch+1:epoch,0,c.capacity,c.nseg,c.address,c.length);
     own(c);
     e.cookie=c.cookie;e.seqno=c.seqno;e.epoch=epoch;e.queue=r;e.frame=f;e.capture=c;
     case(c.kind)
       0:begin e.status=f.supported?0:1;e.length=f.length;e.aux={f.supported,f.rule[3:0]};e.tick_kind=TICK_CAPTURE;end
       3:begin e.status=5;e.length=0;e.aux=0;e.tick_kind=TICK_CAPTURE;end
       default:begin e.status=3;e.length=0;e.aux=0;e.tick_kind=TICK_ZERO;end
     endcase
     expected[r].push_back(e);sq_producer[r]++;
   endtask
   function capture_row capture_of(int frame_id);
     foreach(captures[i]) if(captures[i].frame==frame_id && captures[i].kind==0 && captures[i].phase==frames[frame_id].phase) return captures[i];
     return null;
   endfunction
   task publish_replay(replay_row p);
     expected_record e=new();int r=4+p.queue;frame_row f=frames[p.frame];capture_row source=capture_of(p.frame);
     int offset=0,source_segment=0,source_offset=0;
     expect_true(sq_producer[r]==p.seqno,"replay fixture seqno matches publication counter");
     expect_true(source!=null,"replay source capture");
     for(int s=0;s<p.nseg;s++) for(int b=0;b<p.length[s];b++) begin
       while(source_offset>=source.length[source_segment]) begin source_segment++;source_offset=0;end
       poke(p.address[s]+b,peek(source.address[source_segment]+source_offset));source_offset++;offset++;
     end
     expect_true(offset==f.length,"replay copy length");
     write_descriptor(r,p.seqno,p.cookie,epoch,f.input_tick,f.length,p.nseg,p.address,p.length);
     if(!replay_impair) p.due=replay_start;
     else if(replay_fixed) p.due=replay_start+p.seqno*interval+delays[p.queue];
     else p.due=replay_start+(f.input_tick-replay_origin)+delays[p.queue];
     e.cookie=p.cookie;e.seqno=p.seqno;e.epoch=epoch;e.queue=p.queue;e.aux=0;e.frame=f;e.replay=p;
     if(p.lost) begin e.status=2;e.length=f.length;e.tick_kind=TICK_DUE;end
     else if(p.read_error) begin e.status=4;e.length=0;e.tick_kind=TICK_ZERO;end
     else begin e.status=0;e.length=f.length;e.tick_kind=TICK_DEPARTURE;expected_output[p.queue].push_back(p);end
     expected[r].push_back(e);sq_producer[r]++;
   endtask
   task doorbells();for(int r=0;r<8;r++) wr(rb(r)+8,sq_producer[r]);endtask

   task check_record(int r,bit [31:0] index);
     int unsigned slot=cq_base[r]+(index%64)*32;bit poisoned=1;expected_record e;
     bit [63:0] cookie,tick,expected_tick;bit [31:0] seqno,record_epoch,aux;int length,status,queue;int waits=0;
     for(int b=0;b<32;b++) if(peek(slot+b)!=POISON) poisoned=0;
     expect_true(!poisoned,$sformatf("%s ring %0d producer covers record %0d before it is host visible",platform.name(),r,index));
     expect_true(expected[r].size()>0,$sformatf("unexpected completion ring %0d index %0d",r,index));
     e=expected[r].pop_front();
     cookie=peek_le(slot,8);seqno=peek_le(slot+8,4);record_epoch=peek_le(slot+12,4);tick=peek_le(slot+16,8);
     length=peek_le(slot+24,2);status=peek(slot+26);queue=peek(slot+27);aux=peek_le(slot+28,4);
     expect_true(cookie==e.cookie && seqno==e.seqno && record_epoch==e.epoch,
       $sformatf("ring %0d record identity cookie=%x/%x seq=%0d/%0d epoch=%0d/%0d",r,cookie,e.cookie,seqno,e.seqno,record_epoch,e.epoch));
     expect_true(status==e.status && queue==e.queue && aux==e.aux && length==e.length,
       $sformatf("ring %0d seq %0d record status=%0d/%0d queue=%0d/%0d aux=%x/%x length=%0d/%0d",r,seqno,status,e.status,queue,e.queue,aux,e.aux,length,e.length));
     case(e.tick_kind)
       TICK_ZERO:expected_tick=0;
       TICK_CAPTURE:begin while(!e.frame.observed && waits<1000) begin platform.wait_cycles(1);waits++;end expected_tick=e.frame.input_tick;end
       TICK_DEPARTURE:begin while(!e.replay.departed && waits<2000) begin platform.wait_cycles(1);waits++;end expected_tick=e.replay.departure;
         expect_true(e.replay.departed,"replay completion precedes observed departure");end
       TICK_DUE:expected_tick=e.replay.due;
     endcase
     expect_true(tick==expected_tick,$sformatf("ring %0d seq %0d record tick=%0d expected=%0d",r,seqno,tick,expected_tick));
     if(e.capture!=null) begin
       capture_row c=e.capture;int offset=0;
       for(int s=0;s<c.nseg;s++) for(int b=0;b<c.length[s];b++) begin
         if(c.kind==0 && offset<e.frame.length) begin
`ifndef MUTATION_BYPASS_BYTE_CHECK
           expect_true(peek(c.address[s]+b)==e.frame.data[offset],$sformatf("captured byte frame=%0d offset=%0d",e.frame.id,offset));
           bytes_checked++;compared_capture_bytes++;
`endif
         end else if(c.kind!=3) begin expect_true(peek(c.address[s]+b)==GUARD,$sformatf("capture capacity/BAD_DESC byte unchanged frame=%0d offset=%0d kind=%0d",e.frame.id,offset,c.kind));guards_checked++;end
         offset++;
       end
       for(int s=0;s<c.nseg;s++) for(int g=1;g<=8;g++) begin
         expect_true(peek(c.address[s]-g)==GUARD || c.kind==3,"capture leading guard");expect_true(peek(c.address[s]+c.length[s]+g-1)!=POISON,"segment end sanity");guards_checked++;
       end
       if(c.kind==0) captured_bytes+=e.frame.length;
       release_row(c);
     end
     $fdisplay(log_fd,"CQ %0d %0d %0d %0d %0d %0d %016x",r,seqno,status,queue,length,tick,cookie);
     if(e.status==2) lost_records++;
     status_count[e.status]++;records++;
     cov_ring=r;cov_status=e.status;cov_segments=e.capture!=null?e.capture.nseg:e.replay.nseg;cov_size=e.frame.length;record_coverage.sample();
     for(int b=0;b<32;b++) poke(slot+b,POISON);
   endtask
   task service_ring(int r);
     bit [31:0] producer;
     rd(rb(r)+16,producer);
     expect_true((producer-cq_consumed[r])<=64,"CQ producer within capacity");
     observed_producer[r]=producer;
     while(cq_consumed[r]!=producer) begin check_record(r,cq_consumed[r]);cq_consumed[r]++;end
     wr(rb(r)+20,cq_consumed[r]);
   endtask
   function int outstanding();int n=0;for(int r=0;r<8;r++) n+=expected[r].size();return n;endfunction
   task service_until_done(string phase_name,int timeout=600000);
     bit seen;bit [31:0] conditions;int idle=0;
     while(outstanding()>0) begin
       platform.wait_interrupt(64,seen);
       if(seen) begin
         idle=0;rd('h24,conditions);
         expect_true(!conditions[8] || fault_phase,"unexpected sticky fault condition");
         for(int r=0;r<8;r++) if(conditions[r]) service_ring(r);
         wr('h28,conditions[7:0]);
       end else begin
         idle+=64;
         expect_true(idle<timeout,$sformatf("%s: progress within %0d cycles, %0d records outstanding",phase_name,timeout,outstanding()));
         // poll producers early to catch one that runs ahead of visibility
         for(int r=0;r<8;r++) if(expected[r].size()>0) service_ring(r);
       end
     end
     wr('h28,255);
   endtask

   task input_collector();
     stream_frame f;int id;
     forever begin
       input_frames.get(f);expect_true(sent.size()>0,"input frame without stimulus");id=sent.pop_front();
       expect_true(f.words.size()==frames[id].stimulus.words.size(),"accepted input beat count");
       foreach(f.words[w]) expect_true(f.words[w]==frames[id].stimulus.words[w] && f.keeps[w]==frames[id].stimulus.keeps[w],"accepted input beat");
       frames[id].input_tick=f.first_tick;frames[id].observed=1;
       $fdisplay(log_fd,"IN %0d %0d %0d",id,f.first_tick,f.last_tick);
       if(first_input_tick==0) first_input_tick=f.first_tick;last_input_tick=f.last_tick;
     end
   endtask
   task output_checker();
     stream_frame f;byte unsigned data[$];bit matched;longint unsigned late;
     forever begin
       output_frames.get(f);data.delete();
       foreach(f.words[w]) begin
         expect_true(f.lasts[w]==(w==f.words.size()-1),"output TLAST only on final beat");
         if(w<f.words.size()-1) expect_true(f.keeps[w]==15,"output intermediate keep");
         else expect_true(f.keeps[w] inside {1,3,7,15},"output final keep contiguous");
         for(int lane=0;lane<4;lane++) if(f.keeps[w][lane]) data.push_back(f.words[w][lane*8+:8]);
       end
       matched=0;
       for(int q=0;q<4 && !matched;q++) if(expected_output[q].size()>0) begin
         replay_row p=expected_output[q][0];frame_row src=frames[p.frame];
         if(data.size()==src.length) begin
           bit same=1;foreach(data[i]) if(data[i]!=src.data[i]) same=0;
           if(same) begin
             matched=1;void'(expected_output[q].pop_front());p.departure=f.first_tick;p.departed=1;outputs++;bytes_checked+=data.size();
             output_bytes+=data.size();
             $fdisplay(log_fd,"OUT %0d %0d %0d %0d %0d %0d %0d",q,p.round,p.seqno,p.frame,f.first_tick,f.last_tick,p.due);
             late=f.first_tick-p.due;
             expect_true(late<64'h8000000000000000,$sformatf("replay departed early queue=%0d seq=%0d due=%0d departure=%0d",q,p.seqno,p.due,f.first_tick));
             expect_true(late<400000,$sformatf("replay lateness bound queue=%0d late=%0d",q,late));
             if(late>max_lateness) max_lateness=late;total_lateness+=late;lateness_samples++;
           end
         end
       end
       expect_true(matched,$sformatf("%s output frame of %0d bytes is not the next expected replay of any queue",platform.name(),data.size()));
     end
   endtask
   task send(frame_row f);
     one_frame_sequence s=new();s.frame=f.stimulus;sent.push_back(f.id);s.start(source);
   endtask
   task send_phase(int phase);foreach(frames[i]) if(frames[i].phase==phase) send(frames[i]);endtask
   task wait_inputs_observed();int waits=0;while(sent.size()>0) begin platform.wait_cycles(4);waits++;expect_true(waits<100000,"input monitor");end endtask

   task configure_rules();
     for(int r=0;r<8;r++) begin
       wr('h200+32*r,rule_word[r][0]);wr('h204+32*r,rule_word[r][1]);wr('h208+32*r,rule_word[r][2]);
       wr('h20c+32*r,rule_word[r][3]);wr('h210+32*r,rule_word[r][4]);wr('h214+32*r,rule_word[r][5]);
     end
   endtask
   task configure_replay(bit fixed,int warmup,bit [63:0] origin,bit impair=1);
     bit [63:0] now;snapshot(now);
     replay_fixed=fixed;replay_start=now+warmup;replay_origin=origin;replay_impair=impair;
     wr('h100,fixed);wr64('h108,replay_start);wr64('h110,replay_origin);wr64('h118,impair?interval:0);
     wr('h120,loss_seed);wr('h124,impair?loss_threshold[31:0]:0);wr('h128,impair?loss_threshold[32]:0);
     for(int q=0;q<4;q++) wr64('h140+8*q,impair?delays[q]:0);
   endtask
   task recover_all_rings();
     bit [31:0] value;
     for(int r=0;r<8;r++) begin
       wr(rb(r)+'h1c,1);service_ring(r);wr(rb(r)+'h20,0);
       sq_producer[r]=0;cq_consumed[r]=0;observed_producer[r]=0;poison_ring(r);
       rd(rb(r)+'h18,value);expect_true(value==0,"ring idle after recovery");
     end
   endtask
   task check_quiet_output();
     platform.wait_cycles(3000);
     expect_true(output_frames.used()==0 && platform.output_idle(),"no output after abort/quiescence");
   endtask

   task phase_capture();
     bit [63:0] drops[6];int expected_drops[6]='{0,0,0,0,0,0};
     foreach(captures[i]) if(captures[i].phase==0) begin
       if(captures[i].kind==3 && !platform.synchronous_write_errors()) captures[i].kind=0;
       publish_capture(captures[i]);
       if(captures[i].kind==3) platform.set_write_error(1,captures[i].address[0]);
     end
     doorbells();wr('h8,1);
     fork send_phase(0);service_until_done("capture phase");join
     wait_inputs_observed();platform.set_write_error(0,0);
     foreach(frames[i]) if(frames[i].phase==0 && frames[i].drop!=0) expected_drops[frames[i].drop-1]++;
     read_drops(drops);
     for(int d=0;d<6;d++) expect_true(drops[d]==expected_drops[d],$sformatf("drop counter %0d=%0d expected %0d",d,drops[d],expected_drops[d]));
     `uvm_info("HOST",$sformatf("%s capture phase: %0d records; drops by cause (timeout,mask,oversize,runt,malformed,full)=%0d,%0d,%0d,%0d,%0d,%0d",platform.name(),records,drops[0],drops[1],drops[2],drops[3],drops[4],drops[5]),UVM_LOW)
   endtask
   task phase_replay(int round_id,bit fixed,int capture_phase);
     bit [63:0] origin='1;
     wr('h8,2);wait_quiescent("replay setup");
     foreach(replays[i]) if(replays[i].round==round_id && frames[replays[i].frame].input_tick<origin) origin=frames[replays[i].frame].input_tick;
     configure_replay(fixed,fixed?20000:40000,origin);
     foreach(replays[i]) if(replays[i].round==round_id) begin
       publish_replay(replays[i]);if(replays[i].read_error) platform.set_read_error(1,replays[i].address[0]);
     end
     if(capture_phase>=0) foreach(captures[i]) if(captures[i].phase==capture_phase) publish_capture(captures[i]);
     doorbells();wr('h8,1);
     fork if(capture_phase>=0) send_phase(capture_phase);service_until_done($sformatf("replay round %0d",round_id));join
     wait_inputs_observed();platform.set_read_error(0,0);
     for(int q=0;q<4;q++) expect_true(expected_output[q].size()==0,"every expected replay departed");
     `uvm_info("HOST",$sformatf("%s replay round %0d (%s): outputs=%0d lost=%0d max_lateness=%0d",platform.name(),round_id,fixed?"fixed":"original",outputs,lost_records,max_lateness),UVM_LOW)
   endtask
   task phase_drop_on_full();
     bit [63:0] drops[6],baseline[6];
     read_drops(baseline);
     wr('h8,2);wait_quiescent("drop-on-full setup");wr('h104,default_queue|4);wr('h8,1);
     send_phase(2);wait_inputs_observed();platform.wait_cycles(50);
     read_drops(drops);expect_true(drops[5]-baseline[5]==2,$sformatf("FULL drops %0d",drops[5]-baseline[5]));
     foreach(captures[i]) if(captures[i].phase==2) publish_capture(captures[i]);
     doorbells();service_until_done("drop-on-full");
     wr('h8,2);wait_quiescent("drop-on-full restore");wr('h104,default_queue);
   endtask
   task phase_abort();
     bit [31:0] status,old_epoch,producer;bit [63:0] origin=0;int committed=0;
     rd('h10,old_epoch);expect_true(old_epoch==epoch,"epoch ledger");
     wr('h8,2);wait_quiescent("abort setup");
     configure_replay(1,3000,0);
     foreach(replays[i]) if(replays[i].round==2) publish_replay(replays[i]);
     foreach(captures[i]) if(captures[i].phase==3) publish_capture(captures[i]);
     doorbells();wr('h8,1);abort_sent=0;
     fork
       begin foreach(frames[i]) if(frames[i].phase==3 && !abort_sent) send(frames[i]);end
       begin
         int outputs_at_start=outputs,waits=0;
         while(outputs<outputs_at_start+1) platform.wait_cycles(1);
         // hold the started frame with backpressure so aborting stays observable
         while(!platform.output_active()) begin platform.wait_cycles(1);waits++;expect_true(waits<200000,"replay output for abort");end
         sink_config.force_stall=1;platform.wait_cycles(2);
         abort_midframe_input=platform.input_active();
         wr('h8,4);abort_sent=1;
         rd('hc,status);expect_true(status[2] && !status[0],"ABORTING visible, RUN cleared");
         wr('h8,4,2);
         rd('hc,status);expect_true(status[2],"stalled output frame keeps abort pending");
         sink_config.force_stall=0;
       end
     join
     wait_quiescent("abort drain");
     rd('h10,epoch);expect_true(epoch==old_epoch+1,"epoch increments once on completed abort");
     wait_inputs_observed();
     for(int r=0;r<8;r++) begin
       rd(rb(r)+16,producer);observed_producer[r]=producer;
       while(cq_consumed[r]!=producer) begin check_record(r,cq_consumed[r]);cq_consumed[r]++;committed++;end
       wr(rb(r)+20,cq_consumed[r]);
       while(expected[r].size()>0) begin expected_record e=expected[r].pop_front();if(e.capture!=null) release_row(e.capture);invalidated++;end
     end
     for(int q=0;q<4;q++) expected_output[q].delete();
     check_quiet_output();recover_all_rings();
     wr('h28,255);
     `uvm_info("HOST",$sformatf("%s abort: %0d records committed during abort phase, %0d invalidated, epoch %0d",platform.name(),committed,invalidated,epoch),UVM_LOW)
   endtask
   task phase_fault_recovery();
     bit [31:0] value,conditions;bit seen;capture_row faulted;
     fault_phase=1;wr('h20,'h1ff);wr('h8,1);
     foreach(captures[i]) if(captures[i].phase==4 && captures[i].queue==0) faulted=captures[i];
     faulted.seqno=sq_producer[0];
     write_descriptor(0,faulted.seqno,faulted.cookie,epoch,0,faulted.capacity,faulted.nseg,faulted.address,faulted.length);
     own(faulted);sq_producer[0]++;
     platform.set_write_error(1,cq_base[0]+(cq_consumed[0]%64)*32);
     doorbells();
     foreach(frames[i]) if(frames[i].phase==4 && frames[i].queue==0) send(frames[i]);
     conditions=0;
     for(int attempt=0;attempt<8 && !conditions[8];attempt++) begin
       platform.wait_interrupt(200000,seen);expect_true(seen,"fault interrupt");rd('h24,conditions);
       if(!conditions[8]) wr('h28,conditions[7:0]);
     end
     expect_true(conditions[8] && conditions[7:0]==0,"sticky fault condition without a false ring completion");
     rd('h30,value);expect_true(value==platform.completion_fault_code(),$sformatf("fault code %0d = failed completion publication",value));
     rd('h38,value);expect_true(value==0,"fault ring");rd('h3c,value);expect_true(value==faulted.seqno,"fault seqno");
     rd(rb(0)+'h18,value);expect_true(value==2,"ring 0 halted, reservation invalidated");
     rd(rb(0)+16,value);expect_true(value==cq_consumed[0],"failed completion write not published");
     wr('h34,1,2);
     platform.set_write_error(0,0);
     wr('h8,4);wait_quiescent("fault abort");
     rd('h10,value);expect_true(value==epoch+1,"fault recovery epoch");epoch=value;
     wr('h34,1);rd('h30,value);expect_true(value==0,"sticky fault cleared");
     release_row(faulted);recover_all_rings();wr('h28,255);
     wr('h20,'hff);fault_phase=0;wr('h8,1);
     foreach(captures[i]) if(captures[i].phase==4 && captures[i].queue!=0) publish_capture(captures[i]);
     doorbells();
     fork begin foreach(frames[i]) if(frames[i].phase==4 && frames[i].queue!=0) send(frames[i]);end service_until_done("post-recovery");join
     `uvm_info("HOST",$sformatf("%s fault/recovery: halted ring recovered, epoch %0d, %0d post-recovery records",platform.name(),epoch,3),UVM_LOW)
   endtask

   task run();
     bit [31:0] value;
     for(int r=0;r<8;r++) begin sq_base[r]='h10000+r*'h800;cq_base[r]='h14000+r*'h800;poison_ring(r);end
     begin ownership_observer o=new(this);platform.memory.observer=o;end
     poke_le('h1f000,64'h5343524154434821,8);
     log_fd=$fopen({"observed_",platform.name(),".txt"},"w");expect_true(log_fd!=0,"observation log");
     fork input_collector();output_checker();join_none
     rd('h0,value);expect_true(value=='h4e455431,"engine identity");
     rd('h4,value);expect_true(value==1,"ABI revision");
     begin bit [1:0] response;registers.read('h1000,value,response);
       expect_true(response==(platform.transport_registers()?0:2),"transport register window present only on PCIe");end
     configure_rules();wr('h104,default_queue);wr('h20,'hff);
     phase_mark("capture");phase_capture();
     phase_mark("replay0");phase_replay(0,0,1);
     phase_mark("replay1");phase_replay(1,1,-1);
     phase_mark("drop_on_full");phase_drop_on_full();
     phase_mark("abort");phase_abort();
     phase_mark("fault_recovery");phase_fault_recovery();
     phase_throughput();
     phase_mark("end");
     wr('h8,2);wait_quiescent("final");check_quiet_output();
     expect_true(output_frames.used()==0 && input_frames.used()==0,"no unconsumed stream frames");
     expect_true(owned.size()==0,"all payload ownership returned");
     expect_true(compared_capture_bytes==captured_bytes && captured_bytes>0,
       $sformatf("byte checker compared %0d of %0d captured bytes",compared_capture_bytes,captured_bytes));
   endtask
   task phase_throughput();
     wr('h8,2);wait_quiescent("throughput setup");sink_config.full_rate=1;
     foreach(captures[i]) if(captures[i].phase==6) publish_capture(captures[i]);
     doorbells();phase_mark("throughput_capture");wr('h8,1);
     fork send_phase(6);service_until_done("throughput capture");join
     wait_inputs_observed();
     wr('h8,2);wait_quiescent("throughput replay setup");configure_replay(1,2000,0,0);
     foreach(replays[i]) if(replays[i].round==3) publish_replay(replays[i]);
     doorbells();phase_mark("throughput_replay");wr('h8,1);
     service_until_done("throughput replay");
     wr('h8,2);wait_quiescent("throughput end");sink_config.full_rate=0;configure_replay(1,0,0,1);
     `uvm_info("HOST",$sformatf("%s throughput workload: 16 x 1514-byte capture and replay complete",platform.name()),UVM_LOW)
   endtask
   task phase_mark(string name);
     bit [63:0] tick;snapshot(tick);$fdisplay(log_fd,"PHASE %s %0d",name,tick);
   endtask
   function void close_log();if(log_fd) $fclose(log_fd);log_fd=0;endfunction
   function string summary();
     return $sformatf("records=%0d ok=%0d unsupported=%0d lost=%0d bad_desc=%0d read_error=%0d write_error=%0d outputs=%0d checked_bytes=%0d guards=%0d invalidated=%0d max_lateness=%0d mean_lateness=%0d checks=%0d coverage=%0f",
       records,status_count[0],status_count[1],status_count[2],status_count[3],status_count[4],status_count[5],outputs,bytes_checked,guards_checked,invalidated,
       max_lateness,lateness_samples?total_lateness/lateness_samples:0,checks,record_coverage.get_inst_coverage());
   endfunction
 endclass
endpackage
