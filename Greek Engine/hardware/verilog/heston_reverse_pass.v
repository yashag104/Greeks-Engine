`timescale 1ns / 1ps
//============================================================================
// Heston-COS "Reverse Pass" — Bump-and-Reprice Greeks
//============================================================================
// Heston has no closed-form Greeks, and hardware/matlab/heston_reverse_pass.m
// itself only gets partial derivatives through the characteristic function
// by finite-differencing it (see compute_char_partials_real/imag in
// heston_cos_forward_core.m) — even the project's own "AAD" reference
// falls back to numerical differentiation for exactly this piece. This
// module does the same thing at the top level instead: it owns a private
// heston_cos_forward instance and reprices with each of the 8 non-strike
// parameters (S0,T,r,v0,kappa,theta,xi,rho) bumped up and down in turn,
// computing each Greek as a central difference. This is exactly the
// heston_bump_reference() computation in hardware/matlab/heston_top_level.m
// — the project's own reference/validation target for the Greeks.
//
// Bump size: a relative 1/16 (6.25%) step (or a small absolute floor for a
// near-zero parameter), rather than the ~1e-5 relative step
// heston_bump_reference.m uses — at this design's Q16.16 resolution
// (~1.5e-5) and the forward pricer's own ~0.1-1% intrinsic error (fixed-
// point polynomial/CORDIC approximations throughout), a 1e-5 bump would be
// far smaller than the pricer's own noise floor and the resulting
// "derivative" would be dominated by rounding noise rather than signal.
//
// Latency: 16 full forward-pricer runs (~180k cycles each at N_TERMS=128),
// so ~2.9M cycles end to end — a deliberate latency/area trade-off for a
// design that only needs to reprice occasionally (e.g. offline risk runs).
//============================================================================

module heston_reverse_pass #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire              clk,
    input  wire              rst,

    input  wire               start,
    input  wire signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho,
    input  wire                is_call,

    // Adjoints out (the Greeks) — dV/d(param)
    output reg  signed [WL-1:0] adj_S0,
    output reg  signed [WL-1:0] adj_K,     // not bumped (see module header) — always 0
    output reg  signed [WL-1:0] adj_T,
    output reg  signed [WL-1:0] adj_r,
    output reg  signed [WL-1:0] adj_v0,
    output reg  signed [WL-1:0] adj_kappa,
    output reg  signed [WL-1:0] adj_theta,
    output reg  signed [WL-1:0] adj_xi,
    output reg  signed [WL-1:0] adj_rho,

    output reg               done
);

    localparam signed [WL-1:0] MIN_BUMP = (FL<=16) ? (32'sd1<<<(FL-6)) : (32'sd1<<<10)<<<(FL-16); // ~0.0156 at FL=16

    // 8 parameters to bump, in a fixed order.
    localparam NPARAMS = 8;
    localparam S_IDLE      = 4'd0;
    localparam S_BUMP_SETUP= 4'd1;
    localparam S_RUN_UP    = 4'd2;
    localparam S_RUN_UP_WAIT = 4'd3;
    localparam S_RUN_DN    = 4'd4;
    localparam S_RUN_DN_WAIT = 4'd5;
    localparam S_DIV       = 4'd6;
    localparam S_DIV_WAIT  = 4'd7;
    localparam S_NEXT      = 4'd8;
    localparam S_DONE      = 4'd9;

    reg [3:0] state;
    reg [3:0] param_idx; // 0..7

    reg signed [WL-1:0] S0_p, T_p, r_p, v0_p, kappa_p, theta_p, xi_p, rho_p;
    reg signed [WL-1:0] price_up, price_dn;
    reg signed [WL-1:0] bump, two_bump;

    reg fwd_start;
    wire fwd_done;
    wire signed [WL-1:0] fwd_price;

    heston_cos_forward #(.WL(WL), .FL(FL)) fwd_inst (
        .clk(clk), .rst(rst),
        .S0(S0_p), .K(K), .T(T_p), .r(r_p), .v0(v0_p),
        .kappa(kappa_p), .theta(theta_p), .xi(xi_p), .rho(rho_p),
        .is_call(is_call), .start(fwd_start),
        .price(fwd_price), .done(fwd_done),
        .tape_we(), .tape_addr(), .tape_data_val(), .tape_data_partial()
    );

    reg              div_start;
    reg  [WL-1:0]    div_a, div_b;
    wire [WL-1:0]    div_result;
    wire             div_ready;
    fp_div #(.WL(WL), .FL(FL)) div_inst (
        .clk(clk), .rst(rst), .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready), .divide_by_zero(), .overflow()
    );

    function signed [WL-1:0] bump_of(input signed [WL-1:0] p);
        reg signed [WL-1:0] mag;
        begin
            mag = p[WL-1] ? -p : p;       // |p|
            mag = mag >>> 4;              // 1/16
            bump_of = (mag < MIN_BUMP) ? MIN_BUMP : mag;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            fwd_start <= 1'b0;
            div_start <= 1'b0;
        end else begin
            fwd_start <= 1'b0;
            div_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // Base parameter values for every bumped run.
                        S0_p <= S0; T_p <= T; r_p <= r; v0_p <= v0;
                        kappa_p <= kappa; theta_p <= theta; xi_p <= xi; rho_p <= rho;
                        adj_K <= 0; // K is not bumped — see module header
                        param_idx <= 4'd0;
                        state <= S_BUMP_SETUP;
                    end
                end

                // ---- Bump parameter #param_idx up, launch a run ----
                S_BUMP_SETUP: begin
                    S0_p <= S0; T_p <= T; r_p <= r; v0_p <= v0;
                    kappa_p <= kappa; theta_p <= theta; xi_p <= xi; rho_p <= rho;
                    case (param_idx)
                        4'd0: begin bump <= bump_of(S0);    S0_p    <= S0    + bump_of(S0);    end
                        4'd1: begin bump <= bump_of(T);     T_p     <= T     + bump_of(T);     end
                        4'd2: begin bump <= bump_of(r);     r_p     <= r     + bump_of(r);     end
                        4'd3: begin bump <= bump_of(v0);    v0_p    <= v0    + bump_of(v0);    end
                        4'd4: begin bump <= bump_of(kappa); kappa_p <= kappa + bump_of(kappa); end
                        4'd5: begin bump <= bump_of(theta); theta_p <= theta + bump_of(theta); end
                        4'd6: begin bump <= bump_of(xi);    xi_p    <= xi    + bump_of(xi);    end
                        default: begin bump <= bump_of(rho); rho_p  <= rho   + bump_of(rho);   end
                    endcase
                    state <= S_RUN_UP;
                end

                S_RUN_UP: begin
                    fwd_start <= 1'b1;
                    state <= S_RUN_UP_WAIT;
                end
                S_RUN_UP_WAIT: begin
                    if (fwd_done) begin
                        price_up <= fwd_price;
                        // Now bump the same parameter down instead.
                        S0_p <= S0; T_p <= T; r_p <= r; v0_p <= v0;
                        kappa_p <= kappa; theta_p <= theta; xi_p <= xi; rho_p <= rho;
                        case (param_idx)
                            4'd0: S0_p    <= S0    - bump;
                            4'd1: T_p     <= T     - bump;
                            4'd2: r_p     <= r     - bump;
                            4'd3: v0_p    <= v0    - bump;
                            4'd4: kappa_p <= kappa - bump;
                            4'd5: theta_p <= theta - bump;
                            4'd6: xi_p    <= xi    - bump;
                            default: rho_p <= rho  - bump;
                        endcase
                        state <= S_RUN_DN;
                    end
                end

                S_RUN_DN: begin
                    fwd_start <= 1'b1;
                    state <= S_RUN_DN_WAIT;
                end
                S_RUN_DN_WAIT: begin
                    if (fwd_done) begin
                        price_dn <= fwd_price;
                        two_bump <= bump <<< 1;
                        state <= S_DIV;
                    end
                end

                // ---- Greek = (price_up - price_dn) / (2*bump) ----
                S_DIV: begin
                    div_a <= price_up - price_dn;
                    div_b <= two_bump;
                    div_start <= 1'b1;
                    state <= S_DIV_WAIT;
                end
                S_DIV_WAIT: begin
                    if (div_ready) begin
                        case (param_idx)
                            4'd0: adj_S0    <= div_result;
                            4'd1: adj_T     <= div_result;
                            4'd2: adj_r     <= div_result;
                            4'd3: adj_v0    <= div_result;
                            4'd4: adj_kappa <= div_result;
                            4'd5: adj_theta <= div_result;
                            4'd6: adj_xi    <= div_result;
                            default: adj_rho <= div_result;
                        endcase
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (param_idx == NPARAMS-1) begin
                        state <= S_DONE;
                    end else begin
                        param_idx <= param_idx + 1'b1;
                        state <= S_BUMP_SETUP;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
