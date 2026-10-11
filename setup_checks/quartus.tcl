package require ::quartus::project
project_new ram_smoke -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY ram_smoke
set_global_assignment -name SYSTEMVERILOG_FILE ../../../setup_checks/ram_smoke.sv
set_global_assignment -name SDC_FILE ../../../setup_checks/ram_smoke.sdc
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 2
foreach port {we addr[*] din[*] dout[*]} { set_instance_assignment -name VIRTUAL_PIN ON -to $port }
export_assignments
project_close
