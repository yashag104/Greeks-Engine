`timescale 1ns / 1ps
//============================================================================
// Heston Characteristic Function — Full Datapath
//============================================================================
// Computes φ(u) for the Heston stochastic volatility model:
//
//   d = sqrt[(ρξiu − κ)² + ξ²(iu + u²)]
//   g = (κ − ρξiu − d) / (κ − ρξiu + d)
//   C = riuT + (κθ/ξ²) * [(κ − ρξiu − d)T − 2 ln((1 − g·exp(−dT))/(1 − g))]
//   D = [(κ − ρξiu − d) / ξ²] * [(1 − exp(−dT)) / (1 − g·exp(−dT))]
//   φ(u) = exp(C + D·v₀ + iu·x)
//
// All arithmetic in 64-bit fixed-point Q(32,32) for precision.
// Tape recording: writes intermediate values and partials to BRAM.
//
// Latency per term: ~500-800 cycles (dominated by sequential complex ops)
//============================================================================

module heston_char_func #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,
    
    // Model parameters (Q32.32 signed)
    input  wire signed [WL-1:0] T_in,
    input  wire signed [WL-1:0] r_in,
    input  wire signed [WL-1:0] v0_in,
    input  wire signed [WL-1:0] kappa_in,
    input  wire signed [WL-1:0] theta_in,
    input  wire signed [WL-1:0] xi_in,
    input  wire signed [WL-1:0] rho_in,
    input  wire signed [WL-1:0] x_in,      // ln(S0/K)
    input  wire signed [WL-1:0] u_in,      // Current frequency u_k
    
    input  wire              start,
    
    // Output: phi = phi_r + i*phi_i
    output reg  signed [WL-1:0] phi_r,
    output reg  signed [WL-1:0] phi_i,
    output reg               done,
    
    // Tape write interface
    output reg               tape_we,
    output reg  [15:0]       tape_addr,
    output reg  signed [WL-1:0] tape_data_val,
    output reg  signed [WL-1:0] tape_data_partial
);

    // ==================================================================
    // FSM — Deep sequential pipeline
    // ==================================================================
    localparam S_IDLE        = 5'd0;
    localparam S_RHO_XI      = 5'd1;   // rho * xi
    localparam S_TERM1       = 5'd2;   // term1 = -kappa + i*rho_xi*u
    localparam S_TERM1_SQ    = 5'd3;   // term1²
    localparam S_XI_SQ       = 5'd4;   // xi²
    localparam S_UNDER_SQRT  = 5'd5;   // under_sqrt = term1² + xi²*(iu + u²)
    localparam S_D           = 5'd6;   // d = complex_sqrt(under_sqrt)
    localparam S_WAIT_D      = 5'd7;
    localparam S_NUM_DEN     = 5'd8;   // num, den
    localparam S_G           = 5'd9;   // g = num/den
    localparam S_WAIT_G      = 5'd10;
    localparam S_NEG_DT      = 5'd11;  // -d*T
    localparam S_EXP_DT      = 5'd12;  // exp(-d*T)
    localparam S_WAIT_EDT    = 5'd13;
    localparam S_G_EDT       = 5'd14;  // g * exp(-dT)
    localparam S_WAIT_GEDT   = 5'd15;
    localparam S_RATIOS      = 5'd16;  // (1-g*edT)/(1-g) and (1-edT)/(1-g*edT)
    localparam S_LOG_RATIO   = 5'd17;  // log((1-g*edT)/(1-g))
    localparam S_WAIT_LOG    = 5'd18;
    localparam S_C_D         = 5'd19;  // Compute C and D
    localparam S_EXPONENT    = 5'd20;  // C + D*v0 + i*u*x
    localparam S_PHI         = 5'd21;  // phi = exp(exponent)
    localparam S_WAIT_PHI    = 5'd22;
    localparam S_DONE        = 5'd23;
    // D-term states (kappa*theta/xi^2, num/xi^2, (1-edT)/(1-g*edT), and
    // their product) — inserted between S_C_D and S_EXPONENT.
    localparam S_KTH_XI2      = 5'd24;
    localparam S_KTH_XI2_WAIT = 5'd25;
    localparam S_NXI2         = 5'd26;
    localparam S_NXI2_WAIT    = 5'd27;
    localparam S_OME_DR       = 5'd28;
    localparam S_DR_WAIT      = 5'd29;
    localparam S_DMUL         = 5'd30;
    localparam S_DMUL_WAIT    = 5'd31;

    reg [4:0] state;

    // Working registers — all complex (real, imag pairs)
    reg signed [WL-1:0] rho_xi_val;     // rho * xi (real scalar)
    reg signed [WL-1:0] xi_sq;          // xi² (real scalar)
    reg signed [WL-1:0] kappa_theta_over_xi2; // kappa*theta/xi²
    
    reg signed [WL-1:0] term1_r, term1_i;
    reg signed [WL-1:0] under_sqrt_r, under_sqrt_i;
    reg signed [WL-1:0] d_r, d_i;
    reg signed [WL-1:0] num_r, num_i;
    reg signed [WL-1:0] den_r, den_i;
    reg signed [WL-1:0] g_r, g_i;
    reg signed [WL-1:0] edT_r, edT_i;
    reg signed [WL-1:0] g_edT_r, g_edT_i;
    reg signed [WL-1:0] omge_r, omge_i;    // 1 - g*exp(-dT)
    reg signed [WL-1:0] omg_r, omg_i;      // 1 - g
    reg signed [WL-1:0] ratio_r, ratio_i;
    reg signed [WL-1:0] log_ratio_r, log_ratio_i;
    reg signed [WL-1:0] C_r, C_i;
    reg signed [WL-1:0] D_r, D_i;
    reg signed [WL-1:0] exponent_r, exponent_i;

    // D-term intermediates: nxi2 = num/xi^2 (complex/real), dr = (1-edT)/(1-g*edT)
    reg signed [WL-1:0] nxi2_r, nxi2_i;
    reg signed [WL-1:0] ome_r, ome_i;       // 1 - exp(-dT)
    reg signed [WL-1:0] dr_r, dr_i;
    reg signed [WL-1:0] kth_xi2;            // kappa*theta/xi^2
    reg signed [WL-1:0] numT_r, numT_i;     // num*T (real & imag), reused by C_r/C_i

    reg signed [2*WL-1:0] wp1, wp2, wp3, wp4; // Wide product temps

    // NOTE: hoisted out of nested begin/end blocks further down (each was a
    // SystemVerilog-only construct — plain Verilog only allows declarations
    // at the top of a module or a *named* block, not a nested unnamed one).
    reg signed [2*WL-1:0] xi2_u2, kt, ruT;

    // NOTE: $signed() requires an integer/vector argument, not a `real` —
    // the real-valued constant expression must be rounded to an integer
    // with $rtoi() first (real args to $signed produced an elaboration
    // error). $rtoi returns a 32-bit *signed* integer, though, so
    // computing it directly at (2.0**FL) overflows/wraps for FL >= ~31
    // (this module defaults to FL=32). Instead, round at min(FL,16)
    // fractional bits — comfortably inside $rtoi's 32-bit range for any
    // real FL used in this design — and left-shift the rest of the way
    // when FL > 16 (exact: it just appends zero fractional bits, not a
    // further rounding step).
    wire signed [WL-1:0] ONE = (FL <= 16)
        ? $signed( $rtoi(1.0 * (2.0**FL)) )
        : $signed( $rtoi(1.0 * (2.0**16)) ) <<< (FL-16);

    // Sub-module instances
    // Complex sqrt
    reg csqrt_start;
    wire signed [WL-1:0] csqrt_res_r, csqrt_res_i;
    wire csqrt_done;

    complex_sqrt #(.WL(WL), .FL(FL)) csqrt_inst (
        .clk(clk), .rst(rst),
        .a_r(under_sqrt_r), .a_i(under_sqrt_i),
        .start(csqrt_start),
        .res_r(csqrt_res_r), .res_i(csqrt_res_i),
        .done(csqrt_done)
    );

    // Complex div
    reg cdiv_start;
    reg signed [WL-1:0] cdiv_a_r, cdiv_a_i, cdiv_b_r, cdiv_b_i;
    wire signed [WL-1:0] cdiv_res_r, cdiv_res_i;
    wire cdiv_done;

    complex_div #(.WL(WL), .FL(FL)) cdiv_inst (
        .clk(clk), .rst(rst),
        .a_r(cdiv_a_r), .a_i(cdiv_a_i),
        .b_r(cdiv_b_r), .b_i(cdiv_b_i),
        .start(cdiv_start),
        .res_r(cdiv_res_r), .res_i(cdiv_res_i),
        .done(cdiv_done)
    );

    // Complex exp
    reg cexp_start;
    reg signed [WL-1:0] cexp_a_r, cexp_a_i;
    wire signed [WL-1:0] cexp_res_r, cexp_res_i;
    wire cexp_done;

    complex_exp #(.WL(WL), .FL(FL)) cexp_inst (
        .clk(clk), .rst(rst),
        .a_r(cexp_a_r), .a_i(cexp_a_i),
        .start(cexp_start),
        .res_r(cexp_res_r), .res_i(cexp_res_i),
        .done(cexp_done)
    );

    // Complex mult (for g*edT and final products)
    reg cmul_valid;
    reg signed [WL-1:0] cmul_a_r, cmul_a_i, cmul_b_r, cmul_b_i;
    wire signed [WL-1:0] cmul_res_r, cmul_res_i;
    wire cmul_valid_out;

    complex_mult #(.WL(WL), .FL(FL)) cmul_inst (
        .clk(clk), .rst(rst),
        .a_r(cmul_a_r), .a_i(cmul_a_i),
        .b_r(cmul_b_r), .b_i(cmul_b_i),
        .valid_in(cmul_valid),
        .res_r(cmul_res_r), .res_i(cmul_res_i),
        .valid_out(cmul_valid_out)
    );

    // Complex log
    reg clog_start;
    reg signed [WL-1:0] clog_a_r, clog_a_i;
    wire signed [WL-1:0] clog_res_r, clog_res_i;
    wire clog_done;

    complex_log #(.WL(WL), .FL(FL)) clog_inst (
        .clk(clk), .rst(rst),
        .a_r(clog_a_r), .a_i(clog_a_i),
        .start(clog_start),
        .res_r(clog_res_r), .res_i(clog_res_i),
        .done(clog_done)
    );

    // Real divider — used for kappa*theta/xi^2 (a real/real division that
    // doesn't need the full complex divider above).
    reg fdiv_start;
    reg [WL-1:0] fdiv_a, fdiv_b;
    wire [WL-1:0] fdiv_result;
    wire fdiv_ready;

    fp_div #(.WL(WL), .FL(FL)) fdiv_inst (
        .clk(clk), .rst(rst),
        .a(fdiv_a), .b(fdiv_b), .start(fdiv_start),
        .result(fdiv_result), .ready(fdiv_ready),
        .divide_by_zero(), .overflow()
    );

    // ==================================================================
    // Main FSM
    // ==================================================================
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            tape_we <= 1'b0;
        end else begin
            tape_we     <= 1'b0;
            csqrt_start <= 1'b0;
            cdiv_start  <= 1'b0;
            cexp_start  <= 1'b0;
            cmul_valid  <= 1'b0;
            clog_start  <= 1'b0;
            fdiv_start  <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    // NOTE: this module's tape_* ports are not currently
                    // wired up by its only caller (heston_cos_forward.v
                    // leaves them unconnected) — per-term AAD through the
                    // characteristic function isn't attempted; Heston
                    // Greeks are instead computed by bump-and-reprice in
                    // heston_reverse_pass.v. tape_we simply stays 0.
                    if (start) begin
                        state <= S_RHO_XI;
                    end
                end

                // ---- Step 1: rho * xi ----
                S_RHO_XI: begin
                    wp1 = $signed(rho_in) * $signed(xi_in);
                    rho_xi_val <= wp1 >>> FL;
                    
                    wp2 = $signed(xi_in) * $signed(xi_in);
                    xi_sq <= wp2 >>> FL;
                    
                    state <= S_TERM1;
                end

                // ---- Step 2: term1 = -kappa + i*(rho*xi*u) ----
                S_TERM1: begin
                    term1_r <= -kappa_in;
                    wp1 = $signed(rho_xi_val) * $signed(u_in);
                    term1_i <= wp1 >>> FL;
                    state <= S_TERM1_SQ;
                end

                // ---- Step 3: term1² = (t1r² - t1i²) + i*(2*t1r*t1i) ----
                S_TERM1_SQ: begin
                    wp1 = $signed(term1_r) * $signed(term1_r);
                    wp2 = $signed(term1_i) * $signed(term1_i);
                    wp3 = $signed(term1_r) * $signed(term1_i);
                    
                    // under_sqrt = term1² + xi²*(u² + iu)
                    // xi²*u² (real)
                    wp4 = $signed(xi_sq) * $signed(u_in);
                    xi2_u2 = (wp4 >>> FL) * $signed(u_in);  // xi²*u²

                    under_sqrt_r <= ((wp1 - wp2) >>> FL) + (xi2_u2 >>> FL);
                    under_sqrt_i <= (2 * (wp3 >>> FL)) + (wp4 >>> FL); // +xi²*u
                    state <= S_D;
                end

                // ---- Step 4: d = complex_sqrt(under_sqrt) ----
                S_D: begin
                    csqrt_start <= 1'b1;
                    state <= S_WAIT_D;
                end

                S_WAIT_D: begin
                    if (csqrt_done) begin
                        d_r <= csqrt_res_r;
                        d_i <= csqrt_res_i;
                        state <= S_NUM_DEN;
                    end
                end

                // ---- Step 5: num = kappa - rho*xi*i*u - d ----
                //              den = kappa - rho*xi*i*u + d ----
                S_NUM_DEN: begin
                    num_r <= kappa_in - d_r;
                    num_i <= -term1_i - d_i;   // -rho*xi*u - d_i
                    den_r <= kappa_in + d_r;
                    den_i <= -term1_i + d_i;   // -rho*xi*u + d_i
                    state <= S_G;
                end

                // ---- Step 6: g = num / den ----
                S_G: begin
                    cdiv_a_r <= num_r; cdiv_a_i <= num_i;
                    cdiv_b_r <= den_r; cdiv_b_i <= den_i;
                    cdiv_start <= 1'b1;
                    state <= S_WAIT_G;
                end

                S_WAIT_G: begin
                    if (cdiv_done) begin
                        g_r <= cdiv_res_r;
                        g_i <= cdiv_res_i;
                        state <= S_NEG_DT;
                    end
                end

                // ---- Step 7: -d*T (complex scalar multiply) ----
                S_NEG_DT: begin
                    wp1 = -$signed(d_r) * $signed(T_in);
                    wp2 = -$signed(d_i) * $signed(T_in);
                    cexp_a_r <= wp1 >>> FL;
                    cexp_a_i <= wp2 >>> FL;
                    cexp_start <= 1'b1;
                    state <= S_WAIT_EDT;
                end

                // ---- Step 8: exp(-d*T) ----
                S_WAIT_EDT: begin
                    if (cexp_done) begin
                        edT_r <= cexp_res_r;
                        edT_i <= cexp_res_i;
                        state <= S_G_EDT;
                    end
                end

                // ---- Step 9: g * exp(-dT) ----
                S_G_EDT: begin
                    cmul_a_r <= g_r; cmul_a_i <= g_i;
                    cmul_b_r <= edT_r; cmul_b_i <= edT_i;
                    cmul_valid <= 1'b1;
                    state <= S_WAIT_GEDT;
                end

                S_WAIT_GEDT: begin
                    if (cmul_valid_out) begin
                        g_edT_r <= cmul_res_r;
                        g_edT_i <= cmul_res_i;
                        
                        // Precompute 1-g and 1-g*edT
                        omge_r <= ONE - cmul_res_r;
                        omge_i <= -cmul_res_i;
                        omg_r  <= ONE - g_r;
                        omg_i  <= -g_i;
                        
                        state <= S_RATIOS;
                    end
                end

                // ---- Step 10: ratio = (1-g*edT)/(1-g) for log ----
                S_RATIOS: begin
                    cdiv_a_r <= omge_r; cdiv_a_i <= omge_i;
                    cdiv_b_r <= omg_r;  cdiv_b_i <= omg_i;
                    cdiv_start <= 1'b1;
                    state <= S_LOG_RATIO;
                end

                S_LOG_RATIO: begin
                    if (cdiv_done) begin
                        ratio_r <= cdiv_res_r;
                        ratio_i <= cdiv_res_i;
                        // Now compute log(ratio)
                        clog_a_r <= cdiv_res_r;
                        clog_a_i <= cdiv_res_i;
                        clog_start <= 1'b1;
                        state <= S_WAIT_LOG;
                    end
                end

                S_WAIT_LOG: begin
                    if (clog_done) begin
                        log_ratio_r <= clog_res_r;
                        log_ratio_i <= clog_res_i;
                        state <= S_C_D;
                    end
                end

                // ---- Step 11: Compute C and D ----
                // C_r = kth_xi2 * (num_r*T - 2*log_ratio_r)
                // C_i = r*u*T + kth_xi2 * (num_i*T - 2*log_ratio_i)
                // D   = (num/xi²) * (1-edT) / (1-g*edT)
                S_C_D: begin
                    kt = $signed(kappa_in) * $signed(theta_in);
                    fdiv_a <= kt >>> FL;
                    fdiv_b <= xi_sq;
                    fdiv_start <= 1'b1;

                    // NOTE: route through the wide (2*WL-bit) wp1/wp2 temps
                    // rather than computing `($signed(a)*$signed(b))>>>FL`
                    // directly — a raw multiply's self-determined width is
                    // the max of its *operand* widths (both WL bits here),
                    // not the width of whatever it's eventually assigned
                    // to, so at this module's WL=64/FL=32 the product of
                    // two ordinary O(1)-valued operands (each ~2^32 raw)
                    // is ~2^64 and silently overflows a WL-bit-wide result
                    // before the shift ever runs.
                    wp1 = $signed(num_r) * $signed(T_in);
                    wp2 = $signed(num_i) * $signed(T_in);
                    numT_r <= wp1 >>> FL;
                    numT_i <= wp2 >>> FL;

                    ruT = $signed(r_in) * $signed(u_in);
                    C_i  <= (((ruT >>> FL) * $signed(T_in)) >>> FL); // r*u*T (D_i term added below)

                    state <= S_KTH_XI2_WAIT;
                end

                S_KTH_XI2_WAIT: begin
                    if (fdiv_ready) begin
                        kth_xi2 <= fdiv_result;
                        state <= S_KTH_XI2;
                    end
                end

                S_KTH_XI2: begin
                    // C_r = kth_xi2 * (numT_r - 2*log_ratio_r)
                    // C_i = (r*u*T) + kth_xi2 * (numT_i - 2*log_ratio_i)
                    wp1 = $signed(kth_xi2) * (numT_r - (log_ratio_r <<< 1));
                    wp2 = $signed(kth_xi2) * (numT_i - (log_ratio_i <<< 1));
                    C_r <= wp1 >>> FL;
                    C_i <= C_i + (wp2 >>> FL);

                    // Kick off D: nxi2 = num / xi^2 (complex / real, via the
                    // complex divider with a zero imaginary denominator).
                    cdiv_a_r <= num_r; cdiv_a_i <= num_i;
                    cdiv_b_r <= xi_sq; cdiv_b_i <= 0;
                    cdiv_start <= 1'b1;
                    state <= S_NXI2_WAIT;
                end

                S_NXI2_WAIT: begin
                    if (cdiv_done) begin
                        nxi2_r <= cdiv_res_r;
                        nxi2_i <= cdiv_res_i;
                        state <= S_NXI2;
                    end
                end

                S_NXI2: begin
                    // dr = (1 - exp(-dT)) / (1 - g*exp(-dT))
                    ome_r <= ONE - edT_r;
                    ome_i <= -edT_i;
                    state <= S_OME_DR;
                end

                S_OME_DR: begin
                    cdiv_a_r <= ome_r;  cdiv_a_i <= ome_i;
                    cdiv_b_r <= omge_r; cdiv_b_i <= omge_i;
                    cdiv_start <= 1'b1;
                    state <= S_DR_WAIT;
                end

                S_DR_WAIT: begin
                    if (cdiv_done) begin
                        dr_r <= cdiv_res_r;
                        dr_i <= cdiv_res_i;
                        state <= S_DMUL;
                    end
                end

                S_DMUL: begin
                    // D = nxi2 * dr
                    cmul_a_r <= nxi2_r; cmul_a_i <= nxi2_i;
                    cmul_b_r <= dr_r;   cmul_b_i <= dr_i;
                    cmul_valid <= 1'b1;
                    state <= S_DMUL_WAIT;
                end

                S_DMUL_WAIT: begin
                    if (cmul_valid_out) begin
                        D_r <= cmul_res_r;
                        D_i <= cmul_res_i;
                        state <= S_EXPONENT;
                    end
                end

                // ---- Step 12: exponent = C + D*v0 + i*u*x ----
                S_EXPONENT: begin
                    wp1 = $signed(D_r) * $signed(v0_in);
                    wp2 = $signed(D_i) * $signed(v0_in);
                    wp3 = $signed(u_in) * $signed(x_in);
                    
                    cexp_a_r <= C_r + (wp1 >>> FL);
                    cexp_a_i <= C_i + (wp2 >>> FL) + (wp3 >>> FL);
                    cexp_start <= 1'b1;
                    state <= S_WAIT_PHI;
                end

                // ---- Step 13: phi = exp(exponent) ----
                S_WAIT_PHI: begin
                    if (cexp_done) begin
                        phi_r <= cexp_res_r;
                        phi_i <= cexp_res_i;
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
