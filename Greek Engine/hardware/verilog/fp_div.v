`timescale 1ns / 1ps

module fp_div #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [WL-1:0] a,         // Dividend
    input  wire [WL-1:0] b,         // Divisor
    input  wire          start,
    output reg  [WL-1:0] result,
    output reg           ready,
    output reg           divide_by_zero,
    output reg           overflow
);

    // Iterative restoring division algorithm
    // We need to shift 'a' left by FL, so the division a/b 
    // produces the correct Q(WL.FL) format.
    
    // States
    localparam IDLE = 2'd0;
    localparam DIVIDE = 2'd1;
    localparam DONE = 2'd2;
    
    reg [1:0] state;
    
    reg [2*WL-1:0] dividend_reg;
    reg [WL-1:0] divisor_reg;
    reg [WL-1:0] quotient_reg;
    
    reg [6:0] count;
    reg sign_a, sign_b, sign_res;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            ready <= 1'b0;
            result <= 0;
            divide_by_zero <= 1'b0;
            overflow <= 1'b0;
            count <= 0;
        end else begin
            case (state)
                IDLE: begin
                    ready <= 1'b0;
                    if (start) begin
                        if (b == 0) begin
                            divide_by_zero <= 1'b1;
                            ready <= 1'b1;
                            result <= 0;
                        end else begin
                            divide_by_zero <= 1'b0;
                            sign_a <= a[WL-1];
                            sign_b <= b[WL-1];
                            sign_res <= a[WL-1] ^ b[WL-1];
                            
                            // Absolute values
                            divisor_reg <= b[WL-1] ? -b : b;
                            
                            // Align dividend: shift left by FL
                            // Extended precision for division
                            dividend_reg <= 0;
                            dividend_reg[WL+FL-1 : FL] <= a[WL-1] ? -a : a;
                            
                            quotient_reg <= 0;
                            count <= WL + FL; // Number of shift/subtract iterations
                            state <= DIVIDE;
                        end
                    end
                end
                
                DIVIDE: begin
                    if (count > 0) begin
                        // Shift left
                        dividend_reg = dividend_reg << 1;
                        
                        // Compare top half with divisor
                        if (dividend_reg[2*WL-1 : WL] >= divisor_reg) begin
                            dividend_reg[2*WL-1 : WL] = dividend_reg[2*WL-1 : WL] - divisor_reg;
                            quotient_reg = (quotient_reg << 1) | 1'b1;
                        end else begin
                            quotient_reg = quotient_reg << 1;
                        end
                        
                        count <= count - 1;
                    end else begin
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    ready <= 1'b1;
                    if (sign_res) begin
                        result <= -quotient_reg;
                    end else begin
                        result <= quotient_reg;
                    end
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
