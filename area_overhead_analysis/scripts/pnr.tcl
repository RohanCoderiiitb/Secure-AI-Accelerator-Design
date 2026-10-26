# OpenROAD place & route for the area analysis (Nangate45 / FreePDK45).
# Floorplan -> tapcells -> PDN -> IO pins -> global/detailed placement ->
# CTS -> timing repair -> global route -> detailed route -> RC extraction.
# Driven by environment variables set in run_design.sh:
#   TOP, PLATFORM_DIR, OUT_DIR, SDC, CORE_UTIL, PLACE_DENSITY, THREADS

set top      $::env(TOP)
set pdir     $::env(PLATFORM_DIR)
set out      $::env(OUT_DIR)
set util     $::env(CORE_UTIL)
set density  $::env(PLACE_DENSITY)
set_thread_count $::env(THREADS)

set site      FreePDK45_38x28_10R_NP_162NW_34O
set dont_use  {TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1}
set fillers   {FILLCELL_X1 FILLCELL_X2 FILLCELL_X4 FILLCELL_X8 FILLCELL_X16 FILLCELL_X32}

#---------------------------------------------------------------- read design
read_lef     $pdir/lef/NangateOpenCellLibrary.tech.lef
read_lef     $pdir/lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty $pdir/lib/NangateOpenCellLibrary_typical.lib
read_verilog $out/netlist_synth.v
link_design  $top
read_sdc     $::env(SDC)
source       $pdir/setRC.tcl
set_dont_use $dont_use

set has_clk [expr {[llength [get_ports -quiet clk]] > 0}]

#---------------------------------------------------------------- floorplan
# Same target utilisation for every design, so post-route area differences
# come from the logic, not from floorplan choices.
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 2.0 -site $site
source $pdir/make_tracks.tcl
tapcell -distance 120 -tapcell_master TAPCELL_X1 -endcap_master TAPCELL_X1

# PDN: metal1 follow-pin rails + metal4 straps. The platform default
# (M4 @ 56 um, M7 @ 30 um) is coarser than the smaller multiplier dies,
# so the strap pitch is scaled to the die here; this only affects routing
# resources, not cell area.
add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VSS$} -ground
global_connect
set_voltage_domain -name CORE -power VDD -ground VSS
define_pdn_grid -name grid -voltage_domains CORE
add_pdn_stripe -grid grid -layer metal1 -width 0.17 -pitch 2.4 -offset 0 -followpins
set core_w [expr {[ord::dbu_to_microns [[[ord::get_db_block] getCoreArea] dx]]}]
# whole-micron pitch keeps it on the 5 nm manufacturing grid
set m4_pitch [expr {double(round(min(56.0, max(10.0, $core_w / 4.0))))}]
add_pdn_stripe -grid grid -layer metal4 -width 0.48 -pitch $m4_pitch -offset 2
add_pdn_connect -grid grid -layers {metal1 metal4}
pdngen

#---------------------------------------------------------------- placement
place_pins -hor_layers metal3 -ver_layers metal4
global_placement -density $density
estimate_parasitics -placement
repair_design
detailed_placement

if {$has_clk} {
    clock_tree_synthesis -root_buf CLKBUF_X3 -buf_list {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3}
    set_propagated_clock [all_clocks]
}
estimate_parasitics -placement
repair_timing
detailed_placement
check_placement

#---------------------------------------------------------------- routing
# Platform fastroute.tcl settings, with the ORFS env variables written out.
set_global_routing_layer_adjustment metal2-metal3  0.5
set_global_routing_layer_adjustment metal4-metal10 0.25
set_routing_layers -clock  metal4-metal10
set_routing_layers -signal metal2-metal10
global_route -congestion_iterations 50
estimate_parasitics -global_routing
repair_timing
detailed_placement

# Fillers go in before detailed routing (as in ORFS); they are excluded
# from every area number reported below.
filler_placement $fillers
check_placement
detailed_route -output_drc $out/route_drc.rpt -verbose 0

#---------------------------------------------------------------- post-route
set_extraction_rules_file $pdir/rcx_patterns.rules
extract_parasitics
write_spef    $out/postroute.spef
write_verilog $out/netlist_postroute.v
write_def     $out/postroute.def
write_db      $out/postroute.odb

# Area by cell class, measured on the routed database.
set block [ord::get_db_block]
array set area {seq 0.0 comb 0.0 bufinv 0.0 clkbuf 0.0 tap 0.0 tie 0.0 fill 0.0}
array set count {seq 0 comb 0 bufinv 0 clkbuf 0 tap 0 tie 0 fill 0}
foreach inst [$block getInsts] {
    set m    [$inst getMaster]
    set name [$m getName]
    set a    [expr {[ord::dbu_to_microns [$m getWidth]] * [ord::dbu_to_microns [$m getHeight]]}]
    if {[string match FILLCELL* $name]} {
        set k fill
    } elseif {[string match TAPCELL* $name]} {
        set k tap
    } elseif {[string match LOGIC* $name]} {
        set k tie
    } elseif {[regexp {^(DFF|SDFF|DL)} $name]} {
        set k seq
    } elseif {[string match CLKBUF* $name]} {
        set k clkbuf
    } elseif {[regexp {^(BUF|INV)_} $name]} {
        set k bufinv
    } else {
        set k comb
    }
    set area($k)  [expr {$area($k) + $a}]
    incr count($k)
}
set total_area 0.0; set total_cnt 0
foreach k {seq comb bufinv clkbuf tap tie} {
    set total_area [expr {$total_area + $area($k)}]
    incr total_cnt $count($k)
}
set die  [$block getDieArea]
set core [$block getCoreArea]
set die_w  [ord::dbu_to_microns [$die dx]];  set die_h  [ord::dbu_to_microns [$die dy]]
set core_w [ord::dbu_to_microns [$core dx]]; set core_h [ord::dbu_to_microns [$core dy]]

set drc_count 0
if {[file exists $out/route_drc.rpt]} {
    set fh [open $out/route_drc.rpt]
    set drc_count [regexp -all {violation type} [read $fh]]
    close $fh
}

set fh [open $out/postroute_metrics.txt w]
puts $fh "design $top"
foreach k {seq comb bufinv clkbuf tap tie fill} {
    puts $fh [format "area_%s %.4f" $k $area($k)]
    puts $fh [format "count_%s %d" $k $count($k)]
}
puts $fh [format "stdcell_area %.4f" $total_area]
puts $fh [format "stdcell_count %d" $total_cnt]
puts $fh [format "core_area %.4f" [expr {$core_w * $core_h}]]
puts $fh [format "die_area %.4f" [expr {$die_w * $die_h}]]
puts $fh [format "die_wh %.3f %.3f" $die_w $die_h]
puts $fh [format "core_util %.4f" [expr {$total_area / ($core_w * $core_h)}]]
puts $fh "route_drc_violations $drc_count"
close $fh

# OpenROAD cross-check of stdcell_area (printed to openroad.log; this
# command does not support > redirection)
report_design_area
report_cell_usage -verbose -file             $out/report_cell_usage.rpt
report_checks -path_delay max -digits 3    > $out/openroad_postroute_timing.rpt
report_wns                                 >> $out/openroad_postroute_timing.rpt
report_tns                                 >> $out/openroad_postroute_timing.rpt
exit
