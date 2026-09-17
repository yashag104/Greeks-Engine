`timescale 1ns / 1ps
//============================================================================
// Heston Characteristic Function — Full Datapath, Forward + Reverse-Mode AAD
//============================================================================
// Forward:
//   d = sqrt[(ρξiu − κ)² + ξ²(iu + u²)]
//   g = (κ − ρξiu − d) / (κ − ρξiu + d)
//   C = riuT + (κθ/ξ²) * [(κ − ρξiu − d)T − 2 ln((1 − g·exp(−dT))/(1 − g))]
//   D = [(κ − ρξiu − d) / ξ²] * [(1 − exp(−dT)) / (1 − g·exp(−dT))]
//   φ(u) = exp(C + D·v₀ + iu·x)
//
// Reverse (this is the module that makes this design's Heston Greeks
// genuine reverse-mode AAD rather than bump-and-reprice): given a seed
// adjoint (seed_r, seed_i) = (∂L/∂φ_r, ∂L/∂φ_i) for whatever scalar loss L
// the caller cares about, propagates it backward through the *same* graph
// above to the 8 real leaf adjoints (∂L/∂T, ∂L/∂r, ∂L/∂v0, ∂L/∂κ, ∂L/∂θ,
// ∂L/∂ξ, ∂L/∂ρ, ∂L/∂x) — reusing every forward-pass intermediate register
// (no recomputation) and, crucially, the *same* complex_div/complex_mult
// instances used by the forward pass.
//
// Every named step above is holomorphic in its complex argument(s) (sqrt,
// division, exp, log, multiplication are all complex-analytic away from
// their branch cuts/poles), so its reverse-mode adjoint has a compact
// closed form: for Y = f(X) with known complex derivative f'(X) = p+qi at
// the forward-computed X, and adjoint-of-Y aY = aYr + i·aYi (meaning
// (∂L/∂Yr, ∂L/∂Yi)), the adjoint-of-X is
//     aX = conj(f'(X)) · aY        (ordinary complex multiplication)
// i.e. exactly one call to complex_mult (and, when f'(X) itself needs a
// division, one call to complex_div first). This is verified end-to-end
// against hardware/software/models/heston_cos.py's fully-decomposed
// (operator-overloaded, scalar tape) AAD engine — see the RTL testbench
// comment block below for the exact reference numbers.
//
// All arithmetic in 64-bit fixed-point Q(32,32) for precision.
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
    // 1 = price only: skip the reverse sweep (adjoint outputs are zero).
    // Used by the bump-and-reprice baseline, which needs forward passes
    // only; must be stable from start to done.
    input  wire              fwd_only,

    // Reverse-mode seed: (seed_r, seed_i) = (dL/d phi_r, dL/d phi_i) for
    // whatever scalar loss L the caller is differentiating. Must be valid
    // at `start` and held stable until `done`.
    input  wire signed [WL-1:0] seed_r,
    input  wire signed [WL-1:0] seed_i,

    // Output: phi = phi_r + i*phi_i
    output reg  signed [WL-1:0] phi_r,
    output reg  signed [WL-1:0] phi_i,

    // Reverse-mode outputs: dL/d(param) for this one term, given the seed
    // above. (Caller accumulates these across COS terms k.)
    output reg  signed [WL-1:0] adj_T,
    output reg  signed [WL-1:0] adj_r,
    output reg  signed [WL-1:0] adj_v0,
    output reg  signed [WL-1:0] adj_kappa,
    output reg  signed [WL-1:0] adj_theta,
    output reg  signed [WL-1:0] adj_xi,
    output reg  signed [WL-1:0] adj_rho,
    output reg  signed [WL-1:0] adj_x,

    output reg               done
);

    `include "fx_lib.vh"


    // ==================================================================
    // FSM — forward pipeline, then reverse-mode AAD pipeline
    // ==================================================================
    localparam S_IDLE        = 8'd0;
    localparam S_RHO_XI      = 8'd1;   // rho * xi
    localparam S_TERM1       = 8'd2;   // term1 = -kappa + i*rho_xi*u
    localparam S_TERM1_SQ    = 8'd3;   // term1²
    localparam S_D           = 8'd6;   // d = complex_sqrt(under_sqrt)
    localparam S_WAIT_D      = 8'd7;
    localparam S_NUM_DEN     = 8'd8;   // num, den
    localparam S_G           = 8'd9;   // g = num/den
    localparam S_WAIT_G      = 8'd10;
    localparam S_NEG_DT      = 8'd11;  // -d*T
    localparam S_WAIT_EDT    = 8'd13;
    localparam S_G_EDT       = 8'd14;  // g * exp(-dT)
    localparam S_WAIT_GEDT   = 8'd15;
    localparam S_RATIOS      = 8'd16;  // (1-g*edT)/(1-g)
    localparam S_LOG_RATIO   = 8'd17;
    localparam S_WAIT_LOG    = 8'd18;
    localparam S_C_D         = 8'd19;  // Compute C and D
    localparam S_KTH_XI2_WAIT = 8'd25;
    localparam S_KTH_XI2      = 8'd24;
    localparam S_NXI2_WAIT    = 8'd27;
    localparam S_NXI2         = 8'd26;
    localparam S_OME_DR       = 8'd28;
    localparam S_DR_WAIT      = 8'd29;
    localparam S_DMUL         = 8'd30;
    localparam S_DMUL_WAIT    = 8'd31;
    localparam S_EXPONENT    = 8'd20;  // C + D*v0 + i*u*x
    localparam S_WAIT_PHI    = 8'd22;
    localparam S_DONE        = 8'd23;

    // ---- Reverse-mode states (strict reverse-topological order) ----
    localparam R_INIT          = 8'd40; // clear adjoint accumulators
    localparam R_INV_XISQ_WAIT = 8'd41; // 1/xi^2 (shared by two later steps)
    localparam R_PHI           = 8'd42; // adj_exponent = conj(phi) (x) seed
    localparam R_PHI_WAIT      = 8'd43;
    localparam R_EXPONENT      = 8'd44; // fan out to adj_C, adj_Dv0, adj_iuximag
    localparam R_DV0_X         = 8'd45; // reverse Dv0=D*v0 and iuximag=x*u
    localparam R_D_MUL         = 8'd46; // adj_nxi2 = conj(Dratio) (x) adj_D
    localparam R_D_MUL_WAIT    = 8'd47;
    localparam R_D_MUL2        = 8'd48; // adj_Dratio = conj(nxi2) (x) adj_D
    localparam R_D_MUL2_WAIT   = 8'd49;
    localparam R_DRATIO_INV    = 8'd50; // 1/omge
    localparam R_DRATIO_INV_WAIT = 8'd51;
    localparam R_DRATIO_MUL1   = 8'd52; // adj_ome = conj(1/omge) (x) adj_Dratio
    localparam R_DRATIO_MUL1_WAIT = 8'd53;
    localparam R_DRATIO_RATIO  = 8'd54; // Dratio/omge
    localparam R_DRATIO_RATIO_WAIT = 8'd55;
    localparam R_DRATIO_MUL2   = 8'd56; // adj_omge += conj(-Dratio/omge) (x) adj_Dratio
    localparam R_DRATIO_MUL2_WAIT = 8'd57;
    localparam R_OME           = 8'd58; // adj_edT += -adj_ome
    localparam R_NXI2          = 8'd59; // adj_num += adj_nxi2 * inv_xi_sq ; adj_xi_sq += ...
    localparam R_CFUNC         = 8'd61; // adj_C -> adj_Cfunc -> adj_bracket, adj_kth_xi2
    localparam R_BRACKET       = 8'd62; // adj_numT, adj_logratio
    localparam R_NUMT          = 8'd63; // adj_num += adj_numT*T ; adj_T += ...
    localparam R_P_RUT         = 8'd64; // adj_kappa/theta from adj_p ; adj_r/adj_T from adj_r_u_T
    localparam R_LOGRATIO_INV  = 8'd65; // 1/ratio
    localparam R_LOGRATIO_INV_WAIT = 8'd66;
    localparam R_LOGRATIO_MUL  = 8'd67; // adj_ratio = conj(1/ratio) (x) adj_logratio
    localparam R_LOGRATIO_MUL_WAIT = 8'd68;
    localparam R_RATIO_INV     = 8'd69; // 1/omg
    localparam R_RATIO_INV_WAIT = 8'd70;
    localparam R_RATIO_MUL1    = 8'd71; // adj_omge += conj(1/omg) (x) adj_ratio
    localparam R_RATIO_MUL1_WAIT = 8'd72;
    localparam R_RATIO_RATIO   = 8'd73; // ratio/omg
    localparam R_RATIO_RATIO_WAIT = 8'd74;
    localparam R_RATIO_MUL2    = 8'd75; // adj_omg = conj(-ratio/omg) (x) adj_ratio
    localparam R_RATIO_MUL2_WAIT = 8'd76;
    localparam R_OMGE_OMG      = 8'd77; // adj_gexp = -adj_omge ; adj_g += -adj_omg
    localparam R_GEDT_MUL1     = 8'd78; // adj_g += conj(edT) (x) adj_gexp
    localparam R_GEDT_MUL1_WAIT = 8'd79;
    localparam R_GEDT_MUL2     = 8'd80; // adj_edT += conj(g) (x) adj_gexp
    localparam R_GEDT_MUL2_WAIT = 8'd81;
    localparam R_EDT_MUL       = 8'd82; // adj_negdT = conj(edT) (x) adj_edT
    localparam R_EDT_MUL_WAIT  = 8'd83;
    localparam R_NEGDT         = 8'd84; // adj_d += ... ; adj_T += ...
    localparam R_G_INV         = 8'd85; // 1/den
    localparam R_G_INV_WAIT    = 8'd86;
    localparam R_G_MUL1        = 8'd87; // adj_num += conj(1/den) (x) adj_g
    localparam R_G_MUL1_WAIT   = 8'd88;
    localparam R_G_RATIO       = 8'd89; // g/den
    localparam R_G_RATIO_WAIT  = 8'd90;
    localparam R_G_MUL2        = 8'd91; // adj_den = conj(-g/den) (x) adj_g
    localparam R_G_MUL2_WAIT   = 8'd92;
    localparam R_NUMDEN        = 8'd93; // adj_kappa, adj_term1_i, adj_d from num/den
    localparam R_D_INV         = 8'd94; // 1/(2d)
    localparam R_D_INV_WAIT    = 8'd95;
    localparam R_D_MUL_US      = 8'd96; // adj_undersqrt = conj(1/(2d)) (x) adj_d
    localparam R_D_MUL_US_WAIT = 8'd97;
    localparam R_UNDERSQRT     = 8'd98; // adj_term1 (holomorphic via 2*term1), adj_xi_sq
    localparam R_TERM1SQ_MUL   = 8'd99; // adj_term1 += conj(2*term1) (x) adj_undersqrt
    localparam R_TERM1SQ_MUL_WAIT = 8'd100;
    localparam R_TERM1         = 8'd101; // adj_kappa, adj_rho_xi
    localparam R_XISQ          = 8'd102; // adj_xi from adj_xi_sq (accumulated)
    localparam R_RHOXI         = 8'd103; // adj_rho, adj_xi from adj_rho_xi
    localparam R_FINISH        = 8'd104;
    localparam R_PHI_NORM      = 8'd105; // normalize adj_exponent (see R_PHI)

    reg [7:0] state;

    // Working registers — all complex (real, imag pairs)
    reg signed [WL-1:0] rho_xi_val;     // rho * xi (real scalar)
    reg signed [WL-1:0] xi_sq;          // xi² (real scalar)

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

    // D-term intermediates: nxi2 = num/xi^2 (complex/real), dr = (1-edT)/(1-g*edT)
    reg signed [WL-1:0] nxi2_r, nxi2_i;
    reg signed [WL-1:0] ome_r, ome_i;       // 1 - exp(-dT)
    reg signed [WL-1:0] dr_r, dr_i;         // D_ratio
    reg signed [WL-1:0] kth_xi2;            // kappa*theta/xi^2
    reg signed [WL-1:0] numT_r, numT_i;     // num*T (real & imag), reused by C_r/C_i
    reg signed [WL-1:0] r_u_T_val;          // r*u*T

    reg signed [2*WL-1:0] wp1, wp2, wp3, wp4; // Wide product temps

    reg signed [2*WL-1:0] xi2_u2, kt, ruT;

    wire signed [WL-1:0] ONE = q60(64'sh1000000000000000);

    // ---- Reverse-mode adjoint accumulators ----
    reg signed [WL-1:0] a_exponent_r, a_exponent_i;
    reg signed [WL-1:0] a_C_r, a_C_i;
    reg signed [WL-1:0] a_Dv0_r, a_Dv0_i;
    reg signed [WL-1:0] a_iuximag;
    reg signed [WL-1:0] a_D_r, a_D_i;
    reg signed [WL-1:0] a_nxi2_r, a_nxi2_i;
    reg signed [WL-1:0] a_Dratio_r, a_Dratio_i;
    reg signed [WL-1:0] a_ome_r, a_ome_i;
    reg signed [WL-1:0] a_omge_r, a_omge_i;      // accumulator (2 contributions)
    reg signed [WL-1:0] a_num_r, a_num_i;        // accumulator (3 contributions)
    reg signed [WL-1:0] a_kth_xi2;
    reg signed [WL-1:0] a_p;                     // kappa*theta
    reg signed [WL-1:0] a_r_u_T;
    reg signed [WL-1:0] a_numT_r, a_numT_i;
    reg signed [WL-1:0] a_bracket_r, a_bracket_i;
    reg signed [WL-1:0] a_logratio_r, a_logratio_i;
    reg signed [WL-1:0] a_ratio_r, a_ratio_i;
    reg signed [WL-1:0] a_omg_r, a_omg_i;
    reg signed [WL-1:0] a_g_r, a_g_i;            // accumulator (2 contributions)
    reg signed [WL-1:0] a_gexp_r, a_gexp_i;
    reg signed [WL-1:0] a_edT_r, a_edT_i;        // accumulator (2 contributions)
    reg signed [WL-1:0] a_negdT_r, a_negdT_i;
    reg signed [WL-1:0] a_d_r, a_d_i;            // accumulator (2 contributions)
    reg signed [WL-1:0] a_den_r, a_den_i;
    reg signed [WL-1:0] a_term1_r, a_term1_i;
    reg signed [WL-1:0] a_xi_sq;                 // accumulator (3 contributions)
    reg signed [WL-1:0] a_rho_xi;
    reg signed [WL-1:0] a_undersqrt_r, a_undersqrt_i;

    reg signed [WL-1:0] inv_xi_sq;

    // Adjoint normalization (see R_PHI): the whole reverse sweep is linear
    // in adj_exponent, so it is run on adj_exponent * 2^adj_shift and every
    // leaf adjoint is shifted back down by adj_shift in R_FINISH.
    reg signed [2*WL-1:0] wn_r, wn_i;
    reg        [2*WL-1:0] wn_abs;
    reg        [7:0]      adj_shift;
    integer               nb, npos;

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

    // Complex div (shared by both forward and reverse passes)
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

    // Complex mult (shared by both forward and reverse passes)
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

    // Real divider (shared: kappa*theta/xi^2 in forward; 1/xi_sq in reverse)
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
        end else begin
            csqrt_start <= 1'b0;
            cdiv_start  <= 1'b0;
            cexp_start  <= 1'b0;
            cmul_valid  <= 1'b0;
            clog_start  <= 1'b0;
            fdiv_start  <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        state <= S_RHO_XI;
                    end
                end

                // ---- Step 1: rho * xi ----
                S_RHO_XI: begin
                    wp1 = $signed(rho_in) * $signed(xi_in);
                    rho_xi_val <= rshr(wp1);

                    wp2 = $signed(xi_in) * $signed(xi_in);
                    xi_sq <= rshr(wp2);

                    state <= S_TERM1;
                end

                // ---- Step 2: term1 = -kappa + i*(rho*xi*u) ----
                S_TERM1: begin
                    term1_r <= -kappa_in;
                    wp1 = $signed(rho_xi_val) * $signed(u_in);
                    term1_i <= rshr(wp1);
                    state <= S_TERM1_SQ;
                end

                // ---- Step 3: term1² = (t1r² - t1i²) + i*(2*t1r*t1i) ----
                S_TERM1_SQ: begin
                    wp1 = $signed(term1_r) * $signed(term1_r);
                    wp2 = $signed(term1_i) * $signed(term1_i);
                    wp3 = $signed(term1_r) * $signed(term1_i);

                    wp4 = $signed(xi_sq) * $signed(u_in);
                    xi2_u2 = (rshr(wp4)) * $signed(u_in);  // xi²*u²

                    under_sqrt_r <= (rshr((wp1 - wp2))) + (rshr(xi2_u2));
                    under_sqrt_i <= (2 * (rshr(wp3))) + (rshr(wp4)); // +xi²*u
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
                    cexp_a_r <= rshr(wp1);
                    cexp_a_i <= rshr(wp2);
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
                S_C_D: begin
                    kt = $signed(kappa_in) * $signed(theta_in);
                    fdiv_a <= rshr(kt);
                    fdiv_b <= xi_sq;
                    fdiv_start <= 1'b1;

                    wp1 = $signed(num_r) * $signed(T_in);
                    wp2 = $signed(num_i) * $signed(T_in);
                    numT_r <= rshr(wp1);
                    numT_i <= rshr(wp2);

                    ruT = $signed(r_in) * $signed(u_in);
                    r_u_T_val <= rshr(rshr(ruT) * $signed(T_in));
                    C_i  <= rshr(rshr(ruT) * $signed(T_in)); // r*u*T (D_i term added below)

                    state <= S_KTH_XI2_WAIT;
                end

                S_KTH_XI2_WAIT: begin
                    if (fdiv_ready) begin
                        kth_xi2 <= fdiv_result;
                        state <= S_KTH_XI2;
                    end
                end

                S_KTH_XI2: begin
                    wp1 = $signed(kth_xi2) * (numT_r - (log_ratio_r <<< 1));
                    wp2 = $signed(kth_xi2) * (numT_i - (log_ratio_i <<< 1));
                    C_r <= rshr(wp1);
                    C_i <= C_i + (rshr(wp2));

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

                    cexp_a_r <= C_r + (rshr(wp1));
                    cexp_a_i <= C_i + (rshr(wp2)) + (rshr(wp3));
                    cexp_start <= 1'b1;
                    state <= S_WAIT_PHI;
                end

                // ---- Step 13: phi = exp(exponent) ----
                S_WAIT_PHI: begin
                    if (cexp_done) begin
                        phi_r <= cexp_res_r;
                        phi_i <= cexp_res_i;
                        if (fwd_only) begin
                            adj_shift <= 0;
                            adj_T <= 0; adj_r <= 0; adj_v0 <= 0; adj_kappa <= 0;
                            adj_theta <= 0; adj_xi <= 0; adj_rho <= 0; adj_x <= 0;
                            state <= R_FINISH;
                        end else begin
                            state <= R_INIT;
                        end
                    end
                end

                // ==========================================================
                // REVERSE-MODE AAD — strict reverse-topological order
                // ==========================================================
                R_INIT: begin
                    a_omge_r <= 0; a_omge_i <= 0;
                    a_num_r  <= 0; a_num_i  <= 0;
                    a_g_r    <= 0; a_g_i    <= 0;
                    a_edT_r  <= 0; a_edT_i  <= 0;
                    a_d_r    <= 0; a_d_i    <= 0;
                    a_xi_sq  <= 0;
                    // Leaf adjoints: zeroed here and only ever accumulated
                    // into (+=) below, rather than relying on whichever
                    // reverse state happens to touch each one first also
                    // being written as a plain overwrite — that ordering
                    // dependency is easy to break by accident when editing
                    // this FSM later.
                    adj_T <= 0; adj_r <= 0; adj_v0 <= 0; adj_kappa <= 0;
                    adj_theta <= 0; adj_xi <= 0; adj_rho <= 0; adj_x <= 0;
                    fdiv_a <= ONE; fdiv_b <= xi_sq; fdiv_start <= 1'b1;
                    state <= R_INV_XISQ_WAIT;
                end

                R_INV_XISQ_WAIT: begin
                    if (fdiv_ready) begin
                        inv_xi_sq <= fdiv_result;
                        state <= R_PHI;
                    end
                end

                // adj_exponent = conj(phi) (x) seed, kept at 2*FL fractional
                // bits (not truncated to FL yet).
                //
                // At high COS frequencies |phi| ~ 1e-5, so adj_exponent is
                // only a few hundred ULPs in magnitude; truncating it (and
                // everything downstream of it) at FL and then multiplying by
                // local partials of size |u_k| ~ 10^2 lost most of its
                // significant bits -- the dominant remaining error in
                // dV/drho. Instead the sweep runs on a copy normalized to
                // magnitude ~1 (R_PHI_NORM) and is scaled back in R_FINISH.
                R_PHI: begin
                    wn_r <= $signed(phi_r) * $signed(seed_r) + $signed(phi_i) * $signed(seed_i);
                    wn_i <= $signed(phi_r) * $signed(seed_i) - $signed(phi_i) * $signed(seed_r);
                    state <= R_PHI_NORM;
                end
                R_PHI_NORM: begin
                    wn_abs = (wn_r[2*WL-1] ? -wn_r : wn_r) | (wn_i[2*WL-1] ? -wn_i : wn_i);
                    npos = 0;
                    for (nb = 0; nb < 2*WL; nb = nb + 1)
                        if (wn_abs[nb]) npos = nb;
                    // leading one at bit 2*FL  <=>  magnitude in [1, 2)
                    if (npos >= 2*FL) begin
                        adj_shift    <= 0;
                        a_exponent_r <= rshr(wn_r);
                        a_exponent_i <= rshr(wn_i);
                    end else if (npos >= FL) begin
                        adj_shift    <= 2*FL - npos;
                        a_exponent_r <= wn_r >>> (npos - FL);
                        a_exponent_i <= wn_i >>> (npos - FL);
                    end else begin               // below one ULP: max gain
                        adj_shift    <= FL;
                        a_exponent_r <= wn_r;
                        a_exponent_i <= wn_i;
                    end
                    state <= R_EXPONENT;
                end

                // exponent = C + Dv0 + (0,iuximag): fan out unchanged
                R_EXPONENT: begin
                    a_C_r   <= a_exponent_r;
                    a_C_i   <= a_exponent_i;
                    a_Dv0_r <= a_exponent_r;
                    a_Dv0_i <= a_exponent_i;
                    a_iuximag <= a_exponent_i;
                    state <= R_DV0_X;
                end

                // Dv0 = D*v0 ; iuximag = x*u
                R_DV0_X: begin
                    wp1 = $signed(a_Dv0_r) * $signed(v0_in);
                    a_D_r <= rshr(wp1);
                    wp2 = $signed(a_Dv0_i) * $signed(v0_in);
                    a_D_i <= rshr(wp2);
                    wp3 = $signed(a_Dv0_r) * $signed(D_r);
                    wp4 = $signed(a_Dv0_i) * $signed(D_i);
                    adj_v0 <= adj_v0 + (rshr(wp3)) + (rshr(wp4));
                    wp1 = $signed(a_iuximag) * $signed(u_in);
                    adj_x <= adj_x + (rshr(wp1));
                    state <= R_D_MUL;
                end

                // D = nxi2 * Dratio (holomorphic): adj_nxi2 = conj(Dratio)(x)adj_D
                R_D_MUL: begin
                    cmul_a_r <= dr_r; cmul_a_i <= -dr_i;
                    cmul_b_r <= a_D_r; cmul_b_i <= a_D_i;
                    cmul_valid <= 1'b1;
                    state <= R_D_MUL_WAIT;
                end
                R_D_MUL_WAIT: begin
                    if (cmul_valid_out) begin
                        a_nxi2_r <= cmul_res_r; a_nxi2_i <= cmul_res_i;
                        state <= R_D_MUL2;
                    end
                end

                // adj_Dratio = conj(nxi2) (x) adj_D
                R_D_MUL2: begin
                    cmul_a_r <= nxi2_r; cmul_a_i <= -nxi2_i;
                    cmul_b_r <= a_D_r; cmul_b_i <= a_D_i;
                    cmul_valid <= 1'b1;
                    state <= R_D_MUL2_WAIT;
                end
                R_D_MUL2_WAIT: begin
                    if (cmul_valid_out) begin
                        a_Dratio_r <= cmul_res_r; a_Dratio_i <= cmul_res_i;
                        state <= R_DRATIO_INV;
                    end
                end

                // Dratio = ome/omge (holomorphic): need 1/omge and Dratio/omge
                R_DRATIO_INV: begin
                    cdiv_a_r <= ONE; cdiv_a_i <= 0;
                    cdiv_b_r <= omge_r; cdiv_b_i <= omge_i;
                    cdiv_start <= 1'b1;
                    state <= R_DRATIO_INV_WAIT;
                end
                R_DRATIO_INV_WAIT: begin
                    if (cdiv_done) begin
                        // stash 1/omge in cmul-ready form via cdiv_res; use immediately
                        cmul_a_r <= cdiv_res_r; cmul_a_i <= -cdiv_res_i;
                        cmul_b_r <= a_Dratio_r; cmul_b_i <= a_Dratio_i;
                        cmul_valid <= 1'b1;
                        state <= R_DRATIO_MUL1_WAIT;
                    end
                end
                R_DRATIO_MUL1_WAIT: begin
                    if (cmul_valid_out) begin
                        a_ome_r <= cmul_res_r; a_ome_i <= cmul_res_i;
                        state <= R_DRATIO_RATIO;
                    end
                end

                R_DRATIO_RATIO: begin
                    cdiv_a_r <= dr_r; cdiv_a_i <= dr_i;
                    cdiv_b_r <= omge_r; cdiv_b_i <= omge_i;
                    cdiv_start <= 1'b1;
                    state <= R_DRATIO_RATIO_WAIT;
                end
                R_DRATIO_RATIO_WAIT: begin
                    if (cdiv_done) begin
                        // local deriv = -(Dratio/omge); conj = -(cdiv_res_r) + i*cdiv_res_i
                        cmul_a_r <= -cdiv_res_r; cmul_a_i <= cdiv_res_i;
                        cmul_b_r <= a_Dratio_r; cmul_b_i <= a_Dratio_i;
                        cmul_valid <= 1'b1;
                        state <= R_DRATIO_MUL2_WAIT;
                    end
                end
                R_DRATIO_MUL2_WAIT: begin
                    if (cmul_valid_out) begin
                        a_omge_r <= a_omge_r + cmul_res_r;
                        a_omge_i <= a_omge_i + cmul_res_i;
                        state <= R_OME;
                    end
                end

                // ome = 1 - edT  =>  adj_edT += -adj_ome
                R_OME: begin
                    a_edT_r <= a_edT_r - a_ome_r;
                    a_edT_i <= a_edT_i - a_ome_i;
                    state <= R_NXI2;
                end

                // nxi2 = num/xi_sq (complex/real): adj_num += adj_nxi2*inv_xi_sq
                //   adj_xi_sq += -(adj_nxi2.num)*inv_xi_sq
                R_NXI2: begin
                    wp1 = $signed(a_nxi2_r) * $signed(inv_xi_sq);
                    a_num_r <= a_num_r + (rshr(wp1));
                    wp2 = $signed(a_nxi2_i) * $signed(inv_xi_sq);
                    a_num_i <= a_num_i + (rshr(wp2));
                    wp3 = $signed(a_nxi2_r) * $signed(nxi2_r);
                    wp4 = $signed(a_nxi2_i) * $signed(nxi2_i);
                    wp1 = ((rshr(wp3)) + (rshr(wp4))) * $signed(inv_xi_sq);
                    a_xi_sq <= a_xi_sq - (rshr(wp1));
                    state <= R_CFUNC;
                end

                // C_r = Cfunc_r ; C_i = r_u_T + Cfunc_i
                //   => adj_Cfunc_r = a_C_r ; adj_Cfunc_i = a_C_i ; a_r_u_T = a_C_i
                // Cfunc = kth_xi2 * bracket
                //   => adj_bracket = kth_xi2 * adj_Cfunc (real scalar times complex)
                //      adj_kth_xi2 = adj_Cfunc_r*bracket_r + adj_Cfunc_i*bracket_i
                R_CFUNC: begin
                    a_r_u_T <= a_C_i;
                    wp1 = $signed(kth_xi2) * $signed(a_C_r);
                    a_bracket_r <= rshr(wp1);
                    wp2 = $signed(kth_xi2) * $signed(a_C_i);
                    a_bracket_i <= rshr(wp2);
                    wp3 = $signed(a_C_r) * (numT_r - (log_ratio_r <<< 1));
                    wp4 = $signed(a_C_i) * (numT_i - (log_ratio_i <<< 1));
                    a_kth_xi2 <= (rshr(wp3)) + (rshr(wp4));
                    state <= R_BRACKET;
                end

                // bracket = numT - 2*log_ratio => adj_numT=adj_bracket ; adj_logratio = -2*adj_bracket
                R_BRACKET: begin
                    a_numT_r <= a_bracket_r;
                    a_numT_i <= a_bracket_i;
                    a_logratio_r <= -(a_bracket_r <<< 1);
                    a_logratio_i <= -(a_bracket_i <<< 1);
                    state <= R_NUMT;
                end

                // numT = num*T (complex x real): adj_num += adj_numT*T
                //   adj_T += adj_numT.num (dot)
                R_NUMT: begin
                    wp1 = $signed(a_numT_r) * $signed(T_in);
                    a_num_r <= a_num_r + (rshr(wp1));
                    wp2 = $signed(a_numT_i) * $signed(T_in);
                    a_num_i <= a_num_i + (rshr(wp2));
                    wp3 = $signed(a_numT_r) * $signed(num_r);
                    wp4 = $signed(a_numT_i) * $signed(num_i);
                    adj_T <= adj_T + (rshr(wp3)) + (rshr(wp4));
                    state <= R_P_RUT;
                end

                // r_u_T = u*r*T => adj_r += a_r_u_T*u*T ; adj_T += a_r_u_T*u*r (accumulate onto R_NUMT's adj_T)
                // kth_xi2 = p/xi_sq (p=kappa*theta): adj_p = a_kth_xi2*inv_xi_sq
                //   adj_xi_sq -= a_kth_xi2*kth_xi2*inv_xi_sq
                //   adj_kappa = adj_p*theta ; adj_theta = adj_p*kappa
                R_P_RUT: begin
                    wp1 = $signed(a_r_u_T) * $signed(u_in);
                    wp1 = (rshr(wp1)) * $signed(r_in);
                    adj_T <= adj_T + (rshr(wp1));
                    wp2 = $signed(a_r_u_T) * $signed(u_in);
                    wp2 = (rshr(wp2)) * $signed(T_in);
                    adj_r <= adj_r + (rshr(wp2));

                    wp3 = $signed(a_kth_xi2) * $signed(inv_xi_sq);
                    a_p <= rshr(wp3);
                    wp4 = $signed(a_kth_xi2) * $signed(kth_xi2);
                    wp4 = (rshr(wp4)) * $signed(inv_xi_sq);
                    a_xi_sq <= a_xi_sq - (rshr(wp4));

                    state <= R_LOGRATIO_INV;
                end

                // ---- kappa/theta from a_p, deferred one cycle so a_p is stable ----
                // (folded into R_LOGRATIO_INV below)

                // log_ratio = log(ratio), f'=1/ratio
                R_LOGRATIO_INV: begin
                    wp1 = $signed(a_p) * $signed(theta_in);
                    adj_kappa <= adj_kappa + (rshr(wp1));
                    wp2 = $signed(a_p) * $signed(kappa_in);
                    adj_theta <= adj_theta + (rshr(wp2));

                    cdiv_a_r <= ONE; cdiv_a_i <= 0;
                    cdiv_b_r <= ratio_r; cdiv_b_i <= ratio_i;
                    cdiv_start <= 1'b1;
                    state <= R_LOGRATIO_INV_WAIT;
                end
                R_LOGRATIO_INV_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= cdiv_res_r; cmul_a_i <= -cdiv_res_i;
                        cmul_b_r <= a_logratio_r; cmul_b_i <= a_logratio_i;
                        cmul_valid <= 1'b1;
                        state <= R_LOGRATIO_MUL_WAIT;
                    end
                end
                R_LOGRATIO_MUL_WAIT: begin
                    if (cmul_valid_out) begin
                        a_ratio_r <= cmul_res_r; a_ratio_i <= cmul_res_i;
                        state <= R_RATIO_INV;
                    end
                end

                // ratio = omge/omg (holomorphic): need 1/omg and ratio/omg
                R_RATIO_INV: begin
                    cdiv_a_r <= ONE; cdiv_a_i <= 0;
                    cdiv_b_r <= omg_r; cdiv_b_i <= omg_i;
                    cdiv_start <= 1'b1;
                    state <= R_RATIO_INV_WAIT;
                end
                R_RATIO_INV_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= cdiv_res_r; cmul_a_i <= -cdiv_res_i;
                        cmul_b_r <= a_ratio_r; cmul_b_i <= a_ratio_i;
                        cmul_valid <= 1'b1;
                        state <= R_RATIO_MUL1_WAIT;
                    end
                end
                R_RATIO_MUL1_WAIT: begin
                    if (cmul_valid_out) begin
                        a_omge_r <= a_omge_r + cmul_res_r;
                        a_omge_i <= a_omge_i + cmul_res_i;
                        state <= R_RATIO_RATIO;
                    end
                end
                R_RATIO_RATIO: begin
                    cdiv_a_r <= ratio_r; cdiv_a_i <= ratio_i;
                    cdiv_b_r <= omg_r; cdiv_b_i <= omg_i;
                    cdiv_start <= 1'b1;
                    state <= R_RATIO_RATIO_WAIT;
                end
                R_RATIO_RATIO_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= -cdiv_res_r; cmul_a_i <= cdiv_res_i;
                        cmul_b_r <= a_ratio_r; cmul_b_i <= a_ratio_i;
                        cmul_valid <= 1'b1;
                        state <= R_RATIO_MUL2_WAIT;
                    end
                end
                R_RATIO_MUL2_WAIT: begin
                    if (cmul_valid_out) begin
                        a_omg_r <= cmul_res_r; a_omg_i <= cmul_res_i;
                        state <= R_OMGE_OMG;
                    end
                end

                // omge = 1-g_exp => adj_gexp = -adj_omge ; omg = 1-g => adj_g += -adj_omg
                R_OMGE_OMG: begin
                    a_gexp_r <= -a_omge_r;
                    a_gexp_i <= -a_omge_i;
                    a_g_r <= a_g_r - a_omg_r;
                    a_g_i <= a_g_i - a_omg_i;
                    state <= R_GEDT_MUL1;
                end

                // g_exp = g*edT (holomorphic mult): adj_g += conj(edT)(x)adj_gexp
                R_GEDT_MUL1: begin
                    cmul_a_r <= edT_r; cmul_a_i <= -edT_i;
                    cmul_b_r <= a_gexp_r; cmul_b_i <= a_gexp_i;
                    cmul_valid <= 1'b1;
                    state <= R_GEDT_MUL1_WAIT;
                end
                R_GEDT_MUL1_WAIT: begin
                    if (cmul_valid_out) begin
                        a_g_r <= a_g_r + cmul_res_r;
                        a_g_i <= a_g_i + cmul_res_i;
                        state <= R_GEDT_MUL2;
                    end
                end

                // adj_edT += conj(g)(x)adj_gexp
                R_GEDT_MUL2: begin
                    cmul_a_r <= g_r; cmul_a_i <= -g_i;
                    cmul_b_r <= a_gexp_r; cmul_b_i <= a_gexp_i;
                    cmul_valid <= 1'b1;
                    state <= R_GEDT_MUL2_WAIT;
                end
                R_GEDT_MUL2_WAIT: begin
                    if (cmul_valid_out) begin
                        a_edT_r <= a_edT_r + cmul_res_r;
                        a_edT_i <= a_edT_i + cmul_res_i;
                        state <= R_EDT_MUL;
                    end
                end

                // edT = exp(negdT) (holomorphic, f'=edT): adj_negdT = conj(edT)(x)adj_edT
                R_EDT_MUL: begin
                    cmul_a_r <= edT_r; cmul_a_i <= -edT_i;
                    cmul_b_r <= a_edT_r; cmul_b_i <= a_edT_i;
                    cmul_valid <= 1'b1;
                    state <= R_EDT_MUL_WAIT;
                end
                R_EDT_MUL_WAIT: begin
                    if (cmul_valid_out) begin
                        a_negdT_r <= cmul_res_r; a_negdT_i <= cmul_res_i;
                        state <= R_NEGDT;
                    end
                end

                // negdT = -d*T : adj_d += -adj_negdT*T ; adj_T += -(adj_negdT.d)
                R_NEGDT: begin
                    wp1 = -$signed(a_negdT_r) * $signed(T_in);
                    a_d_r <= a_d_r + (rshr(wp1));
                    wp2 = -$signed(a_negdT_i) * $signed(T_in);
                    a_d_i <= a_d_i + (rshr(wp2));
                    wp3 = -$signed(a_negdT_r) * $signed(d_r);
                    wp4 = -$signed(a_negdT_i) * $signed(d_i);
                    adj_T <= adj_T + (rshr(wp3)) + (rshr(wp4));
                    state <= R_G_INV;
                end

                // g = num/den (holomorphic): need 1/den and g/den
                R_G_INV: begin
                    cdiv_a_r <= ONE; cdiv_a_i <= 0;
                    cdiv_b_r <= den_r; cdiv_b_i <= den_i;
                    cdiv_start <= 1'b1;
                    state <= R_G_INV_WAIT;
                end
                R_G_INV_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= cdiv_res_r; cmul_a_i <= -cdiv_res_i;
                        cmul_b_r <= a_g_r; cmul_b_i <= a_g_i;
                        cmul_valid <= 1'b1;
                        state <= R_G_MUL1_WAIT;
                    end
                end
                R_G_MUL1_WAIT: begin
                    if (cmul_valid_out) begin
                        a_num_r <= a_num_r + cmul_res_r;
                        a_num_i <= a_num_i + cmul_res_i;
                        state <= R_G_RATIO;
                    end
                end
                R_G_RATIO: begin
                    cdiv_a_r <= g_r; cdiv_a_i <= g_i;
                    cdiv_b_r <= den_r; cdiv_b_i <= den_i;
                    cdiv_start <= 1'b1;
                    state <= R_G_RATIO_WAIT;
                end
                R_G_RATIO_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= -cdiv_res_r; cmul_a_i <= cdiv_res_i;
                        cmul_b_r <= a_g_r; cmul_b_i <= a_g_i;
                        cmul_valid <= 1'b1;
                        state <= R_G_MUL2_WAIT;
                    end
                end
                R_G_MUL2_WAIT: begin
                    if (cmul_valid_out) begin
                        a_den_r <= cmul_res_r; a_den_i <= cmul_res_i;
                        state <= R_NUMDEN;
                    end
                end

                // num_r=kappa-d_r ; num_i=-term1_i-d_i ; den_r=kappa+d_r ; den_i=-term1_i+d_i
                R_NUMDEN: begin
                    adj_kappa <= adj_kappa + a_num_r + a_den_r;
                    a_term1_i <= -(a_num_i + a_den_i);
                    a_d_r <= a_d_r + (a_den_r - a_num_r);
                    a_d_i <= a_d_i + (a_den_i - a_num_i);
                    state <= R_D_INV;
                end

                // d = sqrt(under_sqrt) (holomorphic, f'=1/(2d))
                R_D_INV: begin
                    cdiv_a_r <= ONE; cdiv_a_i <= 0;
                    cdiv_b_r <= d_r <<< 1; cdiv_b_i <= d_i <<< 1;
                    cdiv_start <= 1'b1;
                    state <= R_D_INV_WAIT;
                end
                R_D_INV_WAIT: begin
                    if (cdiv_done) begin
                        cmul_a_r <= cdiv_res_r; cmul_a_i <= -cdiv_res_i;
                        cmul_b_r <= a_d_r; cmul_b_i <= a_d_i;
                        cmul_valid <= 1'b1;
                        state <= R_D_MUL_US_WAIT;
                    end
                end
                R_D_MUL_US_WAIT: begin
                    if (cmul_valid_out) begin
                        a_undersqrt_r <= cmul_res_r;
                        a_undersqrt_i <= cmul_res_i;
                        state <= R_UNDERSQRT;
                    end
                end

                // under_sqrt_r = t1_sq_r + xi_sq*u^2 ; under_sqrt_i = t1_sq_i + xi_sq*u
                //   => adj_xi_sq += adj_us_r*u^2 + adj_us_i*u
                R_UNDERSQRT: begin
                    wp3 = $signed(u_in) * $signed(u_in);
                    wp1 = $signed(a_undersqrt_r) * (rshr(wp3));
                    wp2 = $signed(a_undersqrt_i) * $signed(u_in);
                    a_xi_sq <= a_xi_sq + (rshr(wp1)) + (rshr(wp2));
                    state <= R_TERM1SQ_MUL;
                end

                // term1^2 (holomorphic, f'=2*term1): adj_term1 += conj(2term1)(x)adj_us
                R_TERM1SQ_MUL: begin
                    cmul_a_r <= term1_r <<< 1; cmul_a_i <= -(term1_i <<< 1);
                    cmul_b_r <= a_undersqrt_r; cmul_b_i <= a_undersqrt_i;
                    cmul_valid <= 1'b1;
                    state <= R_TERM1SQ_MUL_WAIT;
                end
                R_TERM1SQ_MUL_WAIT: begin
                    if (cmul_valid_out) begin
                        a_term1_r <= cmul_res_r;
                        a_term1_i <= a_term1_i + cmul_res_i;
                        state <= R_TERM1;
                    end
                end

                // term1_r=-kappa ; term1_i=rho_xi*u
                R_TERM1: begin
                    adj_kappa <= adj_kappa - a_term1_r;
                    wp1 = $signed(a_term1_i) * $signed(u_in);
                    a_rho_xi <= rshr(wp1);
                    state <= R_XISQ;
                end

                // xi_sq = xi*xi => adj_xi(part1) = 2*xi*adj_xi_sq
                R_XISQ: begin
                    wp1 = $signed(a_xi_sq) * ($signed(xi_in) <<< 1);
                    adj_xi <= adj_xi + (rshr(wp1));
                    state <= R_RHOXI;
                end

                // rho_xi = rho*xi => adj_rho = a_rho_xi*xi ; adj_xi += a_rho_xi*rho
                R_RHOXI: begin
                    wp1 = $signed(a_rho_xi) * $signed(xi_in);
                    adj_rho <= adj_rho + (rshr(wp1));
                    wp2 = $signed(a_rho_xi) * $signed(rho_in);
                    adj_xi <= adj_xi + (rshr(wp2));
                    state <= R_FINISH;
                end

                R_FINISH: begin
                    if (adj_shift != 0) begin
                        adj_T     <= (adj_T     + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_r     <= (adj_r     + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_v0    <= (adj_v0    + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_kappa <= (adj_kappa + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_theta <= (adj_theta + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_xi    <= (adj_xi    + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_rho   <= (adj_rho   + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                        adj_x     <= (adj_x     + (64'sd1 <<< (adj_shift - 1))) >>> adj_shift;
                    end
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
