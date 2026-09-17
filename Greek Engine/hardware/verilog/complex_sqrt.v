`timescale 1ns / 1ps
//============================================================================
// Complex Square Root — principal branch, sqrt(a_r + i*a_i)
//============================================================================
//   |z| = 2^s * sqrt((a_r>>s)^2 + (a_i>>s)^2)   (s>0 only when the squares
//                                                would overflow)
//   w   = sqrt((|z| + |a_r|) / 2)
//   a_r >= 0:  res = w + i * a_i/(2w)
//   a_r <  0:  res = |a_i|/(2w) + i * sign(a_i)*w
//
// NOTE (previous version): res_i = sqrt((|z| - a_r)/2), which cancels
// catastrophically when a_i is small relative to a_r (low COS frequencies:
// |z| - a_r ~ a_i^2 / 2|z|), and |z|^2 was formed unscaled, overflowing
// WL once |z| > 2^((WL-FL)/2 - 1) (short maturities / high vol-of-vol push
// |u_k|^2 xi^2 past that).
//
// Latency: 2 fp_sqrt + 1 fp_div.
//============================================================================

module complex_sqrt #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,
    input  wire              start,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               done
);

    `include "fx_lib.vh"


    localparam integer SQ_LIM = (WL + FL) / 2 - 2;

    localparam S_IDLE = 3'd0, S_MAG = 3'd1, S_MAG_WAIT = 3'd2, S_W_WAIT = 3'd3,
               S_DIV_WAIT = 3'd4, S_DONE = 3'd5;

    reg [2:0] state;
    reg signed [WL-1:0] ar, ai, w_val;
    reg [WL-1:0]        abs_r, abs_i, big;
    reg [7:0]           sh;
    reg signed [2*WL-1:0] p1, p2;
    integer i, pos;

    reg           sqrt_start;
    reg  [WL-1:0] sqrt_x;
    wire [WL-1:0] sqrt_result;
    wire          sqrt_done;
    fp_sqrt #(.WL(WL), .FL(FL)) sqrt_inst (
        .clk(clk), .rst(rst), .x(sqrt_x), .start(sqrt_start),
        .result(sqrt_result), .done(sqrt_done)
    );

    reg           div_start;
    reg  [WL-1:0] div_a, div_b;
    wire [WL-1:0] div_result;
    wire          div_ready;
    fp_div #(.WL(WL), .FL(FL)) div_inst (
        .clk(clk), .rst(rst), .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready), .divide_by_zero(), .overflow()
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            sqrt_start <= 1'b0;
            div_start  <= 1'b0;
        end else begin
            sqrt_start <= 1'b0;
            div_start  <= 1'b0;
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        ar <= a_r; ai <= a_i;
                        abs_r <= a_r[WL-1] ? -a_r : a_r;
                        abs_i <= a_i[WL-1] ? -a_i : a_i;
                        state <= S_MAG;
                    end
                end

                // scale so the squares cannot overflow: (a_r^2 + a_i^2) >> FL
                // must fit WL-1 bits, i.e. |x >> sh| < 2^SQ_LIM
                S_MAG: begin
                    big = (abs_r > abs_i) ? abs_r : abs_i;
                    pos = 0;
                    for (i = 0; i < WL; i = i + 1)
                        if (big[i]) pos = i;
                    sh = (pos >= SQ_LIM) ? (pos - SQ_LIM + 1) : 0;
                    p1 = $signed({1'b0, abs_r >> sh}) * $signed({1'b0, abs_r >> sh});
                    p2 = $signed({1'b0, abs_i >> sh}) * $signed({1'b0, abs_i >> sh});
                    sqrt_x <= rshr((p1 + p2));
                    sqrt_start <= 1'b1;
                    state <= S_MAG_WAIT;
                end

                S_MAG_WAIT: begin
                    if (sqrt_done) begin
                        // w = sqrt((|z| + |a_r|)/2)
                        sqrt_x <= ((sqrt_result << sh) + abs_r) >> 1;
                        sqrt_start <= 1'b1;
                        state <= S_W_WAIT;
                    end
                end

                S_W_WAIT: begin
                    if (sqrt_done) begin
                        w_val <= sqrt_result;
                        if (sqrt_result == 0) begin
                            res_r <= 0; res_i <= 0;
                            state <= S_DONE;
                        end else begin
                            div_a <= ar[WL-1] ? abs_i : ai;   // a_i or |a_i|
                            div_b <= sqrt_result << 1;
                            div_start <= 1'b1;
                            state <= S_DIV_WAIT;
                        end
                    end
                end

                S_DIV_WAIT: begin
                    if (div_ready) begin
                        if (!ar[WL-1]) begin
                            res_r <= w_val;
                            res_i <= div_result;
                        end else begin
                            res_r <= div_result;
                            res_i <= ai[WL-1] ? -w_val : w_val;
                        end
                        state <= S_DONE;
                    end
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
