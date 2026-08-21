`timescale 1ns / 1ps
//============================================================================
// Complex Square Root — sqrt(a + ib)
//============================================================================
// Uses the formula:
//   |z| = sqrt(a² + b²)
//   Re[sqrt(z)] = sqrt((|z| + a) / 2)
//   Im[sqrt(z)] = sign(b) * sqrt((|z| - a) / 2)
//
// Requires: 2 real multiplications, 3 real square roots, additions.
// Latency: ~3*WL cycles (3 sequential sqrt operations)
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

    // FSM
    localparam S_IDLE      = 4'd0;
    localparam S_MAG_SQ    = 4'd1;
    localparam S_SQRT_MAG  = 4'd2;
    localparam S_WAIT_MAG  = 4'd3;
    localparam S_SQRT_RE   = 4'd4;
    localparam S_WAIT_RE   = 4'd5;
    localparam S_SQRT_IM   = 4'd6;
    localparam S_WAIT_IM   = 4'd7;
    localparam S_SIGN      = 4'd8;
    localparam S_DONE      = 4'd9;

    reg [3:0] state;

    reg signed [WL-1:0] magnitude;    // |z|
    reg sign_b;                        // sign of imaginary part
    reg [WL-1:0] sqrt_input;
    reg sqrt_start;
    wire [WL-1:0] sqrt_result;
    wire sqrt_done;

    reg signed [2*WL-1:0] wide_prod;
    reg signed [WL-1:0] re_arg, im_arg;

    // Shared sqrt instance
    fp_sqrt #(.WL(WL), .FL(FL)) sqrt_inst (
        .clk(clk), .rst(rst),
        .x(sqrt_input), .start(sqrt_start),
        .result(sqrt_result), .done(sqrt_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            sqrt_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        sign_b <= a_i[WL-1];
                        state  <= S_MAG_SQ;
                    end
                end

                S_MAG_SQ: begin
                    // Compute a² + b²
                    begin
                        reg signed [2*WL-1:0] p1, p2;
                        p1 = $signed(a_r) * $signed(a_r);
                        p2 = $signed(a_i) * $signed(a_i);
                        sqrt_input <= (p1 + p2) >>> FL; // Truncate back to WL
                    end
                    sqrt_start <= 1'b1;
                    state      <= S_WAIT_MAG;
                end

                S_WAIT_MAG: begin
                    if (sqrt_done) begin
                        magnitude <= sqrt_result; // |z|
                        // Compute (|z| + a) / 2
                        re_arg <= ($signed(sqrt_result) + a_r) >>> 1;
                        // Compute (|z| - a) / 2
                        im_arg <= ($signed(sqrt_result) - a_r) >>> 1;
                        state  <= S_SQRT_RE;
                    end
                end

                S_SQRT_RE: begin
                    // sqrt((|z| + a) / 2)
                    sqrt_input <= re_arg;
                    sqrt_start <= 1'b1;
                    state      <= S_WAIT_RE;
                end

                S_WAIT_RE: begin
                    if (sqrt_done) begin
                        res_r <= sqrt_result;
                        state <= S_SQRT_IM;
                    end
                end

                S_SQRT_IM: begin
                    // sqrt((|z| - a) / 2)
                    sqrt_input <= im_arg;
                    sqrt_start <= 1'b1;
                    state      <= S_WAIT_IM;
                end

                S_WAIT_IM: begin
                    if (sqrt_done) begin
                        // Apply sign of b to imaginary part
                        if (sign_b)
                            res_i <= -$signed(sqrt_result);
                        else
                            res_i <= sqrt_result;
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
