`timescale 1ns / 1ps
//============================================================================
// Complex Logarithm — ln(a + ib) = ln|z| + i*atan2(b, a)
//============================================================================
// |z| = sqrt(a² + b²)
// Re[ln(z)] = ln(|z|) = 0.5 * ln(a² + b²)   (avoids extra sqrt)
// Im[ln(z)] = atan2(b, a)
//
// Uses fp_log and CORDIC (vectoring mode for atan2).
//============================================================================

module complex_log #(
    parameter WL = 64,
    parameter FL = 32,
    parameter AL = 64,
    parameter AF = 48
) (
    input  wire              clk,
    input  wire              rst,
    input  wire signed [WL-1:0] a_r, a_i,
    input  wire              start,
    output reg  signed [WL-1:0] res_r, res_i,
    output reg               done
);

    // FSM
    localparam S_IDLE     = 3'd0;
    localparam S_LAUNCH   = 3'd1;
    localparam S_WAIT     = 3'd2;
    localparam S_SCALE    = 3'd3;
    localparam S_DONE     = 3'd4;

    reg [2:0] state;

    // Compute a² + b² then ln of that
    reg signed [WL-1:0] mag_sq;
    reg signed [2*WL-1:0] wide_prod;

    // fp_log for ln(a² + b²)
    reg log_start;
    wire signed [WL-1:0] log_result;
    wire log_done, log_err;

    fp_log #(.WL(WL), .FL(FL)) log_inst (
        .clk(clk), .rst(rst),
        .x(mag_sq), .start(log_start),
        .result(log_result), .done(log_done), .err_nonpositive(log_err)
    );

    // CORDIC vectoring mode for atan2(b, a)
    reg cordic_start;
    wire signed [WL-1:0] cordic_x_out, cordic_y_out;
    wire signed [AL-1:0] cordic_angle;
    wire cordic_done;

    cordic #(
        .WL(WL), .AL(AL), .N_ITER(30), .AF(AF)
    ) cordic_atan2_inst (
        .clk(clk), .rst(rst),
        .start(cordic_start),
        .mode(1'b1),  // Vectoring mode
        .x_in(a_r),
        .y_in(a_i),
        .z_in({AL{1'b0}}),
        .x_out(cordic_x_out),
        .y_out(cordic_y_out),
        .z_out(cordic_angle),
        .done(cordic_done)
    );

    reg log_finished, cordic_finished;
    reg signed [WL-1:0] log_val, angle_val;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            log_start    <= 1'b0;
            cordic_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    log_finished    <= 0;
                    cordic_finished <= 0;
                    if (start) begin
                        // Compute a² + b²
                        begin
                            reg signed [2*WL-1:0] p1, p2;
                            p1 = $signed(a_r) * $signed(a_r);
                            p2 = $signed(a_i) * $signed(a_i);
                            mag_sq <= (p1 + p2) >>> FL;
                        end
                        state <= S_LAUNCH;
                    end
                end

                S_LAUNCH: begin
                    // Launch ln(mag_sq) and atan2 in parallel
                    log_start    <= 1'b1;
                    cordic_start <= 1'b1;
                    state        <= S_WAIT;
                end

                S_WAIT: begin
                    if (log_done) begin
                        log_val      <= log_result;
                        log_finished <= 1'b1;
                    end
                    if (cordic_done) begin
                        angle_val       <= cordic_angle[WL-1:0]; // Truncate to WL
                        cordic_finished <= 1'b1;
                    end
                    if ((log_finished || log_done) && (cordic_finished || cordic_done))
                        state <= S_SCALE;
                end

                S_SCALE: begin
                    // Re[ln(z)] = 0.5 * ln(a² + b²) = 0.5 * log_val
                    res_r <= log_val >>> 1;
                    // Im[ln(z)] = atan2(b, a)
                    res_i <= angle_val;
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
