`timescale 1ns / 1ps
//============================================================================
// Complex Divider — (a_r + i*a_i) / (b_r + i*b_i)
//============================================================================
// Uses the conjugate method:
//   (a + ib) / (c + id) = [(ac + bd) + i(bc - ad)] / (c² + d²)
//
// Requires: 4 real multiplications, 3 additions, 1 real division.
// Latency: ~WL+10 cycles (dominated by the real fp_div)
//============================================================================

module complex_div #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,
    input  wire signed [WL-1:0] b_r, b_i,
    input  wire              start,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               done
);

    // FSM
    localparam S_IDLE     = 3'd0;
    localparam S_PRODUCTS = 3'd1;
    localparam S_DIV_R    = 3'd2;
    localparam S_WAIT_R   = 3'd3;
    localparam S_DIV_I    = 3'd4;
    localparam S_WAIT_I   = 3'd5;
    localparam S_DONE     = 3'd6;

    reg [2:0] state;

    reg signed [2*WL-1:0] wide_prod;
    reg signed [WL-1:0] num_r, num_i, denom;
    
    // Divider signals
    reg [WL-1:0] div_a, div_b;
    reg div_start;
    wire [WL-1:0] div_result;
    wire div_ready, div_dbz, div_ovf;

    fp_div #(.WL(WL), .FL(FL)) divider (
        .clk(clk), .rst(rst),
        .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready),
        .divide_by_zero(div_dbz), .overflow(div_ovf)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            div_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= S_PRODUCTS;
                    end
                end

                S_PRODUCTS: begin
                    // Compute numerators and denominator
                    // num_r = a_r*b_r + a_i*b_i
                    // num_i = a_i*b_r - a_r*b_i
                    // denom = b_r*b_r + b_i*b_i
                    
                    // We compute sequentially using the wide multiply register
                    // In a fully pipelined design, these would be parallel DSPs
                    begin
                        reg signed [2*WL-1:0] p1, p2, p3, p4, p5, p6;
                        p1 = $signed(a_r) * $signed(b_r);
                        p2 = $signed(a_i) * $signed(b_i);
                        p3 = $signed(a_i) * $signed(b_r);
                        p4 = $signed(a_r) * $signed(b_i);
                        p5 = $signed(b_r) * $signed(b_r);
                        p6 = $signed(b_i) * $signed(b_i);

                        num_r <= (p1 + p2) >>> FL;
                        num_i <= (p3 - p4) >>> FL;
                        denom <= (p5 + p6) >>> FL;
                    end

                    state <= S_DIV_R;
                end

                S_DIV_R: begin
                    // Divide num_r / denom
                    div_a     <= num_r;
                    div_b     <= denom;
                    div_start <= 1'b1;
                    state     <= S_WAIT_R;
                end

                S_WAIT_R: begin
                    if (div_ready) begin
                        res_r <= div_result;
                        state <= S_DIV_I;
                    end
                end

                S_DIV_I: begin
                    // Divide num_i / denom
                    div_a     <= num_i;
                    div_b     <= denom;
                    div_start <= 1'b1;
                    state     <= S_WAIT_I;
                end

                S_WAIT_I: begin
                    if (div_ready) begin
                        res_i <= div_result;
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
