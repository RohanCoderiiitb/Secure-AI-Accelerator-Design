# OpenROAD place & route for the area analysis, using the PDK set up in
# scripts/pdk_gpdk045.sh (Cadence GPDK045 / gsclib045).
# Floorplan -> PDN -> IO pins -> global/detailed placement -> CTS ->
# timing repair -> global route -> detailed route -> RC extraction.
# Driven by environment variables set in run_design.sh:
#   TOP, OUT_DIR, SDC, CORE_UTIL, PLACE_DENSITY, THREADS + the PDK variables

set top      $::env(TOP)
set out      $::env(OUT_DIR)
set util     $::env(CORE_UTIL)
set density  $::env(PLACE_DENSITY)
set_thread_count $::env(THREADS)

#---------------------------------------------------------------- read design
read_lef     $::env(ROUTER_TECH_LEF)   ;# PDK tech LEF minus front-end via rules
read_lef     $::env(CELL_LEF)
read_liberty $::env(LIB)
read_verilog $out/netlist_synth.v
link_design  $top
read_sdc     $::env(SDC)
foreach p $::env(DONT_USE) {
    set cells [get_lib_cells -quiet $p]
    if {[llength $cells]} { set_dont_use $cells }
}
# Wire RC from the tech LEF (RPERSQ / CPERSQDIST per layer).
set_wire_rc -signal -layer Metal3
set_wire_rc -clock  -layer Metal5

set has_clk [expr {[llength [get_ports -quiet clk]] > 0}]

#---------------------------------------------------------------- floorplan
# Same target utilisation for every design, so post-route area differences
# come from the logic, not from floorplan choices. gsclib045 is a tapless
# library, so no tap/endcap cells are inserted.
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 2.0 -site $::env(SITE)
make_tracks

# PDN: Metal1 follow-pin rails + Metal4 straps, strap pitch scaled to the die.
add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VSS$} -ground
global_connect
set_voltage_domain -name CORE -power VDD -ground VSS
define_pdn_grid -name grid -voltage_domains CORE
add_pdn_stripe -grid grid -layer $::env(RAIL_LAYER) -width $::env(RAIL_WIDTH) -followpins
set core_w [expr {[ord::dbu_to_microns [[[ord::get_db_block] getCoreArea] dx]]}]
# whole-micron pitch keeps it on the 5 nm manufacturing grid
set strap_pitch [expr {double(round(min(56.0, max(10.0, $core_w / 4.0))))}]
add_pdn_stripe -grid grid -layer $::env(STRAP_LAYER) -width $::env(STRAP_WIDTH) \
               -pitch $strap_pitch -offset 2
add_pdn_connect -grid grid -layers [list $::env(RAIL_LAYER) $::env(STRAP_LAYER)]
pdngen

#---------------------------------------------------------------- placement
place_pins -hor_layers $::env(PIN_HOR_LAYER) -ver_layers $::env(PIN_VER_LAYER)
global_placement -density $density
estimate_parasitics -placement
repair_design
detailed_placement

if {$has_clk} {
    clock_tree_synthesis -root_buf $::env(CTS_ROOT_BUF) -buf_list $::env(CTS_BUFS)
    set_propagated_clock [all_clocks]
}
estimate_parasitics -placement
repair_timing
detailed_placement
check_placement

#---------------------------------------------------------------- routing
set_global_routing_layer_adjustment Metal2-Metal3  0.5
set_global_routing_layer_adjustment Metal4-Metal10 0.25
set_routing_layers -clock  $::env(CLOCK_LAYERS)
set_routing_layers -signal $::env(SIGNAL_LAYERS)
global_route -congestion_iterations 50
estimate_parasitics -global_routing
repair_timing
detailed_placement

# Fillers go in before detailed routing (as in ORFS); they are excluded
# from every area number reported below.
filler_placement $::env(FILLERS)
check_placement
detailed_route -output_drc $out/route_drc.rpt -verbose 0

#---------------------------------------------------------------- post-route
# No OpenRCX rules exist for this PDK (only a Cadence QRC .tch), so the
# post-route parasitics are estimated from the routed design's global routes
# with the tech-LEF layer RC, and written out as SPEF for OpenSTA.
estimate_parasitics -global_routing -spef_file $out/postroute.spef
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
    set iname [$inst getName]
    set a    [expr {[ord::dbu_to_microns [$m getWidth]] * [ord::dbu_to_microns [$m getHeight]]}]
    if {[string match FILL* $name]} {
        set k fill
    } elseif {[string match TAPCELL* $name]} {
        set k tap
    } elseif {[string match TIE* $name]} {
        set k tie
    } elseif {[regexp {^(DFF|SDFF|EDFF|SEDFF|MDFF|SMDFF|TLAT|RDFF)} $name]} {
        set k seq
    } elseif {[regexp {^clk(buf|load|inv)} $iname]} {
        # inserted by clock_tree_synthesis (instance names clkbuf_*/clkload*)
        set k clkbuf
    } elseif {[regexp {^(CLK)?(BUF|INV)X} $name]} {
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
