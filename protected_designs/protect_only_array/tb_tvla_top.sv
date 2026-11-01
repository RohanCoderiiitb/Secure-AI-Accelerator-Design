`timescale 1ns/1ps
//=====================================================================
// tb_tvla_top.sv -- TVLA dataset generation for flexnn_top (top.sv)
//
// Same capture API / group scheduling / TVLA_TARGET convention as
// tb_tvla_array.sv ("wt", "row0", anything else = whole activation tile),
// but the stimulus now goes through the real top-level flow:
//
//   IF_GB / FL_GB write ports -> start -> load_controller (ACT_FETCH,
//   weight fetch, wt_load pulses through weight_masker) -> stream_start ->
//   address_generator streams the skewed tile -> post chain -> done.
//
// Rules carried over from the array testbench:
//   * Everything before stream_start is UNTRIGGERED (memory writes,
//     activation fetch, weight load through the masker). Only the compute
//     window [stream_start, stream_start + CAPTURE) is a trace.
//   * Skew / de-skew live in the DUT here (address_generator), but they are
//     outside the dumped scope, so they do not pollute the array activity.
//   * No reset between traces: mask_rng keeps advancing, so every trace
//     (and every weight load) gets a fresh mask. Resetting per trace would
//     replay the same masks and defeat the masking.
//
// Extra things this top-level bench has to handle:
//   * QUIESCE pass. sram_2p read data is held when rd_en is low, so the
//     array inputs keep the LAST activation of the previous trace, and at
//     time 0 they are X. Before each real trace an untriggered pass with an
//     all-zero tile is run so the array starts every window from zero
//     (like the flush in tb_tvla_array). Disable with +QUIESCE=0.
//   * Positive control: +MASK_EN=0 drives mask_en low (w0 = 0, w1 = W).
//     The array scope MUST leak in that mode; if it does not, the bench
//     is blind. Default is +MASK_EN=1.
//   * Functional self-check. Every array output (recombined psum) is
//     compared with act*W computed in the TB, so a bad mask / wiring
//     change fails loudly instead of silently producing a "clean" TVLA.
//
// Dump scope: u_dut.u_array (the protected array) by default.
// Compile with -DTVLA_DUMP_TOP to dump the whole top instead (this will
// show the unmasked downstream chain, which leaks by design in this phase).
//
// Override sizes at compile time, e.g. for iverilog:
//   -Ptb_tvla_top.ROWS=4 -Ptb_tvla_top.COLS=4 -Ptb_tvla_top.WAVES=4
//
// Needs sca_capture.vh (same one tb_tvla_array.sv includes).
//=====================================================================
module tb_tvla_top;

    parameter N          = 8;
    parameter ACCW       = 32;
    parameter SHARE_W    = ACCW;
    parameter ROWS       = 5;
    parameter COLS       = 5;
    parameter WAVES      = 4;                 // activation vectors per trace
    parameter MW         = 32;
    parameter SW         = 6;
    parameter POOL_LEN   = 1;
    parameter [63:0] MASK_SEED = 64'd1;

    localparam real CLK_NS = 10.0;

    // Same derived widths as flexnn_top.
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam WADDR_W   = (WAVES    <= 1) ? 1 : $clog2(WAVES);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);

    // Compute window, counted from the cycle stream_start is sampled:
    //   ~3 cycles for address_generator -> scratchpad -> array entry,
    //   WAVES + ROWS + COLS for the wavefront to cross the array,
    //   a few settling cycles at the end.
    localparam CAPTURE   = WAVES + ROWS + COLS + 8;
    localparam TIMEOUT   = 20000;             // watchdog, cycles per wait

    reg                         clk = 1'b0;
    reg                         reset_n, start, mask_en;
    wire                        done, array_compute_done;

    reg                         if_wr_en;
    reg  [IF_ADDR_W-1:0]        if_wr_addr;
    reg  [N-1:0]                if_wr_data;
    reg                         fl_wr_en;
    reg  [FL_ADDR_W-1:0]        fl_wr_addr;
    reg  [N-1:0]                fl_wr_data;

    reg  [COLS*ACCW-1:0]        bias_flat;
    reg  [COLS*MW-1:0]          m0_flat;
    reg  [COLS*SW-1:0]          shift_flat;
    reg  [1:0]                  act_mode;
    reg  signed [N-1:0]         act_clamp_high;
    reg  [2:0]                  act_leaky_shift;
    reg  [CW-1:0]               pool_win_len;

    wire [COLS-1:0]             psum_ovf_flat;
    wire [COLS-1:0]             requant_sat_flat;

    reg  [COLS-1:0]             of_rd_en;
    reg  [COLS*OF_ADDR_W-1:0]   of_rd_addr_flat;
    wire [COLS*N-1:0]           of_rd_data_flat;

    (* dont_touch = "yes" *)
    flexnn_top #(
        .N(N), .ACCW(ACCW), .SHARE_W(SHARE_W), .MASK_SEED(MASK_SEED),
        .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
        .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)
    ) u_dut (
        .clk(clk), .reset_n(reset_n), .start(start), .mask_en(mask_en),
        .done(done), .array_compute_done(array_compute_done),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high),
        .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len),
        .psum_ovf_flat(psum_ovf_flat), .requant_sat_flat(requant_sat_flat),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat),
        .of_rd_data_flat(of_rd_data_flat)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    //-----------------------------------------------------------------
    // Stimulus storage (names as in tb_tvla_array.sv)
    //-----------------------------------------------------------------
    reg signed [N-1:0] act_tile [0:WAVES-1][0:ROWS-1];   // [wave][row]
    reg signed [N-1:0] fix_tile [0:WAVES-1][0:ROWS-1];
    reg signed [N-1:0] secret_w [0:ROWS-1][0:COLS-1];    // fixed-group weights
    reg signed [N-1:0] rand_w   [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0] tv_cur_w [0:ROWS-1][0:COLS-1];    // weights of THIS trace

    integer t, k, r, c, cyc;
    reg grp, eff;

    integer tv_mask_cfg, tv_quiesce_cfg;

    //-----------------------------------------------------------------
    // Memory loading through the top-level write ports (untriggered).
    //   IF_GB[r*WAVES + k] = act_tile[k][r]     (transposed layout)
    //   FL_GB[row*COLS + c] = weight[row][c]
    //-----------------------------------------------------------------
    task tv_write_if(input integer zero_tile);
        integer rr, kk;
        begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (kk = 0; kk < WAVES; kk = kk + 1) begin
                    @(negedge clk);
                    if_wr_en   = 1'b1;
                    if_wr_addr = rr*WAVES + kk;
                    if_wr_data = zero_tile ? {N{1'b0}} : act_tile[kk][rr];
                end
            @(negedge clk);
            if_wr_en = 1'b0; if_wr_addr = {IF_ADDR_W{1'b0}}; if_wr_data = {N{1'b0}};
        end
    endtask

    task tv_write_fl(input integer zero_w);
        integer rr, cc;
        begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    @(negedge clk);
                    fl_wr_en   = 1'b1;
                    fl_wr_addr = rr*COLS + cc;
                    fl_wr_data = zero_w ? {N{1'b0}} : tv_cur_w[rr][cc];
                end
            @(negedge clk);
            fl_wr_en = 1'b0; fl_wr_addr = {FL_ADDR_W{1'b0}}; fl_wr_data = {N{1'b0}};
        end
    endtask

    //-----------------------------------------------------------------
    // Sticky completion flag: `done` is a one-cycle pulse that can land
    // inside the capture window, so latch it instead of polling for it.
    //-----------------------------------------------------------------
    reg tv_seen_done;
    always @(posedge clk) if (done) tv_seen_done <= 1'b1;

    //-----------------------------------------------------------------
    // One full pass: start -> (untriggered load) -> stream_start ->
    // [optional trace window] -> done.
    //-----------------------------------------------------------------
    integer tv_wd;
    integer tv_win_outs;          // array outputs seen inside the window
    reg     tv_chk_en;            // self-check armed (real pass only)
    reg     tv_in_win;

    task tv_run_pass(input integer do_capture, input reg g);
        begin
            @(negedge clk);
            tv_seen_done = 1'b0;
            tv_win_outs  = 0;
            start        = 1'b1;
            @(negedge clk);
            start        = 1'b0;

            // wait for the compute phase to begin
            tv_wd = 0;
            @(posedge clk);
            while (u_dut.stream_start !== 1'b1) begin
                @(posedge clk);
                tv_wd = tv_wd + 1;
                if (tv_wd > TIMEOUT) begin
                    $display("[SCA][FATAL] stream_start never asserted (trace %0d)", t);
                    $finish;
                end
            end

            if (do_capture) begin
                tv_chk_en = 1'b1;
                tv_in_win = 1'b1;
                sca_trace_begin;
                for (cyc = 1; cyc < CAPTURE; cyc = cyc + 1)
                    @(posedge clk);
                @(negedge clk);
                tv_in_win = 1'b0;
                sca_trace_end(g);
                if (tv_win_outs != COLS*WAVES)
                    $display("[SCA][WARN] trace %0d: %0d/%0d array outputs inside the window -- CAPTURE too short?",
                             t, tv_win_outs, COLS*WAVES);
            end

            // wait for the post chain to finish
            tv_wd = 0;
            while (!tv_seen_done) begin
                @(posedge clk);
                tv_wd = tv_wd + 1;
                if (tv_wd > TIMEOUT) begin
                    $display("[SCA][FATAL] done never asserted (trace %0d)", t);
                    $finish;
                end
            end
            repeat (4) @(posedge clk);
            tv_chk_en = 1'b0;
        end
    endtask

    //-----------------------------------------------------------------
    // Functional self-check on the recombined array output.
    // Sampled at negedge (values stable for the whole cycle).
    //   out_wr_en[c] / out_wr_addr_flat[c] give the wave index; the
    //   expected psum is sum_r act[wave][r] * W[r][c].
    //-----------------------------------------------------------------
    integer tv_errs = 0, tv_checked = 0;
    integer cc_i, rr_i, wv;
    reg signed [ACCW-1:0] tv_gold;
    always @(negedge clk) if (tv_chk_en) begin
        for (cc_i = 0; cc_i < COLS; cc_i = cc_i + 1) begin
            if (u_dut.out_wr_en[cc_i]) begin
                wv = u_dut.out_wr_addr_flat[cc_i*WADDR_W +: WADDR_W];
                tv_gold = 0;
                for (rr_i = 0; rr_i < ROWS; rr_i = rr_i + 1)
                    tv_gold = tv_gold + act_tile[wv][rr_i] * tv_cur_w[rr_i][cc_i];
                tv_checked = tv_checked + 1;
                if (tv_in_win) tv_win_outs = tv_win_outs + 1;
                if (u_dut.arr_psum_out[cc_i*ACCW +: ACCW] !== tv_gold) begin
                    tv_errs = tv_errs + 1;
                    if (tv_errs <= 10)
                        $display("[SCA][MISMATCH] trace %0d col %0d wave %0d: got %0d expected %0d",
                                 t, cc_i, wv,
                                 $signed(u_dut.arr_psum_out[cc_i*ACCW +: ACCW]), tv_gold);
                end
            end
        end
    end

    //-----------------------------------------------------------------
    initial begin
        sca_get_config("top");

        if (!$value$plusargs("MASK_EN=%d", tv_mask_cfg))    tv_mask_cfg    = 1;
        if (!$value$plusargs("QUIESCE=%d", tv_quiesce_cfg)) tv_quiesce_cfg = 1;

        for (r = 0; r < ROWS; r = r + 1)
            for (c = 0; c < COLS; c = c + 1)
                secret_w[r][c] = rand_i8(0);

        for (k = 0; k < WAVES; k = k + 1)
            for (r = 0; r < ROWS; r = r + 1)
                fix_tile[k][r] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
`ifdef TVLA_DUMP_TOP
        $dumpvars(0, u_dut);                     // whole top (downstream leaks by design)
