module flexnn_top #(
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
    parameter CW         = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1)
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

    load_controller #(
        .N          (N),
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_load_ctrl (
        .clk               (clk),
        .reset_n           (reset_n),
        .start             (start),
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

    wire [ARRAY_COLS*ACCW-1:0] arr_psum_out;
    wire [ARRAY_COLS-1:0]      valid_sum_out;
    wire [ARRAY_ROWS*N-1:0]    arr_act_out;
    wire [ARRAY_ROWS-1:0]      arr_valid_act_out;

    systolic_array #(
        .N    (N),
        .ACCW (ACCW),
        .ROWS (ARRAY_ROWS),
        .COLS (ARRAY_COLS)
    ) u_array (
        .clk           (clk),
        .reset_n       (reset_n),
        .wt_load       (wt_load),
        .wt_flat       (wt_flat),
        .valid_act_in  (act_valid),
        .act_flat      (act_flat),
        .psum_flat     ({(ARRAY_COLS*ACCW){1'b0}}),
        .psum_out      (arr_psum_out),
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

    wire [ARRAY_COLS*ACCW-1:0] psum_acc_out;
    wire [ARRAY_COLS-1:0]      psum_acc_valid;

    psum_accum #(
        .N     (N),
        .ACCW  (ACCW),
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
        .psum_in    (arr_psum_out),
        .psum_out   (psum_acc_out),
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

    genvar p;
    generate
        for (p = 0; p < ARRAY_COLS; p = p + 1) begin : g_post
            requantize #(
                .N(N), .ACCW(ACCW), .MW(MW), .SW(SW)
            ) u_requant (
                .clk       (clk),
                .reset_n   (reset_n),
                .valid_in  (psum_acc_valid[p]),
                .acc_in    (psum_acc_out[p*ACCW +: ACCW]),
                .bias_in   (bias_flat[p*ACCW +: ACCW]),
                .m0_in     (m0_flat[p*MW +: MW]),
                .shift_in  (shift_flat[p*SW +: SW]),
                .valid_out (rq_valid[p]),
                .q_out     (rq_q_flat[p*N +: N]),
                .sat_out   (requant_sat_flat[p])
            );

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