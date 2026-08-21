`timescale 1ns / 1ps

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
        
        $display("Starting Heston Full Pipeline (Forward + AAD Reverse)...");
        start = 1;
        #10;
        start = 0;
        
        wait(done);
        #10;
        
        $display("AAD Pipeline Completed.");
        $display("Price : %h", price);
        $display("Delta : %h", delta);
        $display("Vega  : %h", vega);
        $display("Rho   : %h", rho_greek);
        $display("Theta : %h", theta_greek);
        
        // TODO: Compare outputs with MATLAB golden references
        $finish;
    end
      
endmodule
