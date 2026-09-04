`timescale 1ns / 1ps
//============================================================================
// Black-Scholes Forward Pricing Core — Fixed-Point Pipeline
//============================================================================
// Computes the Black-Scholes call/put price in Q16.16 fixed point, and
// records every intermediate operation to an AAD "tape" (value + up to two
// (parent index, local partial derivative) pairs) so that bs_reverse_pass
// can later do a generic reverse-mode adjoint sweep over it to recover all
// five Greeks in one backward pass.
//
// This is a direct RTL port of hardware/matlab/bs_forward_core.m — same
// operation sequence, same tape semantics (see that file for the derivation
// of every partial derivative used below). Tape entries 1-5 are the five
// inputs (S,K,T,r,sigma); entries 6-25 are every computed intermediate,
// ending at entry 25 = price, for both call and put (both branches produce
// exactly 25 entries so tape_max_idx is always 25 regardless of is_call).
//============================================================================

module bs_forward_core #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire        clk,
    input  wire        rst,

    input  wire signed [WL-1:0] S_in,
    input  wire signed [WL-1:0] K_in,
    input  wire signed [WL-1:0] T_in,
    input  wire signed [WL-1:0] r_in,
    input  wire signed [WL-1:0] sigma_in,
    input  wire        is_call,   // 1 for call, 0 for put

    input  wire        start,

    output reg  signed [WL-1:0] price_out,
    output reg          done,

    // Tape write interface — one entry per cycle during the write-back
    // burst at the end of the pipeline (addresses 1..25).
    output reg          tape_we,
    output reg  [7:0]   tape_addr,
    output reg  signed [WL-1:0] tape_val,
    output reg  signed [WL-1:0] tape_partial_1,
    output reg  signed [WL-1:0] tape_partial_2,
    output reg  [7:0]   tape_parent_1,
    output reg  [7:0]   tape_parent_2
);

    // NOTE: this module (like the rest of the design) is used at its
    // default WL=32/FL=16 everywhere in the top level / testbenches, so
    // 1.0 and 0.5 are given directly as Q16.16 constants for clarity.
    localparam signed [WL-1:0] ONE_C  = 32'sd65536;
    localparam signed [WL-1:0] NEG_ONE_C = -32'sd65536;

    // ==================================================================
    // FSM states
    // ==================================================================
    localparam S_IDLE          = 6'd0;
    localparam S_SQRT_T        = 6'd1;
    localparam S_SQRT_T_WAIT   = 6'd2;
    localparam S_SIGMA_SQRT    = 6'd3;
    localparam S_S_DIV_K       = 6'd4;
    localparam S_S_DIV_K_WAIT  = 6'd5;
    localparam S_LN_S_K        = 6'd6;
    localparam S_LN_S_K_WAIT   = 6'd7;
    localparam S_SIGMA_SQ      = 6'd8;
    localparam S_SIGMA_SQ_H    = 6'd9;
    localparam S_R_PLUS        = 6'd10;
    localparam S_DRIFT_T       = 6'd11;
    localparam S_NUM           = 6'd12;
    localparam S_D1            = 6'd13;
    localparam S_D1_WAIT       = 6'd14;
    localparam S_D2            = 6'd15;
    localparam S_NEG_RT        = 6'd16;
    localparam S_DISCOUNT      = 6'd17;
    localparam S_DISCOUNT_WAIT = 6'd18;
    localparam S_ND1           = 6'd19;
    localparam S_ND1_WAIT      = 6'd20;
    localparam S_ND2           = 6'd21;
    localparam S_ND2_WAIT      = 6'd22;
    localparam S_PDF1          = 6'd23;
    localparam S_PDF1_WAIT     = 6'd24;
    localparam S_PDF2          = 6'd25;
    localparam S_PDF2_WAIT     = 6'd26;
    localparam S_PRICE_1       = 6'd27;
    localparam S_PRICE_2       = 6'd28;
    localparam S_PRICE_3       = 6'd29;
    localparam S_PRICE_4       = 6'd30;
    // Partial-derivative-only divisions (needed only to fill in the tape,
    // not the price pipeline itself).
    localparam S_P_SQRTT       = 6'd31;
    localparam S_P_SQRTT_WAIT  = 6'd32;
    localparam S_P_SK1         = 6'd33;
    localparam S_P_SK1_WAIT    = 6'd34;
    localparam S_P_SK2         = 6'd35;
    localparam S_P_SK2_WAIT    = 6'd36;
    localparam S_P_LNSK        = 6'd37;
    localparam S_P_LNSK_WAIT   = 6'd38;
    localparam S_P_D1A         = 6'd39;
    localparam S_P_D1A_WAIT    = 6'd40;
    localparam S_P_D1B         = 6'd41;
    localparam S_P_D1B_WAIT    = 6'd42;
    localparam S_TAPE_BURST    = 6'd43;
    localparam S_DONE          = 6'd44;

    reg [5:0] state;
    reg [4:0] burst_idx; // 0..24 -> tape address burst_idx+1

    // Latched option-type flag (start pulse may not stay stable).
    reg is_call_r;

    // ==================================================================
    // Value pipeline registers (Q16.16)
    // ==================================================================
    reg signed [WL-1:0] sqrt_T_r, sigma_sqrt_T_r, S_over_K_r, ln_S_K_r;
    reg signed [WL-1:0] sigma_sq_r, sigma_sq_half_r, r_plus_r, drift_T_r;
    reg signed [WL-1:0] num_r, d1_r, d2_r, rT_r, neg_rT_r, discount_r;
    reg signed [WL-1:0] Nd1_r, Nd2_r, pdf1_r, pdf2_r;
    reg signed [WL-1:0] price_r;

    // Partial-derivative-only helper results
    reg signed [WL-1:0] p_sqrtT_r, p_SK1_r, p_SK2_r, p_lnSK_r, p_d1a_r, p_d1b_r;

    // Slots 22-24 (branch-dependent identity/position; slot 25 is always price)
    reg signed [WL-1:0] t22_val, t23_val, t24_val;
    reg signed [WL-1:0] t22_pp1, t22_pp2, t23_pp1, t23_pp2, t24_pp1, t24_pp2;
    reg [7:0]            t22_p1, t22_p2, t23_p1, t23_p2, t24_p1, t24_p2;

    reg signed [2*WL-1:0] wp; // wide raw-multiply scratch

    // ==================================================================
    // Shared arithmetic sub-modules (reused sequentially, one op at a time)
    // ==================================================================
    reg                   sqrt_start;
    reg  [WL-1:0]         sqrt_x;
    wire [WL-1:0]         sqrt_result;
    wire                  sqrt_done;
    fp_sqrt #(.WL(WL), .FL(FL)) sqrt_inst (
        .clk(clk), .rst(rst), .x(sqrt_x), .start(sqrt_start),
        .result(sqrt_result), .done(sqrt_done)
    );

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

    reg                   ncdf_start;
    reg  signed [WL-1:0]  ncdf_x;
    wire [WL-1:0]         ncdf_result;
    wire                  ncdf_done;
    fp_normcdf #(.WL(WL), .FL(FL)) ncdf_inst (
        .clk(clk), .rst(rst), .x(ncdf_x), .start(ncdf_start),
        .result(ncdf_result), .done(ncdf_done)
    );

    reg                   npdf_start;
    reg  signed [WL-1:0]  npdf_x;
    wire [WL-1:0]         npdf_result;
    wire                  npdf_done;
    fp_normpdf #(.WL(WL), .FL(FL)) npdf_inst (
        .clk(clk), .rst(rst), .x(npdf_x), .start(npdf_start),
        .result(npdf_result), .done(npdf_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            done    <= 1'b0;
            tape_we <= 1'b0;
            sqrt_start <= 1'b0; div_start <= 1'b0; log_start <= 1'b0;
            exp_start  <= 1'b0; ncdf_start <= 1'b0; npdf_start <= 1'b0;
        end else begin
            tape_we    <= 1'b0; // default: pulse only when actually writing
            sqrt_start <= 1'b0;
            div_start  <= 1'b0;
            log_start  <= 1'b0;
            exp_start  <= 1'b0;
            ncdf_start <= 1'b0;
            npdf_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        is_call_r <= is_call;
                        state <= S_SQRT_T;
                    end
                end

                // ---- sqrt(T) ----
                S_SQRT_T: begin
                    sqrt_x <= T_in;
                    sqrt_start <= 1'b1;
                    state <= S_SQRT_T_WAIT;
                end
                S_SQRT_T_WAIT: begin
                    if (sqrt_done) begin
                        sqrt_T_r <= sqrt_result;
                        state <= S_SIGMA_SQRT;
                    end
                end

                // ---- sigma * sqrt(T) ----
                S_SIGMA_SQRT: begin
                    wp = $signed(sigma_in) * $signed(sqrt_T_r);
                    sigma_sqrt_T_r <= wp >>> FL;
                    state <= S_S_DIV_K;
                end

                // ---- S / K ----
                S_S_DIV_K: begin
                    div_a <= S_in; div_b <= K_in; div_start <= 1'b1;
                    state <= S_S_DIV_K_WAIT;
                end
                S_S_DIV_K_WAIT: begin
                    if (div_ready) begin
                        S_over_K_r <= div_result;
                        state <= S_LN_S_K;
                    end
                end

                // ---- ln(S/K) ----
                S_LN_S_K: begin
                    log_x <= S_over_K_r;
                    log_start <= 1'b1;
                    state <= S_LN_S_K_WAIT;
                end
                S_LN_S_K_WAIT: begin
                    if (log_done) begin
                        ln_S_K_r <= log_result;
                        state <= S_SIGMA_SQ;
                    end
                end

                // ---- sigma^2 ----
                S_SIGMA_SQ: begin
                    wp = $signed(sigma_in) * $signed(sigma_in);
                    sigma_sq_r <= wp >>> FL;
                    state <= S_SIGMA_SQ_H;
                end

                // ---- sigma^2 / 2 ----
                S_SIGMA_SQ_H: begin
                    sigma_sq_half_r <= sigma_sq_r >>> 1;
                    state <= S_R_PLUS;
                end

                // ---- r + sigma^2/2 ----
                S_R_PLUS: begin
                    r_plus_r <= r_in + sigma_sq_half_r;
                    state <= S_DRIFT_T;
                end

                // ---- (r + sigma^2/2) * T ----
                S_DRIFT_T: begin
                    wp = $signed(r_plus_r) * $signed(T_in);
                    drift_T_r <= wp >>> FL;
                    state <= S_NUM;
                end

                // ---- num = ln(S/K) + drift*T ----
                S_NUM: begin
                    num_r <= ln_S_K_r + drift_T_r;
                    state <= S_D1;
                end

                // ---- d1 = num / (sigma*sqrt(T)) ----
                S_D1: begin
                    div_a <= num_r; div_b <= sigma_sqrt_T_r; div_start <= 1'b1;
                    state <= S_D1_WAIT;
                end
                S_D1_WAIT: begin
                    if (div_ready) begin
                        d1_r <= div_result;
                        state <= S_D2;
                    end
                end

                // ---- d2 = d1 - sigma*sqrt(T) ----
                S_D2: begin
                    d2_r <= d1_r - sigma_sqrt_T_r;
                    state <= S_NEG_RT;
                end

                // ---- -r*T ----
                S_NEG_RT: begin
                    wp = $signed(r_in) * $signed(T_in);
                    rT_r     <= wp >>> FL;
                    neg_rT_r <= -(wp >>> FL);
                    state <= S_DISCOUNT;
                end

                // ---- exp(-r*T) ----
                S_DISCOUNT: begin
                    exp_x <= neg_rT_r;
                    exp_start <= 1'b1;
                    state <= S_DISCOUNT_WAIT;
                end
                S_DISCOUNT_WAIT: begin
                    if (exp_done) begin
                        discount_r <= exp_result;
                        state <= S_ND1;
                    end
                end

                // ---- N(d1) [call] or N(-d1) [put] ----
                S_ND1: begin
                    ncdf_x <= is_call_r ? d1_r : -d1_r;
                    ncdf_start <= 1'b1;
                    state <= S_ND1_WAIT;
                end
                S_ND1_WAIT: begin
                    if (ncdf_done) begin
                        Nd1_r <= ncdf_result;
                        state <= S_ND2;
                    end
                end

                // ---- N(d2) [call] or N(-d2) [put] ----
                S_ND2: begin
                    ncdf_x <= is_call_r ? d2_r : -d2_r;
                    ncdf_start <= 1'b1;
                    state <= S_ND2_WAIT;
                end
                S_ND2_WAIT: begin
                    if (ncdf_done) begin
                        Nd2_r <= ncdf_result;
                        state <= S_PDF1;
                    end
                end

                // ---- n(d1) (needed for the tape partial, even function) ----
                S_PDF1: begin
                    npdf_x <= d1_r;
                    npdf_start <= 1'b1;
                    state <= S_PDF1_WAIT;
                end
                S_PDF1_WAIT: begin
                    if (npdf_done) begin
                        pdf1_r <= npdf_result;
                        state <= S_PDF2;
                    end
                end

                // ---- n(d2) ----
                S_PDF2: begin
                    npdf_x <= d2_r;
                    npdf_start <= 1'b1;
                    state <= S_PDF2_WAIT;
                end
                S_PDF2_WAIT: begin
                    if (npdf_done) begin
                        pdf2_r <= npdf_result;
                        state <= S_PRICE_1;
                    end
                end

                // ---- Price combination (branches on is_call_r) ----
                S_PRICE_1: begin
                    if (is_call_r) begin
                        // slot22 = S*N(d1)
                        wp = $signed(S_in) * $signed(Nd1_r);
                        t22_val <= wp >>> FL;
                        t22_p1 <= 8'd1;  t22_pp1 <= Nd1_r;
                        t22_p2 <= 8'd20; t22_pp2 <= S_in;
                    end else begin
                        // slot22 = K*discount
                        wp = $signed(K_in) * $signed(discount_r);
                        t22_val <= wp >>> FL;
                        t22_p1 <= 8'd2;  t22_pp1 <= discount_r;
                        t22_p2 <= 8'd19; t22_pp2 <= K_in;
                    end
                    state <= S_PRICE_2;
                end

                S_PRICE_2: begin
                    if (is_call_r) begin
                        // slot23 = K*discount
                        wp = $signed(K_in) * $signed(discount_r);
                        t23_val <= wp >>> FL;
                        t23_p1 <= 8'd2;  t23_pp1 <= discount_r;
                        t23_p2 <= 8'd19; t23_pp2 <= K_in;
                    end else begin
                        // slot23 = slot22(K*discount) * N(-d2)
                        wp = $signed(t22_val) * $signed(Nd2_r);
                        t23_val <= wp >>> FL;
                        t23_p1 <= 8'd22; t23_pp1 <= Nd2_r;
                        t23_p2 <= 8'd21; t23_pp2 <= t22_val;
                    end
                    state <= S_PRICE_3;
                end

                S_PRICE_3: begin
                    if (is_call_r) begin
                        // slot24 = slot23(K*discount) * N(d2)
                        wp = $signed(t23_val) * $signed(Nd2_r);
                        t24_val <= wp >>> FL;
                        t24_p1 <= 8'd23; t24_pp1 <= Nd2_r;
                        t24_p2 <= 8'd21; t24_pp2 <= t23_val;
                    end else begin
                        // slot24 = S*N(-d1)
                        wp = $signed(S_in) * $signed(Nd1_r);
                        t24_val <= wp >>> FL;
                        t24_p1 <= 8'd1;  t24_pp1 <= Nd1_r;
                        t24_p2 <= 8'd20; t24_pp2 <= S_in;
                    end
                    state <= S_PRICE_4;
                end

                S_PRICE_4: begin
                    if (is_call_r) begin
                        // price = slot22(S*Nd1) - slot24(K*disc*Nd2)
                        price_r <= t22_val - t24_val;
                    end else begin
                        // price = slot23(K*disc*Nnd2) - slot24(S*Nnd1)
                        price_r <= t23_val - t24_val;
                    end
                    state <= S_P_SQRTT;
                end

                // ---- partial-only helper divisions ----
                S_P_SQRTT: begin
                    div_a <= ONE_C; div_b <= sqrt_T_r <<< 1; div_start <= 1'b1;
                    state <= S_P_SQRTT_WAIT;
                end
                S_P_SQRTT_WAIT: begin
                    if (div_ready) begin p_sqrtT_r <= div_result; state <= S_P_SK1; end
                end

                S_P_SK1: begin
                    div_a <= ONE_C; div_b <= K_in; div_start <= 1'b1;
                    state <= S_P_SK1_WAIT;
                end
                S_P_SK1_WAIT: begin
                    if (div_ready) begin p_SK1_r <= div_result; state <= S_P_SK2; end
                end

                S_P_SK2: begin
                    div_a <= S_over_K_r; div_b <= K_in; div_start <= 1'b1;
                    state <= S_P_SK2_WAIT;
                end
                S_P_SK2_WAIT: begin
                    if (div_ready) begin p_SK2_r <= div_result; state <= S_P_LNSK; end
                end

                S_P_LNSK: begin
                    div_a <= ONE_C; div_b <= S_over_K_r; div_start <= 1'b1;
                    state <= S_P_LNSK_WAIT;
                end
                S_P_LNSK_WAIT: begin
                    if (div_ready) begin p_lnSK_r <= div_result; state <= S_P_D1A; end
                end

                S_P_D1A: begin
                    div_a <= ONE_C; div_b <= sigma_sqrt_T_r; div_start <= 1'b1;
                    state <= S_P_D1A_WAIT;
                end
                S_P_D1A_WAIT: begin
                    if (div_ready) begin p_d1a_r <= div_result; state <= S_P_D1B; end
                end

                S_P_D1B: begin
                    div_a <= d1_r; div_b <= sigma_sqrt_T_r; div_start <= 1'b1;
                    state <= S_P_D1B_WAIT;
                end
                S_P_D1B_WAIT: begin
                    if (div_ready) begin
                        p_d1b_r <= div_result;
                        burst_idx <= 5'd0;
                        state <= S_TAPE_BURST;
                    end
                end

                // ---- Write all 25 tape entries, one per cycle ----
                S_TAPE_BURST: begin
                    tape_we   <= 1'b1;
                    tape_addr <= burst_idx + 8'd1;
                    case (burst_idx)
                        5'd0:  begin tape_val<=S_in;    tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                        5'd1:  begin tape_val<=K_in;    tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                        5'd2:  begin tape_val<=T_in;    tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                        5'd3:  begin tape_val<=r_in;    tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                        5'd4:  begin tape_val<=sigma_in;tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                        5'd5:  begin tape_val<=sqrt_T_r;        tape_partial_1<=p_sqrtT_r; tape_partial_2<=0; tape_parent_1<=8'd3; tape_parent_2<=0; end
                        5'd6:  begin tape_val<=sigma_sqrt_T_r;  tape_partial_1<=sqrt_T_r;  tape_partial_2<=sigma_in; tape_parent_1<=8'd5; tape_parent_2<=8'd6; end
                        5'd7:  begin tape_val<=S_over_K_r;      tape_partial_1<=p_SK1_r;   tape_partial_2<=(-p_SK2_r); tape_parent_1<=8'd1; tape_parent_2<=8'd2; end
                        5'd8:  begin tape_val<=ln_S_K_r;        tape_partial_1<=p_lnSK_r;  tape_partial_2<=0; tape_parent_1<=8'd8; tape_parent_2<=0; end
                        5'd9:  begin tape_val<=sigma_sq_r;      tape_partial_1<=sigma_in;  tape_partial_2<=sigma_in; tape_parent_1<=8'd5; tape_parent_2<=8'd5; end
                        5'd10: begin tape_val<=sigma_sq_half_r; tape_partial_1<=32'sd32768; tape_partial_2<=0; tape_parent_1<=8'd10; tape_parent_2<=0; end
                        5'd11: begin tape_val<=r_plus_r;        tape_partial_1<=ONE_C; tape_partial_2<=ONE_C; tape_parent_1<=8'd4; tape_parent_2<=8'd11; end
                        5'd12: begin tape_val<=drift_T_r;       tape_partial_1<=T_in; tape_partial_2<=r_plus_r; tape_parent_1<=8'd12; tape_parent_2<=8'd3; end
                        5'd13: begin tape_val<=num_r;           tape_partial_1<=ONE_C; tape_partial_2<=ONE_C; tape_parent_1<=8'd9; tape_parent_2<=8'd13; end
                        5'd14: begin tape_val<=d1_r;            tape_partial_1<=p_d1a_r; tape_partial_2<=(-p_d1b_r); tape_parent_1<=8'd14; tape_parent_2<=8'd7; end
                        5'd15: begin tape_val<=d2_r;            tape_partial_1<=ONE_C; tape_partial_2<=NEG_ONE_C; tape_parent_1<=8'd15; tape_parent_2<=8'd7; end
                        5'd16: begin tape_val<=rT_r;            tape_partial_1<=T_in; tape_partial_2<=r_in; tape_parent_1<=8'd4; tape_parent_2<=8'd3; end
                        5'd17: begin tape_val<=neg_rT_r;        tape_partial_1<=NEG_ONE_C; tape_partial_2<=0; tape_parent_1<=8'd17; tape_parent_2<=0; end
                        5'd18: begin tape_val<=discount_r;      tape_partial_1<=discount_r; tape_partial_2<=0; tape_parent_1<=8'd18; tape_parent_2<=0; end
                        5'd19: begin tape_val<=Nd1_r;           tape_partial_1<=(is_call_r?pdf1_r:(-pdf1_r)); tape_partial_2<=0; tape_parent_1<=8'd15; tape_parent_2<=0; end
                        5'd20: begin tape_val<=Nd2_r;           tape_partial_1<=(is_call_r?pdf2_r:(-pdf2_r)); tape_partial_2<=0; tape_parent_1<=8'd16; tape_parent_2<=0; end
                        5'd21: begin tape_val<=t22_val; tape_partial_1<=t22_pp1; tape_partial_2<=t22_pp2; tape_parent_1<=t22_p1; tape_parent_2<=t22_p2; end
                        5'd22: begin tape_val<=t23_val; tape_partial_1<=t23_pp1; tape_partial_2<=t23_pp2; tape_parent_1<=t23_p1; tape_parent_2<=t23_p2; end
                        5'd23: begin tape_val<=t24_val; tape_partial_1<=t24_pp1; tape_partial_2<=t24_pp2; tape_parent_1<=t24_p1; tape_parent_2<=t24_p2; end
                        5'd24: begin
                            tape_val<=price_r;
                            if (is_call_r) begin
                                tape_partial_1<=ONE_C;     tape_parent_1<=8'd22;
                                tape_partial_2<=NEG_ONE_C; tape_parent_2<=8'd24;
                            end else begin
                                tape_partial_1<=ONE_C;     tape_parent_1<=8'd23;
                                tape_partial_2<=NEG_ONE_C; tape_parent_2<=8'd24;
                            end
                        end
                        default: begin tape_val<=0; tape_partial_1<=0; tape_partial_2<=0; tape_parent_1<=0; tape_parent_2<=0; end
                    endcase

                    if (burst_idx == 5'd24) begin
                        price_out <= price_r;
                        state <= S_DONE;
                    end else begin
                        burst_idx <= burst_idx + 1'b1;
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
