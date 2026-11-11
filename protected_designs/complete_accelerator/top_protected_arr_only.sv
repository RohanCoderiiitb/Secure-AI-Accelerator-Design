// flexnn accelerator with only the systolic array masked
module flexnn_top_arr_masked #(
    parameter N          = 8,
    parameter ACCW       = 19,                 // 2N + clog2(ARRAY_ROWS)
    parameter ARRAY_ROWS = 5,
    parameter ARRAY_COLS = 5,
    parameter WAVES      = 4,

    parameter MW         = 16,
    parameter SW         = 6,
    parameter BW         = 32,                 // bias width
    parameter POOL_LEN   = 1,

    parameter BMW        = BW + MW,            // bias*m0 width
    parameter IF_DEPTH   = ARRAY_ROWS * WAVES,
    parameter FL_DEPTH   = ARRAY_ROWS * ARRAY_COLS,
    parameter OF_DEPTH   = WAVES / POOL_LEN,

    parameter IF_ADDR_W  = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH),
    parameter FL_ADDR_W  = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH),
    parameter OF_ADDR_W  = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH),
    parameter WADDR_W    = (WAVES    <= 1) ? 1 : $clog2(WAVES),
    parameter CW         = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1),

    parameter XW         = 2*N + $clog2(ARRAY_ROWS)    // share width of the masked array
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

    input  wire [ARRAY_COLS*BW-1:0]    bias_flat,
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

    // registered inputs
    reg                        rst_q;
    wire                       rst_n = rst_q;
    reg                        start_q, if_wr_en_q, fl_wr_en_q;
    reg [IF_ADDR_W-1:0]        if_wr_addr_q;
    reg [FL_ADDR_W-1:0]        fl_wr_addr_q;
    reg [N-1:0]                if_wr_data_q, fl_wr_data_q;
    reg [ARRAY_COLS*BW-1:0]    bias_q;
    reg [ARRAY_COLS*MW-1:0]    m0_q;
    reg [ARRAY_COLS*SW-1:0]    shift_q;
    reg [1:0]                  act_mode_q;
    reg signed [N-1:0]         act_clamp_high_q;
    reg [2:0]                  act_leaky_shift_q;
    reg [CW-1:0]               pool_win_len_q;
    reg [ARRAY_COLS-1:0]           of_rd_en_q;
    reg [ARRAY_COLS*OF_ADDR_W-1:0] of_rd_addr_q;
    always @(posedge clk) begin
        rst_q <= reset_n;
        if (!rst_n) begin
            start_q    <= 1'b0;
            if_wr_en_q <= 1'b0;
            fl_wr_en_q <= 1'b0;
            of_rd_en_q <= {ARRAY_COLS{1'b0}};
        end else begin
            start_q    <= start;
            if_wr_en_q <= if_wr_en;
            fl_wr_en_q <= fl_wr_en;
            of_rd_en_q <= of_rd_en;
        end
        if_wr_addr_q      <= if_wr_addr;
        if_wr_data_q      <= if_wr_data;
        fl_wr_addr_q      <= fl_wr_addr;
        fl_wr_data_q      <= fl_wr_data;
        bias_q            <= bias_flat;
        m0_q              <= m0_flat;
        shift_q           <= shift_flat;
        act_mode_q        <= act_mode;
        act_clamp_high_q  <= act_clamp_high;
        act_leaky_shift_q <= act_leaky_shift;
        pool_win_len_q    <= pool_win_len;
        of_rd_addr_q      <= of_rd_addr_flat;
    end

    wire                if_gb_rd_en;
    wire [IF_ADDR_W-1:0] if_gb_rd_addr;
    wire [N-1:0]         if_gb_rd_data;

    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (IF_DEPTH),
        .GB_ADDR_WIDTH (IF_ADDR_W)
    ) u_if_gb (
        .clk     (clk),
        .wr_en   (if_wr_en_q),
        .wr_addr (if_wr_addr_q),
        .wr_data (if_wr_data_q),
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
        .wr_en   (fl_wr_en_q),
        .wr_addr (fl_wr_addr_q),
        .wr_data (fl_wr_data_q),
        .rd_en   (fl_gb_rd_en),
        .rd_addr (fl_gb_rd_addr),
        .rd_data (fl_gb_rd_data)
    );

    wire [ARRAY_ROWS-1:0]         row_wr_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] row_wr_addr_flat;
    wire [N-1:0]                  row_wr_data;

    wire                     wt_load;
    wire [ARRAY_COLS*XW-1:0] wt_flat;        // masked weight words
    wire [XW-1:0]            arr_r_sel;      // row mask from the array to the load controller

    wire stream_start;
    wire compute_done;
    wire array_done;
    wire lc_idle;

    // mask refresh before every weight load
    reg [7:0] rf_cnt;
    reg       lc_start;
    wire      mask_refresh = (rf_cnt != 8'd0);
    always @(posedge clk) begin
        if (!rst_n) begin
            rf_cnt   <= 8'd0;
            lc_start <= 1'b0;
        end else begin
            lc_start <= 1'b0;
            if (start_q && lc_idle && rf_cnt == 8'd0 && !lc_start) rf_cnt <= ARRAY_ROWS;
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
        .WAVES      (WAVES),
        .WW         (XW)
    ) u_load_ctrl (
        .clk               (clk),
        .reset_n           (rst_n),
        .start             (lc_start),
        .done              (array_done),
        .idle              (lc_idle),

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
        .r_sel             (arr_r_sel),

        .stream_start      (stream_start),
        .compute_done      (compute_done)
    );

    // bias*m0 per column, once per start
    wire [ARRAY_COLS*BMW-1:0] bm_flat;
    bias_scale #(.COLS(ARRAY_COLS), .BW(BW), .MW(MW), .BMW(BMW)) u_bscale (
        .clk(clk), .reset_n(rst_n), .start(lc_start),
        .bias_flat(bias_q), .m0_flat(m0_q), .bm_flat(bm_flat), .busy());

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

    systolic_array_wmask_shared #(
        .N    (N),
        .ACCW (ACCW),
        .ROWS (ARRAY_ROWS),
        .COLS (ARRAY_COLS),
        .SW   (XW)
    ) u_array (
        .clk           (clk),
        .reset_n       (rst_n),
        .mask_en       (1'b1),
        .mask_refresh  (mask_refresh),
        .wt_load       (wt_load),
        .wt_flat       (wt_flat),
        .valid_act_in  (act_valid),
        .act_flat      (act_flat),
        .psum_flat     ({(ARRAY_COLS*ACCW){1'b0}}),
        .psum_out      (arr_psum_out),
        .valid_sum_out (valid_sum_out),
        .act_out       (arr_act_out),
        .valid_act_out (arr_valid_act_out),
        .r_sel_out     (arr_r_sel)
    );

    wire [ARRAY_COLS-1:0]         out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;

    address_generator #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_ag (
        .clk               (clk),
        .reset_n           (rst_n),
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
    wire [ARRAY_COLS-1:0]      psum_ovf;

    psum_accum #(
        .N     (N),
        .ACCW  (ACCW),
        .COLS  (ARRAY_COLS),
        .DEPTH (WAVES),
        .AW    (WADDR_W)
    ) u_psum_accum (
        .clk        (clk),
        .reset_n    (rst_n),
        .tile_start (stream_start),
        .first_tile (1'b1),
        .last_tile  (1'b1),
        .valid_in   (out_wr_en),
        .psum_in    (arr_psum_out),
        .psum_out   (psum_acc_out),
        .valid_out  (psum_acc_valid),
        .ovf        (psum_ovf)
    );

    wire [ARRAY_COLS-1:0]           rq_valid;
    wire [ARRAY_COLS*N-1:0]         rq_q_flat;
    wire [ARRAY_COLS-1:0]           rq_sat;
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
                .N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .BMW(BMW)
            ) u_requant (
                .clk       (clk),
                .reset_n   (rst_n),
                .valid_in  (psum_acc_valid[p]),
                .acc_in    (psum_acc_out[p*ACCW +: ACCW]),
                .bm_in     (bm_flat[p*BMW +: BMW]),
                .m0_in     (m0_q[p*MW +: MW]),
                .shift_in  (shift_q[p*SW +: SW]),
                .valid_out (rq_valid[p]),
                .q_out     (rq_q_flat[p*N +: N]),
                .sat_out   (rq_sat[p])
            );

            activation_unit #(.N(N)) u_act (
                .clk         (clk),
                .reset_n     (rst_n),
                .mode        (act_mode_q),
                .valid_in    (rq_valid[p]),
                .x_in        (rq_q_flat[p*N +: N]),
                .clamp_high  (act_clamp_high_q),
                .leaky_shift (act_leaky_shift_q),
                .valid_out   (act_valid_stage[p]),
                .y_out       (act_y_flat[p*N +: N])
            );

            maxpool_unit #(.N(N), .CW(CW)) u_pool (
                .clk       (clk),
                .reset_n   (rst_n),
                .valid_in  (act_valid_stage[p]),
                .win_len   (pool_win_len_q),
                .x_in      (act_y_flat[p*N +: N]),
                .valid_out (mp_valid[p]),
                .y_out     (mp_y_flat[p*N +: N])
            );

            // OF_DEPTH outputs per column per tile
            assign of_wr_en_c[p] = mp_valid[p];
            assign of_wr_addr_flat_c[p*OF_ADDR_W +: OF_ADDR_W] = post_cnt[p];

            always @(posedge clk) begin
                if (!rst_n)
                    post_cnt[p] <= {OF_ADDR_W{1'b0}};
                else if (of_wr_en_c[p])
                    post_cnt[p] <= (post_cnt[p] == OF_DEPTH-1) ? {OF_ADDR_W{1'b0}} : post_cnt[p] + 1'b1;
            end
        end
    endgenerate

    reg post_done;
    always @(posedge clk) begin
        if (!rst_n)
            post_done <= 1'b0;
        else
            post_done <= of_wr_en_c[ARRAY_COLS-1] && (post_cnt[ARRAY_COLS-1] == OF_DEPTH-1);
    end

    wire [ARRAY_COLS*N-1:0] of_rd_data_c;
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
                .rd_en   (of_rd_en_q[c]),
                .rd_addr (of_rd_addr_q[c*OF_ADDR_W +: OF_ADDR_W]),
                .rd_data (of_rd_data_c[c*N +: N])
            );
        end
    endgenerate

    // registered outputs
    reg                    done_q, acd_q;
    reg [ARRAY_COLS-1:0]   ovf_q, sat_q;
    reg [ARRAY_COLS*N-1:0] of_rd_data_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            done_q <= 1'b0;
            acd_q  <= 1'b0;
        end else begin
            done_q <= post_done;
            acd_q  <= array_done;
        end
        ovf_q        <= psum_ovf;
        sat_q        <= rq_sat;
        of_rd_data_q <= of_rd_data_c;
    end
    assign done               = done_q;
    assign array_compute_done = acd_q;
    assign psum_ovf_flat      = ovf_q;
    assign requant_sat_flat   = sat_q;
    assign of_rd_data_flat    = of_rd_data_q;

endmodule
