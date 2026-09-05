// Scratchpad: one localized SRAM sitting between the Global Buffer and the
// systolic array's operand ports.
//
// How NUM_SPADS / PE_PER_SPAD map onto this design (decided by the actual
// timing of the systolic array in systolic_array.v / processing_element.v,
// per the task's instruction to infer structure from the RTL rather than
// assume it):
//
//   - Activation side: array row r consumes one NEW activation element per
//     cycle, and DIFFERENT rows are reading DIFFERENT addresses on the same
//     cycle (input skew - see address_generator.sv). That means the
//     activation scratchpad MUST be split into ARRAY_ROWS independent
//     memories, one per row, each feeding the ARRAY_COLS PEs in that row
//     (broadcast eastward one column per cycle by the array itself).
//     => NUM_SPADS = ARRAY_ROWS, PE_PER_SPAD = ARRAY_COLS, one scratchpad
//        instance per row, instantiated in accelerator_top.
//
//   - Weight side: only ONE weight row-vector (wt_flat, ARRAY_COLS*N bits)
//     is fed per cycle regardless of array size (weights load via a single
//     systolic shift down the rows). A single scratchpad, ARRAY_ROWS deep
//     and ARRAY_COLS*N wide, is sufficient. Two banks of this scratchpad
//     are instantiated for double buffering (see systolic_controller.sv).
//     => NUM_SPADS = 2 (double-buffer banks), PE_PER_SPAD = full array.
//
//   - Output side: in steady state ALL ARRAY_COLS columns present a valid
//     result on the SAME cycle, each for a DIFFERENT output wave (because
//     columns are staggered in time relative to each other - see
//     address_generator.sv derivation). That requires ARRAY_COLS
//     independent write ports simultaneously, so the output scratchpad is
//     also split into ARRAY_COLS independent memories, one per column.
//     => NUM_SPADS = ARRAY_COLS, one scratchpad instance per column.
//
// This module itself is just the generic memory instantiated NUM_SPADS
// times by accelerator_top; it doesn't know which role it plays.
module scratchpad #(
    parameter DATA_WIDTH = 8,
    parameter SPAD_DEPTH = 64,
    parameter ADDR_WIDTH = (SPAD_DEPTH <= 1) ? 1 : $clog2(SPAD_DEPTH)
) (
    input  wire                     clk,

    input  wire                     wr_en,
    input  wire [ADDR_WIDTH-1:0]    wr_addr,
    input  wire [DATA_WIDTH-1:0]    wr_data,

    input  wire                     rd_en,
    input  wire [ADDR_WIDTH-1:0]    rd_addr,
    output wire [DATA_WIDTH-1:0]    rd_data
);
    sram_2p #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (SPAD_DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_mem (
        .clk     (clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );
endmodule
