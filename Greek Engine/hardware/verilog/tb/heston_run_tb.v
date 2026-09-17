`timescale 1ns / 1ps
//============================================================================
// File-driven Heston testbench (used by hardware/sim/run_heston.py)
//============================================================================
// Reads cases from `CASEFILE, one per line, all values raw Q(WL-FL,FL)
// integers:
//   id S0 K T r v0 kappa theta xi rho is_call h_S0 h_K h_T h_r h_v0 h_kappa h_theta h_xi h_rho
// and prints one result line per case:
//   RES id cycles price delta strike_sens theta rho vega kappa theta_s xi rho_c
// `define BUMP selects the bump-and-reprice baseline (heston_bump_top)
// instead of the AAD engine (heston_top_level); h_* are ignored for AAD.
// WL/FL are overridable (-Pheston_run_tb.WL=.. -Pheston_run_tb.FL=..).
//============================================================================

module heston_run_tb;
    parameter WL = 64;
    parameter FL = 32;

    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;

    reg signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho;
    reg signed [WL-1:0] hS0, hK, hT, hr, hv0, hkappa, htheta, hxi, hrho;
    reg                 is_call;
    reg [63:0]          id, is_call_i;

    wire signed [WL-1:0] price, delta, vega, rho_greek, theta_greek,
                         kappa_sens, theta_sens, xi_sens, rho_corr, strike_sens;
    wire done;

`ifdef BUMP
    heston_bump_top #(.WL(WL), .FL(FL)) uut (
        .clk(clk), .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0), .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .h_S0(hS0), .h_K(hK), .h_T(hT), .h_r(hr), .h_v0(hv0), .h_kappa(hkappa),
        .h_theta(htheta), .h_xi(hxi), .h_rho(hrho),
        .start(start),
        .price(price), .delta(delta), .vega(vega), .rho_greek(rho_greek),
        .theta_greek(theta_greek), .kappa_sens(kappa_sens), .theta_sens(theta_sens),
        .xi_sens(xi_sens), .rho_corr(rho_corr), .strike_sens(strike_sens),
        .done(done)
    );
`else
    heston_top_level #(.WL(WL), .FL(FL)) uut (
        .clk(clk), .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0), .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(start),
        .price(price), .delta(delta), .vega(vega), .rho_greek(rho_greek),
        .theta_greek(theta_greek), .kappa_sens(kappa_sens), .theta_sens(theta_sens),
        .xi_sens(xi_sens), .rho_corr(rho_corr), .strike_sens(strike_sens),
        .done(done)
    );
`endif

    integer fd, n;
    reg [63:0] cycles;

    initial begin
        fd = $fopen(`CASEFILE, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open case file");
            $finish;
        end
        repeat (5) @(posedge clk);
        rst = 0;
        while (!$feof(fd)) begin
            n = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                        id, S0, K, T, r, v0, kappa, theta, xi, rho, is_call_i,
                        hS0, hK, hT, hr, hv0, hkappa, htheta, hxi, hrho);
            if (n == 20) begin
                is_call = is_call_i[0];
                @(negedge clk) start = 1;
                @(negedge clk) start = 0;
                cycles = 1;
                while (!done) begin
                    @(posedge clk);
                    cycles = cycles + 1;
                end
                $display("RES %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", id, cycles,
                         price, delta, strike_sens, theta_greek, rho_greek, vega,
                         kappa_sens, theta_sens, xi_sens, rho_corr);
                @(posedge clk);
            end
        end
        $fclose(fd);
        $finish;
    end
endmodule
