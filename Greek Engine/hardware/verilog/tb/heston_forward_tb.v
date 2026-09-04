`timescale 1ns / 1ps

module heston_forward_tb;

    // Parameters
    localparam WL = 32;
    localparam FL = 16;

    // Inputs
    reg clk;
    reg rst;
    reg start;

    // Model parameters
    reg signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho;
    reg is_call;

    // Outputs
    wire signed [WL-1:0] price;
    wire done;

    // Tape write interface monitor
    wire tape_we;
    wire [15:0] tape_addr;
    wire signed [WL-1:0] tape_data_val, tape_data_partial;

    // Instantiate the Unit Under Test (UUT)
    heston_cos_forward #(
        .WL(WL), .FL(FL)
    ) uut (
        .clk(clk),
        .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(start),
        .price(price),
        .done(done),
        .tape_we(tape_we),
        .tape_addr(tape_addr),
        .tape_data_val(tape_data_val),
        .tape_data_partial(tape_data_partial)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    function real q16(input signed [WL-1:0] v);
        q16 = v / 65536.0;
    endfunction

    // Test sequence
    initial begin
        // Initialize Inputs
        rst = 1;
        start = 0;

        // Example Parameters in Q16 — matches
        // hardware/matlab/heston_top_level.m's own defaults, and the
        // reference price below was computed with
        // hardware/matlab/heston_cos_forward_core.m's own chi_func/
        // psi_func/eval_char formulas (N_TERMS=128, L=10 truncation).
        S0    = 32'h0064_0000; // 100.0
        K     = 32'h0064_0000; // 100.0
        T     = 32'h0001_0000; // 1.0
        r     = 32'h0000_0CCD; // 0.05
        v0    = 32'h0000_0A3D; // 0.04
        kappa = 32'h0001_8000; // 1.5
        theta = 32'h0000_0A3D; // 0.04
        xi    = 32'h0000_4CCC; // 0.3
        rho   = 32'hFFFF_199A; // -0.9
        is_call = 1;

        // Wait for global reset
        #100;
        rst = 0;
        #10;

        $display("Starting Heston COS Forward Pass...");
        start = 1;
        #10;
        start = 0;

        wait(done);
        #10;

        $display("Forward Pass Completed.");
        $display("Calculated Price = %f (expect ~10.387139, N=128 COS reference)", q16(price));
        $finish;
    end

endmodule
