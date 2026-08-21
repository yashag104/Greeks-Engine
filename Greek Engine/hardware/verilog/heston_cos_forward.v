`timescale 1ns / 1ps
//============================================================================
// Heston-COS Forward Engine — Main Summation Loop
//============================================================================
// Iterates k = 0 to 127.
// Accumulates F_k * V_k to produce the final price.
// Records all variables and partial derivatives to the AAD tape (BRAM).
//============================================================================

module heston_cos_forward #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    
    // Model parameters
    input  wire signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho,
    input  wire              is_call,
    input  wire              start,
    
    // Result
    output reg  signed [WL-1:0] price,
    output reg               done,
    
    // Tape write interface (simplified)
    output reg               tape_we,
    output reg  [15:0]       tape_addr,
    output reg  signed [WL-1:0] tape_data_val,
    output reg  signed [WL-1:0] tape_data_partial
);

    localparam N_TERMS = 128;

    // FSM States
    localparam S_IDLE       = 4'd0;
    localparam S_INIT       = 4'd1;
    localparam S_CHAR_START = 4'd2;
    localparam S_WAIT_CHAR  = 4'd3;
    localparam S_PAYOFF     = 4'd4;
    localparam S_WAIT_PAY   = 4'd5;
    localparam S_ACCUM      = 4'd6;
    localparam S_DISC       = 4'd7;
    localparam S_FINISH     = 4'd8;

    reg [3:0] state;
    reg [7:0] k_counter;
    
    reg signed [47:0] accumulator; // Extra bits for accumulation

    // Characteristic Function (phi)
    reg char_start;
    wire signed [63:0] phi_r, phi_i;
    wire char_done;
    
    // Convert 32-bit parameters to 64-bit for char func
    wire signed [63:0] T_64     = {T[WL-1], T, {32-FL{1'b0}}}; 
    // In a real integration, precise bit matching is required.
    
    heston_char_func #(.WL(64), .FL(32)) char_func_inst (
        .clk(clk), .rst(rst),
        .T_in({T[WL-1], T, 32'd0}), // Quick 64-bit padding stub
        .r_in({r[WL-1], r, 32'd0}),
        .v0_in({v0[WL-1], v0, 32'd0}),
        .kappa_in({kappa[WL-1], kappa, 32'd0}),
        .theta_in({theta[WL-1], theta, 32'd0}),
        .xi_in({xi[WL-1], xi, 32'd0}),
        .rho_in({rho[WL-1], rho, 32'd0}),
        .x_in(64'd0), // ln(S0/K) goes here
        .u_in(64'd0), // u_k goes here
        .start(char_start),
        .phi_r(phi_r), .phi_i(phi_i),
        .done(char_done),
        .tape_we(), .tape_addr(), .tape_data_val(), .tape_data_partial()
    );

    // Payoff Coefficient
    reg payoff_start;
    wire signed [WL-1:0] V_k;
    wire payoff_done;

    heston_payoff_coeff #(.WL(WL), .FL(FL)) payoff_inst (
        .clk(clk), .rst(rst),
        .k(k_counter),
        .a(32'd0), .b(32'd0), // Truncation bounds
        .K_strike(K),
        .is_call(is_call),
        .start(payoff_start),
        .V_k(V_k),
        .done(payoff_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 0;
            char_start <= 0;
            payoff_start <= 0;
            tape_we <= 0;
        end else begin
            char_start <= 0;
            payoff_start <= 0;
            tape_we <= 0;

            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        state <= S_INIT;
                    end
                end

                S_INIT: begin
                    k_counter <= 0;
                    accumulator <= 0;
                    tape_addr <= 0;
                    state <= S_CHAR_START;
                end

                S_CHAR_START: begin
                    char_start <= 1'b1;
                    state <= S_WAIT_CHAR;
                end

                S_WAIT_CHAR: begin
                    if (char_done) begin
                        payoff_start <= 1'b1;
                        state <= S_WAIT_PAY;
                    end
                end

                S_WAIT_PAY: begin
                    if (payoff_done) begin
                        state <= S_ACCUM;
                    end
                end

                S_ACCUM: begin
                    // accumulator += F_k * V_k
                    // Write to tape
                    tape_we <= 1'b1;
                    tape_addr <= tape_addr + 1;
                    
                    if (k_counter == N_TERMS - 1) begin
                        state <= S_DISC;
                    end else begin
                        k_counter <= k_counter + 1;
                        state <= S_CHAR_START;
                    end
                end

                S_DISC: begin
                    // Final price = exp(-rT) * accumulator
                    price <= 32'd0; // Stub
                    state <= S_FINISH;
                end

                S_FINISH: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
