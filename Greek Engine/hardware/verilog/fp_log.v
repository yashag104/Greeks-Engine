`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Natural Logarithm — ln(x), x > 0
//============================================================================
// Algorithm (table-assisted Taylor, Tang-style):
//   1. Normalize x = m * 2^k, m in [1,2)  (leading-one detection).
//   2. j = top 4 fractional bits of m; c_j = 1 + (2j+1)/32 is the midpoint
//      of m's 1/16-wide sub-interval. t = m/c_j - 1 is formed as
//      m * (1/c_j) - 1 using the Q4.60 reciprocal, so |t| <= 1/33.
//   3. ln(1+t) by Horner on its degree-N Taylor polynomial; remainder
//      |t|^(N+1)/(N+1): FL<=16: N=3 (2.1e-7), <=24: N=5 (1.8e-10),
//      <=32: N=6 (3.2e-12), else N=8.
//   4. ln(x) = k*ln2 + ln(c_j) + ln(1+t)  (ln2, ln(c_j) at Q4.60).
//
// Error bound (per call): |err| <= (N+4) ULP + remainder.
//
// NOTE (previous version): used a 5-term series in t = m-1 with |t| up to
// 0.414 and 16-bit-truncated coefficients: truncation error up to 8e-4
// at any FL, i.e. only ~3 correct decimal digits even in Q32.32.
//
// Latency: 5 + 2N cycles.
//============================================================================

module fp_log #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [WL-1:0]     x,
    input  wire              start,
    output reg  signed [WL-1:0] result,
    output reg               done,
    output reg               err_nonpositive
);

    `include "fx_lib.vh"

    localparam integer NDEG = (FL <= 16) ? 3 : (FL <= 24) ? 5 : (FL <= 32) ? 6 : 8;

    localparam S_IDLE = 3'd0, S_NORM = 3'd1, S_T = 3'd2, S_MUL = 3'd3,
               S_ADD = 3'd4, S_FINAL = 3'd5, S_RECON = 3'd6, S_DONE = 3'd7;

    reg [2:0] state;
    reg signed [WL-1:0]   k_val, m_val, t_val, accum, ln1pt;
    reg [3:0]             j_idx, step;
    reg signed [2*WL-1:0] wide;
    reg signed [127:0]    w128;
    integer i, pos;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            err_nonpositive <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (x == 0 || x[WL-1]) begin
                            err_nonpositive <= 1'b1;
                            result <= {1'b1, {(WL-1){1'b0}}};
                            done   <= 1'b1;
                        end else begin
                            err_nonpositive <= 1'b0;
                            state <= S_NORM;
                        end
                    end
                end

                // x = m * 2^k with m in [1,2) as Q(.,FL)
                S_NORM: begin
                    pos = 0;
                    for (i = 0; i < WL; i = i + 1)
                        if (x[i]) pos = i;
                    k_val <= pos - FL;
                    if (pos >= FL) m_val <= x >> (pos - FL);
                    else           m_val <= x << (FL - pos);
                    state <= S_T;
                end

                // t = m * (1/c_j) - 1
                S_T: begin
                    j_idx <= m_val[FL-1 -: 4];
                    w128  = $signed(m_val) * log_inv_c(m_val[FL-1 -: 4]);
                    w128  = (w128 + ($signed(128'sd1) <<< 59)) >>> 60;
                    t_val <= w128[WL-1:0] - q60(C_ONE);
                    accum <= q60(log_coef(NDEG));
                    step  <= NDEG - 1;
                    state <= S_MUL;
                end

                S_MUL: begin
                    wide  = $signed(accum) * $signed(t_val);
                    accum <= rshr(wide);
                    state <= S_ADD;
                end

                S_ADD: begin
                    accum <= accum + q60(log_coef(step));
                    if (step == 1) state <= S_FINAL;
                    else begin
                        step  <= step - 1'b1;
                        state <= S_MUL;
                    end
                end

                // ln(1+t) = t * (1 - t/2 + t^2/3 - ...)
                S_FINAL: begin
                    wide  = $signed(accum) * $signed(t_val);
                    ln1pt <= rshr(wide);
                    state <= S_RECON;
                end

                S_RECON: begin
                    w128   = $signed(k_val) * C_LN2 + log_ln_c(j_idx);
                    w128   = (w128 + ($signed(128'sd1) <<< (60-FL-1))) >>> (60-FL);
                    result <= w128[WL-1:0] + ln1pt;
                    state  <= S_DONE;
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
