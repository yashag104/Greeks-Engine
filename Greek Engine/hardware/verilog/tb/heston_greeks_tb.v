`timescale 1ns / 1ps
//============================================================================
// NOTE: heston_reverse_pass.v computes Greeks by bump-and-reprice — 16 full
// forward-pricer runs (see its header for why) — so this testbench takes
// on the order of 3M clock cycles (a few minutes under a Verilog
// simulator) to reach `done`. Expected values below come from
// hardware/matlab/heston_top_level.m's own heston_bump_reference(), scaled
// to the same (larger, fixed-point-appropriate) bump size this hardware
// uses — see heston_reverse_pass.v's header for why that differs from the
// ~1e-5 relative bump the MATLAB reference uses.
//============================================================================

module heston_greeks_tb;

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
    wire signed [WL-1:0] delta, vega, rho_greek, theta_greek;
    wire signed [WL-1:0] kappa_sens, theta_sens, xi_sens, rho_corr;
    wire done;

    // Instantiate the Unit Under Test (UUT)
    heston_top_level #(
        .WL(WL), .FL(FL)
    ) uut (
        .clk(clk),
        .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(start),
        .price(price),
        .delta(delta),
        .vega(vega),
        .rho_greek(rho_greek),
        .theta_greek(theta_greek),
        .kappa_sens(kappa_sens),
        .theta_sens(theta_sens),
        .xi_sens(xi_sens),
        .rho_corr(rho_corr),
        .done(done)
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

        // Example Parameters in Q16
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

        $display("Starting Heston Full Pipeline (Forward + Bump-and-Reprice Reverse)...");
        $display("(this takes ~3M cycles — be patient)");
        start = 1;
        #10;
        start = 0;

        wait(done);
        #10;

        $display("Pipeline Completed.");
        $display("Price      : %f  (expect ~10.387139)", q16(price));
        $display("Delta      : %f  (expect ~0.708162 dV/dS0)",     q16(delta));
        $display("Vega       : %f  (expect ~46.772442 dV/dv0)",    q16(vega));
        $display("Rho        : %f  (expect ~60.992782 dV/dr)",     q16(rho_greek));
        $display("Theta      : %f  (expect ~6.416244  dV/dT)",     q16(theta_greek));
        $display("Kappa sens : %f  (expect ~0.061984  dV/dkappa)", q16(kappa_sens));
        $display("Theta sens : %f  (expect ~44.361521 dV/dtheta)", q16(theta_sens));
        $display("Xi sens    : %f  (expect ~-1.203770 dV/dxi)",    q16(xi_sens));
        $display("Rho corr   : %f  (expect ~-0.117065 dV/drho)",   q16(rho_corr));
        $finish;
    end

endmodule
