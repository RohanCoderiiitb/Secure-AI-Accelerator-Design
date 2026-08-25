`timescale 1ns/1ps
//=====================================================================
// tb_tvla_mult.v -- TVLA dataset generation for the Baugh-Wooley
//                   signed array multiplier.
//
// The bare BW multiplier is purely combinational, so a Hamming-Distance
// register model is undefined for it. The DUT is therefore a minimal
// registered wrapper: operands are latched, the BW array evaluates, the
// product is latched. That is exactly the sequential envelope the
// multiplier sees inside a PE, so the leakage model transfers.
//
// Only the wrapper scope is dumped -- stimulus registers, the group
// schedule and the PRNG state never enter the VCD.
//=====================================================================

module mult_dut #(
    parameter N = 8
)(
    input  wire                  clk,
    input  wire                  reset_n,
    input  wire                  en,
    input  wire signed [N-1:0]   x_in,
    input  wire signed [N-1:0]   y_in,
    output reg  signed [2*N-1:0] p_out
);
    reg  signed [N-1:0]   x_r, y_r;
    wire        [2*N-1:0] p;

    (* dont_touch = "yes" *) (* use_dsp = "no" *)
    baugh_wooley_multiplier #(.N(N)) u_mul (.x(x_r), .y(y_r), .p(p));

    always @(posedge clk) begin
        if (!reset_n) begin
            x_r   <= {N{1'b0}};
            y_r   <= {N{1'b0}};
            p_out <= {(2*N){1'b0}};
        end else if (en) begin
            x_r   <= x_in;
            y_r   <= y_in;
            p_out <= p;          // product of the PREVIOUS operand pair
        end
    end
endmodule


module tb_tvla_mult;

    localparam N      = 8;
    localparam real CLK_NS = 10.0;

    // Per-trace structure:
    //   FLUSH   quiet cycles (zero operands), untriggered, so every trace
    //           starts the window from an identical pipeline state
    //   OPS     operand pairs applied inside the window
    //   +1      one extra cycle to clock the last product into p_out
    localparam OPS     = 4;
    localparam FLUSH   = 3;
    localparam CAPTURE = OPS + 1;

    reg                   clk = 1'b0;
    reg                   reset_n, en;
    reg  signed [N-1:0]   x_in, y_in;
    wire signed [2*N-1:0] p_out;

    mult_dut #(.N(N)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en),
        .x_in(x_in), .y_in(y_in), .p_out(p_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    // Fixed-population operands. Drawn once from the seeded PRNG, held
    // for the whole run. These play the role of the fixed plaintext.
    reg signed [N-1:0] fix_x [0:OPS-1];
    reg signed [N-1:0] fix_y [0:OPS-1];

    integer t, k;
    reg grp, eff;
    reg signed [N-1:0] rx, ry;

    initial begin
        sca_get_config("mult");

        for (k = 0; k < OPS; k = k + 1) begin
            fix_x[k] = rand_i8(0);
            fix_y[k] = rand_i8(0);
        end

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: DUT only

        sca_open_meta("mult_dut", CLK_NS, CAPTURE);

        // Reset. These cycles are never inside a trace window, so the
        // X-propagation transients here cannot reach the analysis.
        reset_n = 1'b0; en = 1'b0;
        x_in = {N{1'b0}}; y_in = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush (untriggered) ----
            @(negedge clk);
            en = 1'b1; x_in = {N{1'b0}}; y_in = {N{1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < OPS; k = k + 1) begin
                @(negedge clk);          // drive off the negedge (see note)
                // R5: always draw, even for the fixed group.
                rx = rand_i8(0);
                ry = rand_i8(0);
                if (!eff) begin rx = fix_x[k]; ry = fix_y[k]; end

                if (TVLA_TARGET == "act") begin
                    x_in = rx;       y_in = fix_y[k];   // vary act, hold the secret weight
                end else if (TVLA_TARGET == "wt") begin
                    x_in = fix_x[k]; y_in = ry;         // vary weight, hold act
                end else begin
                    x_in = rx;       y_in = ry;         // "both"
                end

                @(posedge clk);
                if (k == 0) sca_trace_begin;
            end

            @(negedge clk);
            x_in = {N{1'b0}}; y_in = {N{1'b0}};
            @(posedge clk);              // drain p_out
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        en = 1'b0;
        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
