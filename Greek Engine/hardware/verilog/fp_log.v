`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Natural Logarithm — ln(x)
//============================================================================
// Computes ln(x) for unsigned positive fixed-point inputs using:
//   1. Range reduction: x = m * 2^k where 1 <= m < 2
//   2. Polynomial approximation of ln(m) using Chebyshev minimax on [1, 2)
//   3. Reconstruction: ln(x) = k*ln(2) + ln(m)
//
// Latency: ~20 cycles
//============================================================================

module fp_log #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [WL-1:0]     x,           // Unsigned positive input
    input  wire              start,
    output reg  signed [WL-1:0] result,   // Signed output (ln can be negative)
    output reg               done,
    output reg               err_nonpositive
);

    localparam IL = WL - FL;

    // ln(2) in Q(IL, FL)
    wire signed [WL-1:0] LN2 = $signed( (0.6931471805599453 * (2.0**FL)) );

    // Polynomial coefficients for ln(1+t) where t = m - 1, t ∈ [0, 1)
    // ln(1+t) ≈ t - t²/2 + t³/3 - t⁴/4 + t⁵/5
    // Using Horner's form: t*(1 + t*(-1/2 + t*(1/3 + t*(-1/4 + t*(1/5)))))
    wire signed [WL-1:0] P5 = $signed( ( 0.2               * (2.0**FL)) ); //  1/5
    wire signed [WL-1:0] P4 = $signed( (-0.25              * (2.0**FL)) ); // -1/4
    wire signed [WL-1:0] P3 = $signed( ( 0.3333333333       * (2.0**FL)) ); //  1/3
    wire signed [WL-1:0] P2 = $signed( (-0.5               * (2.0**FL)) ); // -1/2
    wire signed [WL-1:0] P1 = $signed( ( 1.0               * (2.0**FL)) ); //  1

    // FSM
    localparam S_IDLE      = 4'd0;
    localparam S_NORMALIZE = 4'd1;
    localparam S_HORNER    = 4'd2;
    localparam S_MUL       = 4'd3;
    localparam S_ADD       = 4'd4;
    localparam S_NEXT      = 4'd5;
    localparam S_FINAL_MUL = 4'd6;
    localparam S_RECON     = 4'd7;
    localparam S_DONE      = 4'd8;

    reg [3:0] state;
    reg signed [WL-1:0] k_val;       // Exponent
    reg signed [WL-1:0] t_val;       // m - 1
    reg signed [WL-1:0] accum;       // Horner accumulator
    reg signed [2*WL-1:0] wide_prod;
    reg [2:0] poly_step;
    reg signed [WL-1:0] ln_m;        // ln(m) result

    // Leading zero counter for normalization
    integer i;
    reg [5:0] lzc;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            err_nonpositive <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    err_nonpositive <= 1'b0;
                    if (start) begin
                        if (x == 0 || x[WL-1]) begin
                            // Non-positive input
                            err_nonpositive <= 1'b1;
                            result <= {1'b1, {(WL-1){1'b0}}}; // Most negative value
                            done   <= 1'b1;
                        end else begin
                            state <= S_NORMALIZE;
                        end
                    end
                end

                S_NORMALIZE: begin
                    // Find position of leading 1 to extract mantissa
                    // x is in Q(IL, FL). The "1" of the mantissa should be at bit FL.
                    // Count how many positions we need to shift.
                    lzc = 0;
                    for (i = WL-1; i >= 0; i = i - 1) begin
                        if (x[i] == 1'b0 && lzc == (WL - 1 - i))
                            lzc = lzc + 1;
                    end
                    
                    // k = position_of_leading_1 - FL
                    // This gives us x = m * 2^k where m ∈ [1, 2)
                    k_val <= (WL - 1 - lzc) - FL;
                    
                    // Shift x so leading 1 is at bit FL (making m ∈ [1,2))
                    // t = m - 1 (subtract 1.0 in Q format)
                    if ((WL - 1 - lzc) > FL) begin
                        t_val <= (x >> ((WL - 1 - lzc) - FL)) - (1 << FL);
                    end else begin
                        t_val <= (x << (FL - (WL - 1 - lzc))) - (1 << FL);
                    end
                    
                    // Start Horner's method with innermost coefficient
                    accum     <= P5;
                    poly_step <= 3; // 4 multiply-add steps remaining
                    state     <= S_MUL;
                end

                S_MUL: begin
                    // accum = accum * t
                    wide_prod = $signed(accum) * $signed(t_val);
                    accum <= wide_prod[WL + FL - 1 : FL];
                    state <= S_ADD;
                end

                S_ADD: begin
                    case (poly_step)
                        3: accum <= accum + P4;
                        2: accum <= accum + P3;
                        1: accum <= accum + P2;
                        0: accum <= accum + P1;
                    endcase
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (poly_step == 0) begin
                        // Final multiply by t to get ln(1+t) = t * horner_result
                        state <= S_FINAL_MUL;
                    end else begin
                        poly_step <= poly_step - 1;
                        state <= S_MUL;
                    end
                end

                S_FINAL_MUL: begin
                    wide_prod = $signed(accum) * $signed(t_val);
                    ln_m  <= wide_prod[WL + FL - 1 : FL];
                    state <= S_RECON;
                end

                S_RECON: begin
                    // ln(x) = k * ln(2) + ln(m)
                    wide_prod = k_val * LN2;
                    result <= wide_prod[WL-1:0] + ln_m;
                    state  <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
