# SPDX-License-Identifier: GPL-3.0-or-later
# The worst setup paths of a fitted build, by clock:
#   quartus_sta -t scripts/worst_paths.tcl <revision> [n]
# run in the build directory (build/). Writes worst_paths.txt there.
set rev [lindex $argv 0]
set n [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20}]
project_open $rev -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist
set fh [open "worst_paths.txt" w]
foreach_in_collection clk [get_clocks] {
    set name [get_clock_info -name $clk]
    set paths [get_timing_paths -setup -npaths $n -to_clock $name]
    foreach_in_collection p $paths {
        set slack [get_path_info -slack $p]
        if {$slack >= 0} { continue }
        puts $fh [format "%8.3f  %s\n          -> %s  (%s)" $slack \
            [get_node_info -name [get_path_info -from $p]] \
            [get_node_info -name [get_path_info -to $p]] $name]
    }
}
close $fh
delete_timing_netlist
project_close
