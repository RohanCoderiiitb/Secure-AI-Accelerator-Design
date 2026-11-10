//=====================================================================
// requantize_shuffled.sv -- unprotected TFLite requantizer + SHUFFLING
//
// Same function as requantize (source/requantization_block.sv):
//   q = clamp( ((acc + bias) * m0 + round) >>> shift , -128, 127 )
// The plain `requantize` core is reused unchanged. Around it:
//
//   FILL     incoming values are collected into a batch of D slots
//            (two banks, ping-pong, so a new batch fills while the
//            previous one is processed)
//   ISSUE    the batch is fed to the core in a fresh RANDOM order every
//            batch: inside-out Fisher-Yates, one step per cycle
//              j   = (rnd * remaining) >> RW      uniform in [0, remaining)
//              out = list[j];  list[j] = list[remaining-1]
//            (bias of the scaling is <= D / 2^RW, negligible for RW = 16)
//   REORDER  INORDER = 1: results are put back in arrival order and
//            streamed out one per cycle (drop-in replacement for
//            requantize: same ports + flush / shuf_en / rnd / idx / busy)
//            INORDER = 0: results leave in the shuffled order with their
//            slot index on idx_out (the consumer writes by address)
//
// A batch closes when D values have arrived, or on flush_in (partial
// batch, e.g. the last values of a layer; values on the flush cycle are
// included). bias / m0 / shift are captured with the first value of each
// batch, so they may change between batches.
//
// Throughput: one value per cycle with back-to-back full batches.
// Latency, first value in -> first result out, counted like
// tb_requant_latency (requantize = 3), full batch:
//   INORDER = 1 : 2*D + 4 cycles   (D = 8 -> 20)
//   INORDER = 0 :   D + 4 + k      (k = random issue position, 0..D-1;
//                                   D = 8 -> 12 for the first result)
// Rule: a bank is refilled only after it has been issued. Full batches
// always satisfy this; after a flush, do not flush again within D cycles
// (the overflow flag reports a violation in simulation).
//
// shuf_en = 0 : identity order (sanity control for TVLA, same hardware)
// rnd_in      : RW fresh random bits every cycle
//
// Two modules in this file:
//   requantize_shuffled      the shuffler, random bits come in on rnd_in
//   requantize_shuffled_top  the same + its own generator (shuf_rng):
//                            this is the version for the chip and for TVLA
//=====================================================================
module requantize_shuffled #(
    parameter N       = 8,
    parameter ACCW    = 32,
    parameter MW      = 32,
    parameter SW      = 6,
    parameter D       = 8,      // batch size (power of two, >= 2)
    parameter RW      = 16,     // random bits per cycle
    parameter INORDER = 1
)(
    input  wire                   clk,
    input  wire                   reset_n,
    input  wire                   valid_in,
    input  wire signed [ACCW-1:0] acc_in,
    input  wire signed [ACCW-1:0] bias_in,
    input  wire signed [MW-1:0]   m0_in,
    input  wire        [SW-1:0]   shift_in,
    input  wire                   flush_in,
    input  wire                   shuf_en,
    input  wire        [RW-1:0]   rnd_in,
    output reg                    valid_out,
    output reg         [N-1:0]    q_out,
    output reg                    sat_out,
    output reg         [$clog2(D)-1:0] idx_out,   // slot in the batch (INORDER = 0)
    output wire                   busy,
    output reg                    overflow        // rule violated (simulation aid)
);
    localparam AW = $clog2(D);
    localparam CW = $clog2(D + 1);

    // ------------------------- storage -------------------------
    reg signed [ACCW-1:0] ibuf  [0:2*D-1];      // input values, {bank, slot}
    reg        [AW-1:0]   lst   [0:2*D-1];      // remaining slots per bank
    reg signed [ACCW-1:0] bias_b [0:1];
    reg signed [MW-1:0]   m0_b   [0:1];
    reg        [SW-1:0]   sh_b   [0:1];
    reg        [CW-1:0]   rem    [0:1];         // values still to issue per bank
    reg        [CW-1:0]   nb     [0:1];         // batch size per bank

    reg            fb;                          // bank being filled
    reg [CW-1:0]   fcnt;                        // values in the fill bank
    reg            ib;                          // bank being issued
    reg [CW-1:0]   iseq;                        // issue position (shuf_en = 0)

    // ------------------------- fill -------------------------
    wire [CW-1:0] fnext  = fcnt + (valid_in ? 1'b1 : 1'b0);
    wire          fclose = (fnext == D) || (flush_in && fnext != 0);

    // ------------------------- issue -------------------------
    wire              iact  = (rem[ib] != 0);
    wire [RW+CW-1:0]  jprod = rnd_in * rem[ib];
    wire [AW-1:0]     jr    = jprod[RW +: AW];              // floor(rnd*rem / 2^RW) < rem
    wire [AW-1:0]     jsel  = shuf_en ? jr : {AW{1'b0}};
    wire [AW-1:0]     idx   = shuf_en ? lst[ib*D + jsel] : iseq[AW-1:0];
    wire [AW-1:0]     ilast = rem[ib] - 1'b1;
    wire              last  = (rem[ib] == 1);

    // ------------------------- core -------------------------
    wire          c_vo, c_sat;
    wire [N-1:0]  c_q;
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_core (
        .clk(clk), .reset_n(reset_n), .valid_in(iact),
        .acc_in(ibuf[ib*D + idx]), .bias_in(bias_b[ib]), .m0_in(m0_b[ib]), .shift_in(sh_b[ib]),
        .valid_out(c_vo), .q_out(c_q), .sat_out(c_sat));

    // tag pipeline aligned with the core (valid_in -> valid_out = 3 edges)
    reg [AW-1:0] t_idx [0:2];
    reg          t_bk  [0:2];
    reg          t_lst [0:2];

    // ------------------------- reorder (INORDER = 1) -------------------------
    reg [N:0]    obuf [0:2*D-1];                // {sat, q}
    reg [CW-1:0] rcnt [0:1];                    // results received per bank
    reg [CW-1:0] orem [0:1];                    // results still to stream per bank
    reg [CW-1:0] olen [0:1];
    reg          ob;                            // bank being streamed
    wire [CW-1:0] opos = olen[ob] - orem[ob];

    assign busy = (fcnt != 0) || (rem[0] != 0) || (rem[1] != 0) || c_vo ||
                  t_lst[0] | t_lst[1] | t_lst[2] | (rcnt[0] != 0) | (rcnt[1] != 0) |
                  (orem[0] != 0) | (orem[1] != 0) | valid_in;

    integer i;
    always @(posedge clk) begin
        if (!reset_n) begin
            fb <= 1'b0; fcnt <= 0; ib <= 1'b0; iseq <= 0; ob <= 1'b0;
            rem[0] <= 0; rem[1] <= 0; nb[0] <= 0; nb[1] <= 0;
            rcnt[0] <= 0; rcnt[1] <= 0; orem[0] <= 0; orem[1] <= 0; olen[0] <= 0; olen[1] <= 0;
            for (i = 0; i < 3; i = i + 1) begin t_idx[i] <= 0; t_bk[i] <= 0; t_lst[i] <= 0; end
            valid_out <= 1'b0; q_out <= 0; sat_out <= 1'b0; idx_out <= 0; overflow <= 1'b0;
        end else begin
            // ---- issue: one Fisher-Yates step per cycle ----
            if (iact) begin
                lst[ib*D + jsel] <= lst[ib*D + ilast];
                rem[ib]          <= rem[ib] - 1'b1;
                iseq             <= last ? 0 : iseq + 1'b1;
                if (last) ib <= ~ib;
            end
            t_idx[0] <= idx;      t_bk[0] <= ib;      t_lst[0] <= iact & last;
            t_idx[1] <= t_idx[0]; t_bk[1] <= t_bk[0]; t_lst[1] <= t_lst[0];
            t_idx[2] <= t_idx[1]; t_bk[2] <= t_bk[1]; t_lst[2] <= t_lst[1];

            // ---- fill ----
            if (valid_in) begin
                if (rem[fb] != 0) overflow <= 1'b1;               // bank not issued yet
                ibuf[fb*D + fcnt] <= acc_in;
                if (fcnt == 0) begin
                    bias_b[fb] <= bias_in; m0_b[fb] <= m0_in; sh_b[fb] <= shift_in;
                end
            end
            if (fclose) begin
                rem[fb] <= fnext;  nb[fb] <= fnext;
                for (i = 0; i < D; i = i + 1) lst[fb*D + i] <= i;  // identity list
                fb   <= ~fb;
                fcnt <= 0;
            end else begin
                fcnt <= fnext;
            end

            // ---- results ----
            if (INORDER) begin
                if (c_vo) begin
                    obuf[t_bk[2]*D + t_idx[2]] <= {c_sat, c_q};
                    if (t_lst[2]) begin
                        rcnt[t_bk[2]] <= 0;
                        orem[t_bk[2]] <= rcnt[t_bk[2]] + 1'b1;
                        olen[t_bk[2]] <= rcnt[t_bk[2]] + 1'b1;
                    end else
                        rcnt[t_bk[2]] <= rcnt[t_bk[2]] + 1'b1;
                end
                // stream the oldest complete bank in arrival order
                if (orem[ob] != 0) begin
                    valid_out <= 1'b1;
                    {sat_out, q_out} <= obuf[ob*D + opos];
                    idx_out   <= opos[AW-1:0];
                    orem[ob]  <= orem[ob] - 1'b1;
                    if (orem[ob] == 1) ob <= ~ob;
                end else
                    valid_out <= 1'b0;
            end else begin
                valid_out <= c_vo;
                q_out     <= c_q;
                sat_out   <= c_sat;
                idx_out   <= t_idx[2];
            end
        end
    end
endmodule

//=====================================================================
// requantize_shuffled_top -- the shuffled requantizer WITH its own random
//                            number generator (what goes on the chip)
//
// Same ports as requantize_shuffled except rnd_in: the order is driven by
// the on-chip generator below, so a TVLA run that dumps this module also
// sees the generator's own switching.
// The generator only steps while the shuffler is busy (saves power when
// the requantizer is idle; `busy` depends only on when values arrive,
// never on their values).
//=====================================================================
module requantize_shuffled_top #(
    parameter N       = 8,
    parameter ACCW    = 32,
    parameter MW      = 32,
    parameter SW      = 6,
    parameter D       = 8,
    parameter RW      = 16,
    parameter INORDER = 1,
    parameter [63:0] SEED = 64'h9E37_79B9_7F4A_7C15
)(
    input  wire                   clk,
    input  wire                   reset_n,
    input  wire                   valid_in,
    input  wire signed [ACCW-1:0] acc_in,
    input  wire signed [ACCW-1:0] bias_in,
    input  wire signed [MW-1:0]   m0_in,
    input  wire        [SW-1:0]   shift_in,
    input  wire                   flush_in,
    input  wire                   shuf_en,
    output wire                   valid_out,
    output wire        [N-1:0]    q_out,
    output wire                   sat_out,
    output wire [$clog2(D)-1:0]   idx_out,
    output wire                   busy,
    output wire                   overflow
);
    wire [RW-1:0] rnd;
    shuf_rng #(.RW(RW), .SEED(SEED)) u_rng (
        .clk(clk), .reset_n(reset_n), .en(busy | valid_in), .rnd(rnd));

    requantize_shuffled #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .D(D), .RW(RW), .INORDER(INORDER)) u_shuf (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc_in),
        .bias_in(bias_in), .m0_in(m0_in), .shift_in(shift_in),
        .flush_in(flush_in), .shuf_en(shuf_en), .rnd_in(rnd),
        .valid_out(valid_out), .q_out(q_out), .sat_out(sat_out), .idx_out(idx_out),
        .busy(busy), .overflow(overflow));
endmodule

//=====================================================================
// shuf_rng -- xorshift64 pseudo-random generator, RW bits per step
// Good statistics, NOT cryptographically strong: an attacker who learns
// 64 consecutive output bits can predict the order. For silicon, swap in
// a cryptographic generator (e.g. Trivium) or a true RNG; the interface
// stays the same.
//=====================================================================
module shuf_rng #(
    parameter RW = 16,
    parameter [63:0] SEED = 64'h9E37_79B9_7F4A_7C15
)(
    input  wire          clk,
    input  wire          reset_n,
    input  wire          en,
    output wire [RW-1:0] rnd
);
    reg  [63:0] s;
    wire [63:0] s1 = s  ^ (s  << 13);
    wire [63:0] s2 = s1 ^ (s1 >> 7);
    wire [63:0] s3 = s2 ^ (s2 << 17);
    always @(posedge clk)
        if (!reset_n) s <= (SEED == 64'd0) ? 64'd1 : SEED;
        else if (en)  s <= s3;
    assign rnd = s[63 -: RW];
endmodule
