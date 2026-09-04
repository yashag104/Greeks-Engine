`timescale 1ns / 1ps
//============================================================================
// Heston-COS Forward Engine — Main Summation Loop
//============================================================================
// Computes the Heston-COS call/put price: domain truncation [a,b], then
// iterates k = 0..N_TERMS-1 accumulating F_k * V_k, then discounts by
// exp(-rT). Direct RTL port of hardware/matlab/heston_cos_forward_core.m's
// price computation (see heston_payoff_coeff.v for the chi/psi algebra and
// heston_char_func.v for phi(u)).
//
// This module's own arithmetic runs at WL=32/FL=16; heston_char_func runs
// at a wider WL=64/FL=32 internally for precision, so parameters, x and
// u_k are converted Q16.16 -> Q32.32 (a left-shift by FL2-FL1=16 bits) on
// the way in, and phi_r/phi_i are converted back (a right-shift by the
// same 16 bits) on the way out.
//============================================================================

module heston_cos_forward #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,

    // Model parameters
    input  wire signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho,
    input  wire              is_call,
    input  wire              start,

    // Result
    output reg  signed [WL-1:0] price,
    output reg               done,

    // Tape write interface (not used — see heston_reverse_pass.v, which
    // computes Greeks by bump-and-reprice against this forward pricer
    // rather than a generic AAD sweep; kept for interface stability).
    output reg               tape_we,
    output reg  [15:0]       tape_addr,
    output reg  signed [WL-1:0] tape_data_val,
    output reg  signed [WL-1:0] tape_data_partial
);

    localparam N_TERMS = 128;
    localparam WL2 = 64, FL2 = 32; // heston_char_func's internal precision

    localparam signed [WL-1:0] ONE_C  = (FL<=16) ? (32'sd1<<<FL) : (32'sd1<<<16)<<<(FL-16);
    localparam signed [WL-1:0] HALF_C = ONE_C >>> 1;
    localparam signed [WL-1:0] TEN_C  = ONE_C * 10;
    localparam signed [WL-1:0] TWO_C  = ONE_C <<< 1;
    // pi, in Q(.,FL)
    localparam signed [WL-1:0] PI_C = (FL<=16)
        ? $signed($rtoi(3.14159265358979323846 * (2.0**FL)))
        : $signed($rtoi(3.14159265358979323846 * (2.0**16))) <<< (FL-16);
    // CORDIC gain compensation (see cordic.v / complex_exp.v)
    localparam signed [WL-1:0] CORDIC_1_OVER_K = (FL<=16)
        ? $signed($rtoi(0.6072529350088814 * (2.0**FL)))
        : $signed($rtoi(0.6072529350088814 * (2.0**16))) <<< (FL-16);
    // Minimum positive c2 (true reference clamps at 1e-8, unrepresentable
    // at Q16.16 resolution ~1.5e-5 — clamp to the smallest positive step).
    localparam signed [WL-1:0] MIN_C2 = 32'sd1;

    // FSM States
    localparam S_IDLE         = 6'd0;
    localparam S_X_DIV        = 6'd1;
    localparam S_X_DIV_WAIT   = 6'd2;
    localparam S_X_LOG        = 6'd3;
    localparam S_X_LOG_WAIT   = 6'd4;
    localparam S_NEG_KT       = 6'd5;
    localparam S_NEG_KT_WAIT  = 6'd6;
    localparam S_C1B_DIV      = 6'd7;
    localparam S_C1B_DIV_WAIT = 6'd8;
    localparam S_C1_COMBINE   = 6'd9;
    localparam S_C2           = 6'd10;
    localparam S_SQRT_C2      = 6'd11;
    localparam S_SQRT_C2_WAIT = 6'd12;
    localparam S_AB           = 6'd13;
    localparam S_INV_BMA      = 6'd14;
    localparam S_INV_BMA_WAIT = 6'd15;
    localparam S_SCALARS      = 6'd16;
    localparam S_EXP_A        = 6'd17;
    localparam S_EXP_A_WAIT   = 6'd18;
    localparam S_EXP_B        = 6'd19;
    localparam S_EXP_B_WAIT   = 6'd20;
    localparam S_LOOP_START   = 6'd21;
    localparam S_ANGLE        = 6'd22;
    localparam S_CORDIC_WAIT  = 6'd23;
    localparam S_CHAR_START   = 6'd24;
    localparam S_CHAR_WAIT    = 6'd25;
    localparam S_PAYOFF_START = 6'd26;
    localparam S_PAYOFF_WAIT  = 6'd27;
    localparam S_ACCUM        = 6'd28;
    localparam S_DISC         = 6'd29;
    localparam S_DISC_WAIT    = 6'd30;
    localparam S_FINISH       = 6'd31;

    reg [5:0] state;
    reg [7:0] k_counter;
    reg is_call_r;

    reg signed [47:0] accumulator; // Extra bits for accumulation
    reg signed [2*WL-1:0] wp1, wp2, wp3;
    reg signed [WL+48-1:0] wp_price; // wide enough for discount(WL) * accumulator(48)

    reg signed [WL-1:0] x_val, exp_negkT, term_c1b, c1_val, c2_val, sqrt_c2;
    reg signed [WL-1:0] a_val, b_val, bma_val, inv_bma, pi_over_bma, two_K_over_bma;
    reg signed [WL-1:0] exp_a_val, exp_b_val;
    reg signed [WL-1:0] u_k, angle, cos_ua, sin_ua;
    reg signed [WL-1:0] phi_r32, phi_i32;
    reg signed [WL-1:0] F_k;
    reg signed [WL-1:0] contrib;
    // Scratch for S_C2/S_AB: computed via blocking assignment as plain
    // WL-bit *signed* regs, rather than combined into further arithmetic
    // directly as `wide_wire[WL-1:0]` — a raw part-select is always
    // unsigned per the LRM even of a signed vector, which would silently
    // force any surrounding +/-/< expression unsigned too (wrong whenever
    // the other operand, e.g. c1_val, is negative).
    reg signed [WL-1:0] c2_raw, ten_sqrt_c2;

    // ==================================================================
    // Shared sub-modules
    // ==================================================================
    reg                   div_start;
    reg  [WL-1:0]         div_a, div_b;
    wire [WL-1:0]         div_result;
    wire                  div_ready;
    fp_div #(.WL(WL), .FL(FL)) div_inst (
        .clk(clk), .rst(rst), .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready), .divide_by_zero(), .overflow()
    );

    reg                   log_start;
    reg  [WL-1:0]         log_x;
    wire signed [WL-1:0]  log_result;
    wire                  log_done;
    fp_log #(.WL(WL), .FL(FL)) log_inst (
        .clk(clk), .rst(rst), .x(log_x), .start(log_start),
        .result(log_result), .done(log_done), .err_nonpositive()
    );

    reg                   exp_start;
    reg  signed [WL-1:0]  exp_x;
    wire [WL-1:0]         exp_result;
    wire                  exp_done;
    fp_exp #(.WL(WL), .FL(FL)) exp_inst (
        .clk(clk), .rst(rst), .x(exp_x), .start(exp_start),
        .result(exp_result), .done(exp_done)
    );

    reg                   sqrt_start;
    reg  [WL-1:0]         sqrt_x;
    wire [WL-1:0]         sqrt_result;
    wire                  sqrt_done;
    fp_sqrt #(.WL(WL), .FL(FL)) sqrt_inst (
        .clk(clk), .rst(rst), .x(sqrt_x), .start(sqrt_start),
        .result(sqrt_result), .done(sqrt_done)
    );

    // CORDIC — used only for cos(u_k*a), sin(u_k*a).
    reg                   cordic_start;
    wire signed [WL-1:0]  cordic_x_out, cordic_y_out;
    wire                  cordic_done;
    cordic #(.WL(WL), .AL(WL), .N_ITER(30), .AF(FL)) cordic_inst (
        .clk(clk), .rst(rst), .start(cordic_start), .mode(1'b0),
        .x_in(CORDIC_1_OVER_K), .y_in({WL{1'b0}}), .z_in(angle),
        .x_out(cordic_x_out), .y_out(cordic_y_out), .z_out(), .done(cordic_done)
    );

    // Characteristic Function (phi) — WL2/FL2 (Q32.32) precision
    reg char_start;
    reg signed [WL2-1:0] char_T, char_r, char_v0, char_kappa, char_theta, char_xi, char_rho, char_x, char_u;
    wire signed [WL2-1:0] phi_r, phi_i;
    wire char_done;

    heston_char_func #(.WL(WL2), .FL(FL2)) char_func_inst (
        .clk(clk), .rst(rst),
        .T_in(char_T), .r_in(char_r), .v0_in(char_v0), .kappa_in(char_kappa),
        .theta_in(char_theta), .xi_in(char_xi), .rho_in(char_rho),
        .x_in(char_x), .u_in(char_u),
        .start(char_start),
        .phi_r(phi_r), .phi_i(phi_i), .done(char_done),
        .tape_we(), .tape_addr(), .tape_data_val(), .tape_data_partial()
    );

    // Payoff Coefficient
    reg payoff_start;
    wire signed [WL-1:0] V_k;
    wire payoff_done;

    heston_payoff_coeff #(.WL(WL), .FL(FL)) payoff_inst (
        .clk(clk), .rst(rst),
        .k(k_counter), .u_k(u_k), .a_in(a_val), .b_in(b_val),
        .exp_a(exp_a_val), .exp_b(exp_b_val),
        .cos_ua(cos_ua), .sin_ua(sin_ua),
        .two_K_over_bma(two_K_over_bma),
        .is_call(is_call_r),
        .start(payoff_start),
        .V_k(V_k), .done(payoff_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 0;
            tape_we <= 0;
            div_start <= 0; log_start <= 0; exp_start <= 0; sqrt_start <= 0;
            cordic_start <= 0; char_start <= 0; payoff_start <= 0;
        end else begin
            div_start <= 0; log_start <= 0; exp_start <= 0; sqrt_start <= 0;
            cordic_start <= 0; char_start <= 0; payoff_start <= 0;
            tape_we <= 0;

            case (state)
                S_IDLE: begin
                    done <= 0;
                    if (start) begin
                        is_call_r <= is_call;
                        state <= S_X_DIV;
                    end
                end

                // ---- x = ln(S0/K) ----
                S_X_DIV: begin
                    div_a <= S0; div_b <= K; div_start <= 1'b1;
                    state <= S_X_DIV_WAIT;
                end
                S_X_DIV_WAIT: begin
                    if (div_ready) begin
                        log_x <= div_result;
                        log_start <= 1'b1;
                        state <= S_X_LOG_WAIT;
                    end
                end
                S_X_LOG_WAIT: begin
                    if (log_done) begin
                        x_val <= log_result;
                        state <= S_NEG_KT;
                    end
                end

                // ---- exp(-kappa*T) ----
                S_NEG_KT: begin
                    wp1 = $signed(kappa) * $signed(T);
                    exp_x <= -(wp1 >>> FL);
                    exp_start <= 1'b1;
                    state <= S_NEG_KT_WAIT;
                end
                S_NEG_KT_WAIT: begin
                    if (exp_done) begin
                        exp_negkT <= exp_result;
                        state <= S_C1B_DIV;
                    end
                end

                // ---- (1 - exp(-kappa*T)) / (2*kappa) ----
                S_C1B_DIV: begin
                    div_a <= ONE_C - exp_negkT;
                    div_b <= kappa <<< 1;
                    div_start <= 1'b1;
                    state <= S_C1B_DIV_WAIT;
                end
                S_C1B_DIV_WAIT: begin
                    if (div_ready) begin
                        term_c1b <= div_result;
                        state <= S_C1_COMBINE;
                    end
                end

                // ---- c1 = x + (r-0.5*theta)*T + term_c1b*(theta-v0) ----
                S_C1_COMBINE: begin
                    wp1 = (r - (theta >>> 1)) * $signed(T);
                    wp2 = $signed(term_c1b) * (theta - v0);
                    c1_val <= x_val + (wp1 >>> FL) + (wp2 >>> FL);
                    state <= S_C2;
                end

                // ---- c2 = max(v0*T + 0.5*theta*T, MIN_C2) ----
                S_C2: begin
                    wp1 = $signed(v0) * $signed(T);
                    wp2 = (theta >>> 1) * $signed(T);
                    c2_raw = (wp1 >>> FL) + (wp2 >>> FL);
                    c2_val <= (c2_raw < MIN_C2) ? MIN_C2 : c2_raw;
                    sqrt_x <= (c2_raw < MIN_C2) ? MIN_C2 : c2_raw;
                    sqrt_start <= 1'b1;
                    state <= S_SQRT_C2_WAIT;
                end
                S_SQRT_C2_WAIT: begin
                    if (sqrt_done) begin
                        sqrt_c2 <= sqrt_result;
                        state <= S_AB;
                    end
                end

                // ---- a = c1 - 10*sqrt(c2); b = c1 + 10*sqrt(c2) ----
                S_AB: begin
                    ten_sqrt_c2 = $signed(sqrt_result) * 10;
                    a_val   <= c1_val - ten_sqrt_c2;
                    b_val   <= c1_val + ten_sqrt_c2;
                    bma_val <= ten_sqrt_c2 <<< 1;
                    div_a <= ONE_C;
                    div_b <= ten_sqrt_c2 <<< 1;
                    div_start <= 1'b1;
                    state <= S_INV_BMA_WAIT;
                end

                S_INV_BMA_WAIT: begin
                    if (div_ready) begin
                        inv_bma <= div_result;
                        state <= S_SCALARS;
                    end
                end

                // ---- pi/bma and 2K/bma (both reused for every k) ----
                S_SCALARS: begin
                    wp1 = $signed(PI_C) * $signed(div_result);
                    pi_over_bma <= wp1 >>> FL;
                    wp2 = (K <<< 1) * $signed(div_result);
                    two_K_over_bma <= wp2 >>> FL;
                    exp_x <= a_val;
                    exp_start <= 1'b1;
                    state <= S_EXP_A_WAIT;
                end

                S_EXP_A_WAIT: begin
                    if (exp_done) begin
                        exp_a_val <= exp_result;
                        exp_x <= b_val;
                        exp_start <= 1'b1;
                        state <= S_EXP_B_WAIT;
                    end
                end

                S_EXP_B_WAIT: begin
                    if (exp_done) begin
                        exp_b_val <= exp_result;
                        k_counter <= 8'd0;
                        accumulator <= 48'sd0;
                        state <= S_LOOP_START;
                    end
                end

                // ================= Per-k loop =================
                S_LOOP_START: begin
                    wp1 = $signed({{(WL-8){1'b0}}, k_counter}) * $signed(pi_over_bma);
                    u_k <= wp1[WL-1:0];
                    state <= S_ANGLE;
                end

                S_ANGLE: begin
                    wp1 = $signed(u_k) * $signed(a_val);
                    angle <= wp1 >>> FL;
                    state <= S_CORDIC_WAIT;
                end

                S_CORDIC_WAIT: begin
                    // angle became valid last cycle; issue cordic once,
                    // then wait for it.
                    cordic_start <= 1'b1;
                    state <= S_CHAR_START;
                end

                // NOTE: reusing S_CHAR_START as the CORDIC wait target below
                // keeps this a plain linear chain; cordic_done is polled
                // there before launching heston_char_func.
                S_CHAR_START: begin
                    if (cordic_done) begin
                        cos_ua <= cordic_x_out;
                        sin_ua <= cordic_y_out;

                        char_T     <= {{(WL2-WL){T[WL-1]}}, T}         <<< (FL2-FL);
                        char_r     <= {{(WL2-WL){r[WL-1]}}, r}         <<< (FL2-FL);
                        char_v0    <= {{(WL2-WL){v0[WL-1]}}, v0}       <<< (FL2-FL);
                        char_kappa <= {{(WL2-WL){kappa[WL-1]}}, kappa} <<< (FL2-FL);
                        char_theta <= {{(WL2-WL){theta[WL-1]}}, theta} <<< (FL2-FL);
                        char_xi    <= {{(WL2-WL){xi[WL-1]}}, xi}       <<< (FL2-FL);
                        char_rho   <= {{(WL2-WL){rho[WL-1]}}, rho}     <<< (FL2-FL);
                        char_x     <= {{(WL2-WL){x_val[WL-1]}}, x_val} <<< (FL2-FL);
                        char_u     <= {{(WL2-WL){u_k[WL-1]}}, u_k}     <<< (FL2-FL);
                        char_start <= 1'b1;
                        state <= S_CHAR_WAIT;
                    end
                end

                S_CHAR_WAIT: begin
                    if (char_done) begin
                        phi_r32 <= phi_r >>> (FL2-FL);
                        phi_i32 <= phi_i >>> (FL2-FL);
                        state <= S_PAYOFF_START;
                    end
                end

                S_PAYOFF_START: begin
                    payoff_start <= 1'b1;
                    state <= S_PAYOFF_WAIT;
                end

                S_PAYOFF_WAIT: begin
                    if (payoff_done) begin
                        // F_k = Re[phi * exp(-i*u_k*a)] = phi_r*cos_ua + phi_i*sin_ua
                        wp1 = $signed(phi_r32) * $signed(cos_ua);
                        wp2 = $signed(phi_i32) * $signed(sin_ua);
                        F_k <= (wp1 >>> FL) + (wp2 >>> FL);
                        state <= S_ACCUM;
                    end
                end

                S_ACCUM: begin
                    // contrib = weight * F_k * V_k  (weight = 0.5 at k=0, else 1.0)
                    wp1 = $signed(F_k) * $signed(V_k);
                    wp2 = (k_counter == 8'd0) ? (wp1 >>> 1) : wp1;
                    contrib = wp2 >>> FL; // Q(.,FL), same truncate-on-narrower-assign
                                          // pattern used everywhere else in this file
                    accumulator <= accumulator + {{(48-WL){contrib[WL-1]}}, contrib};

                    if (k_counter == N_TERMS - 1) begin
                        state <= S_DISC;
                    end else begin
                        k_counter <= k_counter + 1'b1;
                        state <= S_LOOP_START;
                    end
                end

                // ---- Final price = exp(-rT) * accumulator ----
                S_DISC: begin
                    wp1 = $signed(r) * $signed(T);
                    exp_x <= -(wp1 >>> FL);
                    exp_start <= 1'b1;
                    state <= S_DISC_WAIT;
                end
                S_DISC_WAIT: begin
                    if (exp_done) begin
                        // discount (Q(.,FL)) * accumulator (Q(.,FL), 48-bit
                        // headroom) -> Q(.,2*FL); >>> FL then truncate to
                        // WL bits on assignment gives Q(.,FL) again, same
                        // truncate-on-narrower-assign pattern used
                        // everywhere else in this file.
                        wp_price = $signed(exp_result) * accumulator;
                        price <= wp_price >>> FL;
                        state <= S_FINISH;
                    end
                end

                S_FINISH: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
