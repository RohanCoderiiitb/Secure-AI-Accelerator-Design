`timescale 1ns/1ps
//=====================================================================
// tb_tvla_requantize_masked.sv -- TVLA dataset generation for the
//                                  stand-alone masked requantizer
//                                  (complete_accelerator/requantize_masked.sv)
//
// Masked counterpart of tb_tvla_requantize.sv, same experiment:
//   * fixed/random contrast on acc_in (the accumulated dot product)
//   * OPS = 8 inputs per trace, back to back
//   * bias = 137, m0 = 0x4E8B1C00 (~0.618 Q0.31), shift = 9, held
//     identical in both groups (public per-layer constants)
//   * acc drawn in about +-2^17, as in tb_tvla_requantize.sv
// Differences:
//   * acc enters as two arithmetic shares, x0 random and x1 = acc - x0
//     (mod 2^XW), drawn fresh for EVERY value: the FIXED group has a
//     fixed VALUE, never fixed shares
//   * the random-number bank sits OUTSIDE the dumped scope (only u_dut
//     is dumped, as in the other masked benches)
//   * the capture window covers the deeper pipeline (OPS + latency)
//
// TVLA_TARGET: "act" only (m0 is public in the masked design).
// Plusargs: +NTRACES +SEED +MODE=tvla|null +TVLA_TARGET +TAG +OUTDIR
//           +MASK_OFF=1  sanity control: x0 = 0 (acc in the clear on x1)
//                        and zero randomness -> TVLA MUST detect
//=====================================================================
module tb_tvla_requantize_masked;

    localparam N    = 8;
    localparam ACCW = 32;
    localparam MW   = 32;
    localparam SW   = 6;
    localparam XW   = 19;                 // covers acc +-2^17 (+ bias) as a signed share sum
    localparam RW   = XW + MW + 2;
    parameter  DOM_REG = 1;

    `include "msk_counts.vh"
    localparam RND_W = mskf_rq_rnd(XW, RW);
    localparam LAT   = mskf_rq_lat(XW, RW, DOM_REG);

    localparam real CLK_NS = 10.0;

    localparam OPS     = 8;               // inputs per trace
    localparam DRAIN   = LAT;             // pipeline depth
    localparam CAPTURE = OPS + DRAIN;
    localparam FLUSH   = DRAIN + 2;

    reg                    clk = 1'b0;
    reg                    reset_n, valid_in;
    reg  signed [ACCW-1:0] bias_in;
    reg  signed [MW-1:0]   m0_in;
    reg  [SW-1:0]          shift_in;
    reg  [XW-1:0]          x0_in, x1_in;
    wire                   valid_out, sat0, sat1;
    wire [N-1:0]           q0, q1;

    // ---------------- randomness: outside the dumped scope ----------------
    integer MASK_OFF_I;
    reg     mask_en = 1'b1;
    wire [RND_W-1:0] rnd_raw, rnd;
    rng_bank #(.W(RND_W), .SEED(64'h5EED_0000_0000_0001)) u_rng (
        .clk(clk), .reset_n(reset_n), .en(1'b1), .rnd(rnd_raw));
    assign rnd = mask_en ? rnd_raw : {RND_W{1'b0}};

    (* dont_touch = "yes" *)
    requantize_masked #(.N(N), .XW(XW), .BW(ACCW), .MW(MW), .SW(SW), .DOM_REG(DOM_REG)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .x0_in(x0_in), .x1_in(x1_in),
        .bias_in(bias_in), .m0_in(m0_in), .shift_in(shift_in), .rnd_in(rnd),
        .valid_out(valid_out), .q0_out(q0), .q1_out(q1), .sat0_out(sat0), .sat1_out(sat1));

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [ACCW-1:0] fix_acc [0:OPS-1];

    // same accumulator distribution as tb_tvla_requantize.sv
    function signed [ACCW-1:0] rand_acc(input integer dummy);
        reg [63:0] r;
        begin
            r        = xs64s(0);
            rand_acc = $signed({{(ACCW-18){r[17]}}, r[17:0]});
        end
    endfunction

    integer t, k;
    reg grp, eff;
    reg signed [ACCW-1:0] ra;
    reg [63:0] rs;

    // fresh shares for every value
    task drive_value(input signed [ACCW-1:0] a);
        reg [XW-1:0] ax;
        begin
            ax    = a[XW-1:0];
            rs    = xs64s(0);
            x0_in = mask_en ? rs[XW-1:0] : {XW{1'b0}};
            x1_in = ax - x0_in;
        end
    endtask

    initial begin
        sca_get_config("requantize_masked");
        if (TVLA_TARGET != "act") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- use 'act' (m0 is public in the masked design)", TVLA_TARGET);
            $finish;
        end
        if (!$value$plusargs("MASK_OFF=%d", MASK_OFF_I)) MASK_OFF_I = 0;
        mask_en = (MASK_OFF_I == 0);
        $display("[MASK] mask_en=%0d  XW=%0d  latency=%0d  capture=%0d  random bits/cycle=%0d",
                 mask_en, XW, LAT, CAPTURE, RND_W);

        // public per-layer constants, identical in both groups
        bias_in  = 32'sd137;
        m0_in    = 32'sh4E8B_1C00;
        shift_in = 6'd9;

        for (k = 0; k < OPS; k = k + 1) fix_acc[k] = rand_acc(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                       // SCOPE-LIMITED: masked requantizer only
        sca_open_meta("requantize_masked", CLK_NS, CAPTURE);

        reset_n = 1'b0; valid_in = 1'b0; x0_in = {XW{1'b0}}; x1_in = {XW{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (LAT + 6) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush pipeline, untriggered ----
            @(negedge clk);
            valid_in = 1'b0; drive_value(0);
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < CAPTURE; k = k + 1) begin
                @(negedge clk);
                if (k < OPS) begin
                    ra = rand_acc(0);                // R5: always draw for both groups
                    if (!eff) ra = fix_acc[k];
                    drive_value(ra);
                    valid_in = 1'b1;
                end else begin
                    valid_in = 1'b0;                 // drain
                    drive_value(0);
                end
                @(posedge clk);
                if (k == 0) sca_trace_begin;
            end
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
