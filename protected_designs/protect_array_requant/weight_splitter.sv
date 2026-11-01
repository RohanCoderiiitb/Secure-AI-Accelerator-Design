//=====================================================================
// weight_splitter.sv -- plaintext INT8 weight -> two additive shares
//
//   w0 = mask_en ? r : 0
//   w1 = sext(W) - w0              (mod 2^SHARE_W)   =>  w0 + w1 == sext(W)
//
// Combinational. Sits at the array's NORTH boundary (one per column):
// weights shift down the column on every wt_load pulse, so both shares
// are created once here and then shift together. Keep this module (and
// mask_rng) OUTSIDE the dumped DUT scope, exactly like the baseline
// weight-load phase (rule R4).
//
// mask_en = 0 is the built-in POSITIVE CONTROL: w0 = 0, w1 = W, so the
// masked datapath degenerates to the unmasked function. A masked design
// that does NOT leak again with mask_en = 0 means the test bench is blind.
//
// Known residual (decision 3, Option P): the plaintext weight is present
// at this module's input and the subtractor's internal borrow chain is a
// joint function of W and r. This happens once per weight load, outside
// the compute window.
//=====================================================================
module weight_splitter #(
    parameter N        = 8,
    parameter SHARE_W  = 32,
    parameter COLS     = 1
) (
    input  wire                     mask_en,
    input  wire [COLS*N-1:0]        wt_flat,
    input  wire [COLS*SHARE_W-1:0]  r_flat,
    output wire [COLS*SHARE_W-1:0]  wt0_flat,
    output wire [COLS*SHARE_W-1:0]  wt1_flat
);
    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_col
            wire signed [N-1:0]  w   = wt_flat[c*N +: N];
            wire [SHARE_W-1:0]   we  = {{(SHARE_W-N){w[N-1]}}, w};
            wire [SHARE_W-1:0]   s0  = mask_en ? r_flat[c*SHARE_W +: SHARE_W]
                                               : {SHARE_W{1'b0}};
            assign wt0_flat[c*SHARE_W +: SHARE_W] = s0;
            assign wt1_flat[c*SHARE_W +: SHARE_W] = we - s0;
        end
    endgenerate
endmodule
