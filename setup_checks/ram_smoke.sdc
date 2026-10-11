create_clock -name clk -period 20.000 [get_ports clk]
set_input_delay -clock clk -max 2.0 [get_ports {we addr[*] din[*]}]
set_input_delay -clock clk -min 0.5 [get_ports {we addr[*] din[*]}]
set_output_delay -clock clk -max 2.0 [get_ports {dout[*]}]
set_output_delay -clock clk -min 0.5 [get_ports {dout[*]}]
derive_clock_uncertainty
