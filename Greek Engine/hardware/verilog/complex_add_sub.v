`timescale 1ns / 1ps
//============================================================================
// Complex Add/Subtract — (a_r ± b_r) + i*(a_i ± b_i)
//============================================================================

module complex_add_sub #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,
    input  wire signed [WL-1:0] b_r, b_i,
    input  wire              sub,        // 0 = add, 1 = subtract
    input  wire              valid_in,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               valid_out
);

    always @(posedge clk) begin
        if (rst) begin
            res_r <= 0; res_i <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                if (sub) begin
                    res_r <= a_r - b_r;
                    res_i <= a_i - b_i;
                end else begin
                    res_r <= a_r + b_r;
                    res_i <= a_i + b_i;
                end
            end
        end
    end

endmodule
