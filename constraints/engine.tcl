package require ::quartus::project
set top [lindex $argv 0]
set sources [lrange $argv 1 end]
project_new $top -overwrite
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY $top
foreach source $sources { set_global_assignment -name SYSTEMVERILOG_FILE $source }
set_global_assignment -name SDC_FILE [file join [file dirname [info script]] engine.sdc]
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name OPTIMIZATION_MODE "BALANCED"
foreach port {rst s_* m_* irq quiescent running tick* rx_* tx_* cfg_*} {
  set_instance_assignment -name VIRTUAL_PIN ON -to $port
}
export_assignments
project_close
