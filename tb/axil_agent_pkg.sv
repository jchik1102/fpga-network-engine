`timescale 1ns/1ps
package axil_agent_pkg;
 import uvm_pkg::*;
 `include "uvm_macros.svh"
 class axil_transaction extends uvm_sequence_item;
   `uvm_object_utils(axil_transaction)
   bit write;bit [31:0] address,data;bit [3:0] strobe=15;bit [1:0] response;
   rand int unsigned aw_delay,w_delay,ar_delay,response_delay;
   constraint bounded {aw_delay inside {[0:7]};w_delay inside {[0:7]};ar_delay inside {[0:7]};response_delay inside {[0:7]};}
   function new(string name="axil_transaction");super.new(name);endfunction
 endclass
 class axil_sequence extends uvm_sequence#(axil_transaction);
   `uvm_object_utils(axil_sequence)
   axil_transaction transaction;
   function new(string name="axil_sequence");super.new(name);endfunction
   task body();start_item(transaction);finish_item(transaction);endtask
 endclass
 class axil_driver extends uvm_driver#(axil_transaction);
   `uvm_component_utils(axil_driver)
   virtual axil_if vif;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual axil_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","AXI-Lite vif")
   endfunction
   task write_request(axil_transaction tr);
     fork
       begin
         repeat(tr.aw_delay) @(negedge vif.clk);
         @(negedge vif.clk);vif.awaddr<=tr.address;vif.awvalid<=1;
         do @(posedge vif.clk);while(!vif.awready);
         @(negedge vif.clk);vif.awvalid<=0;
       end
       begin
         repeat(tr.w_delay) @(negedge vif.clk);
         @(negedge vif.clk);vif.wdata<=tr.data;vif.wstrb<=tr.strobe;vif.wvalid<=1;
         do @(posedge vif.clk);while(!vif.wready);
         @(negedge vif.clk);vif.wvalid<=0;
       end
     join
     repeat(tr.response_delay) @(negedge vif.clk);
     @(negedge vif.clk);vif.bready<=1;
     do @(posedge vif.clk);while(!vif.bvalid);
     tr.response=vif.bresp;
     @(negedge vif.clk);vif.bready<=0;
   endtask
   task read_request(axil_transaction tr);
     repeat(tr.ar_delay) @(negedge vif.clk);
     @(negedge vif.clk);vif.araddr<=tr.address;vif.arvalid<=1;
     do @(posedge vif.clk);while(!vif.arready);
     @(negedge vif.clk);vif.arvalid<=0;
     repeat(tr.response_delay) @(negedge vif.clk);
     @(negedge vif.clk);vif.rready<=1;
     do @(posedge vif.clk);while(!vif.rvalid);
     tr.data=vif.rdata;tr.response=vif.rresp;
     @(negedge vif.clk);vif.rready<=0;
   endtask
   task run_phase(uvm_phase phase);
     bit completed;
     wait(!vif.rst);
     forever begin
       seq_item_port.get_next_item(req);completed=0;
       fork
         begin if(req.write) write_request(req);else read_request(req);completed=1;end
         begin repeat(1024) @(posedge vif.clk);if(!completed) `uvm_fatal("AXIL_TIMEOUT","AXI-Lite transaction exceeded 1024 ticks") end
       join_any
       disable fork;
       seq_item_port.item_done();
     end
   endtask
 endclass
 class axil_monitor extends uvm_monitor;
   `uvm_component_utils(axil_monitor)
   virtual axil_if vif;uvm_analysis_port#(axil_transaction) accepted;
   int writes=0,reads=0;int ordering,strobes,response;longint aw_tick,w_tick;
   bit have_aw=0,have_w=0,have_ar=0;bit [31:0] aw_address,w_data,ar_address;bit [3:0] w_strobe;
   covergroup bus_coverage;
     channel_order:coverpoint ordering {bins aw_first={0};bins together={1};bins w_first={2};}
     write_strobes:coverpoint strobes {bins mask[]={[0:15]};}
     result:coverpoint response {bins okay={0};bins rejected={2};}
   endgroup
   function new(string name,uvm_component parent);super.new(name,parent);accepted=new("accepted",this);bus_coverage=new();endfunction
   function void build_phase(uvm_phase phase);
     if(!uvm_config_db#(virtual axil_if)::get(this,"","vif",vif)) `uvm_fatal("CONFIG","AXIL monitor vif")
   endfunction
   task run_phase(uvm_phase phase);
     axil_transaction tr;
     forever begin
       @(posedge vif.clk);
       if(vif.rst) begin have_aw=0;have_w=0;have_ar=0;end
       else begin
         if(vif.awvalid && vif.awready) begin
           if(have_aw) `uvm_fatal("AXIL_PROTOCOL","second outstanding AW")
           have_aw=1;aw_address=vif.awaddr;aw_tick=vif.tick;
         end
         if(vif.wvalid && vif.wready) begin
           if(have_w) `uvm_fatal("AXIL_PROTOCOL","second outstanding W")
           have_w=1;w_data=vif.wdata;w_strobe=vif.wstrb;w_tick=vif.tick;
         end
         if(vif.bvalid && vif.bready) begin
           if(!have_aw || !have_w) `uvm_fatal("AXIL_PROTOCOL","B without AW and W")
           tr=new();tr.write=1;tr.address=aw_address;tr.data=w_data;tr.strobe=w_strobe;tr.response=vif.bresp;
           ordering=aw_tick<w_tick?0:aw_tick==w_tick?1:2;strobes=w_strobe;response=vif.bresp;bus_coverage.sample();
           have_aw=0;have_w=0;writes++;accepted.write(tr);
         end
         if(vif.arvalid && vif.arready) begin
           if(have_ar) `uvm_fatal("AXIL_PROTOCOL","second outstanding AR")
           have_ar=1;ar_address=vif.araddr;
         end
         if(vif.rvalid && vif.rready) begin
           if(!have_ar) `uvm_fatal("AXIL_PROTOCOL","R without AR")
           tr=new();tr.write=0;tr.address=ar_address;tr.data=vif.rdata;tr.response=vif.rresp;
           have_ar=0;reads++;accepted.write(tr);
         end
       end
     end
   endtask
 endclass
 class axil_agent extends uvm_agent;
   `uvm_component_utils(axil_agent)
   uvm_sequencer#(axil_transaction) sequencer;axil_driver driver;axil_monitor monitor;
   function new(string name,uvm_component parent);super.new(name,parent);endfunction
   function void build_phase(uvm_phase phase);
     sequencer=new("sequencer",this);driver=axil_driver::type_id::create("driver",this);monitor=axil_monitor::type_id::create("monitor",this);
   endfunction
   function void connect_phase(uvm_phase phase);driver.seq_item_port.connect(sequencer.seq_item_export);endfunction
 endclass
 class axil_reg_adapter extends uvm_reg_adapter;
   `uvm_object_utils(axil_reg_adapter)
   function new(string name="axil_reg_adapter");super.new(name);supports_byte_enable=1;endfunction
   virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
     axil_transaction tr=new();if(!tr.randomize()) `uvm_fatal("RANDOM","RAL bus delay")
     tr.write=rw.kind==UVM_WRITE;tr.address=rw.addr;tr.data=rw.data;tr.strobe=rw.byte_en;return tr;
   endfunction
   virtual function void bus2reg(uvm_sequence_item bus_item,ref uvm_reg_bus_op rw);
     axil_transaction tr;if(!$cast(tr,bus_item)) `uvm_fatal("RAL","unexpected item")
     rw.kind=tr.write?UVM_WRITE:UVM_READ;rw.addr=tr.address;rw.data=tr.data;rw.byte_en=tr.strobe;rw.status=tr.response==0?UVM_IS_OK:UVM_NOT_OK;
   endfunction
 endclass
 class engine_register extends uvm_reg;
   `uvm_object_utils(engine_register)
   uvm_reg_field value;
   function new(string name="engine_register");super.new(name,32,UVM_NO_COVERAGE);endfunction
   function void build(string access="RW",bit [31:0] reset_value=0,bit is_volatile=0);
     value=uvm_reg_field::type_id::create("value");value.configure(this,32,0,access,is_volatile,reset_value,1,0,1);
   endfunction
 endclass
 class engine_reg_block extends uvm_reg_block;
   `uvm_object_utils(engine_reg_block)
   engine_register identity,seed,defaults,mask,sq_prod[8],sq_cons[8],cq_prod[8],cq_cons[8];
   function new(string name="engine_reg_block");super.new(name,UVM_NO_COVERAGE);endfunction
   function engine_register add_word(string name,int offset,string access,bit [31:0] reset_value=0,bit is_volatile=0);
     engine_register word_reg=new(name);word_reg.configure(this);word_reg.build(access,reset_value,is_volatile);default_map.add_reg(word_reg,offset,access);return word_reg;
   endfunction
   function void build();
     default_map=create_map("control",0,4,UVM_LITTLE_ENDIAN,1);
     identity=add_word("identity",0,"RO",32'h4e455431);seed=add_word("seed",'h120,"RW");defaults=add_word("defaults",'h104,"RW");mask=add_word("mask",'h20,"RW");
     for(int r=0;r<8;r++) begin
       int base_address=(r<4?'h400:'h800)+(r%4)*64;
       sq_prod[r]=add_word($sformatf("sq_prod%0d",r),base_address+8,"RW");
       sq_cons[r]=add_word($sformatf("sq_cons%0d",r),base_address+12,"RO",0,1);
       cq_prod[r]=add_word($sformatf("cq_prod%0d",r),base_address+16,"RO",0,1);
       cq_cons[r]=add_word($sformatf("cq_cons%0d",r),base_address+20,"RW");
     end
     lock_model();
   endfunction
 endclass
endpackage
