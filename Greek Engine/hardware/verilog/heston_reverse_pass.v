`timescale 1ns / 1ps
//============================================================================
// Heston AAD Reverse Pass Engine
//============================================================================
// Reads the execution tape written by the forward pass in reverse order.
// Propagates adjoints to compute 9 Greeks simultaneously:
//   - Delta, Gamma, Vega, Volga, Vanna
//   - Rho, Kappa_sens, Theta_sens, Xi_sens
//============================================================================

module heston_reverse_pass #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    
    input  wire              start,
    
    // Tape read interface
    output reg               tape_re,
    output reg  [15:0]       tape_addr,
    input  wire signed [WL-1:0] tape_data_val,
    input  wire signed [WL-1:0] tape_data_partial,
    
    // Adjoints out (The Greeks)
    output reg  signed [WL-1:0] adj_S0,
    output reg  signed [WL-1:0] adj_K,
    output reg  signed [WL-1:0] adj_T,
    output reg  signed [WL-1:0] adj_r,
    output reg  signed [WL-1:0] adj_v0,
    output reg  signed [WL-1:0] adj_kappa,
    output reg  signed [WL-1:0] adj_theta,
    output reg  signed [WL-1:0] adj_xi,
    output reg  signed [WL-1:0] adj_rho,
    
    output reg               done
);

    // Simplified Stub for Reverse Pass
    // A full AAD reverse pass state machine requires pulling
    // partials from BRAM and multiplying with adjoints.

    localparam S_IDLE  = 2'd0;
    localparam S_SWEEP = 2'd1;
    localparam S_DONE  = 2'd2;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 0;
            tape_re <= 0;
        end else begin
            tape_re <= 0;
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        state <= S_SWEEP;
                        // Start reading tape from end
                        tape_addr <= 16'hFFFF; 
                    end
                end

                S_SWEEP: begin
                    // Dummy sweep loop
                    if (tape_addr == 0) begin
                        state <= S_DONE;
                    end else begin
                        tape_addr <= tape_addr - 1;
                        tape_re <= 1'b1;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    
                    // Initialize outputs to dummy values for synthesis
                    adj_S0 <= 32'd0;
                    adj_K  <= 32'd0;
                    adj_T  <= 32'd0;
                    adj_r  <= 32'd0;
                    adj_v0 <= 32'd0;
                    adj_kappa <= 32'd0;
                    adj_theta <= 32'd0;
                    adj_xi <= 32'd0;
                    adj_rho <= 32'd0;
                    
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
