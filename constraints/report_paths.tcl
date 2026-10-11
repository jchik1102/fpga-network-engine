set project [lindex $argv 0]
project_open $project
create_timing_netlist
read_sdc
update_timing_netlist
foreach corner {slow_85c} {
  report_timing -setup -npaths 12 -detail summary -file paths_setup.txt
  report_timing -hold -npaths 12 -detail summary -file paths_hold.txt
  report_timing -setup -npaths 1 -detail full_path -file path_setup_worst.txt
  report_timing -hold -npaths 1 -detail full_path -file path_hold_worst.txt
}
report_clocks -file clocks.txt
report_ucp -file unconstrained.txt
delete_timing_netlist
project_close
