# Clock-domain-crossing reports for a two-clock fit (engine_axi_cdc_fit):
# metastability analysis of the identified synchronizers and the clock
# transfers between the domains.
set project [lindex $argv 0]
project_open $project
create_timing_netlist
read_sdc
update_timing_netlist
report_clock_transfers -file clock_transfers.txt
report_metastability -file metastability.txt
delete_timing_netlist
project_close
