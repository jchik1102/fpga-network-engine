create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty
set_input_delay -clock clk -max 4.000 [remove_from_collection [all_inputs] [get_ports clk]]
# min input delay models an upstream on-chip register
set_input_delay -clock clk -min 1.000 [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk -max 4.000 [all_outputs]
set_output_delay -clock clk -min 0.000 [all_outputs]
