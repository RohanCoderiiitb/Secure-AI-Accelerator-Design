//=====================================================================
// mask_rng.sv -- SIMULATION-ONLY mask generator (xorshift64*)
//
// One instance per PE column. `advance` is wired to wt_load, so a fresh
// mask is drawn for every weight injected at the array's north boundary.
// r is combinational from the current state: during a wt_load pulse the
// splitter sees the PRE-advance value, the PE latches it at the clock
// edge, and the state advances at the same edge (non-blocking).
//
// NOT for silicon. A real design needs a TRNG (+ conditioner). The
// simulator-independent PRNG is used for the same reason sca_capture.vh
// uses it: reproducible leakage results across tools.
// Give every column a DIFFERENT SEED -- identical masks across columns
// would leak W_i - W_j (see phase1_design.tex, decision 4).
//=====================================================================
module mask_rng #(
    parameter W    = 32,                 // 1..64
    parameter [63:0] SEED = 64'd1
) (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         advance,
    output wire [W-1:0] r
);
    reg  [63:0] state;
    wire [63:0] x1 = state ^ (state >> 12);
    wire [63:0] x2 = x1    ^ (x1    << 25);
    wire [63:0] x3 = x2    ^ (x2    >> 27);
    wire [63:0] out64 = state * 64'd2685821657736338717;

    assign r = out64[63 -: W];           // upper bits are the best bits

    always @(posedge clk) begin
        if (!reset_n)      state <= 64'd88172645463325252 + SEED;
        else if (advance)  state <= x3;
    end
endmodule
