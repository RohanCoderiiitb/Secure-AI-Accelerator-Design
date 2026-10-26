`timescale 1ns/1ps
//=====================================================================
// tb_masked_array_equiv.sv -- Phase 3 gate: masked array == baseline array
//
// Baseline `systolic_array` and `weight_masker` + `systolic_array_masked`
// get identical stimulus: weights loaded exactly like the loader does
// (ROWS wt_load pulses, bottom row first, so weights shift down), then a
// stream of random valid activation vectors with a random PUBLIC north
// psum (split into random shares for the masked array).
//
// Checked every cycle
//   * per column: psum0_out + psum1_out == baseline psum_out
//   * valid_sum_out, act_out, valid_act_out identical
//   * EVERY PE: wt0_reg + wt1_reg == sext(baseline wt_reg)     (shift-load
//     order and share transport through the column)
// Checked after every load
//   * all ROWS*COLS first-share values are pairwise DIFFERENT (independent
//     masks per PE location; a shared mask would leak W_i - W_j)
//   * with mask_en=0 every first share is exactly 0 (positive control)
//
//   +SESSIONS=<n> (default 12)  +STREAM=<n> cycles/session (default 14)
//   +MASK_EN=0|1 (default 1)    +SEED=<n>
//=====================================================================
module tb_masked_array_equiv;
    localparam N = 8, SW = 32, ROWS = 5, COLS = 5, NPE = ROWS*COLS;
    localparam real CLK_NS = 10.0;

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg                    reset_n, wt_load, mask_en;
    reg  [COLS*N-1:0]      wt_flat;
    reg  [ROWS-1:0]        valid_act_in;
    reg  [ROWS*N-1:0]      act_flat;
    reg  [COLS*SW-1:0]     psum_pub, ps0_in, ps1_in;

    // ---- baseline ----
    wire [COLS*SW-1:0] b_psum;  wire [COLS-1:0] b_vs;
    wire [ROWS*N-1:0]  b_act;   wire [ROWS-1:0] b_va;
    systolic_array #(.N(N), .ACCW(SW), .ROWS(ROWS), .COLS(COLS)) dut_b (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat), .psum_flat(psum_pub),
        .psum_out(b_psum), .valid_sum_out(b_vs), .act_out(b_act), .valid_act_out(b_va));

    // ---- masked ----
    wire [COLS*SW-1:0] wt0, wt1, m_ps0, m_ps1;  wire [COLS-1:0] m_vs;
    wire [ROWS*N-1:0]  m_act;   wire [ROWS-1:0] m_va;
    weight_masker #(.N(N), .SHARE_W(SW), .COLS(COLS), .SEED(64'd1)) u_masker (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .mask_en(mask_en),
        .wt_flat(wt_flat), .wt0_flat(wt0), .wt1_flat(wt1));
    systolic_array_masked #(.N(N), .SHARE_W(SW), .ROWS(ROWS), .COLS(COLS)) dut_m (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
        .wt0_flat(wt0), .wt1_flat(wt1), .valid_act_in(valid_act_in), .act_flat(act_flat),
        .psum0_flat(ps0_in), .psum1_flat(ps1_in),
        .psum0_out(m_ps0), .psum1_out(m_ps1),
        .valid_sum_out(m_vs), .act_out(m_act), .valid_act_out(m_va));

    // ---- per-PE weight reconstruction + share export ----
    wire [NPE-1:0]       wt_bad;
    wire [NPE*SW-1:0]    w0_all;
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_chk_r
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_chk_c
                wire [SW-1:0] s0 = dut_m.g_row[gr].g_col[gc].pe_inst.wt0_reg;
                wire [SW-1:0] s1 = dut_m.g_row[gr].g_col[gc].pe_inst.wt1_reg;
                wire signed [N-1:0] wb = dut_b.g_row[gr].g_col[gc].pe_inst.wt_reg;
                wire [SW-1:0] ref_w = {{(SW-N){wb[N-1]}}, wb};
                assign wt_bad[gr*COLS+gc]            = ((s0 + s1) !== ref_w);
                assign w0_all[(gr*COLS+gc)*SW +: SW] = s0;
            end
        end
    endgenerate

    `include "sca_capture.vh"

    integer SESS, STREAM, errors, cycles, sdx, k, t, r, c, a_i, b_i, collisions, nz0;
    integer mc;
    reg signed [N-1:0] W [0:ROWS-1][0:COLS-1];
    reg [COLS*SW-1:0] shr;

    task check_cycle;
        integer cc;
        begin
            #1; cycles = cycles + 1;
            for (cc = 0; cc < COLS; cc = cc + 1)
                if ((m_ps0[cc*SW +: SW] + m_ps1[cc*SW +: SW]) !== b_psum[cc*SW +: SW]) begin
                    errors = errors + 1;
                    if (errors < 8) $display("MISMATCH psum col %0d @%0t", cc, $time);
                end
            if (m_vs !== b_vs || m_act !== b_act || m_va !== b_va) begin
                errors = errors + 1;
                if (errors < 8) $display("MISMATCH valid/act @%0t", $time);
            end
            if (|wt_bad) begin
                errors = errors + 1;
                if (errors < 8) $display("MISMATCH PE weight reconstruction %b @%0t", wt_bad, $time);
            end
        end
    endtask

    task drive(input ld, input [ROWS-1:0] v);
        begin
            @(negedge clk);
            wt_load = ld; valid_act_in = v;
            for (r = 0; r < ROWS; r = r + 1) act_flat[r*N +: N] = rand_i8(0);
            for (c = 0; c < COLS; c = c + 1) begin
                psum_pub[c*SW +: SW] = rand_word(SW);
                shr[c*SW +: SW]      = rand_word(SW);
            end
            ps0_in = mask_en ? shr : {COLS*SW{1'b0}};
            for (c = 0; c < COLS; c = c + 1)      // per-COLUMN modular split (no borrow across columns)
                ps1_in[c*SW +: SW] = psum_pub[c*SW +: SW] - ps0_in[c*SW +: SW];
            @(posedge clk);
            check_cycle;
        end
    endtask

    initial begin
        sca_get_config("array_equiv");
        if (!$value$plusargs("SESSIONS=%d", SESS))   SESS   = 12;
        if (!$value$plusargs("STREAM=%d",   STREAM)) STREAM = 14;
        if (!$value$plusargs("MASK_EN=%d",  mc))     mc     = 1;
        mask_en = (mc != 0);
        errors = 0; cycles = 0; collisions = 0; nz0 = 0;
        reset_n = 0; wt_load = 0; wt_flat = 0; valid_act_in = 0; act_flat = 0;
        psum_pub = 0; ps0_in = 0; ps1_in = 0;
        repeat (4) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);
        $display("[ARR] %0dx%0d  mask_en=%0d  sessions=%0d x (%0d load + %0d stream)",
                 ROWS, COLS, mask_en, SESS, ROWS, STREAM);

        for (sdx = 0; sdx < SESS; sdx = sdx + 1) begin
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    W[r][c] = (sdx == 0) ? -128 : (sdx == 1) ? 127 : rand_i8(0);
            // loader order: bottom row first, one wt_load pulse per row
            for (k = 0; k < ROWS; k = k + 1) begin
                for (c = 0; c < COLS; c = c + 1) wt_flat[c*N +: N] = W[ROWS-1-k][c];
                drive(1'b1, {ROWS{1'b0}});
            end
            for (c = 0; c < COLS; c = c + 1) wt_flat[c*N +: N] = 0;
            // mask independence across PE locations (after the last shift)
            if (mask_en) begin
                for (a_i = 0; a_i < NPE; a_i = a_i + 1)
                    for (b_i = a_i + 1; b_i < NPE; b_i = b_i + 1)
                        if (w0_all[a_i*SW +: SW] === w0_all[b_i*SW +: SW])
                            collisions = collisions + 1;
            end else begin
                for (a_i = 0; a_i < NPE; a_i = a_i + 1)
                    if (w0_all[a_i*SW +: SW] !== {SW{1'b0}}) nz0 = nz0 + 1;
            end
            for (t = 0; t < STREAM; t = t + 1)
                drive(1'b0, (rand_word(3) != 0) ? {ROWS{1'b1}} : rand_word(ROWS));
        end

        $display("[ARR] cycles=%0d  mismatches=%0d  mask collisions across PEs=%0d  nonzero share-0 (mask_en=0)=%0d",
                 cycles, errors, collisions, nz0);
        if (errors == 0 && collisions == 0 && nz0 == 0) $display("PASS");
        else                                           $display("FAIL");
        $finish;
    end
endmodule
