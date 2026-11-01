//=====================================================================
// masked_tail.sv -- one output column of the masked non-linear tail:
//   acc shares -> requantize_masked -> activation_masked -> maxpool_masked
// Declassification points (deliberate, documented):
//   * sat_out  : XOR of the requantize saturation shares, at requantize output
//   * y_out    : XOR of the final maxpool shares  -> goes to the OF scratchpad
// Everything between acc0/acc1 and these XORs exists only as shares.
// mask_en = 0 forces the fresh-mask bus to ZERO: the gadgets collapse to the
// unmasked function (positive control for leakage evaluation); results are
// unchanged.
//=====================================================================
module masked_tail #(
    parameter N    = 8,
    parameter ACCW = 32,
    parameter MW   = 32,
    parameter SW   = 6,
    parameter CW   = 5,
    parameter [63:0] SEED = 64'd1
) (
    input  wire              clk,
    input  wire              reset_n,
    input  wire              mask_en,
    input  wire              valid_in,
    input  wire [ACCW-1:0]   acc0_in, acc1_in,
    input  wire [ACCW-1:0]   bias_in,
    input  wire [MW-1:0]     m0_in,
    input  wire [SW-1:0]     shift_in,
    input  wire [1:0]        act_mode,
    input  wire [N-1:0]      clamp_high,
    input  wire [2:0]        leaky_shift,
    input  wire [CW-1:0]     win_len,
    output wire              rq_valid,
    output wire              sat_out,
    output wire              valid_out,
    output wire [N-1:0]      y_out
);
    localparam PW    = ACCW + MW;
    localparam R_RQ  = masked_pkg::rq_rnd(ACCW, PW, N);
    localparam R_ACT = masked_pkg::act_rnd(N);
    localparam R_MP  = masked_pkg::mp_rnd(N, CW);
    localparam R_TOT = R_RQ + R_ACT + R_MP;

    wire [R_TOT-1:0] rnd_raw, rnd;
    mask_prng_bus #(.W(R_TOT), .SEED(SEED)) u_prng (.clk(clk), .reset_n(reset_n), .rnd(rnd_raw));
    assign rnd = mask_en ? rnd_raw : {R_TOT{1'b0}};

    wire [N-1:0] q0, q1;
    wire         s0, s1;
    requantize_masked #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_rq (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .acc0_in(acc0_in), .acc1_in(acc1_in), .bias_in(bias_in), .m0_in(m0_in), .shift_in(shift_in),
        .rnd(rnd[0 +: R_RQ]), .valid_out(rq_valid),
        .q0_out(q0), .q1_out(q1), .sat0_out(s0), .sat1_out(s1));
    assign sat_out = s0 ^ s1;                                   // declassify status flag

    wire         a_valid;
    wire [N-1:0] a0, a1;
    activation_masked #(.N(N)) u_act (
        .clk(clk), .reset_n(reset_n), .mode(act_mode), .valid_in(rq_valid),
        .x0(q0), .x1(q1), .clamp_high(clamp_high), .leaky_shift(leaky_shift),
        .rnd(rnd[R_RQ +: R_ACT]), .valid_out(a_valid), .y0(a0), .y1(a1));

    wire [N-1:0] m0, m1;
    maxpool_masked #(.N(N), .CW(CW)) u_mp (
        .clk(clk), .reset_n(reset_n), .valid_in(a_valid), .win_len(win_len),
        .x0(a0), .x1(a1), .rnd(rnd[R_RQ + R_ACT +: R_MP]), .valid_out(valid_out), .y0(m0), .y1(m1));
    assign y_out = m0 ^ m1;                                     // declassify layer output
endmodule
