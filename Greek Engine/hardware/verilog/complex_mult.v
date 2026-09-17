`timescale 1ns / 1ps
//============================================================================
// Complex Multiplier — (a_r + i*a_i) * (b_r + i*b_i)
//============================================================================
// res_r = a_r*b_r - a_i*b_i
// res_i = a_r*b_i + a_i*b_r
//
// Uses 4 real multiplications and 2 additions.
// Pipelined: 1 cycle latency for multiply, 1 cycle for accumulate = 2 total.
//============================================================================

module complex_mult #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,
    input  wire signed [WL-1:0] b_r, b_i,
    input  wire              valid_in,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               valid_out
);

    `include "fx_lib.vh"


    // Pipeline stage 1: compute 4 partial products
    reg signed [2*WL-1:0] pp_rr, pp_ii, pp_ri, pp_ir;
    reg pipe1_valid;

    always @(posedge clk) begin
        if (rst) begin
            pp_rr <= 0; pp_ii <= 0; pp_ri <= 0; pp_ir <= 0;
            pipe1_valid <= 0;
        end else begin
            pipe1_valid <= valid_in;
            if (valid_in) begin
                pp_rr <= $signed(a_r) * $signed(b_r);
                pp_ii <= $signed(a_i) * $signed(b_i);
                pp_ri <= $signed(a_r) * $signed(b_i);
                pp_ir <= $signed(a_i) * $signed(b_r);
            end
        end
    end

    // Pipeline stage 2: combine and truncate
    always @(posedge clk) begin
        if (rst) begin
            res_r <= 0; res_i <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= pipe1_valid;
            if (pipe1_valid) begin
                // Truncate from 2*WL bits back to WL, shifting by FL
                res_r <= rshr((pp_rr - pp_ii));
                res_i <= rshr((pp_ri + pp_ir));
            end
        end
    end

endmodule
