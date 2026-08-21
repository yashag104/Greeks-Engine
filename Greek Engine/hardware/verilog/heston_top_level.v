`timescale 1ns / 1ps
//============================================================================
// Heston-COS AAD Top Level
//============================================================================
// Orchestrates the forward pass and reverse pass, managing the shared
// AAD tape (BRAM).
//============================================================================

module heston_top_level #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,
    
    // Model parameters
    input  wire signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho,
    input  wire              is_call,
    
    input  wire              start,
    
    // Results
    output wire signed [WL-1:0] price,
    output wire signed [WL-1:0] delta,
    output wire signed [WL-1:0] vega,
    output wire signed [WL-1:0] rho_greek,
    output wire signed [WL-1:0] theta_greek,
    output wire signed [WL-1:0] kappa_sens,
    output wire signed [WL-1:0] theta_sens,
    output wire signed [WL-1:0] xi_sens,
    output wire signed [WL-1:0] rho_corr,
    
    output reg               done
);

    // ==================================================================
    // Tape BRAM
    // ==================================================================
    wire tape_we;
    wire [15:0] fwd_tape_addr;
    wire signed [WL-1:0] fwd_tape_data_val, fwd_tape_data_partial;
    
    wire tape_re;
    wire [15:0] rev_tape_addr;
    wire signed [WL-1:0] rev_tape_data_val, rev_tape_data_partial;
    
    // Simple dual-port BRAM instantiation (inferred)
    reg signed [WL-1:0] ram_val [0:16383];
    reg signed [WL-1:0] ram_partial [0:16383];
    
    reg signed [WL-1:0] out_val, out_partial;
    
    always @(posedge clk) begin
        if (tape_we) begin
            ram_val[fwd_tape_addr[13:0]] <= fwd_tape_data_val;
            ram_partial[fwd_tape_addr[13:0]] <= fwd_tape_data_partial;
        end
        if (tape_re) begin
            out_val <= ram_val[rev_tape_addr[13:0]];
            out_partial <= ram_partial[rev_tape_addr[13:0]];
        end
    end
    
    assign rev_tape_data_val = out_val;
    assign rev_tape_data_partial = out_partial;

    // ==================================================================
    // Forward Pass
    // ==================================================================
    reg fwd_start;
    wire fwd_done;
    
    heston_cos_forward #(.WL(WL), .FL(FL)) fwd_inst (
        .clk(clk), .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(fwd_start),
        .price(price),
        .done(fwd_done),
        .tape_we(tape_we), .tape_addr(fwd_tape_addr),
        .tape_data_val(fwd_tape_data_val),
        .tape_data_partial(fwd_tape_data_partial)
    );

    // ==================================================================
    // Reverse Pass
    // ==================================================================
    reg rev_start;
    wire rev_done;
    
    heston_reverse_pass #(.WL(WL), .FL(FL)) rev_inst (
        .clk(clk), .rst(rst),
        .start(rev_start),
        .tape_re(tape_re), .tape_addr(rev_tape_addr),
        .tape_data_val(rev_tape_data_val),
        .tape_data_partial(rev_tape_data_partial),
        .adj_S0(delta),
        .adj_K(), // Strike adj not strictly a standard Greek
        .adj_T(theta_greek),
        .adj_r(rho_greek),
        .adj_v0(vega),
        .adj_kappa(kappa_sens),
        .adj_theta(theta_sens),
        .adj_xi(xi_sens),
        .adj_rho(rho_corr),
        .done(rev_done)
    );

    // ==================================================================
    // Top-level FSM
    // ==================================================================
    localparam S_IDLE = 2'd0;
    localparam S_FWD  = 2'd1;
    localparam S_REV  = 2'd2;
    
    reg [1:0] state;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            fwd_start <= 0;
            rev_start <= 0;
            done <= 0;
        end else begin
            fwd_start <= 0;
            rev_start <= 0;
            done <= 0;
            
            case (state)
                S_IDLE: begin
                    if (start) begin
                        fwd_start <= 1'b1;
                        state <= S_FWD;
                    end
                end
                
                S_FWD: begin
                    if (fwd_done) begin
                        rev_start <= 1'b1;
                        state <= S_REV;
                    end
                end
                
                S_REV: begin
                    if (rev_done) begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
