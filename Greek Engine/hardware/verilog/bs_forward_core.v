`timescale 1ns / 1ps

module bs_forward_core (
    input  wire        clk,
    input  wire        rst,
    
    // Inputs (Q32 format, varying fractional lengths as per budget)
    input  wire [31:0] S_in,      // Q(1,14,17)
    input  wire [31:0] K_in,      // Q(1,14,17)
    input  wire [31:0] T_in,      // Q(1,4,27)
    input  wire [31:0] r_in,      // Q(1,1,30)
    input  wire [31:0] sigma_in,  // Q(1,2,29)
    input  wire        is_call,   // 1 for call, 0 for put
    
    input  wire        start,
    
    // Outputs
    output reg  [31:0] price_out, // Q(1,14,17)
    output reg         done,
    
    // Tape Interface (for AAD Reverse Pass)
    // We write value (32-bit), partial derivatives (up to two, 32-bit each) and parent indices
    output reg         tape_we,
    output reg  [7:0]  tape_addr,
    output reg  [31:0] tape_val,
    output reg  [31:0] tape_partial_1,
    output reg  [31:0] tape_partial_2,
    output reg  [7:0]  tape_parent_1,
    output reg  [7:0]  tape_parent_2
);

    // FSM States for 15 pipeline stages
    localparam S_IDLE       = 5'd0;
    localparam S_SQRT_T     = 5'd1;
    localparam S_SIGMA_SQRT = 5'd2;
    localparam S_S_DIV_K    = 5'd3;
    localparam S_LN_S_K     = 5'd4;
    localparam S_SIGMA_SQ   = 5'd5;
    localparam S_SIGMA_SQ_H = 5'd6;
    localparam S_R_PLUS     = 5'd7;
    localparam S_DRIFT_T    = 5'd8;
    localparam S_NUM        = 5'd9;
    localparam S_D1         = 5'd10;
    localparam S_D2         = 5'd11;
    localparam S_NEG_RT     = 5'd12;
    localparam S_DISCOUNT   = 5'd13;
    localparam S_ND1_ND2    = 5'd14;
    localparam S_PRICE      = 5'd15;
    localparam S_DONE       = 5'd16;

    reg [4:0] state;
    
    // Internal Registers for intermediate values
    reg [31:0] sqrt_T_reg;
    reg [31:0] sigma_sqrt_T_reg;
    reg [31:0] S_over_K_reg;
    reg [31:0] ln_S_K_reg;
    reg [31:0] sigma_sq_reg;
    reg [31:0] r_plus_reg;
    reg [31:0] drift_T_reg;
    reg [31:0] num_reg;
    reg [31:0] d1_reg;
    reg [31:0] d2_reg;
    reg [31:0] discount_reg;
    reg [31:0] Nd1_reg, Nd2_reg;
    
    // Shared Arithmetic Units (Stubs/Placeholders for actual instantiation)
    reg [31:0] mul_a, mul_b;
    wire [31:0] mul_res;
    reg mul_start;
    wire mul_valid;
    
    // We instantiate a single multiplier for reuse in this FSM design
    fp_mult #(
        .WL(32), .FL(16) // Note: Dynamic FL handling needed in real implementation
    ) mult_inst (
        .clk(clk), .rst(rst),
        .a(mul_a), .b(mul_b), .valid_in(mul_start),
        .result(mul_res), .valid_out(mul_valid), .overflow()
    );
    
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done <= 0;
            tape_we <= 0;
        end else begin
            tape_we <= 0; // Default
            
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        // Record inputs to tape (Indices 1 to 5)
                        // In a real implementation, this takes multiple cycles or wide BRAM
                        state <= S_SQRT_T;
                    end
                end
                
                S_SQRT_T: begin
                    // Stage 1: sqrt(T)
                    // Request sqrt operation
                    // For simulation FSM, wait for valid
                    state <= S_SIGMA_SQRT; 
                end
                
                S_SIGMA_SQRT: begin
                    // Stage 2: sigma * sqrt(T)
                    state <= S_S_DIV_K;
                end
                
                S_S_DIV_K: begin
                    // Stage 3: S / K
                    state <= S_LN_S_K;
                end
                
                // ... remaining stages follow the same FSM progression
                
                S_PRICE: begin
                    // Final price computation
                    // V = S*N(d1) - K*exp(-rT)*N(d2) (for call)
                    price_out <= 32'h00000000; // Placeholder
                    state <= S_DONE;
                end
                
                S_DONE: begin
                    done <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
