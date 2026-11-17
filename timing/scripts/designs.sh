# Design for the timing check (timing/).
# Format: name | top module | RTL files (repo-relative) | parameter overrides
#
# The complete accelerator with the masked array and the masked requantizer, from
# protected_designs/complete_accelerator, with its RTL defaults: 5x5 array, WAVES=4,
# ACCW=19, MW=16, BW=32, DOM_REG=1, registered I/O; NRQ=1 (one shared masked
# requantizer core).

X=protected_designs/complete_accelerator

ACC_COMMON="$X/global_buffer.sv $X/sram_2p.sv $X/load_controller.sv $X/scratchpad.sv $X/address_generator.sv $X/multiplier.sv $X/activation_unit.sv $X/maxpool_unit.sv $X/bias_scale.sv"
ACC_BOTH="$ACC_COMMON $X/systolic_array_wmask_shared.sv $X/systolic_array_wmask_shares.sv $X/psum_accum_masked.sv $X/masking_gadgets.sv $X/requantize_masked.sv $X/rq_share_server.sv $X/top_protected.sv"

DESIGNS=(
"acc_both_masked_nrq1|flexnn_top_protected|$ACC_BOTH|NRQ=1"
)
