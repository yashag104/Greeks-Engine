`timescale 1ns / 1ps
//============================================================================
// heston_cos_forward now computes the price and all Greeks together in one
// forward + reverse-mode-AAD pass (see heston_char_func.v / heston_cos_
// forward.v headers) — there's no separate tape-write interface to monitor
// any more, so this testbench just exercises price + a couple of Greeks as
// a quick (~400K cycle) sanity check; see tb/heston_greeks_tb.v for all 8.
//============================================================================

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
    wire signed [WL-1:0] adj_S0, adj_K, adj_T, adj_r, adj_v0, adj_kappa, adj_theta, adj_xi, adj_rho;
    wire done;

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
        .adj_S0(adj_S0), .adj_K(adj_K), .adj_T(adj_T), .adj_r(adj_r),
        .adj_v0(adj_v0), .adj_kappa(adj_kappa), .adj_theta(adj_theta),
        .adj_xi(adj_xi), .adj_rho(adj_rho)
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

        $display("Starting Heston COS Forward + AAD Pass...");
        start = 1;
        #10;
        start = 0;

        wait(done);
        #10;

        $display("Pass Completed.");
        $display("Calculated Price = %f (expect ~10.387139, N=128 COS reference)", q16(price));
        $display("Delta (dV/dS0)   = %f (expect ~0.708162, bump-reference)", q16(adj_S0));
        $display("Vega  (dV/dv0)   = %f (expect ~46.772442, bump-reference)", q16(adj_v0));
        $finish;
    end

endmodule
