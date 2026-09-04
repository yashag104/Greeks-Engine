`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Normal PDF — n(x) = (1/√(2π)) * exp(-x²/2)
//============================================================================

module fp_normpdf #(
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

    // NOTE: $signed() requires an integer/vector argument, not a `real` — the
    // real-valued constant expression must be rounded to an integer with
    // $rtoi() first (real args to $signed produced an elaboration error).
    // $rtoi returns a 32-bit *signed* integer, though, so computing it
    // directly at (2.0**FL) overflows/wraps for FL >= ~31. Instead, round
    // at min(FL,16) fractional bits — comfortably inside $rtoi's 32-bit
    // range for any real FL used in this design — and left-shift the rest
    // of the way when FL > 16 (exact: it just appends zero fractional
    // bits, not a further rounding step).
    wire signed [WL-1:0] INV_SQRT2PI = (FL <= 16)
        ? $signed( $rtoi(0.3989422804014327 * (2.0**FL)) )
        : $signed( $rtoi(0.3989422804014327 * (2.0**16)) ) <<< (FL-16);

    // FSM
    localparam S_IDLE    = 3'd0;
    localparam S_XSQ     = 3'd1;
    localparam S_EXP     = 3'd2;
    localparam S_SCALE   = 3'd3;
    localparam S_DONE    = 3'd4;

    reg [2:0] state;
    reg signed [WL-1:0] neg_xsq_half;
    reg signed [2*WL-1:0] wide_prod;

    reg exp_start;
    wire [WL-1:0] exp_result;
    wire exp_done;

    fp_exp #(.WL(WL), .FL(FL)) exp_inst (
        .clk(clk), .rst(rst),
        .x(neg_xsq_half), .start(exp_start),
        .result(exp_result), .done(exp_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            exp_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= S_XSQ;
                    end
                end

                S_XSQ: begin
                    // Compute -x²/2
                    wide_prod = $signed(x) * $signed(x);
                    neg_xsq_half <= -(wide_prod[WL + FL - 1 : FL] >>> 1);
                    exp_start <= 1'b1;
                    state <= S_EXP;
                end

                S_EXP: begin
                    if (exp_done) begin
                        // result = (1/sqrt(2*pi)) * exp(-x²/2)
                        wide_prod = $signed(INV_SQRT2PI) * $signed(exp_result);
                        result <= wide_prod[WL + FL - 1 : FL];
                        state  <= S_DONE;
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
