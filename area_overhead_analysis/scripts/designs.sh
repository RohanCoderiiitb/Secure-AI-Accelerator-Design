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
X=complete_accelerator/complete_accelerator

# Full accelerators (complete_accelerator/): same buffers, controllers, activation
# unit and maxpool in all four. Masked variants differ only in which blocks are
# masked:
#   both : shared-mask-column array (two output shares) + psum_accum_masked +
#          requantize_masked/rng_bank per column            (flexnn_top_protected)
#   arr  : shared-mask-column array (recombined) + plain psum_accum/requantize
#                                                           (flexnn_top_arr_masked)
#   rq   : plain array/psum_accum, fresh-share split + requantize_masked/rng_bank
#                                                           (flexnn_top_rq_masked)
# All at 5x5 to match the array rows; other parameters are RTL defaults
# (WAVES=4, POOL_LEN=1, MW=32, SW=6). chparam works on these tops.
ACC_COMMON="$X/global_buffer.sv $X/sram_2p.sv $X/load_controller.sv $X/scratchpad.sv $X/address_generator.sv $X/multiplier.sv $X/activation_unit.sv $X/maxpool_unit.sv"
ACC_UNMASKED="$ACC_COMMON $X/processing_element.sv $X/systolic_array.sv $X/partial_sum_accumulators.sv $X/requantization_block.sv $X/top.sv"
ACC_BOTH="$ACC_COMMON $X/systolic_array_wmask_shared.sv $X/systolic_array_wmask_shares.sv $X/psum_accum_masked.sv $X/masking_gadgets.sv $X/requantize_masked.sv $X/top_protected.sv"
ACC_ARR="$ACC_COMMON $X/systolic_array_wmask_shared.sv $X/partial_sum_accumulators.sv $X/requantization_block.sv $X/top_protected_arr_only.sv"
ACC_RQ="$ACC_COMMON $X/processing_element.sv $X/systolic_array.sv $X/partial_sum_accumulators.sv $X/masking_gadgets.sv $X/requantize_masked.sv $X/top_protected_rq_only.sv"

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
"acc_unmasked|flexnn_top|$ACC_UNMASKED|ARRAY_ROWS=5 ARRAY_COLS=5"
"acc_arr_masked|flexnn_top_arr_masked|$ACC_ARR|ARRAY_ROWS=5 ARRAY_COLS=5"
"acc_rq_masked|flexnn_top_rq_masked|$ACC_RQ|ARRAY_ROWS=5 ARRAY_COLS=5"
"acc_both_masked|flexnn_top_protected|$ACC_BOTH|ARRAY_ROWS=5 ARRAY_COLS=5"
)
