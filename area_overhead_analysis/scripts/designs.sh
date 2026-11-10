# Design matrix for the masking area-overhead analysis.
# Format: name | top module | RTL files (repo-relative) | parameter overrides
# Parameters match the configurations exercised by the design testbenches
# (protected_designs/sim, sim): N=8, multiplier SW=16, PE/array SHARE_W=ACCW=32,
# 5x5 array.
#
# The array tops carry NO overrides: chparam / hierarchy -chparam on those
# modules hits an internal assertion in the installed Yosys (0.69+75 dev
# build). Their RTL defaults already are the intended configuration
# (systolic_array: N=8 ACCW=32 ROWS=5 COLS=5; systolic_array_masked_act and
# systolic_array_masked: N=8 SHARE_W=32 ROWS=5 COLS=5;
# systolic_array_wmask_shared: N=8 ROWS=5 COLS=5 SW=2N+clog2(ROWS)=19).

U=source
P=protected_designs/source
W=area_overhead_analysis/rtl
X=protected_designs/complete_accelerator

# Full accelerators: NOT built by this flow any more. The four complete-
# accelerator rows (acc_*) are the timing-closed builds from timing/ (100 MHz
# met at both corners, multi-corner setup/hold repair), copied into
# results/acc_*/ (see results/acc_*/SOURCE.txt and timing/REPORT_v2.md):
#   acc_unmasked    <- timing/results/acc_unmasked          (flexnn_top)
#   acc_arr_masked  <- timing/results/acc_arr_masked        (flexnn_top_arr_masked)
#   acc_rq_masked   <- timing/results/acc_rq_masked_nrq1    (flexnn_top_rq_masked, NRQ=1)
#   acc_both_masked <- timing/results/acc_both_masked_nrq1  (flexnn_top_protected, NRQ=1)
# All four use identical parameters (RTL defaults in $X): 5x5 array, WAVES=4,
# ACCW=19, MW=16, SW=6, BW=32, POOL_LEN=1, DOM_REG=1, NRQ=1, registered I/O.
# Rebuild them with timing/scripts/run_design.sh. The pre-timing-closure
# results of this flow are kept in results/old_pre_timing_closure/.

DESIGNS=(
"mult_unmasked|baugh_wooley_multiplier|$U/multiplier.sv|N=8"
"mult_unmasked_wreg|bw_multiplier_wreg|$U/multiplier.sv $W/area_ref_wrappers.sv|N=8"
"mult_wt_masked|masked_weight_multiplier|$P/masked_wt_multiplier.sv|N=8 SW=16"
"mult_act_masked|masked_act_multiplier|$P/masked_wt_multiplier.sv $P/masked_act_multiplier.sv|N=8 SW=16"
"mult_act_wt_masked|masked_multiplier_aw|$P/masked_wt_multiplier.sv $P/masked_act_wt_multiplier.sv|N=8 SW=16"
"pe_unmasked|processing_element|$U/multiplier.sv $U/processing_element.sv|N=8 ACCW=32"
"pe_act_masked|processing_element_masked_act|$P/masked_wt_multiplier.sv $P/processing_element_masked_act.sv|N=8 SHARE_W=32"
"sa_unmasked|systolic_array|$U/multiplier.sv $U/processing_element.sv $U/systolic_array.sv|"
"sa_act_masked|systolic_array_masked_act|$P/masked_wt_multiplier.sv $P/processing_element_masked_act.sv $P/systolic_array_masked_act.sv|"
"pe_wt_masked|processing_element_masked|$P/masked_wt_multiplier.sv $P/processing_element_masked_wt.sv|N=8 SHARE_W=32"
"sa_wt_masked|systolic_array_masked|$P/masked_wt_multiplier.sv $P/processing_element_masked_wt.sv $P/systolic_array_masked_wt.sv|"
"act_masker|act_masker|$P/act_masker.sv|N=8 SHARE_W=32 ROWS=5"
"sa_wmask_shared|systolic_array_wmask_shared|$U/multiplier.sv $P/systolic_array_wmask_shared.sv|"
)
