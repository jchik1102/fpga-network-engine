`timescale 1ns/1ps
interface tiny_if(input bit clk);
  logic flag=0;
endinterface
package smoke_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class item_t;
    rand bit [2:0] a;
    rand bit [7:0] b;
    rand bit parity;
    constraint legal { a inside {[0:3]}; b inside {[8:63]}; b % 4 == a; parity == (b % 2); }
  endclass
  class tiny_reg extends uvm_reg;
    uvm_reg_field value;
    function new(string name="tiny_reg"); super.new(name,32,UVM_NO_COVERAGE); endfunction
    function void build();
      value=new("value"); value.configure(this,8,0,"RW",0,8'h35,1,1,0);
    endfunction
  endclass
  class tiny_block extends uvm_reg_block;
    tiny_reg r;
    function new(string name="tiny_block"); super.new(name,UVM_NO_COVERAGE); endfunction
    function void build();
      r=new(); r.configure(this); r.build();
      default_map=create_map("map",0,4,UVM_LITTLE_ENDIAN); default_map.add_reg(r,0,"RW"); lock_model();
    endfunction
  endclass
  class toy_bus_item extends uvm_sequence_item;
    `uvm_object_utils(toy_bus_item)
    uvm_reg_bus_op op;
    function new(string name="toy_bus_item"); super.new(name); endfunction
  endclass
  class toy_adapter extends uvm_reg_adapter;
    function new(string name="toy_adapter"); super.new(name); endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      toy_bus_item t=new(); t.op=rw; return t;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item,ref uvm_reg_bus_op rw);
      toy_bus_item t;
      if(!$cast(t,bus_item)) `uvm_fatal("ADAPTER","cast")
      rw=t.op;
    endfunction
  endclass
  class toy_frontdoor extends uvm_reg_frontdoor;
    uvm_reg_data_t storage=8'h35;
    function new(string name="toy_frontdoor"); super.new(name); endfunction
    virtual task body();
      if(rw_info.kind==UVM_WRITE) storage=rw_info.value[0];
      else rw_info.value[0]=storage;
      rw_info.status=UVM_IS_OK;
    endtask
  endclass
  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    virtual tiny_if vif;
    tiny_block blk;
    toy_adapter adapter;
    toy_frontdoor frontdoor;
    uvm_reg_predictor#(toy_bus_item) predictor;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if(!uvm_config_db#(virtual tiny_if)::get(this,"","vif",vif)) `uvm_fatal("VIF","missing")
      blk=new(); blk.build(); blk.reset();
      adapter=new(); frontdoor=new(); blk.r.set_frontdoor(frontdoor,blk.default_map);
      predictor=new("predictor",this); predictor.map=blk.default_map; predictor.adapter=adapter;
    endfunction
    task run_phase(uvm_phase phase);
      uvm_status_e status;
      uvm_reg_data_t value;
      uvm_reg_bus_op op,decoded;
      uvm_sequence_item raw_item;
      toy_bus_item toy;
      phase.raise_objection(this);
      if(blk.r.get()!=8'h35) `uvm_fatal("RAL","reset")
      blk.r.set(8'ha6);
      if(blk.r.get()!=8'ha6 || !blk.r.needs_update()) `uvm_fatal("RAL","set")
      if(!blk.r.predict(8'ha6)) `uvm_fatal("RAL","predict")
      if(blk.r.get_mirrored_value()!=8'ha6 || blk.r.needs_update()) `uvm_fatal("RAL","mirror")
      blk.default_map.set_auto_predict(1);
      blk.r.write(status,8'h71,UVM_FRONTDOOR,blk.default_map);
      if(status!=UVM_IS_OK) `uvm_fatal("RAL","write status")
      blk.r.read(status,value,UVM_FRONTDOOR,blk.default_map);
      if(status!=UVM_IS_OK || value!=8'h71) `uvm_fatal("RAL","read value")
      blk.r.mirror(status,UVM_CHECK,UVM_FRONTDOOR,blk.default_map);
      if(status!=UVM_IS_OK) `uvm_fatal("RAL","mirror status")
      op.kind=UVM_WRITE; op.addr=0; op.data=8'h42; op.n_bits=32; op.byte_en='1; op.status=UVM_IS_OK;
      raw_item=adapter.reg2bus(op); adapter.bus2reg(raw_item,decoded);
      if(decoded.data!=8'h42 || decoded.addr!=0 || decoded.kind!=UVM_WRITE) `uvm_fatal("RAL","adapter roundtrip")
      if(!$cast(toy,raw_item)) `uvm_fatal("RAL","toy cast")
      predictor.write(toy);
      if(blk.r.get_mirrored_value()!=8'h42) `uvm_fatal("RAL","predictor")
      @(negedge vif.clk); vif.flag=1;
      @(negedge vif.clk); if(!vif.flag) `uvm_fatal("VIF","readback")
      `uvm_info("SMOKE","UVM_VIF_RAL_PASS",UVM_LOW)
      if($test$plusargs("UVM_FAIL")) `uvm_fatal("EXPECTED_UVM_FAILURE","deliberate setup negative")
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module qualification;
  import uvm_pkg::*; import smoke_pkg::*;
  bit clk=0; always #5 clk=~clk;
  tiny_if tif(clk);
  item_t item;
  int a_sample,b_sample;
  covergroup cg;
    option.per_instance=1;
    ca: coverpoint a_sample { bins v[]={[0:3]}; illegal_bins bad={[4:7]}; }
    cb: coverpoint b_sample { bins low={[8:31]}; bins high={[32:63]}; }
    cab: cross ca,cb;
  endgroup
  cg cov;
  typedef struct packed {bit [7:0] kind; bit [15:0] ident; bit [7:0] count;} tiny_header;
  tiny_header h,h2;
  bit [31:0] words[$];
  int seed,fd; string tracefile;
  bit [55:0] seen;
  int system_nonzero;
  initial begin
    if(!$value$plusargs("SEED=%d",seed)) seed=17;
    if(!$value$plusargs("TRACE=%s",tracefile)) tracefile="trace.txt";
    item=new(); item.srandom(seed); cov=new(); fd=$fopen(tracefile,"w");
    if(!fd) $fatal(1,"trace open failed");
    repeat(256) begin
      if(!item.randomize()) $fatal(1,"legal randomize failed");
      if(item.a>3 || item.b<8 || item.b>63 || item.b%4!=item.a || item.parity!=item.b%2) $fatal(1,"constraint violation");
      seen[item.b-8]=1; a_sample=item.a; b_sample=item.b; cov.sample();
      $fdisplay(fd,"%0d %0d %0d",item.a,item.b,item.parity);
      if($urandom()!=0) system_nonzero++;
    end
    $fclose(fd);
    if($countones(seen)<32) $fatal(1,"insufficient diversity");
    if(item.randomize() with {a==7;}) $fatal(1,"unsatisfiable constraint accepted");
    $display("RANDOM_PASS seed=%0d unique=%0d coverage=%0f system_nonzero=%0d",seed,$countones(seen),cov.get_inst_coverage(),system_nonzero);
    h='{8'h93,16'hb7e2,8'h05}; words.push_back(h); h2=tiny_header'(words.pop_front());
    if(h2.kind!=8'h93 || h2.ident!=16'hb7e2 || h2.count!=5 || words.size()!=0 || h!=32'h93b7e205) $fatal(1,"serialization");
    $display("PACKED_QUEUE_PASS");
    uvm_config_db#(virtual tiny_if)::set(null,"uvm_test_top","vif",tif);
    run_test("smoke_test");
  end
  initial begin #10000; $fatal(1,"WATCHDOG"); end
endmodule
