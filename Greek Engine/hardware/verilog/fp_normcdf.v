`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Normal CDF — Abramowitz & Stegun Approximation
//============================================================================
// Computes N(x) = Φ(x), the standard normal cumulative distribution function.
//
// Uses the rational approximation from Abramowitz & Stegun (1964), Eq. 26.2.17:
//   For x >= 0:
//     t = 1 / (1 + p*x)
//     N(x) ≈ 1 - n(x) * (a1*t + a2*t² + a3*t³ + a4*t⁴ + a5*t⁵)
//   For x < 0:
//     N(x) = 1 - N(-x)       (symmetry)
//
//   where n(x) = (1/√(2π)) * exp(-x²/2)  (the PDF)
//
// Constants:
//   p  = 0.2316419
//   a1 = 0.319381530
//   a2 = -0.356563782
//   a3 = 1.781477937
//   a4 = -1.821255978
//   a5 = 1.330274429
//
// Accuracy: |ε| < 7.5e-8
// Latency: ~60 cycles (due to internal exp, div, and polynomial evaluation)
//============================================================================

module fp_normcdf #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] x,
    input  wire              start,
    output reg  [WL-1:0]     result,   // Unsigned [0, 1] in Q(1, FL-1)
    output reg               done
);

    // Constants in Q(IL, FL) format
    // NOTE: $signed() requires an integer/vector argument, not a `real` — the
    // real-valued constant expression must be rounded to an integer with
    // $rtoi() first (real args to $signed produced an elaboration error).
    // $rtoi returns a 32-bit *signed* integer, though, so computing it
    // directly at (2.0**FL) overflows/wraps for FL >= ~31. Instead, round
    // at min(FL,16) fractional bits — comfortably inside $rtoi's 32-bit
    // range for any real FL used in this design — and left-shift the rest
    // of the way when FL > 16 (exact: it just appends zero fractional
    // bits, not a further rounding step).
    wire signed [WL-1:0] CONST_P  = (FL<=16) ? $signed( $rtoi(0.2316419     * (2.0**FL)) ) : $signed( $rtoi(0.2316419     * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_A1 = (FL<=16) ? $signed( $rtoi(0.319381530   * (2.0**FL)) ) : $signed( $rtoi(0.319381530   * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_A2 = (FL<=16) ? $signed( $rtoi(-0.356563782  * (2.0**FL)) ) : $signed( $rtoi(-0.356563782  * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_A3 = (FL<=16) ? $signed( $rtoi(1.781477937   * (2.0**FL)) ) : $signed( $rtoi(1.781477937   * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_A4 = (FL<=16) ? $signed( $rtoi(-1.821255978  * (2.0**FL)) ) : $signed( $rtoi(-1.821255978  * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_A5 = (FL<=16) ? $signed( $rtoi(1.330274429   * (2.0**FL)) ) : $signed( $rtoi(1.330274429   * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_1  = (FL<=16) ? $signed( $rtoi(1.0           * (2.0**FL)) ) : $signed( $rtoi(1.0           * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] CONST_HALF = (FL<=16) ? $signed( $rtoi(0.5         * (2.0**FL)) ) : $signed( $rtoi(0.5         * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] INV_SQRT2PI = (FL<=16) ? $signed( $rtoi(0.3989422804014327 * (2.0**FL)) ) : $signed( $rtoi(0.3989422804014327 * (2.0**16)) ) <<< (FL-16);

    // FSM
    localparam S_IDLE      = 4'd0;
    localparam S_ABS_X     = 4'd1;
    localparam S_COMP_XSQ  = 4'd2;
    localparam S_COMP_PDF  = 4'd3;
    localparam S_COMP_T    = 4'd4;
    localparam S_HORNER    = 4'd5;
    localparam S_MUL       = 4'd6;
    localparam S_ADD       = 4'd7;
    localparam S_NEXT      = 4'd8;
    localparam S_FINAL     = 4'd9;
    localparam S_SYMMETRY  = 4'd10;
    localparam S_DONE      = 4'd11;

    reg [3:0] state;
    reg was_negative;
    reg signed [WL-1:0] abs_x;
    reg signed [WL-1:0] x_sq_half;   // x²/2
    reg signed [WL-1:0] pdf_val;     // n(x)
    reg signed [WL-1:0] t_val;       // t = 1/(1+p*|x|)
    reg signed [WL-1:0] accum;       // Horner accumulator
    reg signed [2*WL-1:0] wide_prod;
    reg [2:0] poly_step;
    reg signed [WL-1:0] poly_result;

    // Sub-module signals for exp and div
    reg exp_start, div_start;
    wire [WL-1:0] exp_result;
    wire exp_done;
    wire [WL-1:0] div_result;
    wire div_done, div_dbz, div_ovf;

    // Instantiate exp for computing exp(-x²/2)
    fp_exp #(.WL(WL), .FL(FL)) exp_inst (
        .clk(clk), .rst(rst),
        .x(x_sq_half), .start(exp_start),
        .result(exp_result), .done(exp_done)
    );

    // Instantiate divider for computing 1/(1+p*|x|)
    fp_div #(.WL(WL), .FL(FL)) div_inst (
        .clk(clk), .rst(rst),
        .a(CONST_1), .b(t_val), .start(div_start),
        .result(div_result), .ready(div_done),
        .divide_by_zero(div_dbz), .overflow(div_ovf)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            exp_start <= 1'b0;
            div_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        was_negative <= x[WL-1];
                        abs_x <= x[WL-1] ? -x : x;
                        state <= S_COMP_XSQ;
                    end
                end

                S_COMP_XSQ: begin
                    // Compute -x²/2
                    wide_prod = $signed(abs_x) * $signed(abs_x);
                    x_sq_half <= -(wide_prod[WL + FL - 1 : FL] >>> 1); // -x²/2
                    exp_start <= 1'b1;
                    state     <= S_COMP_PDF;
                end

                S_COMP_PDF: begin
                    // Wait for exp(-x²/2)
                    if (exp_done) begin
                        // pdf = (1/sqrt(2*pi)) * exp(-x²/2)
                        wide_prod = $signed(INV_SQRT2PI) * $signed(exp_result);
                        pdf_val <= wide_prod[WL + FL - 1 : FL];

                        // Compute denominator for t: 1 + p*|x|
                        wide_prod = $signed(CONST_P) * $signed(abs_x);
                        t_val <= CONST_1 + wide_prod[WL + FL - 1 : FL];
                        div_start <= 1'b1;
                        state <= S_COMP_T;
                    end
                end

                S_COMP_T: begin
                    // Wait for 1/(1+p*|x|)
                    if (div_done) begin
                        t_val <= div_result;
                        // Start Horner: accum = a5
                        accum     <= CONST_A5;
                        poly_step <= 3; // 4 more multiply-add steps
                        state     <= S_MUL;
                    end
                end

                S_MUL: begin
                    // accum = accum * t
                    wide_prod = $signed(accum) * $signed(t_val);
                    accum <= wide_prod[WL + FL - 1 : FL];
                    state <= S_ADD;
                end

                S_ADD: begin
                    case (poly_step)
                        3: accum <= accum + CONST_A4;
                        2: accum <= accum + CONST_A3;
                        1: accum <= accum + CONST_A2;
                        0: accum <= accum + CONST_A1;
                    endcase
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (poly_step == 0) begin
                        // Final: multiply by t once more
                        wide_prod = $signed(accum) * $signed(t_val);
                        poly_result <= wide_prod[WL + FL - 1 : FL];
                        state <= S_FINAL;
                    end else begin
                        poly_step <= poly_step - 1;
                        state <= S_MUL;
                    end
                end

                S_FINAL: begin
                    // N(|x|) = 1 - pdf * poly_result
                    wide_prod = $signed(pdf_val) * $signed(poly_result);
                    accum <= CONST_1 - wide_prod[WL + FL - 1 : FL];
                    state <= S_SYMMETRY;
                end

                S_SYMMETRY: begin
                    if (was_negative) begin
                        // N(-|x|) = 1 - N(|x|)
                        result <= CONST_1 - accum;
                    end else begin
                        result <= accum;
                    end
                    state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
