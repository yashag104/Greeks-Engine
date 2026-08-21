`timescale 1ns / 1ps

module fp_add_sub #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [WL-1:0] a,
    input  wire [WL-1:0] b,
    input  wire          sub,   // 0 for add, 1 for sub
    input  wire          valid_in,
    output reg  [WL-1:0] result,
    output reg           overflow,
    output reg           valid_out
);

    // Internal extended width for overflow detection
    localparam EXT_WL = WL + 1;
    
    wire signed [EXT_WL-1:0] ext_a = {a[WL-1], a};
    wire signed [EXT_WL-1:0] ext_b = {b[WL-1], b};
    
    wire signed [EXT_WL-1:0] sum_result;
    
    // Add or subtract based on 'sub' flag
    assign sum_result = sub ? (ext_a - ext_b) : (ext_a + ext_b);
    
    wire sign_bit = sum_result[EXT_WL-1];
    wire [WL-2:0] max_val = {(WL-1){1'b1}};
    wire [WL-2:0] min_val = {(WL-1){1'b0}};
    
    always @(posedge clk) begin
        if (rst) begin
            result <= 0;
            overflow <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                // Check for overflow/underflow and saturate
                if (sign_bit == 1'b0 && sum_result[EXT_WL-2] == 1'b1) begin
                    // Positive overflow
                    result <= {1'b0, max_val};
                    overflow <= 1'b1;
                end else if (sign_bit == 1'b1 && sum_result[EXT_WL-2] == 1'b0) begin
                    // Negative overflow (underflow)
                    result <= {1'b1, min_val};
                    overflow <= 1'b1;
                end else begin
                    // No overflow
                    result <= sum_result[WL-1:0];
                    overflow <= 1'b0;
                end
            end
        end
    end

endmodule
