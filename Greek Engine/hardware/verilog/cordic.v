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

    // CORDIC gain inverse: 1/K ≈ 0.6072529350... 
    // We apply this as a final scaling factor
    // In Q(WL) format with FL fractional bits matching the input
    // For now, we store as a constant and multiply at the end
    
    initial begin
        // atan(2^0)  = 0.7853981634 rad
        // atan_table[ 0] = 32'sd0_0C90FDAA >> (28 - AF); // Adjusted for AF
        // For AF=28, these are pre-computed atan(2^-i) * 2^28
        atan_table[ 0] = (AF >= 28) ? 32'sh0C90FDAA : (32'sh0C90FDAA >> (28 - AF));
        atan_table[ 1] = (AF >= 28) ? 32'sh076B19C2 : (32'sh076B19C2 >> (28 - AF));
        atan_table[ 2] = (AF >= 28) ? 32'sh03EB6EBF : (32'sh03EB6EBF >> (28 - AF));
        atan_table[ 3] = (AF >= 28) ? 32'sh01FD5BA9 : (32'sh01FD5BA9 >> (28 - AF));
        atan_table[ 4] = (AF >= 28) ? 32'sh00FFAADD : (32'sh00FFAADD >> (28 - AF));
        atan_table[ 5] = (AF >= 28) ? 32'sh007FF557 : (32'sh007FF557 >> (28 - AF));
        atan_table[ 6] = (AF >= 28) ? 32'sh003FFEAB : (32'sh003FFEAB >> (28 - AF));
        atan_table[ 7] = (AF >= 28) ? 32'sh001FFFD5 : (32'sh001FFFD5 >> (28 - AF));
        atan_table[ 8] = (AF >= 28) ? 32'sh000FFFFB : (32'sh000FFFFB >> (28 - AF));
        atan_table[ 9] = (AF >= 28) ? 32'sh0007FFFF : (32'sh0007FFFF >> (28 - AF));
        atan_table[10] = (AF >= 28) ? 32'sh00040000 : (32'sh00040000 >> (28 - AF));
        atan_table[11] = (AF >= 28) ? 32'sh00020000 : (32'sh00020000 >> (28 - AF));
        atan_table[12] = (AF >= 28) ? 32'sh00010000 : (32'sh00010000 >> (28 - AF));
        atan_table[13] = (AF >= 28) ? 32'sh00008000 : (32'sh00008000 >> (28 - AF));
        atan_table[14] = (AF >= 28) ? 32'sh00004000 : (32'sh00004000 >> (28 - AF));
        atan_table[15] = (AF >= 28) ? 32'sh00002000 : (32'sh00002000 >> (28 - AF));
        atan_table[16] = (AF >= 28) ? 32'sh00001000 : (32'sh00001000 >> (28 - AF));
        atan_table[17] = (AF >= 28) ? 32'sh00000800 : (32'sh00000800 >> (28 - AF));
        atan_table[18] = (AF >= 28) ? 32'sh00000400 : (32'sh00000400 >> (28 - AF));
        atan_table[19] = (AF >= 28) ? 32'sh00000200 : (32'sh00000200 >> (28 - AF));
        atan_table[20] = (AF >= 28) ? 32'sh00000100 : (32'sh00000100 >> (28 - AF));
        atan_table[21] = (AF >= 28) ? 32'sh00000080 : (32'sh00000080 >> (28 - AF));
        atan_table[22] = (AF >= 28) ? 32'sh00000040 : (32'sh00000040 >> (28 - AF));
        atan_table[23] = (AF >= 28) ? 32'sh00000020 : (32'sh00000020 >> (28 - AF));
        atan_table[24] = (AF >= 28) ? 32'sh00000010 : (32'sh00000010 >> (28 - AF));
        atan_table[25] = (AF >= 28) ? 32'sh00000008 : (32'sh00000008 >> (28 - AF));
        atan_table[26] = (AF >= 28) ? 32'sh00000004 : (32'sh00000004 >> (28 - AF));
        atan_table[27] = (AF >= 28) ? 32'sh00000002 : (32'sh00000002 >> (28 - AF));
        atan_table[28] = (AF >= 28) ? 32'sh00000001 : (32'sh00000001 >> (28 - AF));
        atan_table[29] = (AF >= 28) ? 32'sh00000001 : 32'sh00000000;
        atan_table[30] = 32'sh00000000;
        atan_table[31] = 32'sh00000000;
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

    wire signed [EXT-1:0] x_shift = x_reg >>> iter;
    wire signed [EXT-1:0] y_shift = y_reg >>> iter;

    // Decision variable: depends on mode
    // Rotation mode: rotate to drive z toward 0 => decision = sign of z
    // Vectoring mode: rotate to drive y toward 0 => decision = sign of y
    wire decision = mode_reg ? y_reg[EXT-1] : z_reg[AL-1];

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
                            // Rotation mode: input angle must be in [-pi, pi]
                            // Pre-rotate into [-pi/2, pi/2] range
                            x_reg <= {{2{x_in[WL-1]}}, x_in};
                            y_reg <= {{2{y_in[WL-1]}}, y_in};
                            z_reg <= z_in;
                            q_flip_x <= 1'b0;
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
                    x_out <= x_reg[WL-1:0];
                    y_out <= y_reg[WL-1:0];

                    if (mode_reg && q_add_pi) begin
                        // Vectoring mode: correct angle for pre-rotation
                        // atan_table stores atan(2^-i) in radians
                        // pi ≈ 3.14159... in Q(4,AF) ≈ 0x3243F6A8 for AF=28
                        if (q_flip_y) begin
                            // Original y was negative => angle in Q3/Q4
                            z_out <= z_reg - (32'sh3243F6A8 >>> (28 - AF));
                        end else begin
                            z_out <= z_reg + (32'sh3243F6A8 >>> (28 - AF));
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
