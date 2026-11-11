`timescale 1ns/1ps
//=====================================================================
// tb_func_wmask_shared.sv -- functional check of systolic_array_wmask_shared
//
// Runs the BASELINE systolic_array and the new masked array side by side
// on identical stimulus and compares, EVERY cycle of every tile:
//     psum_out, valid_sum_out, act_out, valid_act_out
//
// Also checks the masking itself:
//   mask_en=1 : stored PE weights must differ from sext(w) (masked) and
//               all R words must be non-zero
//   mask_en=0 : stored PE weights must equal sext(w) exactly (positive
//               control path is really unmasked)
//
// Phases: NTILES tiles mask_en=1 psum_flat=0, NTILES tiles mask_en=1 with
// small random psum_flat (tiling), NTILES tiles mask_en=0.
// Corner tiles: all-max/all-min weights and activations.
//
// Compile (from the folder with the RTL):
//   iverilog -g2012 -o func.vvp multiplier.sv processing_element.sv \
//            systolic_array.sv systolic_array_wmask_shared.sv tb_func_wmask_shared.sv
//   vvp func.vvp [+NTILES=200] [+SEED=1]
// Geometry: -Ptb_func_wmask_shared.ROWS=8 -Ptb_func_wmask_shared.COLS=8
//=====================================================================
module tb_func_wmask_shared;
    parameter N    = 8;
    parameter ACCW = 32;
    parameter ROWS = 5;
    parameter COLS = 5;
    localparam SW  = 2*N + $clog2(ROWS);

    localparam STREAM_LEN = 6;
    localparam RUN        = STREAM_LEN + ROWS + COLS + 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                  reset_n, wt_load, mask_en, mask_refresh;
    reg  [COLS*N-1:0]    wt_flat;
    reg  [ROWS-1:0]      valid_act_in;
    reg  [ROWS*N-1:0]    act_flat;
    reg  [COLS*ACCW-1:0] psum_flat;

    wire [COLS*ACCW-1:0] ps_ref, ps_dut;
    wire [COLS-1:0]      vs_ref, vs_dut;
    wire [ROWS*N-1:0]    ao_ref, ao_dut;
    wire [ROWS-1:0]      va_ref, va_dut;

`ifdef WMASK_PREMASK
    // accelerator copy: tb acts as the load controller, masking each column with the array's row mask
    wire [SW-1:0]        r_sel_dut;
    wire [COLS*SW-1:0]   wt_flat_m;
    genvar gm;
    generate
        for (gm = 0; gm < COLS; gm = gm + 1) begin : g_m
            assign wt_flat_m[gm*SW +: SW] = {{(SW-N){wt_flat[gm*N+N-1]}}, wt_flat[gm*N +: N]} - r_sel_dut;
        end
    endgenerate
`endif

    systolic_array #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_ref (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat), .psum_flat(psum_flat),
        .psum_out(ps_ref), .valid_sum_out(vs_ref), .act_out(ao_ref), .valid_act_out(va_ref));

    systolic_array_wmask_shared #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk(clk), .reset_n(reset_n), .mask_en(mask_en), .mask_refresh(mask_refresh),
`ifdef WMASK_PREMASK
        .wt_load(wt_load), .wt_flat(wt_flat_m), .r_sel_out(r_sel_dut),
