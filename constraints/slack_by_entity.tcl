set project [lindex $argv 0]
project_open $project
create_timing_netlist
read_sdc
update_timing_netlist
set worst [dict create]
set count [dict create]
foreach_in_collection path [get_timing_paths -setup -npaths 20000 -nworst 1] {
  set slack [get_path_info $path -slack]
  if {$slack >= 0} { continue }
  set to [get_node_info -name [get_path_info $path -to]]
  set parts [split $to "|"]
  set key [join [lrange $parts 0 [expr {[llength $parts] > 2 ? 2 : [llength $parts]-1}]] "|"]
  regsub -all {\[[0-9]+\]} $key {} key
  if {![dict exists $worst $key] || $slack < [dict get $worst $key]} { dict set worst $key $slack }
  dict incr count $key
}
set out [open slack_by_entity.txt w]
dict for {key slack} $worst { puts $out [format "%9.3f %6d %s" $slack [dict get $count $key] $key] }
close $out
delete_timing_netlist
project_close
