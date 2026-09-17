`timescale 1ns / 1ps
//============================================================================
// Complex Exponential — exp(a + ib) = exp(a) * [cos(b) + i*sin(b)]
//============================================================================
// Combines fp_exp (for exp(a)) and CORDIC rotation (for sin(b), cos(b)).
// Latency: max(exp_latency, cordic_latency) + 2 cycles
//============================================================================

module complex_exp #(
    parameter WL = 64,
    parameter FL = 32,
    // NOTE: default AL/AF off of WL/FL (rather than a fixed 64/48) so that
    // instantiating this module with a different WL/FL still gives a
    // same-width angle port instead of silently slicing out of range —
    // and, importantly, AF=FL (not some larger value) so that the angle
    // (a_i, the imaginary part) shares the *same* Q(.,FL) format as the
    // real/imaginary values themselves. cordic.v's z_in/z_out are only
    // ever used here as a direct bit-reinterpretation of a_i/res_i with no
    // separate rescale step, so their fractional format must match FL
    // exactly (cordic.v itself correctly rescales its internal atan table
    // to whatever AF it's given, including AF > 28).
    parameter AL = WL,       // Angle word length
    parameter AF = FL        // Angle fractional bits
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,  // real and imaginary parts
    input  wire              start,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               done
);

    `include "fx_lib.vh"


    // FSM
    localparam S_IDLE      = 3'd0;
    localparam S_LAUNCH    = 3'd1;
    localparam S_WAIT      = 3'd2;
    localparam S_COMBINE   = 3'd3;
    localparam S_DONE      = 3'd4;

    reg [2:0] state;

    // exp(a_r) sub-module
    reg exp_start;
    wire [WL-1:0] exp_result;
    wire exp_done;

    fp_exp #(.WL(WL), .FL(FL)) exp_real_inst (
        .clk(clk), .rst(rst),
        .x(a_r), .start(exp_start),
        .result(exp_result), .done(exp_done)
    );

    // CORDIC for sin(a_i), cos(a_i) — rotation mode
    reg cordic_start;
    wire signed [WL-1:0] cordic_cos, cordic_sin;
    wire signed [AL-1:0] cordic_z_out;
    wire cordic_done;

    // CORDIC input: x=1/K (pre-compensated), y=0, z=angle
    // After CORDIC: x_out = cos(z), y_out = sin(z)
    // To pre-compensate for CORDIC gain, we initialize x = 1/K ≈ 0.6073
    // NOTE: $signed() requires an integer/vector argument, not a `real` — the
    // real-valued constant expression must be rounded to an integer with
    // $rtoi() first (real args to $signed produced an elaboration error).
    // $rtoi returns a 32-bit *signed* integer, though, so computing it
    // directly at (2.0**FL) overflows/wraps for FL >= ~31 (this module
    // defaults to FL=32). Instead, round at min(FL,16) fractional bits —
    // comfortably inside $rtoi's 32-bit range for any real FL used in this
    // design — and left-shift the rest of the way when FL > 16 (exact: it
    // just appends zero fractional bits, not a further rounding step).
    wire signed [WL-1:0] CORDIC_1_OVER_K = q60(C_CORDIC_INV_K);

    cordic #(
        .WL(WL), .AL(AL), .AF(AF)
    ) cordic_sincos_inst (
        .clk(clk), .rst(rst),
        .start(cordic_start),
        .mode(1'b0),  // Rotation mode
        .x_in(CORDIC_1_OVER_K),
        .y_in({WL{1'b0}}),
        .z_in(a_i[AL-1:0]),  // Angle = imaginary part
        .x_out(cordic_cos),
        .y_out(cordic_sin),
        .z_out(cordic_z_out),
        .done(cordic_done)
    );

    reg exp_finished, cordic_finished;
    reg signed [WL-1:0] exp_a_val;
    reg signed [WL-1:0] cos_b_val, sin_b_val;

    // NOTE: hoisted out of the nested begin/end block in S_COMBINE below —
    // declaring locals inside a nested unnamed begin/end block requires
    // SystemVerilog; plain Verilog only allows declarations at the top of a
    // module or named block.
    reg signed [2*WL-1:0] prod_r, prod_i;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            exp_finished    <= 0;
            cordic_finished <= 0;
        end else begin
            exp_start    <= 1'b0;
            cordic_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    exp_finished    <= 0;
                    cordic_finished <= 0;
                    if (start) begin
                        state <= S_LAUNCH;
                    end
                end

                S_LAUNCH: begin
                    // Launch exp(a_r) and CORDIC(a_i) in parallel
                    exp_start    <= 1'b1;
                    cordic_start <= 1'b1;
                    state        <= S_WAIT;
                end

                S_WAIT: begin
                    // Wait for both sub-modules to finish
                    if (exp_done) begin
                        exp_a_val    <= exp_result;
                        exp_finished <= 1'b1;
                    end
                    if (cordic_done) begin
                        cos_b_val       <= cordic_cos;
                        sin_b_val       <= cordic_sin;
                        cordic_finished <= 1'b1;
                    end
                    if ((exp_finished || exp_done) && (cordic_finished || cordic_done))
                        state <= S_COMBINE;
                end

                S_COMBINE: begin
                    // res = exp(a) * (cos(b) + i*sin(b))
                    prod_r = $signed(exp_a_val) * $signed(cos_b_val);
                    prod_i = $signed(exp_a_val) * $signed(sin_b_val);
                    res_r <= rshr(prod_r);
                    res_i <= rshr(prod_i);
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
