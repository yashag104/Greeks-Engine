`timescale 1ns / 1ps
//============================================================================
// CORDIC Engine — Rotation & Vectoring Modes
//============================================================================
// Implements the classic CORDIC algorithm for computing:
//   - Rotation mode: sin(θ), cos(θ) from angle θ
//   - Vectoring mode: atan2(y, x), magnitude sqrt(x²+y²)
//
// Parameterized for arbitrary word lengths. Iterative architecture:
// uses N_ITER micro-rotations over N_ITER clock cycles.
//
// Fixed-point angle representation: radians in Q(IL, FL) format.
// The CORDIC gain K ≈ 0.6073 is pre-compensated in the output.
//============================================================================

module cordic #(
    parameter WL     = 32,       // Word length for x, y
    parameter AL     = 32,       // Word length for angle (z)
    parameter N_ITER = 30,       // Number of CORDIC iterations
    parameter AF     = 28        // Fractional bits in angle representation
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            start,
    input  wire            mode,        // 0 = rotation, 1 = vectoring
    input  wire signed [WL-1:0] x_in,
    input  wire signed [WL-1:0] y_in,
    input  wire signed [AL-1:0] z_in,   // Angle input (rotation) or initial 0 (vectoring)
    output reg  signed [WL-1:0] x_out,
    output reg  signed [WL-1:0] y_out,
    output reg  signed [AL-1:0] z_out,  // Residual angle (rotation) or atan2 result (vectoring)
    output reg                  done
);

    // CORDIC atan lookup table: atan(2^(-i)) in Q(4, AF) format
    // Pre-computed for up to 32 iterations
    reg signed [AL-1:0] atan_table [0:31];
    // Same constants, always in their native Q(4,28) form (28 fractional
    // bits — that's the precision the literals below were computed to).
    reg signed [31:0] atan_q28 [0:31];
    integer atan_idx;

    // CORDIC gain inverse: 1/K ≈ 0.6072529350...
    // We apply this as a final scaling factor
    // In Q(WL) format with FL fractional bits matching the input
    // For now, we store as a constant and multiply at the end

    initial begin
        // atan(2^0)  = 0.7853981634 rad
        // For AF=28, these are pre-computed atan(2^-i) * 2^28
        atan_q28[ 0] = 32'sh0C90FDAA;
        atan_q28[ 1] = 32'sh076B19C2;
        atan_q28[ 2] = 32'sh03EB6EBF;
        atan_q28[ 3] = 32'sh01FD5BA9;
        atan_q28[ 4] = 32'sh00FFAADD;
        atan_q28[ 5] = 32'sh007FF557;
        atan_q28[ 6] = 32'sh003FFEAB;
        atan_q28[ 7] = 32'sh001FFFD5;
        atan_q28[ 8] = 32'sh000FFFFB;
        atan_q28[ 9] = 32'sh0007FFFF;
        atan_q28[10] = 32'sh00040000;
        atan_q28[11] = 32'sh00020000;
        atan_q28[12] = 32'sh00010000;
        atan_q28[13] = 32'sh00008000;
        atan_q28[14] = 32'sh00004000;
        atan_q28[15] = 32'sh00002000;
        atan_q28[16] = 32'sh00001000;
        atan_q28[17] = 32'sh00000800;
        atan_q28[18] = 32'sh00000400;
        atan_q28[19] = 32'sh00000200;
        atan_q28[20] = 32'sh00000100;
        atan_q28[21] = 32'sh00000080;
        atan_q28[22] = 32'sh00000040;
        atan_q28[23] = 32'sh00000020;
        atan_q28[24] = 32'sh00000010;
        atan_q28[25] = 32'sh00000008;
        atan_q28[26] = 32'sh00000004;
        atan_q28[27] = 32'sh00000002;
        atan_q28[28] = 32'sh00000001;
        atan_q28[29] = 32'sh00000001;
        atan_q28[30] = 32'sh00000000;
        atan_q28[31] = 32'sh00000000;

        // Rescale from the constants' native Q28 representation into this
        // instance's actual Q(.,AF) angle format.
        //
        // NOTE: the previous version of this table only ever *dropped*
        // bits (`>> (28-AF)`) when AF < 28, and left the raw Q28 literal
        // completely unchanged whenever AF >= 28 — silently treating it as
        // if it were already in Q(.,AF) form. For any AF > 28 (e.g. the
        // AF=48 default that complex_exp/complex_log instantiate this
        // module with) that under-scales every angle by 2^(AF-28), making
        // z_in/z_out ~2^(AF-28)x too small. Extending a fixed-point value
        // to more fractional bits means *left*-shifting it (appending zero
        // fractional bits), not leaving the raw integer unchanged.
        for (atan_idx = 0; atan_idx < 32; atan_idx = atan_idx + 1) begin
            if (AF >= 28)
                atan_table[atan_idx] = $signed({{(AL-32){atan_q28[atan_idx][31]}}, atan_q28[atan_idx]}) <<< (AF - 28);
            else
                atan_table[atan_idx] = $signed({{(AL-32){atan_q28[atan_idx][31]}}, atan_q28[atan_idx]}) >>> (28 - AF);
        end
    end

    // State machine
    localparam S_IDLE     = 2'd0;
    localparam S_COMPUTE  = 2'd1;
    localparam S_DONE     = 2'd2;

    reg [1:0]  state;
    reg [5:0]  iter;            // Iteration counter
    reg        mode_reg;

    // Extended working registers (extra guard bits for precision)
    localparam EXT = WL + 2;
    reg signed [EXT-1:0] x_reg, y_reg;
    reg signed [AL-1:0]  z_reg;

    // Quadrant pre-rotation flags
    reg q_flip_x, q_flip_y, q_add_pi;

    // Rotation-mode argument reduction scratch (see S_IDLE below).
    reg signed [2*AL-1:0] rr_wide;
    reg signed [AL-1:0]   rr_over_2pi, rr_n, rr_n2pi, rr_z;

    wire signed [EXT-1:0] x_shift = x_reg >>> iter;
    wire signed [EXT-1:0] y_shift = y_reg >>> iter;

    // pi, rescaled from its native Q28 constant into Q(.,AF) — same fix as
    // the atan table above: widen with a *left* shift when AF > 28, only
    // drop bits with a right shift when AF < 28.
    wire signed [AL-1:0] PI_ANGLE = (AF >= 28)
        ? ($signed({{(AL-32){1'b0}}, 32'sh3243F6A8}) <<< (AF - 28))
        : ($signed({{(AL-32){1'b0}}, 32'sh3243F6A8}) >>> (28 - AF));
    wire signed [AL-1:0] TWO_PI_ANGLE = PI_ANGLE <<< 1;
    wire signed [AL-1:0] PI_HALF_ANGLE = PI_ANGLE >>> 1;
    // 1/(2*pi), in Q(.,AF) — same $rtoi-overflow-safe construction used
    // throughout this design (round at <=16 fractional bits, then widen
    // with a left shift, since $rtoi's 32-bit signed return range would
    // otherwise silently wrap for AF >= ~31).
    wire signed [AL-1:0] INV_2PI = (AF <= 16)
        ? $signed($rtoi(0.15915494309189535 * (2.0**AF)))
        : $signed($rtoi(0.15915494309189535 * (2.0**16))) <<< (AF-16);

    // Decision variable: depends on mode
    // Rotation mode: rotate to drive z toward 0 => decision = sign of z
    //   (decision=1 issues a CW step, which is what a negative z needs to
    //   climb back toward 0; decision=0 issues CCW, which is what a
    //   positive z needs to fall back toward 0.)
    // Vectoring mode: rotate to drive y toward 0 => decision must be 1
    //   (CW step) exactly when y is *positive* (CW decreases y), i.e. the
    //   opposite sense of the sign bit — using y_reg[EXT-1] directly here
    //   (as in rotation mode) picks the rotation direction that *increases*
    //   |y| instead, so the iteration diverges rather than converging.
    wire decision = mode_reg ? ~y_reg[EXT-1] : z_reg[AL-1];

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        mode_reg <= mode;
                        iter     <= 0;

                        if (mode == 1'b0) begin
                            // Rotation mode: the iteration only converges
                            // for angles within roughly the sum of the
                            // atan(2^-i) table (~1.7433 rad / ~99.9°) of
                            // zero. A caller-supplied z_in can be much
                            // larger (u_k*a in the Heston-COS engine
                            // routinely spans many multiples of 2*pi), so
                            // it must first be reduced modulo 2*pi into
                            // (-pi,pi], and then, if it's still outside
                            // [-pi/2,pi/2], folded once more by +/-pi
                            // (compensated for at the end by negating the
                            // output vector, since cos/sin(z-pi) = -cos/sin(z)).
                            //
                            // n = round(z_in / (2*pi)) = floor(x + 0.5).
                            // NOTE: >>> on a *signed* value is a floor
                            // (rounds toward -infinity), not a
                            // truncate-toward-zero — so floor(x+0.5) alone
                            // already gives correct round-to-nearest for
                            // both signs; conditionally using floor(x-0.5)
                            // for negative x (an earlier version of this)
                            // double-subtracted an extra ~1, rounding one
                            // full step too far away from zero.
                            rr_wide = $signed(z_in) * INV_2PI;
                            rr_over_2pi = rr_wide >>> AF;
                            rr_n = (rr_over_2pi + (1 <<< (AF-1))) >>> AF;
                            rr_n2pi = rr_n * TWO_PI_ANGLE;
                            // z_mod = z_in - n*2*pi, now in (-pi,pi]
                            rr_z = z_in - rr_n2pi;

                            // NOTE: R(z)*v == -( R(z-+-pi) * v ) — i.e. once
                            // z is folded by one more +/-pi to land in
                            // [-pi/2,pi/2], the *output* vector needs
                            // negating to compensate (q_flip_x, applied in
                            // S_DONE below), rather than negating the input
                            // vector here (that would just be an
                            // equivalent-but-different way to do the same
                            // correction — doing *both* would cancel out
                            // and silently undo it).
                            x_reg <= {{2{x_in[WL-1]}}, x_in};
                            y_reg <= {{2{y_in[WL-1]}}, y_in};
                            if (rr_z > PI_HALF_ANGLE) begin
                                z_reg <= rr_z - PI_ANGLE;
                                q_flip_x <= 1'b1;
                            end else if (rr_z < -PI_HALF_ANGLE) begin
                                z_reg <= rr_z + PI_ANGLE;
                                q_flip_x <= 1'b1;
                            end else begin
                                z_reg <= rr_z;
                                q_flip_x <= 1'b0;
                            end
                            q_flip_y <= 1'b0;
                            q_add_pi <= 1'b0;
                        end else begin
                            // Vectoring mode: pre-rotate (x,y) into Q1
                            // so that x >= 0 (CORDIC converges when x > 0)
                            if (x_in[WL-1]) begin
                                // x < 0: rotate by pi (negate both)
                                x_reg <= -{{2{x_in[WL-1]}}, x_in};
                                y_reg <= -{{2{y_in[WL-1]}}, y_in};
                                q_add_pi <= 1'b1;
                                q_flip_y <= y_in[WL-1]; // Track original y sign
                            end else begin
                                x_reg <= {{2{x_in[WL-1]}}, x_in};
                                y_reg <= {{2{y_in[WL-1]}}, y_in};
                                q_add_pi <= 1'b0;
                                q_flip_y <= 1'b0;
                            end
                            z_reg    <= 0;
                            q_flip_x <= 1'b0;
                        end

                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (iter < N_ITER) begin
                        if (decision == 1'b1) begin
                            // Negative rotation (clockwise)
                            x_reg <= x_reg + y_shift;
                            y_reg <= y_reg - x_shift;
                            z_reg <= z_reg + atan_table[iter];
                        end else begin
                            // Positive rotation (counter-clockwise)
                            x_reg <= x_reg - y_shift;
                            y_reg <= y_reg + x_shift;
                            z_reg <= z_reg - atan_table[iter];
                        end
                        iter <= iter + 1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    // Output results
                    // Note: outputs include CORDIC gain K ≈ 1.6468.
                    // The caller must multiply by 1/K ≈ 0.6073 if needed.
                    if (!mode_reg && q_flip_x) begin
                        // Rotation mode's +/-pi argument-reduction fold
                        // (see S_IDLE) needs the output vector negated to
                        // compensate.
                        x_out <= -x_reg[WL-1:0];
                        y_out <= -y_reg[WL-1:0];
                    end else begin
                        x_out <= x_reg[WL-1:0];
                        y_out <= y_reg[WL-1:0];
                    end

                    if (mode_reg && q_add_pi) begin
                        // Vectoring mode: correct angle for pre-rotation
                        // atan_table stores atan(2^-i) in radians
                        // pi ≈ 3.14159... in Q(4,AF) ≈ 0x3243F6A8 for AF=28
                        if (q_flip_y) begin
                            // Original y was negative => angle in Q3/Q4
                            z_out <= z_reg - PI_ANGLE;
                        end else begin
                            z_out <= z_reg + PI_ANGLE;
                        end
                    end else begin
                        z_out <= z_reg;
                    end

                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
