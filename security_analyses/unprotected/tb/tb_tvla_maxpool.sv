`timescale 1ns/1ps
//=====================================================================
// tb_tvla_maxpool.v -- TVLA dataset generation for the 1D maxpool unit.
//
// The maxpool unit is a sliding-window running-maximum machine:
//   r_max : running max register — updated every valid cycle
//   cnt   : window position counter
//   y_out : latched when cnt == win_len - 1
//
// Leakage surfaces:
//   r_max register: HD = popcount(next_max XOR r_max) — data-dependent
//                   whenever a new maximum is encountered
//   y_out register: HD on the window maximum, fires once per window
//   cnt register:   deterministic (same in both populations); contributes
//                   constant offset, not to the t-statistic
//
// Capture strategy:
//   Each trace covers WIN_LEN inputs — one complete pooling window.
//   The window produces exactly one y_out pulse at the last cycle.
//   DRAIN=1 cycle lets that y_out register update be captured.
//
//   Fixed population: a fixed sequence of INT8 values (same window
//   content every trace). Random population: uniform random INT8
//   per cycle. The mean r_max trajectory differs because:
//     Fixed    → r_max grows deterministically to a known maximum
//     Random   → r_max grows stochastically; expected value grows
//                as the order statistic E[max(U(1..k))]
//
// TVLA_TARGET choices:
//   "act"  : the input sequence x_in carries the contrast (default)
//   "len"  : win_len varies (fixed population uses a fixed length,
//             random population uses a random length 2..WIN_LEN_MAX).
//             This tests whether the window-length counter leaks.
//
// Plusarg +WIN_LEN=N (default 8) sets the pooling window size.
// Keep WIN_LEN >= 4 so cnt has at least 2 transitions per window.
//=====================================================================
module tb_tvla_maxpool;

    localparam N   = 8;
    localparam CW  = 5;
    localparam real CLK_NS = 10.0;

    localparam WIN_LEN_MAX = 16;       // maximum window length tested
    localparam WINDOWS     = 4;        // windows per trace (captures multiple pools)
    localparam FLUSH_WIN   = 2;        // quiet windows between traces

    // actual window length and per-trace sizing are set at runtime
    integer WIN_LEN;
    integer CAPTURE;   // WIN_LEN * WINDOWS + 1 drain cycle

    reg              clk = 1'b0;
    reg              reset_n, valid_in;
    reg  [CW-1:0]    win_len;
    reg  signed [N-1:0] x_in;
    wire             valid_out;
    wire signed [N-1:0] y_out;

    (* dont_touch = "yes" *)
    maxpool_unit #(.N(N), .CW(CW)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .win_len(win_len), .x_in(x_in),
        .valid_out(valid_out), .y_out(y_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [N-1:0] fix_seq [0:WIN_LEN_MAX*8-1];  // fixed input sequence
    integer t, k, wk;
    reg grp, eff;
    reg signed [N-1:0] rx;

    initial begin
        sca_get_config("maxpool");
        if (!$value$plusargs("WIN_LEN=%d", WIN_LEN)) WIN_LEN = 8;
        CAPTURE = WIN_LEN * WINDOWS + 1;

        win_len = WIN_LEN[CW-1:0];

        // Fixed sequence: same values every trace. Draw once from the PRNG.
        for (k = 0; k < WIN_LEN * WINDOWS; k = k + 1) fix_seq[k] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);

        sca_open_meta("maxpool_unit", CLK_NS, CAPTURE);
        $display("[SCA] WIN_LEN=%0d WINDOWS=%0d CAPTURE=%0d", WIN_LEN, WINDOWS, CAPTURE);

        reset_n = 1'b0; valid_in = 1'b0; x_in = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush: push zero-valid data through a full window to
            //            reset r_max back to MOST_NEG, untriggered ----
            @(negedge clk);
            valid_in = 1'b0; x_in = {N{1'b0}};
            repeat (FLUSH_WIN * WIN_LEN) @(posedge clk);

            // ---- capture window: WINDOWS consecutive pooling windows ----
            for (k = 0; k < CAPTURE; k = k + 1) begin
                @(negedge clk);
                if (k < WIN_LEN * WINDOWS) begin
                    rx = rand_i8(0);           // R5: always draw
                    if (!eff) rx = fix_seq[k];
                    x_in     = rx;
                    valid_in = 1'b1;
                end else begin
                    valid_in = 1'b0;           // drain final y_out latch
                    x_in     = {N{1'b0}};
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
