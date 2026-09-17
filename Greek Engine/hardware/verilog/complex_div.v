`timescale 1ns / 1ps
//============================================================================
// Complex Division — (a_r + i*a_i) / (b_r + i*b_i)
//============================================================================
// Smith's algorithm (no |b|^2 is ever formed):
//   if |b_r| >= |b_i|:  t = b_i/b_r,  den = b_r + b_i*t,
//                       res = ((a_r + a_i*t) + i*(a_i - a_r*t)) / den
//   else:               t = b_r/b_i,  den = b_i + b_r*t,
//                       res = ((a_r*t + a_i) + i*(a_i*t - a_r)) / den
// with the final "/den" done as one division 2^G/den followed by two
// multiplies. G (up to WL-FL-2 guard bits) is chosen from den's leading one
// so 2^G/den cannot overflow; without it the 1-ULP error of 1/den would be
// multiplied by |a| (measured: 47 ULP for |a| ~ 50). Two fp_div calls, as
// before.
//
// NOTE (previous version): res = a*conj(b) / |b|^2, with a*conj(b) and
// |b|^2 each truncated to FL bits before dividing. For |b| < 1 that throws
// away ~2*log2(1/|b|) bits — e.g. num/xi^2 in heston_char_func divided by
// |0.09|^2 = 0.0081 lost ~7 bits and was the dominant error in dV/dxi.
// Squaring also overflows WL for |b| > 2^((WL-FL)/2 - 1).
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

    `include "fx_lib.vh"

    localparam S_IDLE = 3'd0, S_T = 3'd1, S_T_WAIT = 3'd2, S_DEN = 3'd3,
               S_INV_WAIT = 3'd4, S_OUT = 3'd5, S_DONE = 3'd6;

    reg [2:0] state;
    reg signed [WL-1:0] ar, ai, br, bi, t_val, inv_den, nr, ni;
    reg                 swap;   // |b_i| > |b_r|
    reg signed [2*WL-1:0] w1, w2;
    reg signed [WL-1:0]   den;
    reg        [WL-1:0]   den_abs;
    reg        [7:0]      guard;
    integer               i, pos, g_try;

    reg           div_start;
    reg  [WL-1:0] div_a, div_b;
    wire [WL-1:0] div_result;
    wire          div_ready;

    fp_div #(.WL(WL), .FL(FL)) divider (
        .clk(clk), .rst(rst), .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready), .divide_by_zero(), .overflow()
    );

    wire [WL-1:0] abs_br = b_r[WL-1] ? -b_r : b_r;
    wire [WL-1:0] abs_bi = b_i[WL-1] ? -b_i : b_i;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            div_start <= 1'b0;
        end else begin
            div_start <= 1'b0;
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        ar <= a_r; ai <= a_i; br <= b_r; bi <= b_i;
                        swap  <= (abs_bi > abs_br);
                        state <= S_T;
                    end
                end

                S_T: begin
                    if (swap) begin
                        div_a <= br; div_b <= bi;
                    end else if (bi == 0) begin
                        div_a <= 0;  div_b <= br;   // t = 0 exactly
                    end else begin
                        div_a <= bi; div_b <= br;
                    end
                    div_start <= 1'b1;
                    state <= S_T_WAIT;
                end

                S_T_WAIT: begin
                    if (div_ready) begin
                        t_val <= div_result;
                        state <= S_DEN;
                    end
                end

                // den = b_big + b_small*t ; issue 2^G/den
                S_DEN: begin
                    if (swap) begin
                        w1 = $signed(br) * $signed(t_val);
                        den = bi + (rshr(w1));
                        w1 = $signed(ar) * $signed(t_val);
                        w2 = $signed(ai) * $signed(t_val);
                        nr <= (rshr(w1)) + ai;
                        ni <= (rshr(w2)) - ar;
                    end else begin
                        w1 = $signed(bi) * $signed(t_val);
                        den = br + (rshr(w1));
                        w1 = $signed(ai) * $signed(t_val);
                        w2 = $signed(ar) * $signed(t_val);
                        nr <= ar + (rshr(w1));
                        ni <= ai - (rshr(w2));
                    end
                    // |2^G/den| < 2^(WL-FL-2)  <=  G <= pos(den) - FL + (WL-FL) - 3
                    den_abs = den[WL-1] ? -den : den;
                    pos = 0;
                    for (i = 0; i < WL; i = i + 1)
                        if (den_abs[i]) pos = i;
                    g_try = pos - FL + (WL - FL) - 3;
                    if (g_try > WL - FL - 2) g_try = WL - FL - 2;
                    if (g_try < 0) g_try = 0;
                    guard <= g_try;
                    div_b <= den;
                    div_a <= q60(C_ONE) <<< g_try;
                    div_start <= 1'b1;
                    state <= S_INV_WAIT;
                end

                S_INV_WAIT: begin
                    if (div_ready) begin
                        inv_den <= div_result;
                        state <= S_OUT;
                    end
                end

                S_OUT: begin
                    w1 = $signed(nr) * $signed(inv_den);
                    w2 = $signed(ni) * $signed(inv_den);
                    res_r <= (w1 + ($signed({{(2*WL-1){1'b0}}, 1'b1}) <<< (FL + guard - 1))) >>> (FL + guard);
                    res_i <= (w2 + ($signed({{(2*WL-1){1'b0}}, 1'b1}) <<< (FL + guard - 1))) >>> (FL + guard);
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
