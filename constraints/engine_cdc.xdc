# Vivado constraints for engine_axi_cdc_fit (out of context): the engine clock
# at 50 MHz and an unrelated packet clock at 125 MHz. The only paths between
# them are the async FIFO's: each Gray pointer into the first synchronizer
# flop, and the FIFO memory read by the other side. Instead of cutting those
# paths (set_clock_groups), they are bounded the way Xilinx's own CDC macros
# do it: data-path delay under the faster clock's period, and skew between the
# bits of a pointer under that period too, so the receiving side never samples
# a pointer with two bits in transition. report_cdc lists the crossings.
create_clock -name clk -period 20.000 [get_ports clk]
create_clock -name clk_pkt -period 8.000 [get_ports clk_pkt]
set_max_delay -datapath_only -from [get_clocks clk_pkt] -to [get_clocks clk] 8.000
set_max_delay -datapath_only -from [get_clocks clk] -to [get_clocks clk_pkt] 8.000
set_bus_skew -from [get_cells crossing/w_gray_reg*] -to [get_cells crossing/w_sync1_reg*] 8.000
set_bus_skew -from [get_cells crossing/r_gray_reg*] -to [get_cells crossing/r_sync1_reg*] 8.000
