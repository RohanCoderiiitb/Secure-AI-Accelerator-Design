`timescale 1ns/1ps
//=====================================================================
// tb_masked_pe_equiv.sv -- Phase 2 gate: masked PE == baseline PE
//
// Drives the UNCHANGED baseline `processing_element` and the new
// `processing_element_masked` (via weight_splitter + mask_rng) with the
// same stimulus and checks EVERY cycle:
//     (psum0_out + psum1_out) mod 2^SW == baseline psum_out
//     (wt0_out   + wt1_out  ) mod 2^SW == sext(baseline wt_out)
//     act_out, valid_out identical
// Directed corner cases first (incl. -128 x -128, extreme psums), then
// random. Public psum is split into random shares (0,P when mask_en=0).
//
//   +NTRIALS=<n>  random cycles (default 20000; ~6 ms/cycle)   +SEED=<n>
//   +MASK_EN=0|1  (default 1).  With 0 additionally asserts share 0 is
//                 identically zero (positive-control collapse).
// Prints "PASS" / "FAIL" and a summary. Compile:
//   iverilog -g2012 -I ../../scripts -o eq.vvp tb_masked_pe_equiv.sv \
//     ../source/*.sv ../../source/processing_element.sv ../../source/multiplier.sv
//=====================================================================
module tb_masked_pe_equiv;
    localparam N  = 8;
    localparam SW = 32;
    localparam real CLK_NS = 10.0;

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg                    reset_n, wt_load, valid_in, mask_en;
    reg signed [N-1:0]     wt_in, act_in;
    reg signed [SW-1:0]    psum_pub;            // public partial sum

    // ---------------- reference (baseline, untouched) ----------------
    wire                   r_valid;
    wire signed [N-1:0]    r_wt_out, r_act_out;
    wire signed [SW-1:0]   r_psum_out;
    processing_element #(.N(N), .ACCW(SW)) u_ref (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_in(wt_in),
        .valid_in(valid_in), .act_in(act_in), .psum_in(psum_pub),
        .valid_out(r_valid), .wt_out(r_wt_out), .act_out(r_act_out),
        .psum_out(r_psum_out));

    // ---------------- masked path ----------------
    wire [SW-1:0] mk_r, mk_wt0, mk_wt1;
    reg  [SW-1:0] ps0_in, ps1_in;
    wire          m_valid;
    wire signed [N-1:0] m_act_out;
    wire [SW-1:0] m_wt0_out, m_wt1_out, m_ps0_out, m_ps1_out;

    mask_rng #(.W(SW), .SEED(64'd1)) u_rng (
        .clk(clk), .reset_n(reset_n), .advance(wt_load), .r(mk_r));
    weight_splitter #(.N(N), .SHARE_W(SW), .COLS(1)) u_split (
        .mask_en(mask_en), .wt_flat(wt_in), .r_flat(mk_r),
        .wt0_flat(mk_wt0), .wt1_flat(mk_wt1));
    processing_element_masked #(.N(N), .SHARE_W(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
        .wt0_in(mk_wt0), .wt1_in(mk_wt1), .valid_in(valid_in),
        .act_in(act_in), .psum0_in(ps0_in), .psum1_in(ps1_in),
        .valid_out(m_valid), .wt0_out(m_wt0_out), .wt1_out(m_wt1_out),
        .act_out(m_act_out), .psum0_out(m_ps0_out), .psum1_out(m_ps1_out));

    `include "sca_capture.vh"      // project PRNG (rand_i8 / rand_word)

    integer NTRIALS, errors, cycles, loads, dup_mask, zero_mask, i, j, k, mc;
    reg [SW-1:0] last_r;
    reg signed [N-1:0] ext_w [0:4];
    reg signed [N-1:0] ext_a [0:4];
    reg signed [SW-1:0] ext_p [0:3];
    reg [SW-1:0] sh;

    // ---- one clock: drive at negedge, check just after posedge ----
    task drive_and_check(input ld, input v, input signed [N-1:0] w,
                         input signed [N-1:0] a, input signed [SW-1:0] p);
        begin
            @(negedge clk);
            wt_load = ld; valid_in = v; wt_in = w; act_in = a; psum_pub = p;
            sh     = rand_word(SW);
            ps0_in = mask_en ? sh : {SW{1'b0}};
            ps1_in = p - ps0_in;
            @(posedge clk);
            if (ld) begin
                loads = loads + 1;
                if (mask_en) begin
                    if (mk_r === last_r) dup_mask = dup_mask + 1;
                    if (mk_wt0 === {SW{1'b0}}) zero_mask = zero_mask + 1;
                end
                last_r = mk_r;
            end
            #1;
            cycles = cycles + 1;
            if ((m_ps0_out + m_ps1_out) !== r_psum_out) begin
                errors = errors + 1;
                if (errors < 10)
                    $display("MISMATCH psum @%0t: shares %h+%h != ref %h", $time,
                             m_ps0_out, m_ps1_out, r_psum_out);
            end
            if ((m_wt0_out + m_wt1_out) !== {{(SW-N){r_wt_out[N-1]}}, r_wt_out}) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH wt @%0t", $time);
            end
            if (m_act_out !== r_act_out || m_valid !== r_valid) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH act/valid @%0t", $time);
            end
            if (!mask_en && m_ps0_out !== {SW{1'b0}}) begin
                errors = errors + 1;
                if (errors < 10) $display("mask_en=0 but share0 psum nonzero @%0t", $time);
            end
        end
    endtask

    initial begin
        sca_get_config("equiv");
        if (!$value$plusargs("NTRIALS=%d", NTRIALS)) NTRIALS = 20000;
        if (!$value$plusargs("MASK_EN=%d", mc))      mc = 1;
        mask_en = (mc != 0);
        errors = 0; cycles = 0; loads = 0; dup_mask = 0; zero_mask = 0;
        last_r = {SW{1'bx}};

        ext_w[0] = -128; ext_w[1] = 127; ext_w[2] = 0; ext_w[3] = -1; ext_w[4] = 1;
        ext_a[0] = -128; ext_a[1] = 127; ext_a[2] = 0; ext_a[3] = -1; ext_a[4] = 1;
        ext_p[0] = 0; ext_p[1] = 32'sh7FFFFFFF; ext_p[2] = 32'sh80000000; ext_p[3] = -1;

        reset_n = 1'b0; wt_load = 1'b0; valid_in = 1'b0;
        wt_in = 0; act_in = 0; psum_pub = 0; ps0_in = 0; ps1_in = 0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("[EQ] mask_en=%0d  directed corners, then %0d random cycles", mask_en, NTRIALS);

        // ---- directed: every (weight, act, psum) corner ----
        for (i = 0; i < 5; i = i + 1)
            for (j = 0; j < 5; j = j + 1) begin
                drive_and_check(1'b1, 1'b0, ext_w[i], 0, 0);         // load
                for (k = 0; k < 4; k = k + 1)
                    drive_and_check(1'b0, 1'b1, 0, ext_a[j], ext_p[k]);
            end

        // ---- random ----
        for (i = 0; i < NTRIALS; i = i + 1)
            drive_and_check((rand_word(3) == 0), (rand_word(3) != 0),
                            rand_i8(0), rand_i8(0), $signed(rand_word(SW)));

        $display("[EQ] cycles=%0d  weight loads=%0d  mismatches=%0d", cycles, loads, errors);
        if (mask_en)
            $display("[EQ] mask freshness: repeated mask on consecutive loads=%0d, zero share-0 on load=%0d (both expect 0)",
                     dup_mask, zero_mask);
        if (errors == 0 && dup_mask == 0 && zero_mask == 0) $display("PASS");
        else                                               $display("FAIL");
        $finish;
    end
endmodule
