`timescale 1ns / 1ps

module bs_reverse_pass (
    input  wire        clk,
    input  wire        rst,
    
    input  wire        start,
    input  wire [7:0]  tape_max_idx,
    
    // Tape Read Interface
    output reg  [7:0]  tape_read_addr,
    input  wire [31:0] tape_val,
    input  wire [31:0] tape_partial_1,
    input  wire [31:0] tape_partial_2,
    input  wire [7:0]  tape_parent_1,
    input  wire [7:0]  tape_parent_2,
    
    // Outputs (Greeks - accumulated in Q(16,32) extended format)
    output reg  [47:0] delta_out,
    output reg  [47:0] vega_out,
    output reg  [47:0] theta_out,
    output reg  [47:0] rho_out,
    output reg  [47:0] strike_sens_out,
    
    output reg         done
);

    // Local Memory for Adjoints (up to 256 entries, 48-bit wide)
    reg [47:0] adjoints [0:255];
    
    // FSM States
    localparam S_IDLE      = 3'd0;
    localparam S_INIT      = 3'd1;
    localparam S_FETCH     = 3'd2;
    localparam S_WAIT      = 3'd3;
    localparam S_ACCUM     = 3'd4;
    localparam S_EXTRACT   = 3'd5;
    
    reg [2:0] state;
    reg [7:0] current_idx;
    integer i;
    
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done <= 0;
            tape_read_addr <= 0;
            for(i=0; i<256; i=i+1) adjoints[i] <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        state <= S_INIT;
                    end
                end
                
                S_INIT: begin
                    // Clear adjoints memory
                    for(i=0; i<256; i=i+1) adjoints[i] <= 48'd0;
                    
                    // Seed the output adjoint to 1.0 (Q16.32 format)
                    adjoints[tape_max_idx] <= {16'd1, 32'd0}; 
                    current_idx <= tape_max_idx;
                    state <= S_FETCH;
                end
                
                S_FETCH: begin
                    if (current_idx > 0) begin
                        // Request tape data for current index
                        tape_read_addr <= current_idx;
                        state <= S_WAIT;
                    end else begin
                        state <= S_EXTRACT;
                    end
                end
                
                S_WAIT: begin
                    // Wait 1 cycle for BRAM read latency
                    state <= S_ACCUM;
                end
                
                S_ACCUM: begin
                    // Accumulate: adj[parent] += adj[i] * local_partial
                    // This is a stub for the MAC operations
                    // In real RTL, use fp_mult and fp_add_sub instances here
                    
                    /*
                    if (tape_parent_1 != 0)
                        adjoints[tape_parent_1] <= adjoints[tape_parent_1] + (adjoints[current_idx] * tape_partial_1);
                    if (tape_parent_2 != 0)
                        adjoints[tape_parent_2] <= adjoints[tape_parent_2] + (adjoints[current_idx] * tape_partial_2);
                    */
                    
                    current_idx <= current_idx - 1;
                    state <= S_FETCH;
                end
                
                S_EXTRACT: begin
                    // Extract the final Greeks from the inputs indices
                    // 1=S, 2=K, 3=T, 4=r, 5=sigma
                    delta_out       <= adjoints[1];
                    strike_sens_out <= adjoints[2];
                    theta_out       <= adjoints[3];
                    rho_out         <= adjoints[4];
                    vega_out        <= adjoints[5];
                    
                    done <= 1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
