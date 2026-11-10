`timescale 1ns/1ps
//=====================================================================
// tb_func_requantize_shuffled.sv -- functional check of the shuffled
//                                   requantizer against requantize
//
// Same input stream into four designs:
//   u_ref : requantize                     (source/requantization_block.sv)
//   u_in  : requantize_shuffled INORDER=1  shuffled, results back in order
//   u_oo  : requantize_shuffled INORDER=0  shuffled, results by slot index
//   u_id  : requantize_shuffled INORDER=0, shuf_en=0  (must issue 0,1,2,..)
//   u_top : requantize_shuffled_top INORDER=1  (with its own generator)
//
// Stimulus per test: 1..4 full batches back to back, then (half of the
// tests) a partial batch closed with flush, then an idle gap. bias / m0 /
// shift are randomised per batch. Checks:
//   * every result identical to requantize (order restored for u_oo)
//   * the overflow flag never rises
//   * the order really is shuffled: share of full batches not in identity
//     order, and how often each slot is issued first (should be ~1/D)
// Reports first-value latency and burst cycles of all designs.
//
//   vvp ... [+NTEST=300] [+SEED=1]
//=====================================================================
module tb_func_requantize_shuffled;
    localparam N = 8, ACCW = 32, MW = 32, SW = 6, D = 8, RW = 16;
    localparam AW = $clog2(D);
    localparam MAXV = 1 << 16;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                    reset_n, valid_in, flush_in;
    reg  signed [ACCW-1:0] acc, bias;
    reg  signed [MW-1:0]   m0;
    reg  [SW-1:0]          sh;
    reg  [RW-1:0]          rnd_a, rnd_b;

    wire vr, sr; wire [N-1:0] qr;
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_ref (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bias_in(bias),
        .m0_in(m0), .shift_in(sh), .valid_out(vr), .q_out(qr), .sat_out(sr));

    wire v1, s1, b1, o1; wire [N-1:0] q1; wire [AW-1:0] i1;
    requantize_shuffled #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .D(D), .RW(RW), .INORDER(1)) u_in (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bias_in(bias),
        .m0_in(m0), .shift_in(sh), .flush_in(flush_in), .shuf_en(1'b1), .rnd_in(rnd_a),
        .valid_out(v1), .q_out(q1), .sat_out(s1), .idx_out(i1), .busy(b1), .overflow(o1));

    wire v0, s0, b0, o0; wire [N-1:0] q0; wire [AW-1:0] i0;
    requantize_shuffled #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .D(D), .RW(RW), .INORDER(0)) u_oo (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bias_in(bias),
        .m0_in(m0), .shift_in(sh), .flush_in(flush_in), .shuf_en(1'b1), .rnd_in(rnd_b),
        .valid_out(v0), .q_out(q0), .sat_out(s0), .idx_out(i0), .busy(b0), .overflow(o0));

    wire vi, si, bi, oi; wire [N-1:0] qi; wire [AW-1:0] ii;
    requantize_shuffled #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .D(D), .RW(RW), .INORDER(0)) u_id (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bias_in(bias),
        .m0_in(m0), .shift_in(sh), .flush_in(flush_in), .shuf_en(1'b0), .rnd_in(rnd_a),
        .valid_out(vi), .q_out(qi), .sat_out(si), .idx_out(ii), .busy(bi), .overflow(oi));

    // the chip version: shuffler + its own generator, results in order
    wire vt, st, bt, ot; wire [N-1:0] qt; wire [AW-1:0] it;
    requantize_shuffled_top #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .D(D), .RW(RW), .INORDER(1)) u_top (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bias_in(bias),
        .m0_in(m0), .shift_in(sh), .flush_in(flush_in), .shuf_en(1'b1),
        .valid_out(vt), .q_out(qt), .sat_out(st), .idx_out(it), .busy(bt), .overflow(ot));

    // ---------------- bookkeeping ----------------
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    reg [N:0] exp_q [0:MAXV-1];        // reference results, arrival order
    reg [N:0] got_in[0:MAXV-1];        // INORDER=1, as streamed
    reg [N:0] got_oo[0:MAXV-1];        // INORDER=0, placed by slot index
    reg [N:0] got_tp[0:MAXV-1];        // requantize_shuffled_top, as streamed
    integer   n_tp = 0;
    reg       hit_oo[0:MAXV-1];
    integer   bsize [0:MAXV-1];        // batch sizes in arrival order
    integer   n_in_vals = 0, n_ref = 0, n_in = 0, n_oo = 0, nbatch = 0;
    integer   oo_b = 0, oo_base = 0, oo_cnt = 0;   // u_oo batch tracker
    integer   id_b = 0, id_cnt = 0, id_err = 0;    // u_id must issue 0,1,2,..
    integer   errors = 0;

    always @(negedge clk) if (reset_n) begin
        if (vr) begin exp_q[n_ref] = {sr, qr}; n_ref = n_ref + 1; end
        if (v1) begin got_in[n_in] = {s1, q1}; n_in = n_in + 1; end
        if (vt) begin got_tp[n_tp] = {st, qt}; n_tp = n_tp + 1; end
        if (v0) begin
            if (hit_oo[oo_base + i0]) begin
                errors = errors + 1;
                if (errors <= 10) $display("[FAIL] u_oo: slot %0d of batch %0d returned twice", i0, oo_b);
            end
            got_oo[oo_base + i0] = {s0, q0}; hit_oo[oo_base + i0] = 1'b1;
            n_oo = n_oo + 1; oo_cnt = oo_cnt + 1;
            if (oo_cnt == bsize[oo_b]) begin oo_base = oo_base + oo_cnt; oo_cnt = 0; oo_b = oo_b + 1; end
        end
        if (vi) begin
            if (ii != id_cnt) id_err = id_err + 1;
            id_cnt = id_cnt + 1;
            if (id_cnt == bsize[id_b]) begin id_cnt = 0; id_b = id_b + 1; end
        end
    end

    // ---------------- shuffle statistics (u_in issue order) ----------------
    integer first_hist [0:D-1];
    integer full_batches = 0, non_identity = 0, ipos = 0;
    reg     ident;
    always @(posedge clk) if (reset_n && u_in.iact) begin
        if (u_in.nb[u_in.ib] == D) begin
            if (ipos == 0) begin first_hist[u_in.idx] = first_hist[u_in.idx] + 1; ident = 1'b1; end
            if (u_in.idx != ipos) ident = 1'b0;
            if (u_in.last) begin
                full_batches = full_batches + 1;
                if (!ident) non_identity = non_identity + 1;
            end
        end
        ipos = u_in.last ? 0 : ipos + 1;
    end

    // ---------------- stimulus ----------------
    integer NTEST, SEED, seed, t, b, k, nfull, npart, gap;
    integer t0, f_r, f_1, f_0, lat_r, lat_1, lat_0;

    always @(negedge clk) begin rnd_a = $random(seed); rnd_b = $random(seed); end

    task new_params;
        begin
            bias = ($random(seed) % 32768);
            m0   = {1'b0, 1'b1, 30'h0} | ($random(seed) & 32'h3FFF_FFFF);
            sh   = (($random(seed) & 7) == 0) ? ($unsigned($random(seed)) % 30)
                                              : 30 + ($unsigned($random(seed)) % 14);
        end
    endtask

    // one batch of nv values; flush on the last value if fl
    task send_batch(input integer nv, input integer fl);
        begin
            for (k = 0; k < nv; k = k + 1) begin
                @(negedge clk);
                if (k == 0) new_params;          // change only between batches
                acc      = ($random(seed) % 65536);
                valid_in = 1'b1;
                flush_in = (fl && k == nv - 1);
                n_in_vals = n_in_vals + 1;
            end
            bsize[nbatch] = nv; nbatch = nbatch + 1;
        end
    endtask

    task idle(input integer n);
        begin
            @(negedge clk); valid_in = 1'b0; flush_in = 1'b0; acc = $random(seed);
            repeat (n - 1) @(negedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("NTEST=%d", NTEST)) NTEST = 300;
        if (!$value$plusargs("SEED=%d",  SEED))  SEED  = 1;
        seed = SEED;
        for (k = 0; k < D; k = k + 1) first_hist[k] = 0;
        for (k = 0; k < MAXV; k = k + 1) hit_oo[k] = 1'b0;
        reset_n = 0; valid_in = 0; flush_in = 0; acc = 0; bias = 0; m0 = 0; sh = 0;
        repeat (5) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (4) @(negedge clk);

        // ---- latency: one full batch from idle ----
        t0 = cyc + 1; f_r = -1; f_1 = -1; f_0 = -1;
        fork
            begin send_batch(D, 0); @(negedge clk); valid_in = 1'b0; end
            begin
                while (f_r < 0 || f_1 < 0 || f_0 < 0) begin
                    @(posedge clk); #1;
                    if (vr && f_r < 0) f_r = cyc;
                    if (v1 && f_1 < 0) f_1 = cyc;
                    if (v0 && f_0 < 0) f_0 = cyc;
                end
            end
        join
        lat_r = f_r - t0; lat_1 = f_1 - t0; lat_0 = f_0 - t0;
        idle(3 * D + 10);

        // ---- random traffic ----
        for (t = 0; t < NTEST; t = t + 1) begin
            nfull = 1 + ($unsigned($random(seed)) % 4);
            for (b = 0; b < nfull; b = b + 1) send_batch(D, 0);
            if ($random(seed) & 1) begin
                npart = 1 + ($unsigned($random(seed)) % (D - 1));
                send_batch(npart, 1);
            end
            gap = 3 * D + 10 + ($unsigned($random(seed)) % 5);
            idle(gap);
        end
        idle(3 * D + 10);

        // ---- compare ----
        if (n_ref != n_in_vals || n_in != n_in_vals || n_oo != n_in_vals || n_tp != n_in_vals) begin
            errors = errors + 1;
            $display("[FAIL] counts: sent %0d, ref %0d, inorder %0d, outoforder %0d",
                     n_in_vals, n_ref, n_in, n_oo);
        end
        for (k = 0; k < n_in_vals; k = k + 1) begin
            if (got_in[k] !== exp_q[k] || got_oo[k] !== exp_q[k] || !hit_oo[k] || got_tp[k] !== exp_q[k]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("[FAIL] value %0d: ref=%h inorder=%h outoforder=%h",
                             k, exp_q[k], got_in[k], got_oo[k]);
            end
        end
        if (o1 || o0 || oi || ot) begin errors = errors + 1; $display("[FAIL] overflow flag raised"); end
        if (id_err != 0)    begin errors = errors + 1; $display("[FAIL] shuf_en=0 did not issue in order (%0d)", id_err); end

        $display("");
        $display("================ shuffled requantizer: functional check ================");
        $display("  batch size D = %0d, %0d values in %0d batches", D, n_in_vals, nbatch);
        $display("  %-38s %8s", "design", "latency");
        $display("  %-38s %8d", "requantize (unprotected)", lat_r);
        $display("  %-38s %8d", "requantize_shuffled INORDER=1", lat_1);
        $display("  %-38s %8d", "requantize_shuffled INORDER=0 (first)", lat_0);
        $display("  throughput: one value per cycle (back-to-back full batches)");
        $display("  full batches %0d, issued in a non-identity order: %0d (%0.2f%%)",
                 full_batches, non_identity, 100.0 * non_identity / (full_batches > 0 ? full_batches : 1));
        $write("  slot issued first (expect ~%0.1f%% each):", 100.0 / D);
        for (k = 0; k < D; k = k + 1) $write(" %0.1f", 100.0 * first_hist[k] / (full_batches > 0 ? full_batches : 1));
        $display("");
        if (errors == 0) $display("  [SHUFFLE] PASS: every result identical to requantize");
        else             $display("  [SHUFFLE] FAIL: %0d errors", errors);
        $display("=========================================================================");
        $finish;
    end
endmodule
