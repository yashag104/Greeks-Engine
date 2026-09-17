`timescale 1ns / 1ps
//============================================================================
// Heston-COS Bump-and-Reprice Greeks — hardware baseline
//============================================================================
// The comparison baseline for the AAD engine: the *same* heston_cos_forward
// pricing core (same arithmetic library, same Q format, same N_TERMS), run
// in price-only mode (fwd_only=1, no reverse sweep) once at the base point
// and twice per sensitivity at p +- h, giving central differences
//     dV/dp ~ (V(p+h) - V(p-h)) / (2h)
// for the same 9 sensitivities heston_top_level reports:
//     S0 (delta), K, T, r, v0 (vega), kappa, theta, xi, rho.
// Total: 1 + 2*9 = 19 forward pricings, versus one forward+reverse pass.
//
// Bump sizes h_* are inputs (absolute, same Q format) so the bump-size
// trade-off (truncation error ~h^2 vs cancellation error ~ULP/h) can be
// swept without resynthesis — see validation/figures (error vs bump size).
//
// Sharing one pricing core is the minimum-area bump-and-reprice design;
// a throughput-matched one would instantiate 19 cores (area x19).
//============================================================================

module heston_bump_top #(
    parameter WL = 64,
    parameter FL = 32
) (
    input  wire              clk,
    input  wire              rst,

    input  wire signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho,
    input  wire              is_call,
    input  wire signed [WL-1:0] h_S0, h_K, h_T, h_r, h_v0, h_kappa, h_theta, h_xi, h_rho,

    input  wire              start,

    output reg  signed [WL-1:0] price,
    output reg  signed [WL-1:0] delta,
    output reg  signed [WL-1:0] vega,
    output reg  signed [WL-1:0] rho_greek,
    output reg  signed [WL-1:0] theta_greek,
    output reg  signed [WL-1:0] kappa_sens,
    output reg  signed [WL-1:0] theta_sens,
    output reg  signed [WL-1:0] xi_sens,
    output reg  signed [WL-1:0] rho_corr,
    output reg  signed [WL-1:0] strike_sens,
    output reg               done
);

    localparam NP = 9;              // bumped parameters
    localparam NPASS = 2*NP + 1;    // pricings

    // parameter order: 0 S0, 1 K, 2 T, 3 r, 4 v0, 5 kappa, 6 theta, 7 xi, 8 rho
    reg signed [WL-1:0] pbase [0:NP-1];
    reg signed [WL-1:0] hvec  [0:NP-1];
    reg signed [WL-1:0] pcur  [0:NP-1];
    reg signed [WL-1:0] vpass [0:NPASS-1];
    reg signed [WL-1:0] sens  [0:NP-1];
    reg                 is_call_r;

    reg        eng_start;
    wire       eng_done;
    wire signed [WL-1:0] eng_price;

    heston_cos_forward #(.WL(WL), .FL(FL)) engine (
        .clk(clk), .rst(rst),
        .S0(pcur[0]), .K(pcur[1]), .T(pcur[2]), .r(pcur[3]), .v0(pcur[4]),
        .kappa(pcur[5]), .theta(pcur[6]), .xi(pcur[7]), .rho(pcur[8]),
        .is_call(is_call_r),
        .start(eng_start),
        .fwd_only(1'b1),
        .price(eng_price),
        .done(eng_done),
        .adj_S0(), .adj_K(), .adj_T(), .adj_r(), .adj_v0(),
        .adj_kappa(), .adj_theta(), .adj_xi(), .adj_rho()
    );

    reg              div_start;
    reg  [WL-1:0]    div_a, div_b;
    wire [WL-1:0]    div_result;
    wire             div_ready;
    fp_div #(.WL(WL), .FL(FL)) div_inst (
        .clk(clk), .rst(rst), .a(div_a), .b(div_b), .start(div_start),
        .result(div_result), .ready(div_ready), .divide_by_zero(), .overflow()
    );

    localparam S_IDLE = 3'd0, S_SETUP = 3'd1, S_RUN = 3'd2, S_WAIT = 3'd3,
               S_DIV = 3'd4, S_DIV_WAIT = 3'd5, S_OUT = 3'd6;

    reg [2:0] state;
    reg [4:0] pass;
    reg [3:0] g;
    integer   i;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            eng_start <= 1'b0;
            div_start <= 1'b0;
        end else begin
            eng_start <= 1'b0;
            div_start <= 1'b0;
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        pbase[0] <= S0;    pbase[1] <= K;     pbase[2] <= T;
                        pbase[3] <= r;     pbase[4] <= v0;    pbase[5] <= kappa;
                        pbase[6] <= theta; pbase[7] <= xi;    pbase[8] <= rho;
                        hvec[0]  <= h_S0;    hvec[1] <= h_K;     hvec[2] <= h_T;
                        hvec[3]  <= h_r;     hvec[4] <= h_v0;    hvec[5] <= h_kappa;
                        hvec[6]  <= h_theta; hvec[7] <= h_xi;    hvec[8] <= h_rho;
                        is_call_r <= is_call;
                        pass  <= 0;
                        state <= S_SETUP;
                    end
                end

                // pass 0: base; pass 2g+1: p_g + h_g; pass 2g+2: p_g - h_g
                S_SETUP: begin
                    for (i = 0; i < NP; i = i + 1) begin
                        if (pass != 0 && i == (pass - 1) / 2)
                            pcur[i] <= ((pass - 1) % 2 == 0) ? pbase[i] + hvec[i]
                                                             : pbase[i] - hvec[i];
                        else
                            pcur[i] <= pbase[i];
                    end
                    state <= S_RUN;
                end

                S_RUN: begin
                    eng_start <= 1'b1;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (eng_done) begin
                        vpass[pass] <= eng_price;
                        if (pass == NPASS - 1) begin
                            g <= 0;
                            state <= S_DIV;
                        end else begin
                            pass  <= pass + 1'b1;
                            state <= S_SETUP;
                        end
                    end
                end

                S_DIV: begin
                    div_a <= vpass[2*g + 1] - vpass[2*g + 2];
                    div_b <= hvec[g] <<< 1;
                    div_start <= 1'b1;
                    state <= S_DIV_WAIT;
                end

                S_DIV_WAIT: begin
                    if (div_ready) begin
                        sens[g] <= div_result;
                        if (g == NP - 1) state <= S_OUT;
                        else begin
                            g <= g + 1'b1;
                            state <= S_DIV;
                        end
                    end
                end

                S_OUT: begin
                    price       <= vpass[0];
                    delta       <= sens[0];
                    strike_sens <= sens[1];
                    theta_greek <= sens[2];
                    rho_greek   <= sens[3];
                    vega        <= sens[4];
                    kappa_sens  <= sens[5];
                    theta_sens  <= sens[6];
                    xi_sens     <= sens[7];
                    rho_corr    <= sens[8];
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
