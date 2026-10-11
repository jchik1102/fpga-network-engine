module pcie_requester #(parameter integer TIMEOUT=65536)(
 input logic clk,rst,
 input logic [15:0] cfg_requester_id,input logic cfg_bus_master_enable,cfg_rcb128,
 input logic [63:0] aperture_base,input logic four_tag,drain_reset,
 input logic rd_valid,output logic rd_ready,input logic [31:0] rd_address,input logic [7:0] rd_bytes,
 output logic rd_done,output logic [1:0] rd_status,output logic [1023:0] rd_data,
 input logic wr_valid,output logic wr_ready,input logic [31:0] wr_address,input logic [7:0] wr_bytes,
 input logic [1023:0] wr_data,output logic wr_done,output logic [1:0] wr_status,
 output logic w_valid,input logic w_ready,output logic [31:0] w_data,output logic w_sop,w_eop,
 output logic r_valid,input logic r_ready,output logic [31:0] r_data,output logic r_sop,r_eop,
 input logic c_valid,output logic c_ready,input logic [31:0] c_data,input logic c_sop,c_eop,
 output logic [3:0] active,quarantined,output logic [2:0] max_active,
 output logic unexpected_pulse,late_pulse,malformed_pulse,poisoned_pulse,status_pulse,timeout_pulse,translation_pulse,
 output logic accepted_pulse,write_request_pulse,read_request_pulse,output logic busy
);
 typedef enum logic [1:0] {W_IDLE,W_SEND,W_FAIL} write_state_t;
 write_state_t write_state;
 logic [1023:0] write_buffer;logic [63:0] write_host;logic [7:0] write_length_bytes;logic [5:0] write_beat;
 logic [5:0] write_dw;logic write_64;logic [3:0] write_first_be,write_last_be;
 logic [64:0] write_sum,read_sum;
 function automatic logic [3:0] tail_be(input logic [7:0] bytes);
   logic [2:0] n;n=bytes[1:0]==0?3'd4:{1'b0,bytes[1:0]};
   return 4'b1111>>(4-n);
 endfunction
 function automatic logic [31:0] payload_dw(input logic [1023:0] buffer,input logic [4:0] index);
   logic [31:0] value;value=buffer[index*32+:32];
   return {value[7:0],value[15:8],value[23:16],value[31:24]};
 endfunction
 always_comb begin
   write_sum={1'b0,aperture_base}+{33'b0,wr_address};
   wr_ready=write_state==W_IDLE;
   w_valid=write_state==W_SEND;w_sop=write_beat==0;
   w_eop=write_beat==(write_64?6'd3:6'd2)+write_dw;
   case(write_beat)
     0:w_data={write_64?3'b011:3'b010,5'b00000,14'b0,write_dw==32?10'd32:{4'b0,write_dw}};
     1:w_data={cfg_requester_id,8'h00,write_last_be,write_first_be};
     2:w_data=write_64?write_host[63:32]:{write_host[31:2],2'b00};
     3:w_data=write_64?{write_host[31:2],2'b00}:payload_dw(write_buffer,5'd0);
     default:w_data=payload_dw(write_buffer,write_beat-(write_64?6'd4:6'd3));
   endcase
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     write_state<=W_IDLE;write_buffer<=0;write_host<=0;write_length_bytes<=0;write_beat<=0;write_dw<=0;write_64<=0;
     write_first_be<=0;write_last_be<=0;wr_done<=0;wr_status<=0;
   end else begin
     wr_done<=0;
     case(write_state)
       W_IDLE:if(wr_valid) begin
         write_buffer<=wr_data;write_host<=write_sum[63:0];write_length_bytes<=wr_bytes;write_beat<=0;
         write_dw<=({1'b0,wr_bytes}+9'd3)>>2;write_64<=write_sum[63:32]!=0;
`ifdef MUTATION_WRONG_BE
         write_first_be<=wr_bytes<=4?tail_be(wr_bytes):4'b1111;write_last_be<=wr_bytes<=4?4'b0000:tail_be(wr_bytes+(wr_bytes[1:0]!=0));
`else
         write_first_be<=wr_bytes<=4?tail_be(wr_bytes):4'b1111;write_last_be<=wr_bytes<=4?4'b0000:tail_be(wr_bytes);
`endif
         if(write_sum[64] || ({1'b0,wr_address}+{25'b0,wr_bytes})>33'h100000 || !cfg_bus_master_enable ||
            wr_bytes==0 || wr_bytes>128 || wr_address[2:0]!=0 || ({1'b0,wr_address[11:0]}+{5'b0,wr_bytes})>13'h1000)
           write_state<=W_FAIL;
         else write_state<=W_SEND;
       end
       W_SEND:if(w_ready) begin
         if(w_eop) begin wr_done<=1;wr_status<=0;write_state<=W_IDLE;end
         else write_beat<=write_beat+1'b1;
       end
       W_FAIL:begin wr_done<=1;wr_status<=3;write_state<=W_IDLE;end
       default:write_state<=W_IDLE;
     endcase
   end
 end
 typedef enum logic [2:0] {R_IDLE,R_SEND,R_WAIT,R_DONE,R_FAIL} read_state_t;
 read_state_t read_state;
 logic [63:0] read_host;logic [7:0] read_total;logic [2:0] request_count,request_index;logic [2:0] read_beat;logic read_64;
 logic [3:0] pending,errored;logic [31:0] timer;logic timed_out;
 logic [7:0] tag_bytes[0:3],remaining[0:3],received[0:3];logic [6:0] next_low[0:3];
 logic [7:0] request_bytes;logic [63:0] request_host;logic [3:0] request_first_be,request_last_be;logic [5:0] request_dw;
 always_comb begin
   read_sum={1'b0,aperture_base}+{33'b0,rd_address};
   rd_ready=read_state==R_IDLE;
   request_bytes=tag_bytes[request_index[1:0]];
   request_host=read_host+(four_tag?{58'b0,request_index[1:0],5'b0}:64'b0);
   request_dw=({1'b0,request_bytes}+9'd3)>>2;
   request_first_be=request_bytes<=4?tail_be(request_bytes):4'b1111;
   request_last_be=request_bytes<=4?4'b0000:tail_be(request_bytes);
   r_valid=read_state==R_SEND;r_sop=read_beat==0;r_eop=read_beat==(read_64?3'd3:3'd2);
   case(read_beat)
     0:r_data={read_64?3'b001:3'b000,5'b00000,14'b0,4'b0,request_dw};
`ifdef MUTATION_WRONG_TAG
     1:r_data={cfg_requester_id,6'b0,request_index[1],1'b0,request_last_be,request_first_be};
`else
     1:r_data={cfg_requester_id,6'b0,request_index[1:0],request_last_be,request_first_be};
`endif
     2:r_data=read_64?request_host[63:32]:{request_host[31:2],2'b00};
     default:r_data={request_host[31:2],2'b00};
   endcase
 end
 typedef enum logic [2:0] {P_H0,P_H1,P_H2,P_DATA,P_DROP} parse_state_t;
 parse_state_t parse_state;
 logic [2:0] fmt;logic [4:0] tlp_type;logic [2:0] tc,cpl_status;logic [2:0] attr;logic ep;logic [9:0] length_dw;logic [11:0] byte_count;
 logic [1:0] tag;logic [5:0] data_beat;logic [4:0] write_index;logic accept_data,poisoned_tag,final_cpl;
 logic [7:0] cpl_bytes;logic [9:0] span;logic header_ok,is_cpl,is_cpld,matched,rcb_ok,length_ok;
 logic [7:0] tag_remaining;logic [6:0] tag_next;logic [7:0] tag_base;
 logic [1:0] tag_count;logic [2:0] active_count;
 always_comb begin
   c_ready=1;
   is_cpl=c_data[31:29]==3'b000 && c_data[28:24]==5'b01010;
   is_cpld=c_data[31:29]==3'b010 && c_data[28:24]==5'b01010;
   tag_remaining=remaining[c_data[9:8]];tag_next=next_low[c_data[9:8]];tag_base=received[c_data[9:8]];
   matched=c_data[31:16]==cfg_requester_id && c_data[15:10]==0 && active[c_data[9:8]] && (four_tag || c_data[9:8]==0);
   span={length_dw,2'b00}-{8'b0,c_data[1:0]};
   final_cpl=span>={2'b0,tag_remaining};
   length_ok=length_dw!=0 && length_dw<=32;
   rcb_ok=cfg_rcb128?(({1'b0,c_data[6:0]}+span[7:0])&8'h7f)==0:(({1'b0,c_data[6:0]}+span[7:0])&8'h3f)==0;
   header_ok=tc==0 && attr==0 && length_ok && byte_count=={4'b0,tag_remaining} && c_data[6:0]==tag_next &&
     (final_cpl?length_dw==(({8'b0,c_data[1:0]}+{2'b0,tag_remaining}+10'd3)>>2):rcb_ok);
   active_count=0;for(integer t=0;t<4;t++) active_count=active_count+active[t];
   busy=write_state!=W_IDLE || read_state!=R_IDLE || parse_state!=P_H0;
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     read_state<=R_IDLE;read_host<=0;read_total<=0;request_count<=0;request_index<=0;read_beat<=0;read_64<=0;
     pending<=0;errored<=0;timer<=0;timed_out<=0;active<=0;quarantined<=0;max_active<=0;rd_done<=0;rd_status<=0;rd_data<=0;
     parse_state<=P_H0;fmt<=0;tlp_type<=0;tc<=0;cpl_status<=0;attr<=0;ep<=0;length_dw<=0;byte_count<=0;tag<=0;data_beat<=0;
     write_index<=0;accept_data<=0;poisoned_tag<=0;cpl_bytes<=0;
     for(integer t=0;t<4;t++) begin tag_bytes[t]<=0;remaining[t]<=0;received[t]<=0;next_low[t]<=0;end
     unexpected_pulse<=0;late_pulse<=0;malformed_pulse<=0;poisoned_pulse<=0;status_pulse<=0;timeout_pulse<=0;translation_pulse<=0;
     accepted_pulse<=0;write_request_pulse<=0;read_request_pulse<=0;
   end else begin
     rd_done<=0;unexpected_pulse<=0;late_pulse<=0;malformed_pulse<=0;poisoned_pulse<=0;status_pulse<=0;timeout_pulse<=0;
     translation_pulse<=0;accepted_pulse<=0;write_request_pulse<=w_valid && w_ready && w_eop;read_request_pulse<=0;
     if(active_count>max_active) max_active<=active_count;
     if(drain_reset) quarantined<=0;
     if(write_state==W_FAIL) translation_pulse<=1;
     case(read_state)
       R_IDLE:if(rd_valid) begin
         read_host<=read_sum[63:0];read_total<=rd_bytes;request_index<=0;read_beat<=0;read_64<=read_sum[63:32]!=0;
         rd_data<=0;errored<=0;timer<=0;timed_out<=0;
         request_count<=four_tag?(({1'b0,rd_bytes}+9'd31)>>5):3'd1;
         for(integer t=0;t<4;t++) begin
           tag_bytes[t]<=four_tag?((rd_bytes>t*32)?((rd_bytes-t*32)>32?8'd32:rd_bytes-t*32):8'd0):(t==0?rd_bytes:8'd0);
         end
         if(read_sum[64] || ({1'b0,rd_address}+{25'b0,rd_bytes})>33'h100000 || !cfg_bus_master_enable || quarantined!=0 ||
            rd_bytes==0 || rd_bytes>128 || rd_address[2:0]!=0 || ({1'b0,rd_address[11:0]}+{5'b0,rd_bytes})>13'h1000)
           read_state<=R_FAIL;
         else read_state<=R_SEND;
       end
       R_SEND:begin
         if(r_valid && r_ready) begin
           if(r_sop) begin
             active[request_index[1:0]]<=1;pending[request_index[1:0]]<=1;remaining[request_index[1:0]]<=request_bytes;
             received[request_index[1:0]]<=four_tag?{1'b0,request_index[1:0],5'b0}:8'd0;next_low[request_index[1:0]]<=request_host[6:0];
           end
           if(r_eop) begin
             read_beat<=0;read_request_pulse<=1;
             if(request_index+1==request_count) read_state<=R_WAIT;else request_index<=request_index+1'b1;
           end else read_beat<=read_beat+1'b1;
         end
       end
       R_WAIT:if(pending==0) read_state<=R_DONE;
       R_DONE:begin rd_done<=1;rd_status<=timed_out?2'd3:errored!=0?2'd2:2'd0;read_state<=R_IDLE;end
       R_FAIL:begin rd_done<=1;rd_status<=3;translation_pulse<=1;read_state<=R_IDLE;end
       default:read_state<=R_IDLE;
     endcase
     if(read_state==R_SEND || read_state==R_WAIT) begin
       timer<=timer+1'b1;
       if(timer>=TIMEOUT-1 && pending!=0) begin
         // unfinished tags can still get completions, so quarantine instead of reuse
         quarantined<=quarantined|pending;active<=active&~pending;pending<=0;timed_out<=1;timeout_pulse<=1;read_state<=R_DONE;
       end
     end
     if(c_valid && c_ready) case(parse_state)
       P_H0:begin
         fmt<=c_data[31:29];tlp_type<=c_data[28:24];tc<=c_data[22:20];attr<={c_data[18],c_data[13:12]};ep<=c_data[14];length_dw<=c_data[9:0];
         if(!c_sop || c_eop) begin malformed_pulse<=1;parse_state<=c_eop?P_H0:P_DROP;end
         else parse_state<=P_H1;
       end
       P_H1:begin
         cpl_status<=c_data[15:13];byte_count<=c_data[11:0];
         if(c_eop) begin malformed_pulse<=1;parse_state<=P_H0;end else parse_state<=P_H2;
       end
       P_H2:begin
         tag<=c_data[9:8];data_beat<=0;accept_data<=0;poisoned_tag<=0;
         write_index<=tag_base[6:2];
         if(!matched) begin
           if(c_data[31:16]==cfg_requester_id && c_data[15:10]==0 && quarantined[c_data[9:8]]) late_pulse<=1;else unexpected_pulse<=1;
           parse_state<=c_eop?P_H0:P_DROP;
         end else if(cpl_status!=0) begin
           status_pulse<=1;active[c_data[9:8]]<=0;pending[c_data[9:8]]<=0;errored[c_data[9:8]]<=1;
           if(fmt!=3'b000 || tlp_type!=5'b01010) malformed_pulse<=1;
           parse_state<=c_eop?P_H0:P_DROP;
         end else if(fmt!=3'b010 || tlp_type!=5'b01010 || !header_ok || c_eop) begin
           malformed_pulse<=1;active[c_data[9:8]]<=0;pending[c_data[9:8]]<=0;errored[c_data[9:8]]<=1;quarantined[c_data[9:8]]<=1;
           parse_state<=c_eop?P_H0:P_DROP;
         end else begin
           accept_data<=1;poisoned_tag<=ep;cpl_bytes<=final_cpl?tag_remaining:span[7:0];parse_state<=P_DATA;
         end
       end
       P_DATA:begin
         if(!ep && data_beat<32) begin
           rd_data[(write_index+data_beat)*32+:32]<={c_data[7:0],c_data[15:8],c_data[23:16],c_data[31:24]};
         end
         data_beat<=data_beat+1'b1;
         if(c_eop) begin
           parse_state<=P_H0;
           if(data_beat+1!=length_dw) begin
             malformed_pulse<=1;active[tag]<=0;pending[tag]<=0;errored[tag]<=1;quarantined[tag]<=1;
           end else begin
             accepted_pulse<=1;
             if(poisoned_tag) begin poisoned_pulse<=1;errored[tag]<=1;end
             remaining[tag]<=remaining[tag]-cpl_bytes;received[tag]<=received[tag]+cpl_bytes;next_low[tag]<=next_low[tag]+cpl_bytes[6:0];
`ifdef MUTATION_EARLY_TAG_REUSE
             begin active[tag]<=0;pending[tag]<=0;end
`else
             if(remaining[tag]==cpl_bytes) begin active[tag]<=0;pending[tag]<=0;end
`endif
           end
         end else if(data_beat+1==length_dw) begin
           malformed_pulse<=1;active[tag]<=0;pending[tag]<=0;errored[tag]<=1;quarantined[tag]<=1;parse_state<=P_DROP;
         end
       end
       P_DROP:if(c_eop) parse_state<=P_H0;
       default:parse_state<=P_H0;
     endcase
   end
 end
endmodule
