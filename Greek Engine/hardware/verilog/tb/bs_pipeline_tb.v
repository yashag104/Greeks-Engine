`timescale 1ns / 1ps
//============================================================================
// Black-Scholes Pipeline Testbench (Forward + Reverse AAD)
//============================================================================
// Exercises bs_top_level for both a call and a put, and compares the
// fixed-point price and all five Greeks against the closed-form
// floating-point reference (see hardware/matlab/bs_top_level.m,
// bs_reference_greeks) at the same parameters.
//============================================================================

module bs_pipeline_tb;

    localparam WL = 32;
    localparam FL = 16;

    reg clk;
    reg rst;
    reg start;

    reg  [WL-1:0] S, K, T, r, sigma;
    reg           is_call;

    wire [WL-1:0] price;
    wire [47:0]   delta, vega, theta, rho, strike_sens;
    wire          done;

    bs_top_level uut (
        .clk(clk), .rst(rst),
        .S(S), .K(K), .T(T), .r(r), .sigma(sigma), .is_call(is_call),
        .start(start),
        .price(price), .delta(delta), .vega(vega), .theta(theta),
        .rho(rho), .strike_sens(strike_sens), .done(done)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    function real q16(input signed [WL-1:0] v);
        q16 = v / 65536.0;
    endfunction
    function real q1632(input signed [47:0] v);
        q1632 = v / 65536.0;
    endfunction

    task run_case(
        input [WL-1:0] S_v, K_v, T_v, r_v, sigma_v, input is_call_v,
        input real exp_price, exp_delta, exp_vega, exp_theta, exp_rho, exp_strike_sens
    );
        begin
            S = S_v; K = K_v; T = T_v; r = r_v; sigma = sigma_v; is_call = is_call_v;
            start = 1; #10; start = 0;
            wait (done); #1;
            $display("  price       = %10.6f  (expect %10.6f)", q16(price), exp_price);
            $display("  delta       = %10.6f  (expect %10.6f)", q1632(delta), exp_delta);
            $display("  vega        = %10.6f  (expect %10.6f)", q1632(vega), exp_vega);
            $display("  theta       = %10.6f  (expect %10.6f)", q1632(theta), exp_theta);
            $display("  rho         = %10.6f  (expect %10.6f)", q1632(rho), exp_rho);
            $display("  strike_sens = %10.6f  (expect %10.6f)", q1632(strike_sens), exp_strike_sens);
            #10;
        end
    endtask

    initial begin
        rst = 1;
        start = 0;
        #100;
        rst = 0;
        #10;

        // S=100, K=105, T=0.5, r=0.05, sigma=0.2 (Q16.16)
        $display("--- Call ---");
        run_case(32'd100 << 16, 32'd105 << 16, 32'd32768, 32'd3277, 32'd13107, 1'b1,
                  4.581680, 0.461160, 28.075684, 7.691854, 20.767171, -0.395565);

        $display("--- Put ---");
        run_case(32'd100 << 16, 32'd105 << 16, 32'd32768, 32'd3277, 32'd13107, 1'b0,
                  6.989221, -0.538840, 28.075684, 2.571477, -30.436599, 0.579745);

        $finish;
    end

endmodule
