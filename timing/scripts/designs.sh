# Design matrix for the timing-closure / area flow (timing/).
# Format: name | top module | RTL files (repo-relative) | parameter overrides
#
# All four complete-accelerator builds come from protected_designs/complete_accelerator.
# Their RTL defaults are the evaluated configuration: 5x5 array, WAVES=4,
# ACCW=19 (= 2N + clog2(5), the share width of the masked datapath, in every
# build), MW=16, BW=32, DOM_REG=1, registered I/O. Only NRQ (number of
# shared masked requantizer cores) is overridden here.
#
# pre_* : the RTL before the timing / area changes (the zip copy in
# complete_accelerator/complete_accelerator), with the parameters the old
# area flow used. Only used for the "before" hierarchical path report.

X=protected_designs/complete_accelerator
O=complete_accelerator/complete_accelerator

ACC_COMMON="$X/global_buffer.sv $X/sram_2p.sv $X/load_controller.sv $X/scratchpad.sv $X/address_generator.sv $X/multiplier.sv $X/activation_unit.sv $X/maxpool_unit.sv $X/bias_scale.sv"
ACC_UNMASKED="$ACC_COMMON $X/processing_element.sv $X/systolic_array.sv $X/partial_sum_accumulators.sv $X/requantization_block.sv $X/top.sv"
ACC_BOTH="$ACC_COMMON $X/systolic_array_wmask_shared.sv $X/systolic_array_wmask_shares.sv $X/psum_accum_masked.sv $X/masking_gadgets.sv $X/requantize_masked.sv $X/rq_share_server.sv $X/top_protected.sv"
ACC_ARR="$ACC_COMMON $X/systolic_array_wmask_shared.sv $X/partial_sum_accumulators.sv $X/requantization_block.sv $X/top_protected_arr_only.sv"
ACC_RQ="$ACC_COMMON $X/processing_element.sv $X/systolic_array.sv $X/partial_sum_accumulators.sv $X/masking_gadgets.sv $X/requantize_masked.sv $X/rq_share_server.sv $X/top_protected_rq_only.sv"

PRE_COMMON="$O/global_buffer.sv $O/sram_2p.sv $O/load_controller.sv $O/scratchpad.sv $O/address_generator.sv $O/multiplier.sv $O/activation_unit.sv $O/maxpool_unit.sv"
PRE_UNMASKED="$PRE_COMMON $O/processing_element.sv $O/systolic_array.sv $O/partial_sum_accumulators.sv $O/requantization_block.sv $O/top.sv"
PRE_BOTH="$PRE_COMMON $O/systolic_array_wmask_shared.sv $O/systolic_array_wmask_shares.sv $O/psum_accum_masked.sv $O/masking_gadgets.sv $O/requantize_masked.sv $O/top_protected.sv"
PRE_ARR="$PRE_COMMON $O/systolic_array_wmask_shared.sv $O/partial_sum_accumulators.sv $O/requantization_block.sv $O/top_protected_arr_only.sv"
PRE_RQ="$PRE_COMMON $O/processing_element.sv $O/systolic_array.sv $O/partial_sum_accumulators.sv $O/masking_gadgets.sv $O/requantize_masked.sv $O/top_protected_rq_only.sv"

DESIGNS=(
"acc_unmasked|flexnn_top|$ACC_UNMASKED|"
"acc_arr_masked|flexnn_top_arr_masked|$ACC_ARR|"
"acc_rq_masked_nrq1|flexnn_top_rq_masked|$ACC_RQ|NRQ=1"
"acc_rq_masked_nrq2|flexnn_top_rq_masked|$ACC_RQ|NRQ=2"
"acc_rq_masked_nrq5|flexnn_top_rq_masked|$ACC_RQ|NRQ=5"
"acc_both_masked_nrq1|flexnn_top_protected|$ACC_BOTH|NRQ=1"
"acc_both_masked_nrq2|flexnn_top_protected|$ACC_BOTH|NRQ=2"
"acc_both_masked_nrq5|flexnn_top_protected|$ACC_BOTH|NRQ=5"
"pre_acc_unmasked|flexnn_top|$PRE_UNMASKED|ARRAY_ROWS=5 ARRAY_COLS=5 ACCW=19"
"pre_acc_arr_masked|flexnn_top_arr_masked|$PRE_ARR|ARRAY_ROWS=5 ARRAY_COLS=5"
"pre_acc_rq_masked|flexnn_top_rq_masked|$PRE_RQ|ARRAY_ROWS=5 ARRAY_COLS=5"
"pre_acc_both_masked|flexnn_top_protected|$PRE_BOTH|ARRAY_ROWS=5 ARRAY_COLS=5"
)
