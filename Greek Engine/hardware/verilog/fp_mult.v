`timescale 1ns / 1ps

module fp_mult #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [WL-1:0] a,
    input  wire [WL-1:0] b,
    input  wire          valid_in,
    output reg  [WL-1:0] result,
    output reg           overflow,
    output reg           valid_out
);

    // Full product is 2*WL bits
    wire signed [2*WL-1:0] full_product;
    wire signed [WL-1:0] a_signed = a;
    wire signed [WL-1:0] b_signed = b;
    
    assign full_product = a_signed * b_signed;
    
    // We need to extract WL bits, shifting right by FL.
    // The relevant bits are full_product[WL+FL-1 : FL]
    
    wire sign_bit = full_product[2*WL-1];
    
    // Max and min values for saturation
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
                // Simple truncation and saturation logic
                // Check if upper bits (beyond the extracted WL bits) are all same as sign bit
                
                // For a 32-bit Q16.16: full product is 64-bit.
                // We extract bits [47:16].
                // Bits [63:47] must be all 0s (if positive) or all 1s (if negative) to avoid overflow.
                
                // In general, we extract bits [WL+FL-1 : FL]
                // We must check bits [2*WL-1 : WL+FL-1]
                
                // Note: bit WL+FL-1 is the sign bit of our extracted result.
                
                // To avoid parameter range issues, we implement a generic check
                integer i;
                reg ovf;
                ovf = 0;
                
                for (i = WL+FL-1; i < 2*WL; i = i + 1) begin
                    if (full_product[i] != sign_bit) begin
                        ovf = 1;
                    end
                end
                
                if (ovf) begin
                    overflow <= 1'b1;
                    if (sign_bit == 1'b0) begin
                        result <= {1'b0, max_val}; // Positive saturate
                    end else begin
                        result <= {1'b1, min_val}; // Negative saturate
                    end
                end else begin
                    overflow <= 1'b0;
                    result <= full_product[WL+FL-1 : FL];
                end
            end
        end
    end

endmodule
