module ram_smoke(input logic clk, input logic we, input logic [7:0] addr,
 input logic [31:0] din, output logic [31:0] dout);
 (* ramstyle = "M9K" *) logic [31:0] mem [0:255];
 always_ff @(posedge clk) begin
   if(we) mem[addr] <= din;
   dout <= mem[addr];
 end
endmodule
