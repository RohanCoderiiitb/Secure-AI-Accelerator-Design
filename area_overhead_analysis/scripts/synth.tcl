# Yosys logic synthesis to the Nangate45 (FreePDK45) standard-cell library.
# Driven by environment variables set in run_design.sh:
#   TOP, VERILOG_FILES, PARAMS ("NAME=VAL NAME=VAL"), LIB, OUT_DIR, DONT_USE
yosys -import

set top      $::env(TOP)
set lib      $::env(LIB)
set out      $::env(OUT_DIR)
set dont_use {}
foreach c $::env(DONT_USE) { lappend dont_use -dont_use $c }

# Cell port directions for `check` (cells stay blackboxes).
read_liberty -lib $lib

foreach f $::env(VERILOG_FILES) {
    read_verilog -sv $f
}

# Parameter overrides on the top module. The two array tops leave PARAMS
# empty (see designs.sh) and elaborate with their RTL defaults.
foreach kv $::env(PARAMS) {
    lassign [split $kv =] k v
    chparam -set $k $v $top
}
hierarchy -check -top $top

# Generic synthesis. -flatten collapses everything EXCEPT instances carrying
# keep_hierarchy (the per-share multipliers in the masked designs), so the
# share domains stay physically separate exactly as the RTL intends.
synth -top $top -flatten
opt_clean -purge

dfflibmap -liberty $lib {*}$dont_use
opt
abc -D 10000 -liberty $lib {*}$dont_use
opt_clean -purge

hilomap -singleton -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
setundef -zero
splitnets
insbuf -buf BUF_X1 A Z
opt_clean -purge

check
tee -o $out/synth_stat.rpt stat -liberty $lib
write_verilog -noattr -noexpr -nohex -nodec $out/netlist_synth.v

# OpenROAD's Verilog reader rejects `signed` on port/wire declarations
# (kept from the RTL); it carries no meaning in a mapped netlist.
set fh [open $out/netlist_synth.v]; set nl [read $fh]; close $fh
regsub -all -line {^(\s*(?:input|output|wire|inout))\s+signed\s} $nl {\1 } nl
set fh [open $out/netlist_synth.v w]; puts -nonewline $fh $nl; close $fh
