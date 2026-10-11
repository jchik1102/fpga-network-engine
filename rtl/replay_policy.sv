module replay_policy(
 input logic clk,rst,start,output logic ready,
 input logic fixed_mode,input logic [63:0] start_tick,captured_tick,origin_tick,interval,delay_ticks,
 input logic [31:0] descriptor_sequence,seed,input logic [1:0] queue_id,input logic [32:0] threshold,
 output logic done,valid,lost,output logic [63:0] due_tick,output logic [31:0] random_word
);
 typedef enum logic [2:0] {IDLE,HASH,MULTIPLY,SHIFT13,SHIFT17,SHIFT5,FINISH} state_t;
 state_t state;logic [95:0] accumulator,multiplicand;logic [31:0] multiplier,x;
 logic [5:0] count;logic [63:0] start_saved,delta;logic [32:0] threshold_saved;
 logic [31:0] sequence_q,seed_q;logic [1:0] queue_q;logic fixed_q;
 assign ready=state==IDLE;
 assign delta=captured_tick-origin_tick;
 always_ff @(posedge clk) begin
   if(rst) begin state<=IDLE;sequence_q<=0;seed_q<=0;queue_q<=0;fixed_q<=0;accumulator<=0;multiplicand<=0;multiplier<=0;x<=0;count<=0;start_saved<=0;threshold_saved<=0;done<=0;valid<=0;lost<=0;due_tick<=0;random_word<=0;end
   else begin
     done<=0;
     case(state)
       IDLE:if(start) begin
         start_saved<=start_tick;threshold_saved<=threshold;
         sequence_q<=descriptor_sequence;seed_q<=seed;queue_q<=queue_id;fixed_q<=fixed_mode;state<=HASH;
         if(fixed_mode) begin accumulator<={32'b0,delay_ticks};multiplicand<={32'b0,interval};multiplier<=descriptor_sequence;count<=0;end
         else accumulator<={32'b0,delta}+{32'b0,delay_ticks};
       end
       HASH:begin
`ifdef MUTATION_WRONG_LOSS
         // equivalent mutant for this corpus, kept on purpose
         x<=seed_q^(sequence_q*32'h9e3779b8)^({30'b0,queue_q}*32'h85ebca6b);
`elsif MUTATION_LOSS_IGNORES_QUEUE
         x<=seed_q^(sequence_q*32'h9e3779b9);
`else
         x<=seed_q^(sequence_q*32'h9e3779b9)^({30'b0,queue_q}*32'h85ebca6b);
`endif
         state<=fixed_q?MULTIPLY:SHIFT13;
       end
       // serial shift-add multiply instead of a combinational 64x32 one, for timing
       MULTIPLY:begin
         if(multiplier[0]) accumulator<=accumulator+multiplicand;
         multiplier<=multiplier>>1;multiplicand<=multiplicand<<1;count<=count+1'b1;
         if(count==31) state<=SHIFT13;
       end
       SHIFT13:begin x<=x^(x<<13);state<=SHIFT17;end
       SHIFT17:begin x<=x^(x>>17);state<=SHIFT5;end
       SHIFT5:begin x<=x^(x<<5);state<=FINISH;end
       FINISH:begin
         random_word<=x;lost<={1'b0,x}<threshold_saved;
         valid<=accumulator[95:63]==0 && threshold_saved<=33'h100000000;
         due_tick<=start_saved+accumulator[63:0];done<=1;state<=IDLE;
       end
       default:state<=IDLE;
     endcase
   end
 end
endmodule
