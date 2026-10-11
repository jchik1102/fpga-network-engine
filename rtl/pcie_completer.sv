module pcie_completer(
 input logic clk,rst,
 input logic [15:0] cfg_requester_id,input logic [63:0] cfg_bar0_base,
 input logic cfg_bus_master_enable,cfg_msi_enable,cfg_msi_mask,
 input logic q_valid,output logic q_ready,input logic [31:0] q_data,input logic q_sop,q_eop,
 output logic t_valid,input logic t_ready,output logic [31:0] t_data,output logic t_sop,t_eop,
 output logic [31:0] m_awaddr,output logic m_awvalid,input logic m_awready,
 output logic [31:0] m_wdata,output logic [3:0] m_wstrb,output logic m_wvalid,input logic m_wready,
 input logic [1:0] m_bresp,input logic m_bvalid,output logic m_bready,
 output logic [31:0] m_araddr,output logic m_arvalid,input logic m_arready,
 input logic [31:0] m_rdata,input logic [1:0] m_rresp,input logic m_rvalid,output logic m_rready,
 input logic engine_quiescent,requester_busy,
 input logic [3:0] active_tags,quarantined_tags,input logic [2:0] max_active,
 input logic msi_pending,msi_armed,
 input logic unexpected_pulse,late_pulse,malformed_pulse,poisoned_pulse,status_pulse,timeout_pulse,translation_pulse,
 input logic accepted_pulse,write_request_pulse,read_request_pulse,msi_sent_pulse,
 output logic four_tag,output logic [63:0] aperture_base,output logic drain_reset,
 output logic bar_write_error_pulse,unsupported_pulse
);
 typedef enum logic [3:0] {S_H0,S_H1,S_H2,S_H3,S_DATA,S_DRAIN,S_EXEC,S_AXI_W,S_AXI_R,S_CPL} state_t;
 state_t state;
 logic [2:0] fmt;logic [4:0] tlp_type;logic [2:0] tc,attr;logic ep;logic [9:0] length_dw;
 logic [15:0] requester;logic [7:0] tag;logic [3:0] first_be,last_be;logic [63:0] address;logic [31:0] payload;
 logic framing_error,aw_done,w_done,ar_done;
 logic [2:0] cpl_status;logic cpl_data;logic [31:0] cpl_value;logic [11:0] cpl_count;logic [1:0] cpl_beat;
 logic is_read,is_write,in_bar,transport,supported;logic [13:0] offset;
 logic [8:0] sticky;logic [15:0] unexpected_count,late_count;logic [31:0] msi_count,request_count,accepted_count;
 logic [31:0] reg_value;logic reg_ok,config_ok,write_bad;
 always_comb begin
   is_read=fmt[1]==0 && tlp_type==0;is_write=fmt[1]==1 && tlp_type==0;
   in_bar=address[63:14]==cfg_bar0_base[63:14];offset=address[13:0];
   transport=offset>=14'h1000 && offset<14'h1100;
   supported=(is_read || is_write) && length_dw==1 && tc==0 && attr==0 && !ep && in_bar && last_be==0 && !framing_error &&
     (is_write || first_be==4'hf);
   config_ok=engine_quiescent && !requester_busy && active_tags==0;
   q_ready=state==S_H0 || state==S_H1 || state==S_H2 || state==S_H3 || state==S_DATA || state==S_DRAIN;
   reg_ok=1;
   case(offset)
     14'h1000:reg_value=32'h50434931;
     14'h1004:reg_value={31'b0,four_tag};
     14'h1008:reg_value=aperture_base[31:0];
     14'h100c:reg_value=aperture_base[63:32];
     14'h1010:reg_value={16'b0,quarantined_tags,active_tags,2'b0,msi_armed,cfg_msi_mask,cfg_msi_enable,msi_pending,cfg_bus_master_enable,quarantined_tags!=0};
     14'h1014:reg_value={23'b0,sticky};
     14'h1020:reg_value={late_count,unexpected_count};
     14'h1024:reg_value=msi_count;
     14'h1028:reg_value=request_count;
     14'h102c:reg_value=accepted_count;
     14'h1030:reg_value={29'b0,max_active};
     default:begin reg_value=0;reg_ok=0;end
   endcase
   t_valid=state==S_CPL;t_sop=cpl_beat==0;t_eop=cpl_beat==(cpl_data?2'd3:2'd2);
   case(cpl_beat)
     0:t_data={cpl_data?3'b010:3'b000,5'b01010,14'b0,cpl_data?10'd1:10'd0};
     1:t_data={cfg_requester_id,cpl_status,1'b0,cpl_count};
     2:t_data={requester,tag,1'b0,address[6:0]};
     default:t_data={cpl_value[7:0],cpl_value[15:8],cpl_value[23:16],cpl_value[31:24]};
   endcase
   write_bad=0;
   case(offset)
     14'h1004:write_bad=first_be!=0 && (first_be!=4'hf || payload>1 || !config_ok);
     14'h1008:write_bad=first_be!=0 && (first_be!=4'hf || payload[11:0]!=0 || !config_ok);
     14'h100c:write_bad=first_be!=0 && (first_be!=4'hf || !config_ok);
     14'h1018:write_bad=first_be!=0 && (first_be!=4'hf || payload>511);
     14'h101c:write_bad=first_be!=0 && (first_be!=4'hf || payload!=1 || !engine_quiescent || active_tags!=0);
     default:write_bad=1;
   endcase
   m_awaddr={18'b0,offset};m_araddr={18'b0,offset};m_wdata=payload;m_wstrb=first_be;
   m_awvalid=state==S_AXI_W && !aw_done;m_wvalid=state==S_AXI_W && !w_done;m_bready=state==S_AXI_W && aw_done && w_done;
   m_arvalid=state==S_AXI_R && !ar_done;m_rready=state==S_AXI_R && ar_done;
 end
 always_ff @(posedge clk) begin
   if(rst) begin
     state<=S_H0;fmt<=0;tlp_type<=0;tc<=0;attr<=0;ep<=0;length_dw<=0;requester<=0;tag<=0;first_be<=0;last_be<=0;address<=0;payload<=0;
     framing_error<=0;aw_done<=0;w_done<=0;ar_done<=0;cpl_status<=0;cpl_data<=0;cpl_value<=0;cpl_count<=0;cpl_beat<=0;
     four_tag<=0;aperture_base<=0;drain_reset<=0;bar_write_error_pulse<=0;unsupported_pulse<=0;
     sticky<=0;unexpected_count<=0;late_count<=0;msi_count<=0;request_count<=0;accepted_count<=0;
   end else begin
     drain_reset<=0;bar_write_error_pulse<=0;unsupported_pulse<=0;
     if(unexpected_pulse && unexpected_count!=16'hffff) unexpected_count<=unexpected_count+1'b1;
     if(late_pulse && late_count!=16'hffff) late_count<=late_count+1'b1;
     if(msi_sent_pulse) msi_count<=msi_count+1'b1;
     request_count<=request_count+write_request_pulse+read_request_pulse;
     if(accepted_pulse) accepted_count<=accepted_count+1'b1;
     case(state)
       S_H0:if(q_valid) begin
         fmt<=q_data[31:29];tlp_type<=q_data[28:24];tc<=q_data[22:20];attr<={q_data[18],q_data[13:12]};ep<=q_data[14];length_dw<=q_data[9:0];
         framing_error<=!q_sop || q_eop;
         if(q_eop) begin unsupported_pulse<=1;sticky[7]<=1;end else state<=S_H1;
       end
       S_H1:if(q_valid) begin
         requester<=q_data[31:16];tag<=q_data[15:8];last_be<=q_data[7:4];first_be<=q_data[3:0];
         if(q_eop) begin unsupported_pulse<=1;sticky[7]<=1;state<=S_H0;end else state<=S_H2;
       end
       S_H2:if(q_valid) begin
         if(fmt[0]) begin address[63:32]<=q_data;if(q_eop) begin unsupported_pulse<=1;sticky[7]<=1;state<=S_H0;end else state<=S_H3;end
         else begin
           address<={32'b0,q_data[31:2],2'b00};
           if(fmt[1]) begin if(q_eop) begin framing_error<=1;state<=S_EXEC;end else state<=S_DATA;end
           else begin if(!q_eop) begin framing_error<=1;state<=S_DRAIN;end else state<=S_EXEC;end
         end
       end
       S_H3:if(q_valid) begin
         address[31:0]<={q_data[31:2],2'b00};
         if(fmt[1]) begin if(q_eop) begin framing_error<=1;state<=S_EXEC;end else state<=S_DATA;end
         else begin if(!q_eop) begin framing_error<=1;state<=S_DRAIN;end else state<=S_EXEC;end
       end
       S_DATA:if(q_valid) begin
         payload<={q_data[7:0],q_data[15:8],q_data[23:16],q_data[31:24]};
         if(q_eop) state<=S_EXEC;else begin framing_error<=1;state<=S_DRAIN;end
       end
       S_DRAIN:if(q_valid && q_eop) state<=S_EXEC;
       S_EXEC:begin
         aw_done<=0;w_done<=0;ar_done<=0;cpl_beat<=0;cpl_count<={length_dw==0?2'b0:length_dw[9:0],2'b00};
         if(!supported) begin
           unsupported_pulse<=1;sticky[7]<=1;
           if(fmt[1]==0) begin cpl_status<=3'b001;cpl_data<=0;state<=S_CPL;end else state<=S_H0;
         end else if(transport) begin
           if(is_read) begin
             cpl_count<=4;
             if(reg_ok) begin cpl_status<=0;cpl_data<=1;cpl_value<=reg_value;end else begin cpl_status<=3'b100;cpl_data<=0;end
             state<=S_CPL;
           end else begin
             if(write_bad) begin bar_write_error_pulse<=1;sticky[6]<=1;end
             else if(first_be!=0) case(offset)
               14'h1004:four_tag<=payload[0];
               14'h1008:aperture_base[31:0]<=payload;
               14'h100c:aperture_base[63:32]<=payload;
               14'h1018:sticky<=sticky&~payload[8:0];
               14'h101c:drain_reset<=1;
               default:begin end
             endcase
             state<=S_H0;
           end
         end else state<=is_read?S_AXI_R:S_AXI_W;
       end
       S_AXI_W:begin
         if(m_awvalid && m_awready) aw_done<=1;
         if(m_wvalid && m_wready) w_done<=1;
         if(m_bvalid && m_bready) begin
           if(m_bresp!=0) begin bar_write_error_pulse<=1;sticky[6]<=1;end
           state<=S_H0;
         end
       end
       S_AXI_R:begin
         if(m_arvalid && m_arready) ar_done<=1;
         if(m_rvalid && m_rready) begin
           cpl_count<=4;
           if(m_rresp==0) begin cpl_status<=0;cpl_data<=1;cpl_value<=m_rdata;end else begin cpl_status<=3'b100;cpl_data<=0;end
           state<=S_CPL;
         end
       end
       S_CPL:if(t_ready) begin
         if(t_eop) state<=S_H0;else cpl_beat<=cpl_beat+1'b1;
       end
       default:state<=S_H0;
     endcase
     if(unexpected_pulse) sticky[0]<=1;if(malformed_pulse) sticky[1]<=1;if(poisoned_pulse) sticky[2]<=1;
     if(status_pulse) sticky[3]<=1;if(timeout_pulse) sticky[4]<=1;if(late_pulse) sticky[5]<=1;if(translation_pulse) sticky[8]<=1;
   end
 end
endmodule
