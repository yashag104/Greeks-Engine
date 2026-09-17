`timescale 1ns / 1ps
//============================================================================
// Heston COS core in price-only mode (fwd_only=1: no reverse sweep, the
// mode the bump-and-reprice baseline uses), self-checking; also reports the
// forward-only cycle count, i.e. the cost of one "reprice".
// Reference values: validation/reference/heston_reference.py cos_price /
// cos_greeks (double precision, same COS algorithm: N=128, L=10 cumulant
// range held fixed when differentiating). Tolerance 1e-6 * max(1, |ref|);
// measured errors are ~1e-7 absolute (see docs/precision_bound.md).
//============================================================================

module heston_forward_tb;
    localparam WL = 64;
    localparam FL = 32;

    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;

    reg signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho;
    reg is_call;
    wire signed [WL-1:0] price;
    wire done;
    integer failures = 0, cycles = 0;

    heston_cos_forward #(.WL(WL), .FL(FL)) uut (
        .clk(clk), .rst(rst),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call), .start(start), .fwd_only(1'b1),
        .price(price), .done(done),
        .adj_S0(), .adj_K(), .adj_T(), .adj_r(), .adj_v0(),
        .adj_kappa(), .adj_theta(), .adj_xi(), .adj_rho()
    );

    // |rtl - ref| <= tol * max(1, |ref|)
    task check(input [8*12-1:0] name, input signed [WL-1:0] v, input real ref, input real tol);
        real got, err, scale;
        begin
            got = v / 4294967296.0;
            err = got - ref; if (err < 0) err = -err;
            scale = (ref < 0 ? -ref : ref); if (scale < 1.0) scale = 1.0;
            if (err > tol * scale) begin
                $display("FAIL %s rtl=%.10f ref=%.10f err=%.3e", name, got, ref, err);
                failures = failures + 1;
            end else
                $display("ok   %s rtl=%.10f ref=%.10f err=%.3e", name, got, ref, err);
        end
    endtask

    initial begin
        S0    = 64'sd429496729600; // 100.0
        K     = 64'sd429496729600; // 100.0
        T     = 64'sd4294967296; // 1.0
        r     = 64'sd214748365; // 0.05
        v0    = 64'sd171798692; // 0.04
        kappa = 64'sd6442450944; // 1.5
        theta = 64'sd171798692; // 0.04
        xi    = 64'sd1288490189; // 0.3
        rho   = -64'sd3865470566; // -0.9
        is_call = 1;
        #100 rst = 0;
        @(negedge clk) start = 1;
        @(negedge clk) start = 0;
        while (!done) begin @(posedge clk); cycles = cycles + 1; end
        #1;
        $display("price-only pass completed in %0d cycles", cycles);
        check("price", price, 10.387139265110, 1e-6);
        if (failures == 0) $display("PASS");
        else               $display("FAIL");
        $finish;
    end
endmodule
