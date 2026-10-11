module packet_classifier (
 input logic [511:0] header,
 input logic [15:0] frame_length,
 input logic bad_mask, timed_out,
 input logic [3:0] reserved_queues,
 input logic [1:0] default_queue,
 input logic [4:0] rule_control [0:7],
 input logic [31:0] rule_src [0:7], rule_src_mask [0:7],
 input logic [31:0] rule_dst [0:7], rule_dst_mask [0:7], rule_ports [0:7],
 output logic [2:0] drop_reason,
 output logic parsed_valid,
 output logic [1:0] queue_id,
 output logic [3:0] rule_id,
 output logic [31:0] source_ip, destination_ip,
 output logic [15:0] source_port, destination_port
);
 function automatic [7:0] octet(input integer index);
   octet=header[index*8 +: 8];
 endfunction
 function automatic [15:0] network16(input integer index);
   network16={octet(index),octet(index+1)};
 endfunction
 function automatic [31:0] network32(input integer index);
   network32={octet(index),octet(index+1),octet(index+2),octet(index+3)};
 endfunction
 logic [7:0] ihl_bytes;
 logic [15:0] ip_length,fragment,udp_length;
 logic found;
 always_comb begin
   drop_reason=0; parsed_valid=0; queue_id=default_queue; rule_id=15;
   source_ip=0; destination_ip=0; source_port=0; destination_port=0;
   ihl_bytes={2'b0,header[112 +: 4],2'b0};
   ip_length=network16(16); fragment=network16(20); udp_length=network16(38);
   found=0;
   if(timed_out) drop_reason=1;
   else if(bad_mask) drop_reason=2;
   else if(frame_length>1514) drop_reason=3;
   else if(frame_length<60) drop_reason=4;
   else if(network16(12)==16'h0800) begin
     if(header[116 +: 4]!=4 || ihl_bytes<20 || ({8'b0,ihl_bytes}+16'd14)>frame_length ||
        ip_length<ihl_bytes || ip_length>(frame_length-16'd14)) drop_reason=5;
     else if(ihl_bytes==20 && (fragment & 16'h3fff)==0 && octet(23)==17) begin
       if(ip_length<28 || udp_length<8 || udp_length!=(ip_length-16'd20)) drop_reason=5;
       else begin
         parsed_valid=1; source_ip=network32(26); destination_ip=network32(30);
         source_port=network16(34); destination_port=network16(36);
         for(integer r=0;r<8;r=r+1) begin
           if(!found && rule_control[r][0] &&
              ((source_ip & rule_src_mask[r])==(rule_src[r] & rule_src_mask[r])) &&
              ((destination_ip & rule_dst_mask[r])==(rule_dst[r] & rule_dst_mask[r])) &&
              (!rule_control[r][3] || source_port==rule_ports[r][15:0]) &&
              (!rule_control[r][4] || destination_port==rule_ports[r][31:16])) begin
             found=1; queue_id=rule_control[r][2:1]; rule_id=r[3:0];
           end
         end
       end
     end
   end
   if(drop_reason==0 && !reserved_queues[queue_id]) drop_reason=6;
   if(drop_reason!=0) begin
     queue_id=0; rule_id=15; parsed_valid=0;
     source_ip=0; destination_ip=0; source_port=0; destination_port=0;
   end
 end
endmodule