`else
        $dumpvars(0, u_dut.u_array);             // SCOPE-LIMITED: protected array only
`endif

        sca_open_meta("flexnn_top", CLK_NS, CAPTURE);
        $display("[SCA] top geometry ROWS=%0d COLS=%0d WAVES=%0d ACCW=%0d SHARE_W=%0d capture=%0d cycles",
                 ROWS, COLS, WAVES, ACCW, SHARE_W, CAPTURE);
        $display("[SCA] mask_en=%0d quiesce=%0d", tv_mask_cfg[0], tv_quiesce_cfg[0]);

        // idle / static configuration
        reset_n = 1'b0;  start = 1'b0;  mask_en = tv_mask_cfg[0];
        if_wr_en = 1'b0; if_wr_addr = 0; if_wr_data = 0;
        fl_wr_en = 1'b0; fl_wr_addr = 0; fl_wr_data = 0;
        bias_flat       = {(COLS*ACCW){1'b0}};
        m0_flat         = {COLS{32'd1}};         // requant is not under test:
        shift_flat      = {(COLS*SW){1'b0}};     // saturating pass-through
        act_mode        = 2'd0;
        act_clamp_high  = {1'b0, {(N-1){1'b1}}};
        act_leaky_shift = 3'd0;
        pool_win_len    = POOL_LEN;
        of_rd_en        = {COLS{1'b0}};
        of_rd_addr_flat = {(COLS*OF_ADDR_W){1'b0}};
        tv_chk_en = 1'b0; tv_in_win = 1'b0; tv_seen_done = 1'b0; tv_win_outs = 0;

        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw the full random stimulus set for both groups.
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    rand_w[r][c] = rand_i8(0);
            for (k = 0; k < WAVES; k = k + 1)
                for (r = 0; r < ROWS; r = r + 1)
                    act_tile[k][r] = rand_i8(0);

            if (TVLA_TARGET == "wt") begin
                // weights carry the contrast; activations held fixed
                for (k = 0; k < WAVES; k = k + 1)
                    for (r = 0; r < ROWS; r = r + 1)
                        act_tile[k][r] = fix_tile[k][r];
            end else if (TVLA_TARGET == "row0") begin
                // ONE row carries the contrast; all other rows random in
                // BOTH populations (algorithmic noise for the size sweep).
                if (!eff)
                    for (k = 0; k < WAVES; k = k + 1)
                        act_tile[k][0] = fix_tile[k][0];
            end else if (!eff) begin
                for (k = 0; k < WAVES; k = k + 1)
                    for (r = 0; r < ROWS; r = r + 1)
                        act_tile[k][r] = fix_tile[k][r];
            end

            // weights of this trace (what the self-check expects)
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    tv_cur_w[r][c] = ((TVLA_TARGET == "wt") && eff) ? rand_w[r][c]
                                                                    : secret_w[r][c];

            // ---- quiesce pass (untriggered): zero tile, array -> all zero ----
            if (tv_quiesce_cfg != 0) begin
                tv_write_if(1);
                tv_write_fl(1);
                tv_run_pass(0, grp);
            end

            // ---- real pass: untriggered load, triggered compute ----
            tv_write_if(0);
            tv_write_fl(0);
            tv_run_pass(1, grp);

            if (t % 200 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        $display("[SCA] self-check: %0d array outputs checked, %0d mismatches", tv_checked, tv_errs);
        if (tv_errs != 0)
            $display("[SCA][FAIL] functional mismatch -- do NOT trust this TVLA dataset");
        sca_close_meta;
        $finish;
    end

endmodule