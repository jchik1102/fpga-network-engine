`timescale 1ns/1ps
module random_calls;
  integer signed_value;
  int unsigned unsigned_value, ranged_value;
  int signed_nonzero=0,unsigned_nonzero=0,ranged_nonzero=0;
  bit [15:0] seen;
  initial begin
    repeat(256) begin
      signed_value=$random(); unsigned_value=$urandom(); ranged_value=$urandom_range(15,0);
      if(signed_value!=0) signed_nonzero++;
      if(unsigned_value!=0) unsigned_nonzero++;
      if(ranged_value!=0) ranged_nonzero++;
      if(ranged_value>15) $fatal(1,"RANGE_FAILURE");
      seen[ranged_value]=1;
    end
    $display("SYSTEM_RANDOM signed_nonzero=%0d unsigned_nonzero=%0d ranged_nonzero=%0d range_bins=%0d",signed_nonzero,unsigned_nonzero,ranged_nonzero,$countones(seen));
    if(signed_nonzero<200 || unsigned_nonzero<200 || ranged_nonzero<200 || $countones(seen)<12) $fatal(1,"CONSTANT_RANDOM_FAILURE");
    $display("SYSTEM_RANDOM_PASS"); $finish;
  end
endmodule
