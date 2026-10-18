# engine_axi_cdc_fit: engine clock (50 MHz) and an unrelated packet clock
# (125 MHz, a Gigabit Ethernet receive rate).
create_clock -name clk -period 20.000 [get_ports clk]
create_clock -name clk_pkt -period 8.000 [get_ports clk_pkt]
derive_clock_uncertainty

# The only paths between the domains are the FIFO's Gray-code pointer
# synchronizers and the FIFO memory read, which the pointer protocol makes
# safe (a word is written before its pointer can be seen). Timing them as
# synchronous paths would be meaningless, so the clocks are asynchronous;
# Quartus identifies the two-flop synchronizers for metastability analysis.
set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks clk_pkt]

# I/O of each domain against its own clock, as in engine.sdc
set pkt_in [get_ports {pkt_rst pkt_data[*] pkt_keep[*] pkt_valid pkt_last}]
set eng_in [remove_from_collection [all_inputs] [add_to_collection [get_ports {clk clk_pkt}] $pkt_in]]
set_input_delay -clock clk -max 4.000 $eng_in
set_input_delay -clock clk -min 1.000 $eng_in
set_input_delay -clock clk_pkt -max 1.600 $pkt_in
set_input_delay -clock clk_pkt -min 0.400 $pkt_in
set eng_out [remove_from_collection [all_outputs] [get_ports pkt_ready]]
set_output_delay -clock clk -max 4.000 $eng_out
set_output_delay -clock clk -min 0.000 $eng_out
set_output_delay -clock clk_pkt -max 1.600 [get_ports pkt_ready]
set_output_delay -clock clk_pkt -min 0.000 [get_ports pkt_ready]
