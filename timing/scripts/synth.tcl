# Yosys logic synthesis to the standard-cell library in scripts/pdk_gpdk045.sh.
# Driven by environment variables set in run_design.sh / hier_paths.sh:
#   TOP, VERILOG_FILES, PARAMS ("NAME=VAL NAME=VAL"), LIB, SYN_LIB, ABC_D,
#   OUT_DIR, DONT_USE, TIEHI_CELL, TIELO_CELL, BUF_CELL, HIER
#
# SYN_LIB is the liberty ABC maps against. It defaults to the SLOW corner
# (0.9 V / 125 C): the design has to meet 100 MHz there too, and mapping for
# delay at the corner where timing is worst gives OpenROAD a netlist it can
# close at both corners. Cell areas are identical in both libraries.
# ABC_D is ABC's delay target in ps (10 ns period minus clk->q, setup and
# wire margin).
# HIER=1 keeps every module boundary (no -flatten): per-block area and
# hierarchical critical paths. HIER=0 (default) is the implementation netlist.
yosys -import

set top      $::env(TOP)
set lib      $::env(LIB)
set synlib   [expr {[info exists ::env(SYN_LIB)] ? $::env(SYN_LIB) : $lib}]
set abc_d    [expr {[info exists ::env(ABC_D)]   ? $::env(ABC_D)   : 8000}]
set hier     [expr {[info exists ::env(HIER)]    ? $::env(HIER)    : 0}]
set out      $::env(OUT_DIR)
set dont_use {}
foreach c $::env(DONT_USE) { lappend dont_use -dont_use $c }

# Cell port directions for `check` (cells stay blackboxes).
read_liberty -lib $lib

foreach f $::env(VERILOG_FILES) {
    read_verilog -sv -I [file dirname $f] $f
}

foreach kv $::env(PARAMS) {
    lassign [split $kv =] k v
    chparam -set $k $v $top
}
hierarchy -check -top $top

if {$hier} {
    synth -top $top
} else {
    # -flatten collapses everything EXCEPT instances carrying keep_hierarchy
    # (the per-share multipliers / PEs in the masked designs), so the share
    # domains stay physically separate exactly as the RTL intends.
    synth -top $top -flatten
}
opt_clean -purge

dfflibmap -liberty $lib {*}$dont_use
opt
abc -D $abc_d -liberty $synlib {*}$dont_use
opt_clean -purge

hilomap -singleton -hicell {*}$::env(TIEHI_CELL) -locell {*}$::env(TIELO_CELL)
setundef -zero
splitnets
insbuf -buf {*}$::env(BUF_CELL)
opt_clean -purge
# name every flip-flop after the RTL signal it drives (timing reports then
# show e.g. g_post[0].u_requant/prod_s2_reg instead of _9010_)
yosys rename -wire -suffix _reg t:DFF*

check
if {$hier} {
    tee -o $out/hier_stat.txt stat -liberty $lib
} else {
    tee -o $out/synth_stat.rpt stat -liberty $lib
}
write_verilog -noattr -noexpr -nohex -nodec $out/netlist_synth.v

# OpenROAD's / OpenSTA's Verilog reader rejects `signed` on port/wire
# declarations (kept from the RTL); it carries no meaning in a mapped netlist.
set fh [open $out/netlist_synth.v]; set nl [read $fh]; close $fh
regsub -all -line {^(\s*(?:input|output|wire|inout))\s+signed\s} $nl {\1 } nl
set fh [open $out/netlist_synth.v w]; puts -nonewline $fh $nl; close $fh
