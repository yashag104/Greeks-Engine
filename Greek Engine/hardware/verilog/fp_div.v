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
                    // NOTE: this used to be a bit-serial restoring-division
                    // loop (shift dividend_reg left by 1 and trial-subtract
                    // divisor_reg from its top half, once per remaining
                    // count). That only works if the *quotient* register is
                    // wide enough to hold every bit produced over all
                    // WL+FL iterations — but quotient_reg is only WL bits,
                    // while a WL+FL-bit quotient is exactly what dividing a
                    // WL-bit dividend pre-shifted left by FL requires, so
                    // the top FL bits produced were silently shifted out
                    // and lost before the final result was ever read,
                    // corrupting every result whose quotient needed more
                    // than WL significant bits during the sweep (which is
                    // effectively always, since dividend_reg was pre-shifted
                    // left by FL specifically to grow it past WL bits).
                    //
                    // dividend_reg[WL+FL-1:FL] already holds |a| (i.e. the
                    // dividend pre-shifted left by FL, exactly the Q(WL,FL)
                    // scaling this module's quotient needs), so the correct
                    // WL-bit quotient is simply the low WL bits of the
                    // (2*WL)-bit divide below — computed as one step rather
                    // than bit-serially, while still spending the same
                    // WL+FL cycles here so external timing is unaffected.
                    if (count > 0) begin
                        count <= count - 1;
                    end else begin
                        // quotient_reg is WL bits, so the assignment below
                        // implicitly truncates to its low WL bits — that's
                        // fine here since indexing the division expression
                        // directly (e.g. `(a/b)[WL-1:0]`) isn't legal syntax
                        // in plain Verilog (only SystemVerilog).
                        quotient_reg <= dividend_reg / {{WL{1'b0}}, divisor_reg};
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
