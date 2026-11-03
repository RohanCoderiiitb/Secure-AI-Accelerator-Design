
// Both IF_GB and FL_GB are single-element-per-word memories here (unlike
// the lut6-mm design, where the weight scratchpad word already held a full
// packed COLS*N-bit row) - so this controller has to do more assembly work
// than lut6-mm's systolic_controller did:
//
//   ACT_FETCH:      drain IF_GB serially (ARRAY_ROWS*WAVES single elements)
//                   into the ARRAY_ROWS per-row activation scratchpads.
//                   Address convention: IF_GB[r*WAVES + k] = A[k][r]
//                   (transposed activation layout - row r, wave k), matching
//                   the lut6-mm convention so address_generator's skewed
//                   reads line up correctly.
//
//   WT_COL_FETCH:   for the current row, serially fetch ARRAY_COLS
//                   individual weight elements from FL_GB (address
//                   convention: FL_GB[row*ARRAY_COLS + c] = W[row][c]) and
//                   assemble them into a COLS*N-bit register (column 0 in
//                   the low N bits, matching wt_flat's expected packing -
//                   see systolic_array.v: wt[0][c] = wt_flat[c*N +: N]).
//
//   WT_PRESENT:     hold wt_load high for exactly ONE cycle with the
//                   assembled row on wt_flat. Rows are presented in
//                   REVERSE order (ARRAY_ROWS-1 down to 0) - this is what
//                   makes PE row r end up holding W[r][:], given the
//                   array's systolic shift-down weight loading (each row's
//                   wt_reg only updates on a wt_load pulse, so gaps between
//                   pulses while the NEXT row is being assembled are safe:
//                   nothing decays between pulses, only the pulse ORDER and
//                   COUNT matter). Full derivation: see lut6-mm-memory-
//                   hierarchy/README.md section 1, or the chat history.
//
//   STREAM_KICK/WAIT: pulse stream_start into address_generator, then wait
//                   for its compute_done pulse (activation streaming +
//                   output capture, entirely handled by address_generator
//                   and the systolic array - this controller just waits).
//
// Every serial fetch (ACT_FETCH and WT_COL_FETCH) uses a SINGLE delay
// stage between issuing a read (rd_en/rd_addr, combinational from current
// counters) and committing the result (write-enable + captured indices,
// registered exactly 1 cycle later, matching sram_2p's 1-cycle read
// latency) - with the destination data driven LIVE/combinationally from
// rd_data at the commit cycle. This is deliberately the same pattern used
// (after debugging) in the lut6-mm design's activation-scratchpad loader;
// an earlier version of that loader used a mismatched double-delay here
// and silently dropped/shifted every element by one position.
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
    parameter CA_W       = (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS)
) (
    input  wire clk,
    input  wire reset_n,
    input  wire start,
    output reg  done,

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
    input  wire [N-1:0]          fl_rd_data,

    // Systolic array weight-load interface
    output reg                      wt_load,
    output reg  [ARRAY_COLS*N-1:0]  wt_flat,

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

    // ---------------- ACT_FETCH: IF_GB -> per-row scratchpads ----------------
    // Correct pipelining requires capturing the (row,col) indices THAT WERE
    // ACTUALLY USED to build the read address, at the SAME cycle the read
    // is issued - then committing them one cycle later, once if_rd_data is
    // valid. Using the CURRENT act_row/act_col at commit time is wrong:
    // by the commit cycle, the counter-advance logic (which runs every
    // cycle a read is issued) has already moved them on to the NEXT
    // index - found via simulation (weight elements were landing one
    // column late; W[row][0]'s data ended up written into wt_flat's
    // column-1 slot, etc.), and traced back to exactly this pipelining
    // mismatch. This is the same conceptual lesson as the lut6-mm
    // al_ loader fix, but that earlier "fix" here (using current,
    // undelayed indices directly) turned out to be the wrong direction -
    // the delayed-capture form below is the one that's actually correct.
    reg [RA_W-1:0]    act_row;
    reg [WADDR_W-1:0] act_col;
    wire act_issue = (state == S_ACT_FETCH);
    assign if_rd_en   = act_issue;
    assign if_rd_addr = act_row * WAVES + act_col;

    reg               act_commit_pending;
    reg [RA_W-1:0]    act_row_captured;
    reg [WADDR_W-1:0] act_col_captured;
    // NOTE: row_wr_data is written directly from if_rd_data INSIDE the
    // act_commit_pending-gated block below (mirroring exactly how wt_flat
    // is written from fl_rd_data inside the wt_commit_pending-gated block) -
    // if_rd_data is valid and correct at that exact cycle (1 cyc after
    // issue), so reading it live there needs no separate pre-latch stage.
    // An earlier version here added an extra act_data_captured pre-latch,
    // which just pushed the mismatch one cycle deeper instead of fixing it
    // (found via simulation): reading a register in the same NBA group
    // that's also being written this cycle sees its PRE-this-edge value,
    // not the new one - so consuming a same-cycle-latched value one more
    // cycle later, instead of live-reading the source at the gated cycle
    // directly, just adds a third pipeline stage where only two exist.

    // ---------------- WT_COL_FETCH: FL_GB -> wt_flat assembly ----------------
    reg [RA_W-1:0] wrow;                 // current row being assembled/presented (counts DOWN)
    reg [CA_W-1:0] wcol;                 // current column being fetched (counts UP, 0..ARRAY_COLS-1)
    wire wt_issue = (state == S_WT_COL_FETCH);
    assign fl_rd_en   = wt_issue;
    assign fl_rd_addr = wrow * ARRAY_COLS + wcol;

    reg               wt_commit_pending;
    reg [CA_W-1:0]    wcol_captured;

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
            wt_commit_pending <= 1'b0; wcol_captured <= 0;
            wt_load <= 1'b0;
            wt_flat <= {(ARRAY_COLS*N){1'b0}};
            stream_start <= 1'b0;
        end else begin
            done         <= 1'b0;
            stream_start <= 1'b0;
            wt_load      <= 1'b0;
            row_wr_en    <= {ARRAY_ROWS{1'b0}};

            // ---- ACT_FETCH: capture (row,col) at issue+1; commit 1 cycle later,
            // reading if_rd_data LIVE at the commit cycle (matches its own
            // valid-data cycle exactly - same pattern as WT_COL_FETCH below) ----
            act_commit_pending <= act_issue;
            act_row_captured   <= act_row;
            act_col_captured   <= act_col;
            if (act_commit_pending) begin
                row_wr_en[act_row_captured] <= 1'b1;
                row_wr_addr_flat[act_row_captured*WADDR_W +: WADDR_W] <= act_col_captured;
                row_wr_data <= if_rd_data;
            end

            // ---- WT_COL_FETCH: capture wcol at issue, commit 1 cycle later ----
            wt_commit_pending <= wt_issue;
            wcol_captured     <= wcol;
            if (wt_commit_pending)
                wt_flat[wcol_captured*N +: N] <= fl_rd_data[N-1:0];

            case (state)
                S_IDLE: if (start) begin
                    act_row <= 0; act_col <= 0;
                    state <= S_ACT_FETCH;
                end

                S_ACT_FETCH: begin
                    // Advance issue-side counters every cycle we're issuing.
                    // Only reset act_col when actually moving to a NEW row -
                    // on the terminal (ROWS-1, WAVES-1) cycle, hold both
                    // counters put until the state transition below actually
                    // fires, rather than resetting act_col a cycle early
                    // (which would otherwise cause one extra, harmless-but-
                    // needless re-issue at the same final address).
                    if (act_col == WAVES-1) begin
                        if (act_row != ARRAY_ROWS-1) begin
                            act_row <= act_row + 1'b1;
                            act_col <= 0;
                        end
                    end else begin
                        act_col <= act_col + 1'b1;
                    end

                    // Move on once the FINAL commit (row=ROWS-1, col=WAVES-1) lands.
                    if (act_commit_pending && act_row_captured == ARRAY_ROWS-1 && act_col_captured == WAVES-1) begin
                        wrow <= ARRAY_ROWS-1;  // reverse order: highest row first
                        wcol <= 0;
                        state <= S_WT_COL_FETCH;
                    end
                end

                S_WT_COL_FETCH: begin
                    if (wcol != ARRAY_COLS-1)
                        wcol <= wcol + 1'b1;
                    // else: last column of this row issued - hold, commit still in flight.

                    if (wt_commit_pending && wcol_captured == ARRAY_COLS-1) begin
                        state <= S_WT_PRESENT;
                    end
                end

                S_WT_PRESENT: begin
                    // wt_flat already holds the fully-assembled row from the
                    // commits above; just pulse wt_load for this one cycle.
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
