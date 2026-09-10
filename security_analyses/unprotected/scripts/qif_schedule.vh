//=====================================================================
// qif_schedule.vh -- exhaustive enumeration driver for QIF capture.
//
// `include INSIDE a QIF testbench module body, AFTER sca_capture.vh.
// Compile with -g2012.
//
// WHY SEPARATE TESTBENCHES FROM THE TVLA ONES
// -------------------------------------------
// The QIF stimulus is fundamentally different: an odometer walking a
// declared secret space with a one-operation capture window, rather than
// a balanced fixed/random split over an eight-operation window. Branching
// inside the working tb_tvla_*.v files would risk the TVLA flow for no
// benefit, so the QIF testbenches are separate. The DUT instantiation,
// dont_touch attributes, negedge drive discipline and scope-limited
// dumping are copied verbatim -- if you edit those in one place, edit
// them in both.
//
// WHAT "EXHAUSTIVE" MEANS HERE
// ----------------------------
// Nominal bit width is NOT the reachable state space, and enumerating
// unreachable states makes the channel wrong rather than more rigorous.
// acc_in is declared 32 bits, but with INT8 operands and ROWS=5 the
// accumulator can only ever reach 5*127*128 = 81,280 plus bias.
// Everything past +/-2^17 is unreachable, and feeding it in would put
// probability mass on states the hardware never occupies. So each
// testbench declares its own REACHABLE bounds and sweeps those
// exhaustively.
//
// Enumeration budgets actually used:
//   multiplier   x,y full INT8                     2^16 =    65,536
//   mac (1 step) wt,act full INT8                  2^16 =    65,536
//   PE           wt,act full INT8, psum_in = 0     2^16 =    65,536
//   activation   x_in full INT8 x 4 modes                    1,024
//   requantize   acc_in over +/-2^17                       262,144
//   psum_accum   psum_in over +/-2^17                       262,144
//   maxpool      WIN_LEN=2 full window             2^16 =    65,536
//   array 5x5    w[0][0] full INT8 x N_CTX contexts   256 * N_CTX
//
// The 5x5 array is the one case where the joint space cannot be
// enumerated: 25 INT8 weights is 2^200. But exhaustiveness survives in
// the form that matters. For each enumerated context k, ALL 256 values
// of the secret w[0][0] are simulated, so every conditional channel
// I(S;O|K=k) is EXACT. max_k of those is the chosen-context bound, which
// is the security-relevant number. Only the context-marginalised figure
// is an estimate, and it is the weakest threat model of the three.
//
// SECRET LOGGING
// --------------
// Rule R3 from sca_capture.vh still binds absolutely: the secret is
// written to the metadata sidecar, NEVER into a register inside the
// dumped scope. A secret-valued register inside the DUT hierarchy would
// leak the label straight into the power proxy and produce a channel
// with maximal, meaningless MI.
//=====================================================================

integer QIF_CTX;        // number of enumerated contexts (array only)
integer QIF_RESUME;     // first trace index to run; earlier ones skipped
integer QIF_LIMIT;      // stop after this many traces, 0 = no limit
integer qif_total;      // total traces the schedule will emit
integer qif_idx;        // running trace counter

//---------------------------------------------------------------------
// Extended metadata sidecar
//---------------------------------------------------------------------
// Superset of the TVLA format. TVLA runs leave secret/context at -1, so
// vcd_power.py reads both layouts with the same parser.
//---------------------------------------------------------------------
task qif_open_meta(input string dut_name, input real clk_period_ns,
                   input integer capture_cycles, input integer n_traces);
    string path;
    begin
        path    = {OUTDIR, "/", TAG, ".meta.csv"};
        meta_fd = $fopen(path, "w");
        if (meta_fd == 0) begin
            $display("[QIF] FATAL: cannot open %0s", path);
            $finish;
        end
        $fdisplay(meta_fd, "# dut=%0s",            dut_name);
        $fdisplay(meta_fd, "# mode=qif");
        $fdisplay(meta_fd, "# seed=%0d",           SEED);
        $fdisplay(meta_fd, "# ntraces=%0d",        n_traces);
        $fdisplay(meta_fd, "# clk_period_ns=%0f",  clk_period_ns);
        $fdisplay(meta_fd, "# capture_cycles=%0d", capture_cycles);
        $fdisplay(meta_fd, "# time_unit=ns");
        $fdisplay(meta_fd,
            "trace_id,group,secret_id,secret_val,context_id,context_val,t_start_ns,t_end_ns");
        trace_id = 0;
    end
endtask

// Call after the posedge that ends the last captured cycle.
task qif_trace_end(input integer secret_id, input integer secret_val,
                   input integer context_id, input integer context_val);
    begin
        $fdisplay(meta_fd, "%0d,Q,%0d,%0d,%0d,%0d,%0f,%0f",
                  trace_id, secret_id, secret_val,
                  context_id, context_val, trace_t0, $realtime);
        trace_id = trace_id + 1;
    end
endtask

//---------------------------------------------------------------------
// Config
//---------------------------------------------------------------------
task qif_get_config(input string default_tag, input integer default_ctx);
    begin
        if (!$value$plusargs("SEED=%d",    SEED))       SEED       = 1;
        if (!$value$plusargs("QIF_CTX=%d", QIF_CTX))    QIF_CTX    = default_ctx;
        if (!$value$plusargs("RESUME=%d",  QIF_RESUME)) QIF_RESUME = 0;
        if (!$value$plusargs("LIMIT=%d",   QIF_LIMIT))  QIF_LIMIT  = 0;
        if (!$value$plusargs("TAG=%s",     TAG))        TAG        = default_tag;
        if (!$value$plusargs("OUTDIR=%s",  OUTDIR))     OUTDIR     = "traces";
        MODE        = "qif";
        TVLA_TARGET = "qif";
        NTRACES     = 0;
        prng_state  = 64'd88172645463325252 + SEED;
        qif_idx     = 0;
        $display("[QIF] tag=%0s seed=%0d ctx=%0d resume=%0d limit=%0d",
                 TAG, SEED, QIF_CTX, QIF_RESUME, QIF_LIMIT);
    end
endtask

// True when the current trace index lies inside the requested slice.
// Long runs are checkpointable: split a 262,144-trace sweep into chunks
// with +RESUME= and +LIMIT= and merge the resulting .npz files.
function qif_in_slice(input integer idx);
    begin
        qif_in_slice = (idx >= QIF_RESUME) &&
                       ((QIF_LIMIT == 0) || (idx < QIF_RESUME + QIF_LIMIT));
    end
endfunction

function qif_past_slice(input integer idx);
    begin
        qif_past_slice = (QIF_LIMIT != 0) && (idx >= QIF_RESUME + QIF_LIMIT);
    end
endfunction

task qif_progress(input integer idx, input integer total);
    begin
        if (idx % 8192 == 0)
            $display("[QIF] %0d / %0d  (%0d%%)  t=%0t",
                     idx, total, (100*idx)/((total > 0) ? total : 1), $time);
    end
endtask
