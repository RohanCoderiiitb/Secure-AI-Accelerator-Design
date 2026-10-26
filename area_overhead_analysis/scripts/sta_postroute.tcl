# Standalone OpenSTA sign-off of the routed netlist with extracted SPEF.
#   TOP, PLATFORM_DIR, OUT_DIR, SDC
set out $::env(OUT_DIR)

read_liberty $::env(PLATFORM_DIR)/lib/NangateOpenCellLibrary_typical.lib
read_verilog $out/netlist_postroute.v
link_design  $::env(TOP)
read_sdc     $::env(SDC)
read_spef    $out/postroute.spef
if {[llength [get_ports -quiet clk]] > 0} { set_propagated_clock [all_clocks] }

set rpt $out/sta_postroute.rpt
report_checks -path_delay max -fields {slew cap fanout} -digits 3 > $rpt
report_checks -path_delay min -digits 3                          >> $rpt
report_check_types -max_slew -max_capacitance -violators          >> $rpt

set wns [sta::worst_slack_cmd max]
set tns [sta::total_negative_slack_cmd max]
set whs [sta::worst_slack_cmd min]
set fh [open $out/sta_metrics.txt w]
puts $fh [format "setup_wns_ns %.4f" [sta::time_sta_ui $wns]]
puts $fh [format "setup_tns_ns %.4f" [sta::time_sta_ui $tns]]
puts $fh [format "hold_wns_ns %.4f"  [sta::time_sta_ui $whs]]
# Critical-path data arrival -> achievable period estimate.
set path [lindex [find_timing_paths -path_delay max -group_path_count 1] 0]
puts $fh [format "crit_arrival_ns %.4f" [sta::time_sta_ui [$path data_arrival_time]]]
close $fh
exit
