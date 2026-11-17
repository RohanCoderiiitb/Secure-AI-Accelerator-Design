// Load controller: global buffers -> activation scratchpads and array weight columns
module load_controller #(
    parameter N          = 8,
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    parameter WAVES      = 4,

    parameter IF_DEPTH  = ARRAY_ROWS * WAVES,
    parameter FL_DEPTH  = ARRAY_ROWS * ARRAY_COLS,
    parameter IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH),
    parameter FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH),
    parameter WADDR_W   = (WAVES    <= 1) ? 1 : $clog2(WAVES),
    parameter RA_W       = (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS),
    parameter CA_W       = (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS),
    parameter WW         = N,     // weight word sent to the array: N = plain, XW = masked
    parameter MASKED     = 0,     // 1: two weight memories, m and sext(w) - m, converted here to w - R of the row
    parameter FW         = MASKED ? WW : N
) (
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    output reg  done,
    output wire idle,             // in S_IDLE: a start is accepted

    // IF_GB read port
    output wire                  if_rd_en,
    output wire [IF_ADDR_W-1:0]  if_rd_addr,
    input  wire [N-1:0]          if_rd_data,

    // Per-row activation scratchpad write ports (shared data bus, gated per row)
    output reg  [ARRAY_ROWS-1:0]         row_wr_en,
    output reg  [ARRAY_ROWS*WADDR_W-1:0] row_wr_addr_flat,
    output reg  [N-1:0]                  row_wr_data,

    // FL_GB read port
    output wire                  fl_rd_en,
    output wire [FL_ADDR_W-1:0]  fl_rd_addr,
    input  wire [FW-1:0]         fl_rd_data,       // MASKED: share w - m
    output wire                  fl_rdm_en,        // MASKED: read of the share-m memory (same address)
    input  wire [WW-1:0]         fl_rdm_data,      // MASKED: share m

    // Systolic array weight-load interface
    output reg                      wt_load,
    output reg  [ARRAY_COLS*WW-1:0] wt_flat,
    input  wire [ARRAY_ROWS*WW-1:0] r_flat,   // MASKED: row masks of the array (unused otherwise)
    input  wire [WW-1:0]            rnd_gap,  // MASKED: fresh random word every cycle (unused otherwise)
    output wire                     wt_phase, // weight fetch in progress (MASKED: steps rnd_gap)

    // address_generator handshake
    output reg  stream_start,
    input  wire compute_done
);
    localparam S_IDLE          = 0,
               S_ACT_FETCH     = 1,
               S_WT_COL_FETCH  = 2,
               S_WT_PRESENT    = 3,
               S_WT_NEXT       = 4,
               S_STREAM_KICK   = 5,
               S_STREAM_WAIT   = 6,
               S_DONE          = 7;
    reg [2:0] state;
    assign idle = (state == S_IDLE);

    // ACT_FETCH
    reg [RA_W-1:0]    act_row;
    reg [WADDR_W-1:0] act_col;
    wire act_issue = (state == S_ACT_FETCH);
    assign if_rd_en   = act_issue;
    assign if_rd_addr = act_row * WAVES + act_col;

    reg               act_commit_pending;
    reg [RA_W-1:0]    act_row_captured;
    reg [WADDR_W-1:0] act_col_captured;

    // WT_COL_FETCH
    reg [RA_W-1:0] wrow;                 // current row being assembled/presented (counts DOWN)
    reg [CA_W-1:0] wcol;                 // current column being fetched (counts UP, 0..ARRAY_COLS-1)
    // MASKED: two cycles per column: share m is read first, share w - m in the next cycle, so the two
    // shares of a weight never sit in registers that change in the same cycle
    reg  wgap;
    wire wt_fetch = (state == S_WT_COL_FETCH);
    wire wt_issue = wt_fetch && (!MASKED || wgap);      // w - m (or plain weight) read
    wire wm_issue = wt_fetch && MASKED && !wgap;        // m read
    assign wt_phase = (state == S_WT_COL_FETCH) || (state == S_WT_PRESENT) || (state == S_WT_NEXT);
    assign fl_rd_en   = wt_issue;
    assign fl_rdm_en  = wm_issue;
    assign fl_rd_addr = wrow * ARRAY_COLS + wcol;

    reg               wt_commit_pending;
    reg [CA_W-1:0]    wcol_captured;

    // word to the array: plain weight, or (MASKED) (w - m) + (m - R) = w - R. dm_q holds m - R only
    // for the commit cycle and rnd - R otherwise, so the converter only ever holds random values
    wire [WW-1:0] wt_word;
    generate
        if (MASKED) begin : g_cv
            reg  [WW-1:0] dm_q;
            reg           m_valid_q;
            wire [WW-1:0] r_row = r_flat[wrow*WW +: WW];
            always @(posedge clk) begin
                m_valid_q <= wm_issue;
                dm_q      <= (m_valid_q ? fl_rdm_data : rnd_gap) - r_row;
            end
            assign wt_word = fl_rd_data + dm_q;
        end else begin : g_pl
            assign wt_word = fl_rd_data[WW-1:0];
        end
    endgenerate

    integer ii;

    always @(posedge clk) begin
        if (!reset_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
            act_row <= 0; act_col <= 0;
            act_commit_pending <= 1'b0; act_row_captured <= 0; act_col_captured <= 0;
            row_wr_en <= {ARRAY_ROWS{1'b0}};
            row_wr_addr_flat <= {(ARRAY_ROWS*WADDR_W){1'b0}};
            row_wr_data <= {N{1'b0}};
            wrow <= 0; wcol <= 0;
            wt_commit_pending <= 1'b0; wcol_captured <= 0; wgap <= 1'b0;
            wt_load <= 1'b0;
            wt_flat <= {(ARRAY_COLS*WW){1'b0}};
            stream_start <= 1'b0;
        end else begin
            done         <= 1'b0;
            stream_start <= 1'b0;
            wt_load      <= 1'b0;
            row_wr_en    <= {ARRAY_ROWS{1'b0}};

            // ACT_FETCH
            act_commit_pending <= act_issue;
            act_row_captured   <= act_row;
            act_col_captured   <= act_col;
            if (act_commit_pending) begin
                row_wr_en[act_row_captured] <= 1'b1;
                row_wr_addr_flat[act_row_captured*WADDR_W +: WADDR_W] <= act_col_captured;
                row_wr_data <= if_rd_data;
            end

            // WT_COL_FETCH
            wt_commit_pending <= wt_issue;
            wcol_captured     <= wcol;
            if (wt_commit_pending)
                wt_flat[wcol_captured*WW +: WW] <= wt_word;
            wgap <= MASKED && wt_fetch && !wgap;

            case (state)
                S_IDLE: if (start) begin
                    act_row <= 0; act_col <= 0;
                    state <= S_ACT_FETCH;
                end

                S_ACT_FETCH: begin
                    // advance the issue-side counters every issuing cycle
                    if (act_col == WAVES-1) begin
                        if (act_row != ARRAY_ROWS-1) begin
                            act_row <= act_row + 1'b1;
                            act_col <= 0;
                        end
                    end else begin
                        act_col <= act_col + 1'b1;
                    end

                    // Move on once the FINAL commit (row=ROWS-1, col=WAVES-1) lands
                    if (act_commit_pending && act_row_captured == ARRAY_ROWS-1 && act_col_captured == WAVES-1) begin
                        wrow <= ARRAY_ROWS-1;  // reverse order: highest row first
                        wcol <= 0;
                        state <= S_WT_COL_FETCH;
                    end
                end

                S_WT_COL_FETCH: begin
                    if (wt_issue && wcol != ARRAY_COLS-1)
                        wcol <= wcol + 1'b1;

                    if (wt_commit_pending && wcol_captured == ARRAY_COLS-1) begin
                        state <= S_WT_PRESENT;
                    end
                end

                S_WT_PRESENT: begin
                    // wt_flat already holds the fully-assembled row from the commits above
                    wt_load <= 1'b1;
                    state   <= S_WT_NEXT;
                end

                S_WT_NEXT: begin
                    if (wrow == 0) begin
                        state <= S_STREAM_KICK;
                    end else begin
                        wrow <= wrow - 1'b1;
                        wcol <= 0;
                        state <= S_WT_COL_FETCH;
                    end
                end

                S_STREAM_KICK: begin
                    stream_start <= 1'b1;
                    state <= S_STREAM_WAIT;
                end

                S_STREAM_WAIT: if (compute_done) begin
                    state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
