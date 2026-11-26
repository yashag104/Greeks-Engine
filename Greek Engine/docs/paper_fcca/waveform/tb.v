`timescale 1ns/1ps
module tb;
reg clk=0, rst=1, start=0; always #5 clk=~clk;
reg signed [63:0] S0, K, T, r, v0, kappa, theta, xi, rho;
reg is_call;
wire signed [63:0] price, delta, strike_sens, theta_greek, rho_greek, vega, kappa_sens, theta_sens, xi_sens, rho_corr;
wire done, range_err; integer errors=0;
heston_aad_zu dut(.clk(clk),.rst(rst),.start(start),.S0(S0),.K(K),.T(T),.r(r),.v0(v0),.kappa(kappa),.theta(theta),.xi(xi),.rho(rho),.is_call(is_call),.price(price),.delta(delta),.strike_sens(strike_sens),.theta_greek(theta_greek),.rho_greek(rho_greek),.vega(vega),.kappa_sens(kappa_sens),.theta_sens(theta_sens),.xi_sens(xi_sens),.rho_corr(rho_corr),.done(done),.range_err(range_err));
initial begin $dumpfile("/tmp/claude-1002/-mnt-c-Users-hp-Greeks-Engine/c97595b7-3a1b-4c6f-8b1b-0473ed6116f6/scratchpad/wave/wave.vcd"); $dumpvars(0, tb.clk, tb.start, tb.done, tb.range_err, tb.is_call, tb.price, tb.delta, tb.strike_sens, tb.theta_greek, tb.rho_greek, tb.vega, tb.kappa_sens, tb.theta_sens, tb.xi_sens, tb.rho_corr, tb.dut.running, tb.dut.t, tb.dut.ph, tb.dut.kcur, tb.dut.in_setup, tb.dut.in_term, tb.dut.in_fin, tb.dut.acc_price);
#40 rst=0; repeat(3) @(negedge clk);
S0 = 64'sd429496729600;
K = 64'sd429496729600;
T = 64'sd4294967296;
r = 64'sd214748365;
v0 = 64'sd171798692;
kappa = 64'sd6442450944;
theta = 64'sd171798692;
xi = 64'sd1288490189;
rho = (-64'sd3865470566);
is_call=1; @(negedge clk) start=1; @(negedge clk) start=0;
@(posedge done); #1;
if (price !== 64'sd44612421806) begin errors=errors+1; $display("MISMATCH price"); end
if (delta !== 64'sd3067244061) begin errors=errors+1; $display("MISMATCH delta"); end
if (strike_sens !== (-64'sd2621119843)) begin errors=errors+1; $display("MISMATCH strike_sens"); end
if (theta_greek !== 64'sd27549498160) begin errors=errors+1; $display("MISMATCH theta_greek"); end
if (rho_greek !== 64'sd262111984315) begin errors=errors+1; $display("MISMATCH rho_greek"); end
if (vega !== 64'sd200145170394) begin errors=errors+1; $display("MISMATCH vega"); end
if (kappa_sens !== 64'sd266030900) begin errors=errors+1; $display("MISMATCH kappa_sens"); end
if (theta_sens !== 64'sd189778399478) begin errors=errors+1; $display("MISMATCH theta_sens"); end
if (xi_sens !== (-64'sd5173634624)) begin errors=errors+1; $display("MISMATCH xi_sens"); end
if (rho_corr !== (-64'sd501135228)) begin errors=errors+1; $display("MISMATCH rho_corr"); end
repeat(12) @(negedge clk);
S0 = 64'sd429496729600;
K = 64'sd472446402560;
T = 64'sd1073741824;
r = 64'sd0;
v0 = 64'sd75161928;
kappa = 64'sd6772304432;
theta = 64'sd170939698;
xi = 64'sd2470035692;
rho = (-64'sd2452855823);
is_call=0; @(negedge clk) start=1; @(negedge clk) start=0;
@(posedge done); #1;
if (price !== 64'sd43522424668) begin errors=errors+1; $display("MISMATCH price"); end
if (delta !== (-64'sd4093067907)) begin errors=errors+1; $display("MISMATCH delta"); end
if (strike_sens !== 64'sd4116629231) begin errors=errors+1; $display("MISMATCH strike_sens"); end
if (theta_greek !== 64'sd5508219701) begin errors=errors+1; $display("MISMATCH theta_greek"); end
if (rho_greek !== (-64'sd113207303851)) begin errors=errors+1; $display("MISMATCH rho_greek"); end
if (vega !== 64'sd47902136379) begin errors=errors+1; $display("MISMATCH vega"); end
if (kappa_sens !== 64'sd121767927) begin errors=errors+1; $display("MISMATCH kappa_sens"); end
if (theta_sens !== 64'sd10588862033) begin errors=errors+1; $display("MISMATCH theta_sens"); end
if (xi_sens !== (-64'sd129843196)) begin errors=errors+1; $display("MISMATCH xi_sens"); end
if (rho_corr !== 64'sd2093352787) begin errors=errors+1; $display("MISMATCH rho_corr"); end
repeat(260) @(negedge clk);
$display("errors=%0d", errors); $finish; end
endmodule