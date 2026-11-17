`timescale 1ns/1ps
// Throughput of the whole accelerator: unprotected (flexnn_top) vs masked (flexnn_top_protected)
//   1) full workload : NTILES tiles, each with new weights, activations and constants;
//                      per tile = write memories + start + wait done + read all outputs
//   2) compute stream: NBURST tiles started back-to-back (data already in memory)
// Every output of every tile in the full workload is checked against the behavioural model.
module tb_accel_throughput;
    parameter N = 8, ACCW = 19, ROWS = 5, COLS = 5, WAVES = 4;
    parameter MW = 16, SW = 6, BW = 32, POOL_LEN = 1;
    parameter DOM_REG = 1;
    parameter NRQ = 1;
    parameter real FMHZ_R = 100.0;         // clock of the unprotected design in MHz (set from timing analysis)
    parameter real FMHZ_D = 100.0;         // clock of the masked design in MHz
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);
    localparam RD_LAT    = 3;              // of_rd_en pin -> of_rd_data pin
    localparam OPS_TILE  = 2 * ROWS * COLS * WAVES;   // 1 MAC = 2 OPs (multiply + add)

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n, start_r, start_d;
    reg if_wr_en, fl_wr_en;
    reg [IF_ADDR_W-1:0] if_wr_addr;
    reg [FL_ADDR_W-1:0] fl_wr_addr;
    reg [N-1:0] if_wr_data, fl_wr_data;
    reg [COLS*BW-1:0]   bias_flat;
    reg [COLS*MW-1:0]   m0_flat;
    reg [COLS*SW-1:0]   shift_flat;
    reg [1:0]           act_mode;
    reg signed [N-1:0]  act_clamp_high;
    reg [2:0]           act_leaky_shift;
    reg [CW-1:0]        pool_win_len;
    reg [COLS-1:0]           of_rd_en;
    reg [COLS*OF_ADDR_W-1:0] of_rd_addr_flat;

    wire done_r, done_d, acd_r, acd_d;
    wire [COLS-1:0] ovf_r, ovf_d, sat_r, sat_d;
    wire [COLS*N-1:0] of_r, of_d;

    flexnn_top #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN)) u_ref (
        .clk(clk), .reset_n(reset_n), .start(start_r), .done(done_r), .array_compute_done(acd_r),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_r), .requant_sat_flat(sat_r),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_r));

    flexnn_top_protected #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN), .DOM_REG(DOM_REG), .NRQ(NRQ)) u_dut (
        .clk(clk), .reset_n(reset_n), .start(start_d), .done(done_d), .array_compute_done(acd_d),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_d), .requant_sat_flat(sat_d),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_d));

    integer NTILES, NBURST, SEED, seed, t, i, c, k;
    integer errors = 0, compared = 0;
    integer cyc = 0;
    integer w_r, w_d;                       // full workload cycles
    integer s_r, s_d;                       // compute stream cycles (first done -> last done)
    integer ph_wr, ph_cmp, ph_rd;           // per-design cycle split of the full workload
    integer wr_r, cmp_r, rd_r, wr_d, cmp_d, rd_d;
    always @(posedge clk) cyc <= cyc + 1;

    // behavioural model (same as tb_accel_func)
    reg signed [N-1:0] ifm [0:IF_DEPTH-1];
    reg signed [N-1:0] flm [0:FL_DEPTH-1];
    reg        [N-1:0] gold [0:COLS-1][0:OF_DEPTH-1];

    function [N-1:0] model_out;
        input integer cc, kk;
        integer rr;
        reg signed [63:0] acc, v, rnd;
        reg signed [N-1:0] q;
        reg signed [BW-1:0] bias;
        reg signed [MW-1:0] m0;
        reg [SW-1:0] sh;
        begin
            acc = 0;
            for (rr = 0; rr < ROWS; rr = rr + 1) acc = acc + ifm[rr*WAVES + kk] * flm[rr*COLS + cc];
            bias = bias_flat[cc*BW +: BW];
            m0   = m0_flat[cc*MW +: MW];
            sh   = shift_flat[cc*SW +: SW];
            v    = (acc + bias) * m0;
            rnd  = (sh == 0) ? 64'sd0 : (64'sd1 <<< (sh - 1));
            v    = (v + rnd) >>> sh;
            q    = (v > 127) ? 8'sd127 : ((v < -128) ? -8'sd128 : v[N-1:0]);
            case (act_mode)
                2'd0: model_out = q;
                2'd1: model_out = q[N-1] ? 8'd0 : q;
                2'd2: model_out = q[N-1] ? 8'd0 : ((q > act_clamp_high) ? act_clamp_high : q);
                2'd3: model_out = q[N-1] ? (q >>> act_leaky_shift) : q;
            endcase
        end
    endfunction

    task write_mems;
        begin
            for (i = 0; i < IF_DEPTH; i = i + 1) begin
                @(negedge clk); if_wr_en = 1; if_wr_addr = i; if_wr_data = $random(seed); ifm[i] = if_wr_data;
            end
            @(negedge clk); if_wr_en = 0;
            for (i = 0; i < FL_DEPTH; i = i + 1) begin
                @(negedge clk); fl_wr_en = 1; fl_wr_addr = i; fl_wr_data = $random(seed); flm[i] = fl_wr_data;
            end
            @(negedge clk); fl_wr_en = 0;
        end
    endtask

    task set_constants;
        reg [31:0] m32;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                bias_flat[c*BW +: BW]  = $random(seed) % 4096;
                m32                    = {1'b0, 1'b1, 30'h0} | ($random(seed) & 32'h3FFF_FFFF);
                m0_flat[c*MW +: MW]    = m32[31:16];
                shift_flat[c*SW +: SW] = (($random(seed) & 7) == 0) ? ($unsigned($random(seed)) % 14)
                                                                     : 16 + ($unsigned($random(seed)) % 9);
            end
            act_mode        = $random(seed);
            act_clamp_high  = 8'sd20 + ($unsigned($random(seed)) % 100);
            act_leaky_shift = $random(seed);
            for (c = 0; c < COLS; c = c + 1)
                for (k = 0; k < OF_DEPTH; k = k + 1) gold[c][k] = model_out(c, k);
        end
    endtask

    // read every output entry of one design and compare with the model
    task read_outputs;
        input sel;
        input integer tag;
        reg [N-1:0] v;
        begin
            for (i = 0; i < OF_DEPTH; i = i + 1) begin
                @(negedge clk);
                of_rd_en = {COLS{1'b1}};
                for (c = 0; c < COLS; c = c + 1) of_rd_addr_flat[c*OF_ADDR_W +: OF_ADDR_W] = i;
                @(negedge clk);
                of_rd_en = 0;
                repeat (RD_LAT - 1) @(negedge clk);
                for (c = 0; c < COLS; c = c + 1) begin
                    v = sel ? of_d[c*N +: N] : of_r[c*N +: N];
                    compared = compared + 1;
                    if (v !== gold[c][i]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("[FAIL] %0s tile %0d col %0d entry %0d: got %h model %h",
                                     sel ? "masked" : "unprot", tag, c, i, v, gold[c][i]);
                    end
                end
            end
        end
    endtask

    // full workload on one design: same data sequence for both (seed restarted)
    task workload;
        input sel;
        output integer total, twr, tcmp, trd;
        integer t0, ta, guard;
        begin
            seed = SEED; twr = 0; tcmp = 0; trd = 0;
            @(negedge clk); t0 = cyc;
            for (t = 0; t < NTILES; t = t + 1) begin
                ta = cyc;
                write_mems;
                set_constants;
                twr = twr + (cyc - ta);
                ta = cyc;
                @(negedge clk); if (sel) start_d = 1; else start_r = 1;
                @(negedge clk); start_r = 0; start_d = 0;
                guard = 0;
                while (!(sel ? done_d : done_r) && guard < 2000) begin @(negedge clk); guard = guard + 1; end
                if (guard >= 2000) begin
                    errors = errors + 1;
                    $display("[FAIL] %0s tile %0d: done missing", sel ? "masked" : "unprot", t);
                end
                tcmp = tcmp + (cyc - ta);
                ta = cyc;
                read_outputs(sel, t);
                trd = trd + (cyc - ta);
            end
            total = cyc - t0;
        end
    endtask

    // NBURST tiles started back-to-back on one design (same data in memory)
    task stream;
        input sel;
        output integer span;
        integer nst, nd, guard, tf, tl;
        begin
            nd = 0; nst = 0; guard = 0; tf = 0; tl = 0;
            while (nd < NBURST && guard < 400 * NBURST) begin
                @(negedge clk);
                guard = guard + 1;
                start_r = 0; start_d = 0;
                if (nst == 0 || (nst < NBURST && (sel ? acd_d : acd_r))) begin
                    if (sel) start_d = 1; else start_r = 1;
                    nst = nst + 1;
                end
                if (sel ? done_d : done_r) begin
                    if (nd == 0) tf = cyc;
                    tl = cyc;
                    nd = nd + 1;
                end
            end
            @(negedge clk); start_r = 0; start_d = 0;
            if (nd != NBURST) begin
                errors = errors + 1;
                $display("[FAIL] stream on %0s: %0d of %0d tiles done", sel ? "masked" : "unprot", nd, NBURST);
            end
            span = tl - tf;
        end
    endtask

    initial begin
        if (!$value$plusargs("NTILES=%d", NTILES)) NTILES = 100;
        if (!$value$plusargs("NBURST=%d", NBURST)) NBURST = 100;
        if (!$value$plusargs("SEED=%d",   SEED))   SEED   = 1;
        seed = SEED;
        reset_n = 0; start_r = 0; start_d = 0; if_wr_en = 0; fl_wr_en = 0;
        if_wr_addr = 0; fl_wr_addr = 0; if_wr_data = 0; fl_wr_data = 0;
        bias_flat = 0; m0_flat = 0; shift_flat = 0; act_mode = 0;
        act_clamp_high = 8'sd100; act_leaky_shift = 3'd2; pool_win_len = 1;
        of_rd_en = 0; of_rd_addr_flat = 0;
        repeat (6) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (40) @(posedge clk);

        workload(1'b0, w_r, wr_r, cmp_r, rd_r);
        repeat (20) @(negedge clk);
        workload(1'b1, w_d, wr_d, cmp_d, rd_d);
        repeat (20) @(negedge clk);
        stream(1'b0, s_r);
        repeat (300) @(negedge clk);
        stream(1'b1, s_d);
        repeat (3) @(negedge clk);
        read_outputs(1'b1, -1);                  // last streamed tile still correct

        $display("");
        $display("================ accelerator throughput: unprotected vs masked ================");
        $display("  masked = flexnn_top_protected  NRQ=%0d DOM_REG=%0d", NRQ, DOM_REG);
        $display("  1 tile = %0d MACs = %0d OPs; clock unprotected %0.1f MHz, masked %0.1f MHz",
                 OPS_TILE/2, OPS_TILE, FMHZ_R, FMHZ_D);
        $display("  1) full workload, %0d tiles (write memories + compute + read outputs, new data every tile)", NTILES);
        $display("                     cycles/tile   OPs/cycle   MOPS (OPs/s x1e6)   [write compute read] cycles/tile");
        $display("     unprotected     %11.1f   %9.3f   %17.1f   [%0.1f %0.1f %0.1f]",
                 w_r*1.0/NTILES, OPS_TILE*1.0*NTILES/w_r, OPS_TILE*FMHZ_R*NTILES/w_r,
                 wr_r*1.0/NTILES, cmp_r*1.0/NTILES, rd_r*1.0/NTILES);
        $display("     masked          %11.1f   %9.3f   %17.1f   [%0.1f %0.1f %0.1f]",
                 w_d*1.0/NTILES, OPS_TILE*1.0*NTILES/w_d, OPS_TILE*FMHZ_D*NTILES/w_d,
                 wr_d*1.0/NTILES, cmp_d*1.0/NTILES, rd_d*1.0/NTILES);
        $display("     masked throughput = %0.1f%% of unprotected (OPs/s)",
                 100.0 * (FMHZ_D*NTILES/w_d) / (FMHZ_R*NTILES/w_r));
        $display("  2) compute stream, %0d tiles back-to-back (data already in memory)", NBURST);
        $display("     unprotected     %11.1f   %9.3f   %17.1f",
                 s_r*1.0/(NBURST-1), OPS_TILE*(NBURST-1)*1.0/s_r, OPS_TILE*FMHZ_R*(NBURST-1)/s_r);
        $display("     masked          %11.1f   %9.3f   %17.1f",
                 s_d*1.0/(NBURST-1), OPS_TILE*(NBURST-1)*1.0/s_d, OPS_TILE*FMHZ_D*(NBURST-1)/s_d);
        $display("     masked throughput = %0.1f%% of unprotected (OPs/s)",
                 100.0 * (FMHZ_D/s_d) / (FMHZ_R/s_r));
        $display("  peak of the array: %0d OPs/cycle", 2*ROWS*COLS);
        $display("  outputs checked against the model: %0d", compared);
        if (errors == 0) $display("  [THRU] PASS: every output correct, every tile finished");
        else             $display("  [THRU] FAIL: %0d errors", errors);
        $display("================================================================================");
        $finish;
    end
endmodule
