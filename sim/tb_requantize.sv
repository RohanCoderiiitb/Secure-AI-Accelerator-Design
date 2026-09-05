`timescale 1ns/1ps
`include "./sim/nn_params.vh"

module tb_requantize;

    parameter ACCW = 32;
    parameter N    = 8;
    parameter MW   = 32;
    parameter SW   = 6;
    localparam NRQ = `NN_NRQ;
    localparam LAT = 2;

    reg                   clk = 1'b0;
    reg                   reset_n;        // Updated to match your port name
    reg                   valid_in;
    reg signed [ACCW-1:0] acc_in, bias_in;
    reg signed [MW-1:0]   m0_in;
    reg        [SW-1:0]   shift_in;
    wire                  valid_out;
    wire signed [N-1:0]   q_out;
    wire                  sat_out;

    always #5 clk = ~clk;

    // DUT Instantiation with updated port mapping
    requantize #(.ACCW(ACCW), .N(N), .MW(MW), .SW(SW)) dut (
        .clk(clk), 
        .reset_n(reset_n),                 // Updated mapping
        .valid_in(valid_in),
        .acc_in(acc_in), 
        .bias_in(bias_in), 
        .m0_in(m0_in), 
        .shift_in(shift_in),
        .valid_out(valid_out), 
        .q_out(q_out), 
        .sat_out(sat_out)
    );

    // ---------------- Python vectors --------------------------------------
    reg signed [31:0] RQ_ACC  [0:NRQ-1];
    reg signed [31:0] RQ_BIAS [0:NRQ-1];
    reg signed [31:0] RQ_M0   [0:NRQ-1];
    reg        [7:0]  RQ_SH   [0:NRQ-1];
    reg signed [7:0]  RQ_EXP  [0:NRQ-1];
    reg        [7:0]  RQ_SAT  [0:NRQ-1];

    reg signed [N-1:0] exp_q  [0:LAT];
    reg                exp_s  [0:LAT];
    reg                exp_v  [0:LAT];
    integer            exp_i  [0:LAT];

    integer errors = 0, checks = 0, nsat = 0;
    integer i, d;

    task push_expect;
        input                v;
        input signed [N-1:0] q;
        input                s;
        input integer        idx;
        integer p;
        begin
            for (p = LAT; p > 0; p = p - 1) begin
                exp_v[p] = exp_v[p-1];
                exp_q[p] = exp_q[p-1];
                exp_s[p] = exp_s[p-1];
                exp_i[p] = exp_i[p-1];
            end
            exp_v[0] = v; exp_q[0] = q; exp_s[0] = s; exp_i[0] = idx;
        end
    endtask

    task check_out;
        begin
            if (valid_out !== exp_v[LAT]) begin
                errors = errors + 1;
                if (errors < 12)
                    $display("  FAIL valid: got %0b expected %0b @%0t",
                             valid_out, exp_v[LAT], $time);
            end
            if (exp_v[LAT]) begin
                checks = checks + 1;
                if (q_out !== exp_q[LAT] || sat_out !== exp_s[LAT]) begin
                    errors = errors + 1;
                    if (errors < 12)
                        $display("  FAIL vec %0d: q=%0d/%0d sat=%0b/%0b",
                                 exp_i[LAT], q_out, exp_q[LAT], sat_out, exp_s[LAT]);
                end
            end
        end
    endtask

    task drain;
        integer p;
        begin
            for (p = 0; p < LAT; p = p + 1) begin
                @(negedge clk);
                valid_in = 1'b0;
                push_expect(1'b0, 8'sd0, 1'b0, -1);
                @(posedge clk); #1;
                check_out;
            end
        end
    endtask

    initial begin
        $readmemh({`NN_DIR, "./sim/rq_acc.hex"},   RQ_ACC);
        $readmemh({`NN_DIR, "./sim/rq_bias.hex"},  RQ_BIAS);
        $readmemh({`NN_DIR, "./sim/rq_m0.hex"},    RQ_M0);
        $readmemh({`NN_DIR, "./sim/rq_shift.hex"}, RQ_SH);
        $readmemh({`NN_DIR, "./sim/rq_exp.hex"},   RQ_EXP);
        $readmemh({`NN_DIR, "./sim/rq_sat.hex"},   RQ_SAT);

        for (d = 0; d <= LAT; d = d + 1) begin
            exp_v[d] = 1'b0; exp_q[d] = 0; exp_s[d] = 1'b0; exp_i[d] = -1;
        end

        reset_n = 1'b0; valid_in = 1'b0;  // Updated reset
        acc_in = 0; bias_in = 0; m0_in = 0; shift_in = 0;
        repeat (3) @(negedge clk);

        // ---- T5 reset ------------------------------------------------
        @(posedge clk); #1;
        checks = checks + 1;
        if (valid_out !== 1'b0 || q_out !== 0 || sat_out !== 1'b0) begin
            errors = errors + 1;
            $display("  FAIL reset state");
        end
        reset_n = 1'b1;  // Updated reset

        // ---- T1/T2 back-to-back Python vectors -----------------------
        $display("T1/T2: %0d Python cross-check vectors, back to back...", NRQ);
        for (i = 0; i < NRQ; i = i + 1) begin
            @(negedge clk);
            valid_in = 1'b1;
            acc_in   = RQ_ACC[i];
            bias_in  = RQ_BIAS[i];
            m0_in    = RQ_M0[i];
            shift_in = RQ_SH[i][SW-1:0];
            push_expect(1'b1, RQ_EXP[i], RQ_SAT[i][0], i);
            if (RQ_SAT[i][0]) nsat = nsat + 1;
            @(posedge clk); #1;
            check_out;
        end
        drain;
        $display("  after %0d vectors: %0d checks, %0d errors (%0d saturating)",
                 NRQ, checks, errors, nsat);

        // ---- T4 valid gating: bubbles must not produce output ---------
        $display("T4: valid gating with random bubbles...");
        for (i = 0; i < NRQ; i = i + 1) begin
            @(negedge clk);
            if (i % 3 == 0) begin
                valid_in = 1'b0;
                acc_in   = 32'hDEADBEEF;         
                bias_in  = 32'h12345678;
                push_expect(1'b0, 8'sd0, 1'b0, -1);
            end else begin
                valid_in = 1'b1;
                acc_in   = RQ_ACC[i];
                bias_in  = RQ_BIAS[i];
                m0_in    = RQ_M0[i];
                shift_in = RQ_SH[i][SW-1:0];
                push_expect(1'b1, RQ_EXP[i], RQ_SAT[i][0], i);
            end
            @(posedge clk); #1;
            check_out;
        end
        drain;

        $display("----------------------------------------------------------");
        if (errors == 0) $display("tb_requantize: PASS  (%0d checks vs Python)", checks);
        else             $display("tb_requantize: FAIL  (%0d/%0d errors)", errors, checks);
        $display("----------------------------------------------------------");
        $finish;
    end

endmodule