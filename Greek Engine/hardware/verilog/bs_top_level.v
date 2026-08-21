`timescale 1ns / 1ps

module bs_top_level (
    input  wire        clk,
    input  wire        rst,
    
    // Inputs
    input  wire [31:0] S,
    input  wire [31:0] K,
    input  wire [31:0] T,
    input  wire [31:0] r,
    input  wire [31:0] sigma,
    input  wire        is_call,
    input  wire        start,
    
    // Outputs
    output wire [31:0] price,
    output wire [47:0] delta,
    output wire [47:0] vega,
    output wire [47:0] theta,
    output wire [47:0] rho,
    output wire [47:0] strike_sens,
    output reg         done
);

    // Tape BRAM signals
    wire        tape_we;
    wire [7:0]  tape_waddr;
    wire [31:0] tape_wval;
    wire [31:0] tape_wp1;
    wire [31:0] tape_wp2;
    wire [7:0]  tape_wparent1;
    wire [7:0]  tape_wparent2;
    
    wire [7:0]  tape_raddr;
    reg  [31:0] tape_rval;
    reg  [31:0] tape_rp1;
    reg  [31:0] tape_rp2;
    reg  [7:0]  tape_rparent1;
    reg  [7:0]  tape_rparent2;
    
    // BRAM Instantiation (behavioral)
    reg [31:0] mem_val [0:255];
    reg [31:0] mem_p1 [0:255];
    reg [31:0] mem_p2 [0:255];
    reg [7:0]  mem_parent1 [0:255];
    reg [7:0]  mem_parent2 [0:255];
    
    always @(posedge clk) begin
        if (tape_we) begin
            mem_val[tape_waddr]     <= tape_wval;
            mem_p1[tape_waddr]      <= tape_wp1;
            mem_p2[tape_waddr]      <= tape_wp2;
            mem_parent1[tape_waddr] <= tape_wparent1;
            mem_parent2[tape_waddr] <= tape_wparent2;
        end
        tape_rval     <= mem_val[tape_raddr];
        tape_rp1      <= mem_p1[tape_raddr];
        tape_rp2      <= mem_p2[tape_raddr];
        tape_rparent1 <= mem_parent1[tape_raddr];
        tape_rparent2 <= mem_parent2[tape_raddr];
    end

    wire fwd_done;
    
    bs_forward_core fwd_inst (
        .clk(clk),
        .rst(rst),
        .S_in(S), .K_in(K), .T_in(T), .r_in(r), .sigma_in(sigma), .is_call(is_call),
        .start(start),
        .price_out(price),
        .done(fwd_done),
        .tape_we(tape_we), .tape_addr(tape_waddr),
        .tape_val(tape_wval), .tape_partial_1(tape_wp1), .tape_partial_2(tape_wp2),
        .tape_parent_1(tape_wparent1), .tape_parent_2(tape_wparent2)
    );
    
    wire rev_done;
    reg rev_start;
    
    always @(posedge clk) begin
        if (rst) rev_start <= 0;
        else if (fwd_done) rev_start <= 1;
        else rev_start <= 0;
    end
    
    bs_reverse_pass rev_inst (
        .clk(clk),
        .rst(rst),
        .start(rev_start),
        .tape_max_idx(tape_waddr), // Last written address is max
        .tape_read_addr(tape_raddr),
        .tape_val(tape_rval), .tape_partial_1(tape_rp1), .tape_partial_2(tape_rp2),
        .tape_parent_1(tape_rparent1), .tape_parent_2(tape_rparent2),
        .delta_out(delta), .vega_out(vega), .theta_out(theta), .rho_out(rho),
        .strike_sens_out(strike_sens),
        .done(rev_done)
    );
    
    always @(posedge clk) begin
        if (rst) done <= 0;
        else done <= rev_done;
    end

endmodule
