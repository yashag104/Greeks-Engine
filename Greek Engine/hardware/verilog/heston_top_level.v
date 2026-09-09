`timescale 1ns / 1ps
//============================================================================
// Heston-COS Top Level
//============================================================================
// heston_cos_forward now computes the price AND all Greeks together in one
// forward+reverse-mode-AAD pass (see heston_char_func.v's header for the
// calculus and heston_cos_forward.v's header for how the per-term seeds
// and discount/x chain are assembled) — so this top level is now just that
// one module's start/done handshake; there's no separate reverse-pass
// engine or tape to orchestrate any more.
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
    output wire signed [WL-1:0] strike_sens,

    output wire               done
);

    heston_cos_forward #(.WL(WL), .FL(FL)) engine (
        .clk(clk), .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(start),
        .price(price),
        .done(done),
        .adj_S0(delta),
        .adj_K(strike_sens), // dV/dK — not one of the 8 "standard" Heston
                              // Greeks, but heston_cos_forward computes it
                              // for free (it falls out of x=ln(S0/K)'s own
                              // adjoint), so it's exposed here too, mirroring
                              // bs_top_level's strike_sens output.
        .adj_T(theta_greek),
        .adj_r(rho_greek),
        .adj_v0(vega),
        .adj_kappa(kappa_sens),
        .adj_theta(theta_sens),
        .adj_xi(xi_sens),
        .adj_rho(rho_corr)
    );

endmodule
