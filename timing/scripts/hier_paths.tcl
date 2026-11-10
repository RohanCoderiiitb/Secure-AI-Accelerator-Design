# Top-N setup paths of a HIERARCHICAL (unflattened) synthesised netlist at one
# library corner, pre-layout (ideal clock, no wire parasitics). One path per
# endpoint, so the list shows N different failing registers/ports, with the
# hierarchical instance names kept.
#   TOP, OUT_DIR, SDC, STA_LIB, STA_TAG, NPATHS + PDK variables
set out $::env(OUT_DIR)
set tag $::env(STA_TAG)
set n   [expr {[info exists ::env(NPATHS)] ? $::env(NPATHS) : 20}]

read_liberty $::env(STA_LIB)
read_verilog $out/netlist_synth.v
link_design  $::env(TOP)
read_sdc     $::env(SDC)
# No wire-load model in gsclib045: give every net a fixed wire capacitance so
# the pre-layout delays are closer to post-route ones (default 3 fF).
set wcap [expr {[info exists ::env(WIRE_CAP)] ? $::env(WIRE_CAP) : 0.003}]
set_load -wire_load $wcap [get_nets -hierarchical *]

set fh [open $out/hier_paths_$tag.tsv w]
puts $fh "rank\tslack_ns\tarrival_ns\tstartpoint\tendpoint\tinstances"
set rank 0
foreach pe [find_timing_paths -path_delay max -group_path_count $n -endpoint_path_count 1 -sort_by_slack] {
    incr rank
    set p [$pe path]
    # pins run endpoint -> startpoint; with an ideal clock the last one is the
    # clk port itself, the register clock pin just before it is the startpoint
    set pl [$p pins]
    set sp [lindex $pl end]
    if {[get_full_name $sp] eq "clk" && [llength $pl] > 1} { set sp [lindex $pl end-1] }
    set insts {}
    foreach pin [$p pins] {
        set nm [get_full_name $pin]
        set parts [split $nm /]
        # drop "<cell>/<pin>": keep the hierarchical instance that owns the cell
        if {[llength $parts] > 2} {
            set h [join [lrange $parts 0 end-2] /]
            if {[lsearch -exact $insts $h] < 0} { lappend insts $h }
        }
    }
    puts $fh [format "%d\t%.3f\t%.3f\t%s\t%s\t%s" $rank \
        [sta::time_sta_ui [$pe slack]] [sta::time_sta_ui [$pe data_arrival_time]] \
        [get_full_name $sp] [get_full_name [$pe pin]] [join $insts " "]]
}
close $fh
# every failing endpoint (worst path each), for the per-block summary
set fh [open $out/hier_endpoints_$tag.tsv w]
puts $fh "slack_ns\tstartpoint\tendpoint"
foreach pe [find_timing_paths -path_delay max -group_path_count 20000 -endpoint_path_count 1 -slack_max 0.0] {
    set pl [[$pe path] pins]
    set sp [lindex $pl end]
    if {[get_full_name $sp] eq "clk" && [llength $pl] > 1} { set sp [lindex $pl end-1] }
    puts $fh [format "%.3f\t%s\t%s" [sta::time_sta_ui [$pe slack]] [get_full_name $sp] [get_full_name [$pe pin]]]
}
close $fh
report_checks -path_delay max -group_path_count 3 -endpoint_path_count 1 -digits 3 \
    > $out/hier_paths_$tag.rpt
set fh [open $out/hier_metrics_$tag.txt w]
puts $fh [format "setup_wns_ns %.4f" [sta::time_sta_ui [sta::worst_slack_cmd max]]]
puts $fh [format "setup_tns_ns %.4f" [sta::time_sta_ui [sta::total_negative_slack_cmd max]]]
close $fh
exit
