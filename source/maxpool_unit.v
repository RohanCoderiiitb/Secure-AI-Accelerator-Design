// 1D Maxpooling unit
// Useful hardware block for CNN workloads
// In the full accelerator accelerator to simulate the M dimensional max pooling, M number of these units instantiated with FIFOs and delay units

module maxpool_unit #(
    parameter N = 8,
    parameter CW = 5
) (
    input wire                  clk,
    input wire                  reset_n,
    input wire                  valid_in,
    input wire         [CW-1:0] win_len,
    input wire signed  [N-1:0]  x_in,
    output reg                  valid_out,
    output reg signed [N-1:0]   y_out
);
    localparam signed [N-1:0] MOST_NEG = {1'b1, {(N-1){1'b0}}};
    
    reg signed [N-1:0]  r_max;
    reg        [CW-1:0] cnt;
    reg        [CW-1:0] r_len;
    reg                 in_window;

    wire        [CW-1:0]   l_eff    = in_window ? r_len : win_len;
    wire signed [N-1:0]    base     = in_window ? r_max : MOST_NEG;
    wire signed [N-1:0]    next_max = (x_in > base) ? x_in : base;
    wire                   last     = (cnt == (l_eff - 1'b1));

    always @(posedge clk) begin
        if(!reset_n) begin
            r_max     <= MOST_NEG;
            cnt       <= {CW{1'b0}};
            r_len     <= {CW{1'b0}};
            in_window <= 1'b0;
            valid_out <= 1'b0;
            y_out     <= {N{1'b0}};
        end
        else begin
            valid_out <= 1'b0;
            if(valid_in) begin
                if(!in_window) r_len <= l_eff;
                if(last) begin
                    y_out     <= next_max;
                    valid_out <= 1'b1;
                    r_max     <= MOST_NEG;
                    cnt       <= {CW{1'b0}};
                    in_window <= 1'b0;
                end else begin
                    r_max     <= next_max;
                    cnt       <= cnt + 1'b1;
                    in_window <= 1'b1;
                end
            end
        end
    end
endmodule