`else
        .wt_load(wt_load), .wt_flat(wt_flat),
`endif
        .valid_act_in(valid_act_in), .act_flat(act_flat), .psum_flat(psum_flat),
        .psum_out(ps_dut), .valid_sum_out(vs_dut), .act_out(ao_dut), .valid_act_out(va_dut));

    integer NTILES, SEED, seed;
    integer errors = 0, checks = 0, valid_checks = 0;
    integer masked_hits = 0, masked_total = 0;

    reg signed [N-1:0] W   [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0] A   [0:STREAM_LEN-1][0:ROWS-1];

    function signed [N-1:0] rnd8; input integer dummy; begin rnd8 = $random(seed); end endfunction

    // ---- compare every cycle (sample just before the next posedge) ----
    always @(negedge clk) if (reset_n === 1'b1) begin
        checks = checks + 1;
        if (vs_ref !== vs_dut || va_ref !== va_dut || ao_ref !== ao_dut) begin
            errors = errors + 1;
            if (errors <= 10) $display("[FAIL] t=%0t valid/act mismatch", $time);
        end
        if (ps_ref !== ps_dut) begin
            errors = errors + 1;
            if (errors <= 10) $display("[FAIL] t=%0t psum mismatch ref=%h dut=%h", $time, ps_ref, ps_dut);
        end
        if (|vs_ref) valid_checks = valid_checks + 1;
    end

    task refresh_masks;
        begin
            @(negedge clk); mask_refresh = 1'b1;
            repeat (ROWS) @(posedge clk);
            @(negedge clk); mask_refresh = 1'b0;
        end
    endtask

    task load_weights;
        integer rr, cc;
        begin
            for (rr = ROWS-1; rr >= 0; rr = rr - 1) begin
                @(negedge clk);
                wt_load = 1'b1;
                for (cc = 0; cc < COLS; cc = cc + 1) wt_flat[cc*N +: N] = W[rr][cc];
                @(posedge clk);
            end
            @(negedge clk);
            wt_load = 1'b0;
            wt_flat = {(COLS*N){1'b0}};
        end
    endtask

    // check what each PE actually stores
    task check_storage;
        input expect_masked;
        reg [SW-1:0] ext;
        reg [SW-1:0] stored;
        integer rr, cc;
        begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    ext = {{(SW-N){W[rr][cc][N-1]}}, W[rr][cc]};
                    stored = peek(rr, cc);
                    if (expect_masked) begin
                        masked_total = masked_total + 1;
                        if (stored != ext) masked_hits = masked_hits + 1;
                    end else if (stored !== ext) begin
                        errors = errors + 1;
                        if (errors <= 10) $display("[FAIL] mask_en=0 but PE(%0d,%0d) holds %h, expected %h", rr, cc, stored, ext);
                    end
                end
        end
    endtask

    // hierarchical peek into the PE weight registers
    wire [SW-1:0] pe_w [0:ROWS*COLS-1];
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_pk_r
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_pk_c
                assign pe_w[gr*COLS+gc] = u_dut.g_row[gr].g_col[gc].pe_inst.wt_reg;
            end
        end
    endgenerate
    function [SW-1:0] peek;
        input integer rr, cc;
        begin
            peek = pe_w[rr*COLS + cc];
        end
    endfunction

    task run_tile;
        input integer kind;      // 0 random, 1 all max, 2 all min, 3 mixed extremes
        input use_psum_flat;
        integer k, r, c, cyc, idx;
        begin
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    case (kind)
                        1: W[r][c] = 8'sd127;
                        2: W[r][c] = -8'sd128;
                        3: W[r][c] = ((r+c) & 1) ? 8'sd127 : -8'sd128;
                        default: W[r][c] = rnd8(0);
                    endcase
            for (k = 0; k < STREAM_LEN; k = k + 1)
                for (r = 0; r < ROWS; r = r + 1)
                    case (kind)
                        1: A[k][r] = 8'sd127;
                        2: A[k][r] = -8'sd128;
                        3: A[k][r] = ((k+r) & 1) ? -8'sd128 : 8'sd127;
                        default: A[k][r] = rnd8(0);
                    endcase
            for (c = 0; c < COLS; c = c + 1)
                psum_flat[c*ACCW +: ACCW] = use_psum_flat ? ($random(seed) % 4096) : 0;

            refresh_masks;
            load_weights;
            check_storage(mask_en);

            for (cyc = 0; cyc < RUN; cyc = cyc + 1) begin
                @(negedge clk);
                for (r = 0; r < ROWS; r = r + 1) begin
                    idx = cyc - r;
                    if (idx >= 0 && idx < STREAM_LEN) begin
                        act_flat[r*N +: N] = A[idx][r];
                        valid_act_in[r]    = 1'b1;
                    end else begin
                        act_flat[r*N +: N] = {N{1'b0}};
                        valid_act_in[r]    = 1'b0;
                    end
                end
                @(posedge clk);
            end
            @(negedge clk);
            valid_act_in = {ROWS{1'b0}};
            act_flat     = {(ROWS*N){1'b0}};
            psum_flat    = {(COLS*ACCW){1'b0}};
        end
    endtask

    integer t, rr;
    reg [SW-1:0] rword;
    initial begin
        if (!$value$plusargs("NTILES=%d", NTILES)) NTILES = 200;
        if (!$value$plusargs("SEED=%d",   SEED))   SEED   = 1;
        seed = SEED;
        $display("[FUNC] ROWS=%0d COLS=%0d SW=%0d NTILES=%0d/phase", ROWS, COLS, SW, NTILES);

        reset_n = 0; wt_load = 0; mask_en = 1; mask_refresh = 0;
        wt_flat = 0; valid_act_in = 0; act_flat = 0; psum_flat = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (2) @(posedge clk);

        // corner tiles, masked
        mask_en = 1;
        for (t = 1; t <= 3; t = t + 1) run_tile(t, 0);

        // phase 1: masked, single tile
        for (t = 0; t < NTILES; t = t + 1) begin
            run_tile(0, 0);
            if (t == 0)
                for (rr = 0; rr < ROWS; rr = rr + 1) begin
                    rword = u_dut.R[rr];
                    if (rword == 0) begin
                        errors = errors + 1;
                        $display("[FAIL] R[%0d] is zero with mask_en=1", rr);
                    end
                end
        end
        // phase 2: masked, with psum_flat
        for (t = 0; t < NTILES; t = t + 1) run_tile(0, 1);
        // phase 3: positive control, unmasked
        mask_en = 0;
        for (t = 1; t <= 3; t = t + 1) run_tile(t, 0);
        for (t = 0; t < NTILES; t = t + 1) run_tile(0, 0);

        $display("[FUNC] cycles compared=%0d (with valid output=%0d)", checks, valid_checks);
        $display("[FUNC] masked storage: %0d / %0d PE weights differ from plaintext", masked_hits, masked_total);
        if (masked_hits * 100 < masked_total * 99) begin
            errors = errors + 1;
            $display("[FAIL] too many PEs hold the plaintext weight with mask_en=1");
        end
        if (errors == 0) $display("[FUNC] PASS");
        else             $display("[FUNC] FAIL  errors=%0d", errors);
        $finish;
    end
endmodule
