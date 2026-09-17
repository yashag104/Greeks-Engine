`timescale 1ns / 1ps
//============================================================================
// CORDIC Engine — Rotation & Vectoring Modes
//============================================================================
//   - Rotation mode:  (x_out, y_out) = K*R(z_in)*(x_in, y_in); with
//                     x_in = 1/K, y_in = 0 this is (cos z, sin z).
//   - Vectoring mode: z_out = atan2(y_in, x_in), x_out = K*|(x_in, y_in)|.
//
// Iterative: N micro-rotations over N clock cycles. N defaults to AF+2
// (N_ITER=0), which drives the residual angle below one angle-ULP.
//
// Precision measures (all new in this revision):
//   * atan(2^-i), pi, 2pi, 1/(2pi) come from Q4.60 constants (fx_lib.vh)
//     instead of a Q4.28 table / 16-bit $rtoi literals. At AF=16 the old
//     pi was 6.3e-6 low, and rotation-mode argument reduction subtracts
//     n*2pi with n up to ~30 for the Heston-COS angles u_k*a — i.e. up to
//     4e-4 rad of error in cos/sin(u_k*a), the dominant error of the old
//     Heston engine.
//   * GB fractional guard bits on x, y and z, so the ~N truncations of
//     the shift-add recurrence and of the atan table do not accumulate
//     into the output's ULP.
//   * n*2pi is formed at 60 fractional bits before truncation.
//============================================================================

module cordic #(
    parameter WL     = 32,   // Word length for x, y
    parameter AL     = 32,   // Word length for angle (z)
    parameter N_ITER = 0,    // Iterations; 0 = automatic (AF + 2)
    parameter AF     = 28    // Fractional bits in angle representation
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            start,
    input  wire            mode,        // 0 = rotation, 1 = vectoring
    input  wire signed [WL-1:0] x_in,
    input  wire signed [WL-1:0] y_in,
    input  wire signed [AL-1:0] z_in,
    output reg  signed [WL-1:0] x_out,
    output reg  signed [WL-1:0] y_out,
    output reg  signed [AL-1:0] z_out,
    output reg                  done
);

    localparam integer FL = AF;          // for fx_lib.vh's q60()
    `include "fx_lib.vh"

    localparam integer GB  = 6;          // fractional guard bits
    localparam integer NIT = (N_ITER > 0) ? N_ITER : ((AF + 2 > 62) ? 62 : AF + 2);
    localparam integer XW  = WL + 2 + GB; // x/y: 2 integer guard bits (gain 1.647) + GB
    localparam integer ZW  = AL + 1 + GB; // z: 1 integer guard bit + GB

    // angle constants at AF+GB fractional bits
    function signed [ZW-1:0] zc;
        input signed [63:0] c;
        reg   signed [127:0] t;
        begin
            t  = ($signed({{64{c[63]}}, c}) >>> (60 - AF - GB - 1)) + 128'sd1;
            t  = t >>> 1;
            zc = t[ZW-1:0];
        end
    endfunction

    wire signed [ZW-1:0] PI_Z      = zc(C_PI);
    wire signed [ZW-1:0] HALF_PI_Z = zc(C_HALF_PI);
    wire signed [AL-1:0] INV_2PI   = q60(C_INV_2PI);   // at AF

    localparam S_IDLE = 2'd0, S_COMPUTE = 2'd1, S_DONE = 2'd2;

    reg [1:0] state;
    reg [5:0] iter;
    reg       mode_reg;
    reg       q_flip_out, q_add_pi, q_neg_y;

    reg signed [XW-1:0] x_reg, y_reg;
    reg signed [ZW-1:0] z_reg;

    reg signed [2*AL-1:0] rr_wide;
    reg signed [AL-1:0]   rr_n;
    reg signed [127:0]    rr_n2pi;
    reg signed [ZW-1:0]   rr_z;

    wire signed [XW-1:0] x_shift = x_reg >>> iter;
    wire signed [XW-1:0] y_shift = y_reg >>> iter;
    wire signed [ZW-1:0] atan_i  = zc(atan_q60(iter));

    // rotation: drive z -> 0; vectoring: drive y -> 0
    wire decision = mode_reg ? ~y_reg[XW-1] : z_reg[ZW-1];

    // rounding helpers for outputs
    wire signed [XW-1:0] x_rnd = (x_reg + (1 <<< (GB-1))) >>> GB;
    wire signed [XW-1:0] y_rnd = (y_reg + (1 <<< (GB-1))) >>> GB;

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
                            // Reduce z_in into (-pi, pi]: n = round(z/2pi),
                            // z -= n*2pi (2pi at 60 fractional bits), then
                            // fold once more by +-pi into [-pi/2, pi/2] and
                            // negate the output vector to compensate.
                            rr_wide = $signed(z_in) * INV_2PI;
                            rr_wide = (rr_wide + ($signed({{(2*AL-1){1'b0}},1'b1}) <<< (2*AF-1))) >>> (2*AF);
                            rr_n    = rr_wide[AL-1:0];
                            rr_n2pi = $signed(rr_n) * C_TWO_PI;
                            rr_n2pi = (rr_n2pi + ($signed(128'sd1) <<< (60-AF-GB-1))) >>> (60-AF-GB);
                            rr_z    = ($signed({{(ZW-AL){z_in[AL-1]}}, z_in}) <<< GB) - rr_n2pi[ZW-1:0];

                            x_reg <= $signed({{2{x_in[WL-1]}}, x_in}) <<< GB;
                            y_reg <= $signed({{2{y_in[WL-1]}}, y_in}) <<< GB;
                            if (rr_z > HALF_PI_Z) begin
                                z_reg <= rr_z - PI_Z;  q_flip_out <= 1'b1;
                            end else if (rr_z < -HALF_PI_Z) begin
                                z_reg <= rr_z + PI_Z;  q_flip_out <= 1'b1;
                            end else begin
                                z_reg <= rr_z;         q_flip_out <= 1'b0;
                            end
                            q_add_pi <= 1'b0;
                            q_neg_y  <= 1'b0;
                        end else begin
                            // Vectoring: pre-rotate by pi if x < 0
                            if (x_in[WL-1]) begin
                                x_reg <= -($signed({{2{x_in[WL-1]}}, x_in}) <<< GB);
                                y_reg <= -($signed({{2{y_in[WL-1]}}, y_in}) <<< GB);
                                q_add_pi <= 1'b1;
                                q_neg_y  <= y_in[WL-1];
                            end else begin
                                x_reg <= $signed({{2{x_in[WL-1]}}, x_in}) <<< GB;
                                y_reg <= $signed({{2{y_in[WL-1]}}, y_in}) <<< GB;
                                q_add_pi <= 1'b0;
                                q_neg_y  <= 1'b0;
                            end
                            z_reg      <= 0;
                            q_flip_out <= 1'b0;
                        end
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (iter < NIT) begin
                        if (decision) begin
                            x_reg <= x_reg + y_shift;
                            y_reg <= y_reg - x_shift;
                            z_reg <= z_reg + atan_i;
                        end else begin
                            x_reg <= x_reg - y_shift;
                            y_reg <= y_reg + x_shift;
                            z_reg <= z_reg - atan_i;
                        end
                        iter <= iter + 1'b1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (q_flip_out) begin
                        x_out <= -x_rnd[WL-1:0];
                        y_out <= -y_rnd[WL-1:0];
                    end else begin
                        x_out <= x_rnd[WL-1:0];
                        y_out <= y_rnd[WL-1:0];
                    end
                    if (mode_reg && q_add_pi)
                        z_out <= (q_neg_y ? (z_reg - PI_Z) : (z_reg + PI_Z)) + (1 <<< (GB-1)) >>> GB;
                    else
                        z_out <= (z_reg + (1 <<< (GB-1))) >>> GB;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
