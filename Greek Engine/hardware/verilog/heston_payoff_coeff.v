`timescale 1ns / 1ps
//============================================================================
// Heston Payoff Coefficient Calculator (chi_k and psi_k functions)
//============================================================================
// Computes V_k for the COS summation (Fang & Oosterlee), matching
// hardware/matlab/heston_cos_forward_core.m's chi_func/psi_func exactly —
// with (c,d) always one of {0,a,b} (the payoff-domain edges), the general
// chi_k(c,d)/psi_k(c,d) formulas reduce to a single non-trivial trig pair
// per k, (cos(u_k*a), sin(u_k*a)), since:
//   call (c=0,d=b): kp*(d-a) = kp*(b-a) = k*pi exactly, so
//                    cos(kp*(d-a))=(-1)^k, sin(kp*(d-a))=0
//   put  (c=a,d=0):  kp*(c-a) = 0, so cos(...)=1, sin(...)=0
// so the caller only needs to run CORDIC once per k (for cos(u_k*a),
// sin(u_k*a)) and pass the result in here, along with exp(a), exp(b), and
// 2*K/(b-a) precomputed once outside the k-loop (all three are the same
// for every k). See the derivation in the accompanying commit/PR message
// for the full algebra.
//============================================================================

module heston_payoff_coeff #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,

    input  wire [7:0]        k,
    input  wire signed [WL-1:0] u_k,            // kp = k*pi/(b-a)
    input  wire signed [WL-1:0] a_in,            // COS truncation lower bound
    input  wire signed [WL-1:0] b_in,            // COS truncation upper bound
    input  wire signed [WL-1:0] exp_a,           // exp(a), precomputed once
    input  wire signed [WL-1:0] exp_b,           // exp(b), precomputed once
    input  wire signed [WL-1:0] cos_ua,          // cos(u_k*a)
    input  wire signed [WL-1:0] sin_ua,          // sin(u_k*a)
    input  wire signed [WL-1:0] two_K_over_bma,  // 2*K/(b-a), precomputed once
    input  wire               is_call,

    input  wire               start,
    output reg  signed [WL-1:0] V_k,
    output reg                done
);

    localparam signed [WL-1:0] ONE_C = (FL <= 16) ? (32'sd1 <<< FL) : (32'sd1 <<< 16) <<< (FL-16);

    localparam S_IDLE     = 3'd0;
    localparam S_K0       = 3'd1;
    localparam S_DIV_DEN  = 3'd2;
    localparam S_DIV_DEN_WAIT = 3'd3;
    localparam S_DIV_KP   = 3'd4;
    localparam S_DIV_KP_WAIT  = 3'd5;
    localparam S_COMBINE  = 3'd6;

    reg [2:0] state;

    reg fdiv_start;
    reg [WL-1:0] fdiv_a, fdiv_b;
    wire [WL-1:0] fdiv_result;
    wire fdiv_ready;

    fp_div #(.WL(WL), .FL(FL)) fdiv_inst (
        .clk(clk), .rst(rst),
        .a(fdiv_a), .b(fdiv_b), .start(fdiv_start),
        .result(fdiv_result), .ready(fdiv_ready),
        .divide_by_zero(), .overflow()
    );

    reg signed [WL-1:0] inv_denom, inv_kp;
    reg signed [WL-1:0] chi_v, psi_v;
    reg signed [2*WL-1:0] wp1, wp2, wp3;
    reg sign_k;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            fdiv_start <= 1'b0;
        end else begin
            fdiv_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        if (k == 8'd0) begin
                            state <= S_K0;
                        end else begin
                            // inv_denom = 1 / (1 + kp^2)
                            wp1 = $signed(u_k) * $signed(u_k);
                            fdiv_a <= ONE_C;
                            fdiv_b <= ONE_C + (wp1 >>> FL);
                            fdiv_start <= 1'b1;
                            state <= S_DIV_DEN_WAIT;
                        end
                    end
                end

                // ---- k == 0 (closed form, no division needed) ----
                S_K0: begin
                    if (is_call) begin
                        chi_v <= exp_b - ONE_C;
                        psi_v <= b_in;
                    end else begin
                        chi_v <= ONE_C - exp_a;
                        psi_v <= -a_in;
                    end
                    state <= S_COMBINE;
                end

                // ---- k > 0: 1/(1+kp^2) ----
                S_DIV_DEN_WAIT: begin
                    if (fdiv_ready) begin
                        inv_denom <= fdiv_result;
                        fdiv_a <= ONE_C;
                        fdiv_b <= u_k;
                        fdiv_start <= 1'b1;
                        state <= S_DIV_KP_WAIT;
                    end
                end

                // ---- k > 0: 1/kp ----
                S_DIV_KP_WAIT: begin
                    if (fdiv_ready) begin
                        inv_kp <= fdiv_result;
                        sign_k <= k[0]; // odd k -> cos(k*pi) = -1

                        if (is_call) begin
                            // chi = inv_denom * (exp_b*sign_k - cos_ua + kp*sin_ua)
                            wp1 = $signed(exp_b) * (k[0] ? -ONE_C : ONE_C);
                            wp2 = $signed(u_k) * $signed(sin_ua);
                            wp3 = $signed(inv_denom) * (( (wp1>>>FL) - cos_ua + (wp2>>>FL) ));
                            chi_v <= wp3 >>> FL;
                            // psi = inv_kp * sin_ua
                            wp1 = $signed(fdiv_result) * $signed(sin_ua);
                            psi_v <= wp1 >>> FL;
                        end else begin
                            // chi = inv_denom * (cos_ua - exp_a - kp*sin_ua)
                            wp2 = $signed(u_k) * $signed(sin_ua);
                            wp3 = $signed(inv_denom) * ( cos_ua - $signed(exp_a) - (wp2>>>FL) );
                            chi_v <= wp3 >>> FL;
                            // psi = -inv_kp * sin_ua
                            wp1 = $signed(fdiv_result) * $signed(sin_ua);
                            psi_v <= -(wp1 >>> FL);
                        end

                        state <= S_COMBINE;
                    end
                end

                S_COMBINE: begin
                    // V_k = two_K_over_bma * (chi - psi) [call], (psi - chi) [put]
                    if (is_call)
                        wp1 = $signed(two_K_over_bma) * (chi_v - psi_v);
                    else
                        wp1 = $signed(two_K_over_bma) * (psi_v - chi_v);
                    V_k  <= wp1 >>> FL;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
