`timescale 1ns/1ps
//=====================================================================
// tb_act_masker.sv -- act_mask_rng / act_splitter / act_masker
//
// Compile (from protected_designs/sim):
//   iverilog -g2012 -o masker.vvp ../source/act_masker.sv tb_act_masker.sv
//   vvp masker.vvp
//
//   T1 splitter: ALL 256 activations x random masks: a0 + a1 == sext(a)
//   T2 mask_en=0: a0 == 0, a1 == sext(a)  (positive control)
//   T3 rng: holds when advance=0, changes on every advance, resets to seed
//   T4 act_masker: recombination holds every cycle for every row; each
//      row's mask stream differs from its neighbours'; no zero/repeated
//      mask while masking is on
//   T5 a single share is (almost) never equal to the plaintext
//=====================================================================
module tb_act_masker;
    localparam N = 8, SW = 32, ROWS = 5;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg reset_n = 1'b0, advance = 1'b0, mask_en = 1'b1;
    reg [ROWS*N-1:0] act_flat = 0;
    wire [ROWS*SW-1:0] a0_flat, a1_flat;

    act_masker #(.N(N), .SHARE_W(SW), .ROWS(ROWS), .SEED(64'd1)) dut (
        .clk(clk), .reset_n(reset_n), .advance(advance), .mask_en(mask_en),
        .act_flat(act_flat), .act0_flat(a0_flat), .act1_flat(a1_flat));

    // standalone splitter for the exhaustive test
    reg  [N-1:0]  s_a = 0;
    reg  [SW-1:0] s_r = 0;
    reg           s_en = 1;
    wire [SW-1:0] s_a0, s_a1;
    act_splitter #(.N(N), .SHARE_W(SW), .ROWS(1)) u_sp (
        .mask_en(s_en), .act_flat(s_a), .r_flat(s_r), .act0_flat(s_a0), .act1_flat(s_a1));

    // standalone rng
    reg           g_adv = 0;
    wire [SW-1:0] g_r;
    act_mask_rng #(.W(SW), .SEED(64'd1)) u_g (.clk(clk), .reset_n(reset_n), .advance(g_adv), .r(g_r));

    reg [63:0] st = 64'h9E3779B97F4A7C15;
    function [63:0] rnd64(input dummy);
        reg [63:0] t;
        begin
            t = st ^ (st >> 12); t = t ^ (t << 25); t = t ^ (t >> 27);
            st = t;
            rnd64 = t * 64'h2545F4914F6CDD1D;
        end
    endfunction

    integer errs = 0, checks = 0, i, r, hits, same_row, rep, zero;
    reg [SW-1:0] ext, prev_r, hold_r, seed_r;
    reg [SW-1:0] prev_m [0:ROWS-1];
    reg [SW-1:0] cur_m;

    task bad(input [8*32-1:0] msg);
        begin
            errs = errs + 1;
            if (errs <= 15) $display("  FAIL %0s", msg);
        end
    endtask

    initial begin
        // ---- T1/T2: splitter, exhaustive in a ----
        for (i = 0; i < 256; i = i + 1) begin
            s_a = i[N-1:0]; s_r = rnd64(0); s_en = 1; #1;
            ext = {{(SW-N){s_a[N-1]}}, s_a};
            checks = checks + 1;
            if (s_a0 + s_a1 !== ext || s_a0 !== s_r) bad("T1 splitter");
            s_en = 0; #1;
            checks = checks + 1;
            if (s_a0 !== 0 || s_a1 !== ext) bad("T2 mask off");
        end
        $display("T1/T2 splitter + mask-off : done");

        // ---- T3: rng ----
        repeat (3) @(posedge clk);
        #1 seed_r = g_r;
        checks = checks + 1;
        if (seed_r !== 32'd1) bad("T3 seed value");
        reset_n = 1'b1;
        @(negedge clk); g_adv = 0;
        repeat (4) @(posedge clk); #1;
        checks = checks + 1;
        if (g_r !== seed_r) bad("T3 hold");
        prev_r = g_r; g_adv = 1;
        for (i = 0; i < 1000; i = i + 1) begin
            @(posedge clk); #1;
            checks = checks + 1;
            if (g_r === prev_r) bad("T3 advance");
            prev_r = g_r;
        end
        g_adv = 0;
        $display("T3 rng hold/advance       : done");

        // ---- T4/T5: act_masker ----
        for (r = 0; r < ROWS; r = r + 1) prev_m[r] = 0;
        reset_n = 0; repeat (2) @(posedge clk); @(negedge clk); reset_n = 1; advance = 1;
        mask_en = 1; same_row = 0; rep = 0; zero = 0; hits = 0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            for (r = 0; r < ROWS; r = r + 1) act_flat[r*N +: N] = rnd64(0);
            #1;
            for (r = 0; r < ROWS; r = r + 1) begin
                ext = {{(SW-N){act_flat[r*N+N-1]}}, act_flat[r*N +: N]};
                cur_m = a0_flat[r*SW +: SW];
                checks = checks + 1;
                if (a0_flat[r*SW +: SW] + a1_flat[r*SW +: SW] !== ext) bad("T4 recombine");
                if (cur_m === prev_m[r]) rep = rep + 1;
                if (cur_m === 0)         zero = zero + 1;
                if (r > 0 && cur_m === a0_flat[(r-1)*SW +: SW]) same_row = same_row + 1;
                if (a0_flat[r*SW +: SW] === ext || a1_flat[r*SW +: SW] === ext) hits = hits + 1;
                prev_m[r] = cur_m;
            end
        end
        checks = checks + 3;
        if (rep != 0)      begin errs = errs + 1; $display("  FAIL T4: %0d repeated masks", rep); end
        if (zero != 0)     begin errs = errs + 1; $display("  FAIL T4: %0d zero masks", zero); end
        if (same_row != 0) begin errs = errs + 1; $display("  FAIL T4: %0d equal masks across rows", same_row); end
        if (hits > 20) begin errs = errs + 1; $display("  FAIL T5: single share equalled plaintext %0d times", hits); end
        $display("T4/T5 act_masker          : done (repeat=%0d zero=%0d cross-row=%0d share==plain=%0d)",
                 rep, zero, same_row, hits);

        // mask_en=0 through the full masker
        mask_en = 0;
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk);
            for (r = 0; r < ROWS; r = r + 1) act_flat[r*N +: N] = rnd64(0);
            #1;
            for (r = 0; r < ROWS; r = r + 1) begin
                ext = {{(SW-N){act_flat[r*N+N-1]}}, act_flat[r*N +: N]};
                checks = checks + 1;
                if (a0_flat[r*SW +: SW] !== 0 || a1_flat[r*SW +: SW] !== ext) bad("T2 masker mask off");
            end
        end

        $display("------------------------------------------------");
        $display("TOTAL: %0d checks, %0d errors -> %0s", checks, errs, (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
