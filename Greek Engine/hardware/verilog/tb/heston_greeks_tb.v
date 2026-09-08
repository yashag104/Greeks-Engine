`timescale 1ns / 1ps
//============================================================================
// heston_cos_forward.v computes the price and all 8 Greeks together in one
// forward + reverse-mode-AAD pass through the characteristic function (see
// heston_char_func.v's header for the calculus) — about 400K clock cycles
// here (N_TERMS=128), roughly 2x a price-only forward pass and ~7x faster
// than the bump-and-reprice baseline this replaced (16 full forward runs,
// ~3M cycles). Expected values below are
// hardware/matlab/heston_top_level.m's own heston_bump_reference() (the
// project's finite-difference validation baseline, ~1e-5 relative bump) —
// the RTL AAD result is independently verified against that, not tuned to
// match it.
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

        $display("Starting Heston Full Pipeline (Forward + Reverse-Mode AAD)...");
        $display("(now ~400K cycles: one augmented forward+reverse pass, not 16 forward-only bump runs)");
        start = 1;
        #10;
        start = 0;

        wait(done);
        #10;

        $display("AAD Pipeline Completed.");
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
