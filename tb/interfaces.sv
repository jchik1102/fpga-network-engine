`timescale 1ns/1ps
interface stream_if(input logic clk);
 logic rst=1;
 logic [31:0] data=0;
 logic [3:0] keep=0;
 logic valid=0,ready,last=0;
 logic [63:0] tick=0;
endinterface
interface axil_if(input logic clk);
 logic rst=1;
 logic [31:0] awaddr=0,wdata=0,araddr=0,rdata;
 logic [3:0] wstrb=0;
 logic awvalid=0,awready,wvalid=0,wready,bvalid,bready=0,arvalid=0,arready,rvalid,rready=0;
 logic [1:0] bresp,rresp;
 logic [63:0] tick=0;
endinterface
interface tlp_if(input logic clk);
 logic rst;
 logic [31:0] data;
 logic valid,ready,sop,eop;
endinterface
interface engine_side_if(input logic clk);
 logic irq,quiescent,running;logic [63:0] tick;
endinterface
interface axi_memory_if(input logic clk);
 logic rst=1;
 logic [31:0] awaddr,araddr;
 logic [7:0] awlen,arlen;
 logic [2:0] awsize,arsize;
 logic [1:0] awburst,arburst;
 logic awvalid,awready=0,arvalid,arready=0;
 logic [63:0] wdata,rdata=0;
 logic [7:0] wstrb;
 logic wlast,wvalid,wready=0,rlast=0,rvalid=0,rready;
 logic [1:0] bresp=0,rresp=0;
 logic bvalid=0,bready;
 logic [63:0] tick=0;
endinterface
