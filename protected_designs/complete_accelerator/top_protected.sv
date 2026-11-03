//=====================================================================
// top_protected.sv -- weight-protected flexnn accelerator
//
// Same ports, memories, controllers and dataflow as flexnn_top
// (source/top.sv). The weight-dependent datapath is masked end to end:
//
//   systolic_array_wmask_shares  one masked weight share per PE + shadow
//                                column; result leaves as two shares
//   psum_accum_masked            accumulates each share separately
//   requantize_masked (x COLS)   masked requant, Boolean shares out
//   rng_bank (x COLS)            fresh randomness for the requantizers
//
// The two output shares are combined only at the activation-unit input
// (and for the requant_sat_flat port), outside the masked datapath.
// The activation unit, maxpool, output buffer and the weight-load path
// (FL global buffer, load controller) are NOT masked.
//
// On start, the per-row weight masks are refreshed for ARRAY_ROWS cycles,
// then the unchanged load controller is started.
//=====================================================================
module flexnn_top_protected #(
    parameter N          = 8,
    parameter ACCW       = 32,
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    parameter WAVES      = 4,

    parameter MW         = 32,
    parameter SW         = 6,
    parameter POOL_LEN   = 1,

    parameter IF_DEPTH   = ARRAY_ROWS * WAVES,
    parameter FL_DEPTH   = ARRAY_ROWS * ARRAY_COLS,
    parameter OF_DEPTH   = WAVES / POOL_LEN,

    parameter IF_ADDR_W  = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH),
    parameter FL_ADDR_W  = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH),
    parameter OF_ADDR_W  = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH),
    parameter WADDR_W    = (WAVES    <= 1) ? 1 : $clog2(WAVES),
    parameter CW         = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1),

    parameter XW         = 2*N + $clog2(ARRAY_ROWS),   // share width of the masked datapath
    parameter DOM_REG    = 1                           // 1: glitch-robust requant, 0: low latency
) (
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    output wire done,
    output wire array_compute_done,

    input  wire                        if_wr_en,
    input  wire [IF_ADDR_W-1:0]        if_wr_addr,
    input  wire [N-1:0]                if_wr_data,

    input  wire                        fl_wr_en,
    input  wire [FL_ADDR_W-1:0]        fl_wr_addr,
    input  wire [N-1:0]                fl_wr_data,

    input  wire [ARRAY_COLS*ACCW-1:0]  bias_flat,
    input  wire [ARRAY_COLS*MW-1:0]    m0_flat,
    input  wire [ARRAY_COLS*SW-1:0]    shift_flat,

    input  wire [1:0]                  act_mode,
    input  wire signed [N-1:0]         act_clamp_high,
    input  wire [2:0]                  act_leaky_shift,

    input  wire [CW-1:0]               pool_win_len,

    output wire [ARRAY_COLS-1:0]       psum_ovf_flat,
    output wire [ARRAY_COLS-1:0]       requant_sat_flat,

    input  wire [ARRAY_COLS-1:0]           of_rd_en,
    input  wire [ARRAY_COLS*OF_ADDR_W-1:0] of_rd_addr_flat,
    output wire [ARRAY_COLS*N-1:0]         of_rd_data_flat
);

    wire                if_gb_rd_en;
    wire [IF_ADDR_W-1:0] if_gb_rd_addr;
    wire [N-1:0]         if_gb_rd_data;

    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (IF_DEPTH),
        .GB_ADDR_WIDTH (IF_ADDR_W)
    ) u_if_gb (
        .clk     (clk),
        .wr_en   (if_wr_en),
        .wr_addr (if_wr_addr),
        .wr_data (if_wr_data),
        .rd_en   (if_gb_rd_en),
        .rd_addr (if_gb_rd_addr),
        .rd_data (if_gb_rd_data)
    );

    wire                fl_gb_rd_en;
    wire [FL_ADDR_W-1:0] fl_gb_rd_addr;
    wire [N-1:0]         fl_gb_rd_data;

    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (FL_DEPTH),
        .GB_ADDR_WIDTH (FL_ADDR_W)
    ) u_fl_gb (
        .clk     (clk),
        .wr_en   (fl_wr_en),
        .wr_addr (fl_wr_addr),
        .wr_data (fl_wr_data),
        .rd_en   (fl_gb_rd_en),
        .rd_addr (fl_gb_rd_addr),
        .rd_data (fl_gb_rd_data)
    );

    wire [ARRAY_ROWS-1:0]         row_wr_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] row_wr_addr_flat;
    wire [N-1:0]                  row_wr_data;

    wire                     wt_load;
    wire [ARRAY_COLS*N-1:0]  wt_flat;

    wire stream_start;
    wire compute_done;
    wire array_done;

    // ---------------- mask refresh before every weight load ----------------
    reg [7:0] rf_cnt;
    reg       lc_start;
    wire      mask_refresh = (rf_cnt != 8'd0);
    always @(posedge clk) begin
        if (!reset_n) begin
            rf_cnt   <= 8'd0;
            lc_start <= 1'b0;
        end else begin
            lc_start <= 1'b0;
            if (start && rf_cnt == 8'd0) rf_cnt <= ARRAY_ROWS;
            else if (rf_cnt != 8'd0) begin
                rf_cnt <= rf_cnt - 1'b1;
                if (rf_cnt == 8'd1) lc_start <= 1'b1;
            end
        end
    end

    load_controller #(
        .N          (N),
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_load_ctrl (
        .clk               (clk),
        .reset_n           (reset_n),
        .start             (lc_start),
        .done              (array_done),

        .if_rd_en          (if_gb_rd_en),
        .if_rd_addr        (if_gb_rd_addr),
        .if_rd_data        (if_gb_rd_data),

        .row_wr_en         (row_wr_en),
        .row_wr_addr_flat  (row_wr_addr_flat),
        .row_wr_data       (row_wr_data),

        .fl_rd_en          (fl_gb_rd_en),
        .fl_rd_addr        (fl_gb_rd_addr),
        .fl_rd_data        (fl_gb_rd_data),

        .wt_load           (wt_load),
        .wt_flat           (wt_flat),

        .stream_start      (stream_start),
        .compute_done      (compute_done)
    );

    assign array_compute_done = array_done;

    wire [ARRAY_ROWS-1:0]         act_rd_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] act_rd_addr_flat;
    wire [ARRAY_ROWS-1:0]         act_valid;
    wire [ARRAY_ROWS*N-1:0]       act_flat;

    genvar r;
    generate
        for (r = 0; r < ARRAY_ROWS; r = r + 1) begin : g_act_spad
            scratchpad #(
                .DATA_WIDTH (N),
                .SPAD_DEPTH (WAVES)
            ) u_act_spad (
                .clk     (clk),
                .wr_en   (row_wr_en[r]),
                .wr_addr (row_wr_addr_flat[r*WADDR_W +: WADDR_W]),
                .wr_data (row_wr_data),
                .rd_en   (act_rd_en[r]),
                .rd_addr (act_rd_addr_flat[r*WADDR_W +: WADDR_W]),
                .rd_data (act_flat[r*N +: N])
            );
        end
    endgenerate

    wire [ARRAY_COLS*XW-1:0]   arr_psum0_out, arr_psum1_out;
    wire [ARRAY_COLS-1:0]      valid_sum_out;
    wire [ARRAY_ROWS*N-1:0]    arr_act_out;
    wire [ARRAY_ROWS-1:0]      arr_valid_act_out;

    systolic_array_wmask_shares #(
        .N    (N),
        .ROWS (ARRAY_ROWS),
        .COLS (ARRAY_COLS),
        .SW   (XW)
    ) u_array (
        .clk           (clk),
        .reset_n       (reset_n),
        .mask_en       (1'b1),
        .mask_refresh  (mask_refresh),
        .wt_load       (wt_load),
        .wt_flat       (wt_flat),
        .valid_act_in  (act_valid),
        .act_flat      (act_flat),
        .psum0_out     (arr_psum0_out),
        .psum1_out     (arr_psum1_out),
        .valid_sum_out (valid_sum_out),
        .act_out       (arr_act_out),
        .valid_act_out (arr_valid_act_out)
    );

    wire [ARRAY_COLS-1:0]         out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;

    address_generator #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_ag (
        .clk               (clk),
        .reset_n           (reset_n),
        .stream_start      (stream_start),
        .stream_busy       (),
        .compute_done      (compute_done),

        .act_rd_en         (act_rd_en),
        .act_rd_addr_flat  (act_rd_addr_flat),
        .act_valid         (act_valid),

        .valid_sum_out     (valid_sum_out),
        .out_wr_en         (out_wr_en),
        .out_wr_addr_flat  (out_wr_addr_flat)
    );

    wire [ARRAY_COLS*XW-1:0]   psum_acc0_out, psum_acc1_out;
    wire [ARRAY_COLS-1:0]      psum_acc_valid;

    psum_accum_masked #(
        .N     (N),
        .XW    (XW),
        .COLS  (ARRAY_COLS),
        .DEPTH (WAVES),
        .AW    (WADDR_W)
    ) u_psum_accum (
        .clk        (clk),
        .reset_n    (reset_n),
        .tile_start (stream_start),
        .first_tile (1'b1),
        .last_tile  (1'b1),
        .valid_in   (out_wr_en),
        .psum0_in   (arr_psum0_out),
        .psum1_in   (arr_psum1_out),
        .psum0_out  (psum_acc0_out),
        .psum1_out  (psum_acc1_out),
        .valid_out  (psum_acc_valid),
        .ovf        (psum_ovf_flat)
    );

    wire [ARRAY_COLS-1:0]           rq_valid;
    wire [ARRAY_COLS*N-1:0]         rq_q_flat;
    wire [ARRAY_COLS-1:0]           act_valid_stage;
    wire [ARRAY_COLS*N-1:0]         act_y_flat;
    wire [ARRAY_COLS-1:0]           mp_valid;
    wire [ARRAY_COLS*N-1:0]         mp_y_flat;
    wire [ARRAY_COLS-1:0]           of_wr_en_c;
    wire [ARRAY_COLS*OF_ADDR_W-1:0] of_wr_addr_flat_c;

    reg [OF_ADDR_W-1:0] post_cnt [0:ARRAY_COLS-1];

    `include "msk_counts.vh"
    localparam RW_RQ  = XW + MW + 2;
    localparam RND_RQ = mskf_rq_rnd(XW, RW_RQ);

    genvar p;
    generate
        for (p = 0; p < ARRAY_COLS; p = p + 1) begin : g_post
            // Randomness runs while this requantizer has data in flight:
            // from the cycle BEFORE a new accumulator value appears (out_wr_en
            // updates the accumulator at the next edge) until the pipeline has
            // drained. Idle -> bits held -> no switching. Stage registers keep
            // shifting for RQ_LAT cycles after the last input change, so the
            // window covers RQ_LAT + 2 cycles.
            localparam RQ_LAT = mskf_rq_lat(XW, RW_RQ, DOM_REG);
            reg [7:0] rq_busy;
            always @(posedge clk) begin
                if (!reset_n)                rq_busy <= 8'd0;
                else if (out_wr_en[p])       rq_busy <= RQ_LAT + 2;
                else if (rq_busy != 8'd0)    rq_busy <= rq_busy - 1'b1;
            end
            wire rq_rng_en = out_wr_en[p] | (rq_busy != 8'd0);

            wire [RND_RQ-1:0] rq_rnd;
            rng_bank #(.W(RND_RQ), .SEED(64'hC0FF_EE00_0000_0001 + p)) u_rng (
                .clk(clk), .reset_n(reset_n), .en(rq_rng_en), .rnd(rq_rnd));

            wire [N-1:0] rq_q0, rq_q1;
            wire         rq_s0, rq_s1;
            requantize_masked #(
                .N(N), .XW(XW), .BW(ACCW), .MW(MW), .SW(SW), .DOM_REG(DOM_REG)
            ) u_requant (
                .clk       (clk),
                .reset_n   (reset_n),
                .valid_in  (psum_acc_valid[p]),
                .x0_in     (psum_acc0_out[p*XW +: XW]),
                .x1_in     (psum_acc1_out[p*XW +: XW]),
                .bias_in   (bias_flat[p*ACCW +: ACCW]),
                .m0_in     (m0_flat[p*MW +: MW]),
                .shift_in  (shift_flat[p*SW +: SW]),
                .rnd_in    (rq_rnd),
                .valid_out (rq_valid[p]),
                .q0_out    (rq_q0),
                .q1_out    (rq_q1),
                .sat0_out  (rq_s0),
                .sat1_out  (rq_s1)
            );
            // shares recombined here, at the edge of the masked datapath
            assign rq_q_flat[p*N +: N] = rq_q0 ^ rq_q1;
            assign requant_sat_flat[p] = rq_s0 ^ rq_s1;

            activation_unit #(.N(N)) u_act (
                .clk         (clk),
                .reset_n     (reset_n),
                .mode        (act_mode),
                .valid_in    (rq_valid[p]),
                .x_in        (rq_q_flat[p*N +: N]),
                .clamp_high  (act_clamp_high),
                .leaky_shift (act_leaky_shift),
                .valid_out   (act_valid_stage[p]),
                .y_out       (act_y_flat[p*N +: N])
            );

            maxpool_unit #(.N(N), .CW(CW)) u_pool (
                .clk       (clk),
                .reset_n   (reset_n),
                .valid_in  (act_valid_stage[p]),
                .win_len   (pool_win_len),
                .x_in      (act_y_flat[p*N +: N]),
                .valid_out (mp_valid[p]),
                .y_out     (mp_y_flat[p*N +: N])
            );

            assign of_wr_en_c[p] = mp_valid[p] && (post_cnt[p] < OF_DEPTH);
            assign of_wr_addr_flat_c[p*OF_ADDR_W +: OF_ADDR_W] = post_cnt[p];

            always @(posedge clk) begin
                if (!reset_n)
                    post_cnt[p] <= {OF_ADDR_W{1'b0}};
                else if (stream_start)
                    post_cnt[p] <= {OF_ADDR_W{1'b0}};
                else if (of_wr_en_c[p])
                    post_cnt[p] <= post_cnt[p] + 1'b1;
            end
        end
    endgenerate

    reg post_done;
    always @(posedge clk) begin
        if (!reset_n)
            post_done <= 1'b0;
        else
            post_done <= of_wr_en_c[ARRAY_COLS-1] && (post_cnt[ARRAY_COLS-1] == OF_DEPTH-1);
    end
    assign done = post_done;

    genvar c;
    generate
        for (c = 0; c < ARRAY_COLS; c = c + 1) begin : g_of_spad
            scratchpad #(
                .DATA_WIDTH (N),
                .SPAD_DEPTH (OF_DEPTH)
            ) u_of_spad (
                .clk     (clk),
                .wr_en   (of_wr_en_c[c]),
                .wr_addr (of_wr_addr_flat_c[c*OF_ADDR_W +: OF_ADDR_W]),
                .wr_data (mp_y_flat[c*N +: N]),
                .rd_en   (of_rd_en[c]),
                .rd_addr (of_rd_addr_flat[c*OF_ADDR_W +: OF_ADDR_W]),
                .rd_data (of_rd_data_flat[c*N +: N])
            );
        end
    endgenerate

endmodule