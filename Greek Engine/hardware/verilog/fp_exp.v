`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Exponential Function — exp(x)
//============================================================================
// Computes exp(x) for signed fixed-point inputs using range reduction
// and a degree-6 minimax polynomial approximation.
//
// Algorithm:
//   1. Range reduction: decompose x = k*ln(2) + r, where |r| <= ln(2)/2
//   2. Approximate exp(r) using polynomial: 1 + r + r²/2 + r³/6 + ...
//   3. Reconstruct: exp(x) = exp(r) * 2^k (left shift by k)
//
// Latency: ~20 cycles (iterative multiply-accumulate for polynomial)
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

    localparam IL = WL - FL; // Integer bits (including sign)

    // Constants in Q(IL, FL) format
    // ln(2) ≈ 0.693147... 
    // 1/ln(2) ≈ 1.442695...
    // We need these as fixed-point constants
    
    // ln(2) in Q(IL, FL): round(0.6931471805599453 * 2^FL)
    // NOTE: $signed() requires an integer/vector argument, not a `real` — the
    // real-valued constant expression must be rounded to an integer with
    // $rtoi() first (real args to $signed produced an elaboration error).
    // $rtoi returns a 32-bit *signed* integer, though, so computing it
    // directly at (2.0**FL) overflows/wraps for FL >= ~31 (e.g. this
    // module is instantiated with FL=32 inside complex_exp.v). Instead,
    // round at min(FL,16) fractional bits — comfortably inside $rtoi's
    // 32-bit range for any real FL used in this design — and left-shift
    // the rest of the way when FL > 16 (that's exact: it just appends
    // zero fractional bits, not a further rounding step).
    wire signed [WL-1:0] LN2     = (FL <= 16)
        ? $signed( $rtoi(0.6931471805599453 * (2.0**FL)) )
        : $signed( $rtoi(0.6931471805599453 * (2.0**16)) ) <<< (FL-16);
    wire signed [WL-1:0] INV_LN2 = (FL <= 16)
        ? $signed( $rtoi(1.4426950408889634 * (2.0**FL)) )
        : $signed( $rtoi(1.4426950408889634 * (2.0**16)) ) <<< (FL-16);

    // Polynomial coefficients for exp(r) ≈ c0 + c1*r + c2*r² + c3*r³ + c4*r⁴ + c5*r⁵
    // Minimax approximation on [-ln(2)/2, ln(2)/2]
    wire signed [WL-1:0] C0 = (FL <= 16) ? $signed( $rtoi(1.0 * (2.0**FL)) ) : $signed( $rtoi(1.0 * (2.0**16)) ) <<< (FL-16); // 1.0
    wire signed [WL-1:0] C1 = (FL <= 16) ? $signed( $rtoi(1.0 * (2.0**FL)) ) : $signed( $rtoi(1.0 * (2.0**16)) ) <<< (FL-16); // 1.0
    wire signed [WL-1:0] C2 = (FL <= 16) ? $signed( $rtoi(0.5 * (2.0**FL)) ) : $signed( $rtoi(0.5 * (2.0**16)) ) <<< (FL-16); // 1/2!
    wire signed [WL-1:0] C3 = (FL <= 16) ? $signed( $rtoi(0.16666666666666666  * (2.0**FL)) ) : $signed( $rtoi(0.16666666666666666  * (2.0**16)) ) <<< (FL-16); // 1/3!
    wire signed [WL-1:0] C4 = (FL <= 16) ? $signed( $rtoi(0.041666666666666664 * (2.0**FL)) ) : $signed( $rtoi(0.041666666666666664 * (2.0**16)) ) <<< (FL-16); // 1/4!
    wire signed [WL-1:0] C5 = (FL <= 16) ? $signed( $rtoi(0.008333333333333333 * (2.0**FL)) ) : $signed( $rtoi(0.008333333333333333 * (2.0**16)) ) <<< (FL-16); // 1/5!

    // FSM states
    localparam S_IDLE       = 4'd0;
    localparam S_RANGE_RED  = 4'd1;
    localparam S_POLY_INIT  = 4'd2;
    localparam S_POLY_MUL   = 4'd3;
    localparam S_POLY_ADD   = 4'd4;
    localparam S_POLY_NEXT  = 4'd5;
    localparam S_RECON      = 4'd6;
    localparam S_DONE       = 4'd7;

    reg [3:0] state;

    // Working registers
    reg signed [2*WL-1:0] wide_product;  // For multiply intermediate
    reg signed [WL-1:0]   r_val;         // Reduced argument
    reg signed [WL-1:0]   k_val;         // Integer part (shift amount)
    reg signed [WL-1:0]   accum;         // Horner accumulator
    reg signed [WL-1:0]   r_power;       // Current power of r
    reg [3:0]              poly_step;     // Polynomial evaluation step

    // Horner's method: exp(r) = C0 + r*(C1 + r*(C2 + r*(C3 + r*(C4 + r*C5))))
    // We evaluate inside-out

    reg signed [WL-1:0] coeffs [0:5];

    // Scratch for the k-extraction step below (needs to be wide enough to
    // hold wide_product >>> (2*FL) before truncating to WL bits).
    reg signed [2*WL-1:0] k_val_c;

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            done   <= 1'b0;
            result <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= S_RANGE_RED;
                    end
                end

                S_RANGE_RED: begin
                    // k = round(x / ln(2))
                    wide_product = $signed(x) * INV_LN2;
                    // Extract integer part of x/ln(2) via an arithmetic
                    // right-shift (sign-extending) rather than a raw
                    // [2*FL+IL-1:2*FL] part-select — a part-select is always
                    // unsigned per the LRM, so it *zero*-extended into the
                    // wider k_val whenever k was negative, corrupting it.
                    k_val_c = wide_product >>> (2*FL);

                    // r = x - k * ln(2)
                    // NOTE: use k_val_c (computed via blocking assignment,
                    // above) here, not k_val itself — k_val is only updated
                    // by the nonblocking assignment below, which doesn't
                    // take effect until the end of this clock edge, so
                    // reading k_val in this same state would see its
                    // *stale* (pre-update, initially undefined) value.
                    k_val <= k_val_c[WL-1:0];
                    r_val <= x - k_val_c[WL-1:0] * LN2;
                    
                    // Initialize Horner's method: start with innermost coeff
                    accum     <= C5;
                    poly_step <= 4;  // We'll do 5 multiply-add steps
                    state     <= S_POLY_MUL;
                end

                S_POLY_MUL: begin
                    // accum = accum * r + C[poly_step]
                    wide_product = $signed(accum) * $signed(r_val);
                    accum <= wide_product[WL + FL - 1 : FL]; // Truncate back to Q format
                    state <= S_POLY_ADD;
                end

                S_POLY_ADD: begin
                    // Add the next coefficient
                    case (poly_step)
                        4: accum <= accum + C4;
                        3: accum <= accum + C3;
                        2: accum <= accum + C2;
                        1: accum <= accum + C1;
                        0: accum <= accum + C0;
                    endcase
                    state <= S_POLY_NEXT;
                end

                S_POLY_NEXT: begin
                    if (poly_step == 0) begin
                        state <= S_RECON;
                    end else begin
                        poly_step <= poly_step - 1;
                        state     <= S_POLY_MUL;
                    end
                end

                S_RECON: begin
                    // Reconstruct: exp(x) = exp(r) * 2^k
                    // 2^k is a left shift by k (if k >= 0) or right shift (if k < 0)
                    if (k_val[WL-1]) begin
                        // k < 0: right shift
                        result <= accum >>> (-k_val);
                    end else begin
                        result <= accum <<< k_val;
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
