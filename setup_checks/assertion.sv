`timescale 1ns/1ps
module assertion_smoke;
 bit clk=0; always #5 clk=~clk;
 bit enable=0,good=1;
 int pass_count=0;
 property stable_good; @(posedge clk) enable |-> good; endproperty
 check_good: assert property(stable_good) begin if(enable) pass_count++; end
   else $fatal(1,"EXPECTED_SVA_FAILURE");
 initial begin
   repeat(2) @(negedge clk); enable=1;
   repeat(3) @(negedge clk);
   if($test$plusargs("FAIL")) good=0;
   repeat(3) @(negedge clk);
   if(pass_count<3) $fatal(1,"assertion not exercised");
   $display("SVA_PASS count=%0d",pass_count); $finish;
 end
 initial begin #1000; $fatal(1,"WATCHDOG"); end
endmodule
