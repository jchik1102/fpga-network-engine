module descriptor_validator(
 input logic [511:0] descriptor,
 input logic replay,
 input logic [31:0] expected_sequence,expected_epoch,
 input logic [15:0] capture_length,
 output logic valid,
 output logic [63:0] cookie,captured_tick,
 output logic [15:0] length,
 output logic [2:0] segment_count,
 output logic [31:0] address[0:3],
 output logic [15:0] segment_length[0:3]
);
 logic [18:0] total;
 logic [32:0] end_address[0:3];
 logic [31:0] lower_bound,upper_bound;
 always_comb begin
   cookie=descriptor[63:0];captured_tick=descriptor[191:128];length=descriptor[207:192];
   segment_count=descriptor[210:208];total=0;
   lower_bound=replay?32'h80000:32'h40000;upper_bound=replay?32'hc0000:32'h80000;
   valid=descriptor[95:64]==expected_sequence && descriptor[127:96]==expected_epoch &&
     descriptor[215:208]>=1 && descriptor[215:208]<=4 && descriptor[255:216]==0 &&
     length>=60 && length<=(replay?1514:2048) && (replay || captured_tick==0) &&
     (replay || length>=capture_length);
   for(integer i=0;i<4;i++) begin
     address[i]=descriptor[256+64*i +:32];segment_length[i]=descriptor[288+64*i +:16];
     end_address[i]={1'b0,address[i]}+{17'b0,segment_length[i]};
     if(i<segment_count) begin
       total=total+segment_length[i];
       if(address[i][2:0]!=0 || segment_length[i]==0 || (i+1<segment_count && segment_length[i][2:0]!=0) ||
          address[i]<lower_bound || end_address[i]>{1'b0,upper_bound} || descriptor[304+64*i +:16]!=0) valid=0;
       for(integer j=0;j<4;j++) if(j<i) begin
         if({1'b0,address[i]}<end_address[j] && {1'b0,address[j]}<end_address[i]) valid=0;
       end
     end else if(descriptor[256+64*i +:64]!=0) valid=0;
   end
   if(total!={3'b0,length}) valid=0;
 end
endmodule
