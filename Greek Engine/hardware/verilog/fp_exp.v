`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Exponential Function — exp(x)
//============================================================================
// Algorithm:
//   1. Range reduction: k = round(x / ln2), r = x - k*ln2, so |r| <= ln2/2
//      (k*ln2 is formed from the Q4.60 ln2 constant, so r carries no
//      constant-quantization error beyond one ULP).
//   2. exp(r) by Horner evaluation of its degree-N Taylor polynomial, with
//      N picked from FL so the truncation remainder |r|^(N+1)/(N+1)! is
//      below one ULP:  FL<=16: N=6 (1.2e-7), <=24: N=8 (2.0e-10),
//      <=32: N=10 (2.6e-13), else N=13.
//   3. exp(x) = exp(r) * 2^k  (shift), saturating on overflow.
//
// Error bound (per call): |err| <= (N+2) ULP * exp(r) * 2^k + remainder,
// i.e. relative error ~ (N+3) * 2^-FL.
//
// NOTE (previous version): k was floor(x/ln2) rather than round, so r ran
// over [0, ln2) instead of [-ln2/2, ln2/2], and the polynomial stopped at
// degree 5 with 16-bit-truncated coefficients — a relative error of up to
// 1.5e-4 at *any* FL, including the Q32.32 characteristic-function path.
//
// Latency: 3 + 2N cycles.
//============================================================================

module fp_exp #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] x,
    input  wire              start,
    output reg  [WL-1:0]     result,
    output reg               done
);

    `include "fx_lib.vh"

    localparam integer NDEG = (FL <= 16) ? 6 : (FL <= 24) ? 8 : (FL <= 32) ? 10 : 13;

    wire signed [WL-1:0] INV_LN2 = q60(C_INV_LN2);

    localparam S_IDLE = 3'd0, S_RANGE = 3'd1, S_MUL = 3'd2, S_ADD = 3'd3,
               S_RECON = 3'd4, S_DONE = 3'd5;

    reg [2:0] state;
    reg signed [2*WL-1:0] wide;
    reg signed [127:0]    kln2;
    reg signed [WL-1:0]   k_val, r_val, accum;
    reg [3:0]             step;

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            done   <= 1'b0;
            result <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) state <= S_RANGE;
                end

                S_RANGE: begin
                    // k = round(x * (1/ln2))
                    wide  = $signed(x) * INV_LN2;
                    wide  = (wide + ($signed({{(2*WL-1){1'b0}}, 1'b1}) <<< (2*FL-1))) >>> (2*FL);
                    k_val <= wide[WL-1:0];
                    // r = x - k*ln2, with ln2 at 60 fractional bits
                    kln2  = $signed(wide[WL-1:0]) * C_LN2;
                    kln2  = (kln2 + ($signed(128'sd1) <<< (60-FL-1))) >>> (60-FL);
                    r_val <= x - kln2[WL-1:0];
                    accum <= q60(inv_fact(NDEG));
                    step  <= NDEG - 1;
                    state <= S_MUL;
                end

                S_MUL: begin
                    wide  = $signed(accum) * $signed(r_val);
                    accum <= rshr(wide);
                    state <= S_ADD;
                end

                S_ADD: begin
                    accum <= accum + q60(inv_fact(step));
                    if (step == 0) state <= S_RECON;
                    else begin
                        step  <= step - 1'b1;
                        state <= S_MUL;
                    end
                end

                S_RECON: begin
                    if (k_val[WL-1]) begin
                        result <= ((-k_val) >= WL) ? {WL{1'b0}} : ((accum + ($signed({{(WL-1){1'b0}}, 1'b1}) <<< (-k_val - 1))) >>> (-k_val));
                    end else if (k_val >= WL-FL-1) begin
                        result <= {1'b0, {(WL-1){1'b1}}};   // saturate
                    end else begin
                        result <= accum <<< k_val;
                    end
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
