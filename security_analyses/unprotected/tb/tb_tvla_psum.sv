`timescale 1ns/1ps
//=====================================================================
// tb_tvla_psum.v -- TVLA dataset generation for the tile partial-sum
//                   accumulator bank at the south edge of the array.
//
// This block holds a full tile of accumulated results in mem[] and is a
// genuine leakage surface: the read-modify-write of mem[addr] produces
// an HD proportional to the difference between the old and new tile
// partial sums, i.e. directly on the accumulated dot products.
//
// The fixed/random contrast is applied to psum_in, which is what the
// array actually delivers. Addressing and tile control are identical
// across both populations so no control-flow difference can alias into
// the t-statistic.
//=====================================================================
module tb_tvla_psum;

    localparam N     = 8;
    localparam ACCW  = 32;
    localparam COLS  = 5;
    localparam DEPTH = 32;
    localparam AW    = 6;
    localparam real CLK_NS = 10.0;

    localparam TILES    = 2;        // accumulate across 2 tiles
    localparam VECS     = 4;        // rows written per tile
    localparam CAPTURE  = TILES*VECS + 2;
    localparam FLUSH    = 4;

    reg                     clk = 1'b0;
    reg                     reset_n, tile_start, first_tile, last_tile;
    reg  [COLS-1:0]         valid_in;
    reg  [COLS*ACCW-1:0]    psum_in;
    wire [COLS*ACCW-1:0]    psum_out;
    wire [COLS-1:0]         valid_out;
    wire [COLS-1:0]         ovf;

    (* dont_touch = "yes" *)
    psum_accum #(.N(N), .ACCW(ACCW), .COLS(COLS), .DEPTH(DEPTH), .AW(AW)) u_dut (
        .clk(clk), .reset_n(reset_n),
        .tile_start(tile_start), .first_tile(first_tile), .last_tile(last_tile),
        .valid_in(valid_in), .psum_in(psum_in),
        .psum_out(psum_out), .valid_out(valid_out), .ovf(ovf)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [ACCW-1:0] fix_ps [0:TILES*VECS-1][0:COLS-1];
    reg signed [ACCW-1:0] cur_ps [0:TILES*VECS-1][0:COLS-1];

    integer t, k, c, tl, v, step;
    reg grp, eff;

    // Realistic magnitudes: an INT8 x INT8 dot product of length ROWS
    // occupies far fewer than ACCW bits. Feeding uniform 32-bit noise
    // would inflate the HD and overstate the leakage.
    function signed [ACCW-1:0] rand_psum(input integer dummy);
        reg [63:0] r;
        begin
            r         = xs64s(0);
            rand_psum = $signed({{(ACCW-18){r[17]}}, r[17:0]});   // ~ +/-2^17
        end
    endfunction

    // Icarus resolves a hierarchical array-word reference at elaboration
    // only for constant indices, so the lane/word pairs are enumerated by
    // a generate-free explicit case. For a large DEPTH sweep, generate the
    // equivalent block with a script rather than extending this by hand.
    task dump_mem_word(input integer lane, input integer word);
        begin
            case (lane)
                0: $dumpvars(1, u_dut.g_lane[0].mem[word]);
                1: $dumpvars(1, u_dut.g_lane[1].mem[word]);
                2: $dumpvars(1, u_dut.g_lane[2].mem[word]);
                3: $dumpvars(1, u_dut.g_lane[3].mem[word]);
                4: $dumpvars(1, u_dut.g_lane[4].mem[word]);
                default: ;
            endcase
        end
    endtask

    initial begin
        sca_get_config("psum");

        for (k = 0; k < TILES*VECS; k = k + 1)
            for (c = 0; c < COLS; c = c + 1)
                fix_ps[k][c] = rand_psum(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        // $dumpvars does NOT descend into memory arrays. mem[] is the
        // dominant storage element in this block, so without the explicit
        // per-word dump below its Hamming Distance -- the read-modify-write
        // on the accumulated tile partial sums -- is silently absent from
        // P_reg. Only the first TILES*VECS words are ever addressed here.
        for (k = 0; k < TILES*VECS; k = k + 1)
            for (c = 0; c < COLS; c = c + 1)
                dump_mem_word(c, k);

        sca_open_meta("psum_accum", CLK_NS, CAPTURE);

        reset_n = 1'b0; tile_start = 1'b0; first_tile = 1'b0; last_tile = 1'b0;
        valid_in = {COLS{1'b0}}; psum_in = {(COLS*ACCW){1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw for both groups, then overwrite for the fixed one.
            for (k = 0; k < TILES*VECS; k = k + 1)
                for (c = 0; c < COLS; c = c + 1) begin
                    cur_ps[k][c] = rand_psum(0);
                    if (!eff) cur_ps[k][c] = fix_ps[k][c];
                end

            // ---- flush, untriggered ----
            @(negedge clk);
            valid_in = {COLS{1'b0}}; psum_in = {(COLS*ACCW){1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            step = 0;
            for (tl = 0; tl < TILES; tl = tl + 1) begin
                for (v = 0; v < VECS; v = v + 1) begin
                    @(negedge clk);      // drive off the negedge (see note)
                    tile_start = (v == 0);
                    first_tile = (tl == 0);
                    last_tile  = (tl == TILES-1);
                    valid_in   = {COLS{1'b1}};
                    for (c = 0; c < COLS; c = c + 1)
                        psum_in[c*ACCW +: ACCW] = cur_ps[step][c];
                    @(posedge clk);
                    if (step == 0) sca_trace_begin;
                    step = step + 1;
                end
            end
            @(negedge clk);
            tile_start = 1'b0; first_tile = 1'b0; last_tile = 1'b0;
            valid_in = {COLS{1'b0}}; psum_in = {(COLS*ACCW){1'b0}};
            repeat (2) @(posedge clk);
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
