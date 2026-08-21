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
    parameter AL = 64,       // Angle word length
    parameter AF = 48        // Angle fractional bits
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,  // real and imaginary parts
    input  wire              start,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               done
);

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
    wire signed [WL-1:0] CORDIC_1_OVER_K = $signed( (0.6072529350088814 * (2.0**FL)) );

    cordic #(
        .WL(WL), .AL(AL), .N_ITER(30), .AF(AF)
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
                    begin
                        reg signed [2*WL-1:0] prod_r, prod_i;
                        prod_r = $signed(exp_a_val) * $signed(cos_b_val);
                        prod_i = $signed(exp_a_val) * $signed(sin_b_val);
                        res_r <= prod_r >>> FL;
                        res_i <= prod_i >>> FL;
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
