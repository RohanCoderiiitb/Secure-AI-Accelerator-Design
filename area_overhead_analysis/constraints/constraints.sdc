# 100 MHz quick timing check (10 ns period).
# Sequential designs: real clock on port "clk".
# Purely combinational designs (bare multiplier): a virtual clock, so the
# input->output path is still checked against the same 10 ns budget.
set clk_period 10.0
set io_delay   [expr {0.2 * $clk_period}]

if {[llength [get_ports -quiet clk]] > 0} {
    create_clock -name clk -period $clk_period [get_ports clk]
    set data_inputs [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
} else {
    create_clock -name clk -period $clk_period
    set data_inputs [all_inputs]
}

set_input_delay  $io_delay -clock clk $data_inputs
set_output_delay $io_delay -clock clk [all_outputs]
set_driving_cell -lib_cell BUF_X2 -pin Z $data_inputs
set_load 0.005 [all_outputs]
