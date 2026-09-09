`timescale 1ns / 1ps
//============================================================================
// Second-Order AAD — Forward-over-Reverse Hessian Sweep
//============================================================================
// Computes one full row of the Hessian, d2(price)/d(seed)d(x_j) for every
// input x_j, from the same tape bs_forward_core.v writes — by running the
// standard forward-over-reverse construction:
//
//   1. tangent (forward) sweep, seeded with a unit tangent on one input:
//        xdot_k = SUM_j (dv_k/dv_j) * xdot_j
//      i.e. the ordinary first-order forward-mode sweep, using the same
//      first partials p1/p2 the reverse pass uses.
//
//   2. second-order reverse sweep, carrying two adjoints per node — the
//      ordinary adjoint abar (= d price / d v_k) and the "tangent-adjoint"
//      bbar (= d/d(seed) of that adjoint):
//        abar_j += abar_k * p_kj
//        bbar_j += bbar_k * p_kj + abar_k * SUM_l h_kjl * xdot_l
//      where h_kjl are the node's *local* second partials, supplied on the
//      tape alongside p1/p2.
//
//   3. bbar at each input node is then exactly d2(price)/d(seed)d(x_j).
//
// This is genuine second-order automatic differentiation over the recorded
// graph — not a finite difference of the first-order Greeks, and not
// closed-form Greek formulas: nothing here knows it is pricing an option.
// Cost is one extra forward+reverse sweep per seed direction, so a full
// n x n Hessian costs O(n) sweeps rather than the O(n^2) repricings a
// bump-and-reprice second-order scheme would need.
//
// Assumes tape_max_idx <= 31 (bs_forward_core writes exactly 25 entries).
//============================================================================

module bs_second_order #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  tape_max_idx,
    input  wire [7:0]  seed_idx,      // input node carrying the unit tangent

    // Tape read interface
    output reg  [7:0]  tape_read_addr,
    input  wire signed [WL-1:0] tape_partial_1,
    input  wire signed [WL-1:0] tape_partial_2,
    input  wire signed [WL-1:0] tape_h11,
    input  wire signed [WL-1:0] tape_h12,
    input  wire signed [WL-1:0] tape_h22,
    input  wire [7:0]  tape_parent_1,
    input  wire [7:0]  tape_parent_2,

    // One Hessian row: d2(price)/d(seed)d(x_j) for the five BS inputs
    // (1=S, 2=K, 3=T, 4=r, 5=sigma).
    output reg  signed [WL-1:0] hess_S,
    output reg  signed [WL-1:0] hess_K,
    output reg  signed [WL-1:0] hess_T,
    output reg  signed [WL-1:0] hess_r,
    output reg  signed [WL-1:0] hess_sigma,

    output reg         done
);

    localparam signed [WL-1:0] ONE_C = 32'sd65536;

    // Per-node state. Index 0 is unused and permanently zero, so that a
    // parent index of 0 ("no parent") reads back as a harmless zero
    // tangent without needing a special case in the arithmetic below.
    reg signed [WL-1:0] xdot [0:31];
    reg signed [WL-1:0] abar [0:31];
    reg signed [WL-1:0] bbar [0:31];

    localparam S_IDLE      = 4'd0;
    localparam S_CLEAR     = 4'd1;
    localparam S_SEED      = 4'd2;
    localparam S_FWD_FETCH = 4'd3;
    localparam S_FWD_WAIT  = 4'd4;
    localparam S_FWD_ACC   = 4'd5;
    localparam S_REV_SEED  = 4'd6;
    localparam S_REV_FETCH = 4'd7;
    localparam S_REV_WAIT  = 4'd8;
    localparam S_REV_ACC   = 4'd9;
    localparam S_EXTRACT   = 4'd10;

    reg [3:0] state;
    reg [7:0] cur_idx;
    integer i;

    reg signed [2*WL-1:0] wp1, wp2, wp3;
    reg signed [WL-1:0] t_xdot, t_a, t_b;
    reg signed [WL-1:0] xd_p1, xd_p2;
    reg signed [WL-1:0] cross1, cross2;
    reg signed [WL-1:0] ca1, cb1, ca2, cb2;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            tape_read_addr <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) state <= S_CLEAR;
                end

                S_CLEAR: begin
                    for (i = 0; i < 32; i = i + 1) begin
                        xdot[i] <= 0;
                        abar[i] <= 0;
                        bbar[i] <= 0;
                    end
                    state <= S_SEED;
                end

                // Unit tangent on the seed input; every other input's
                // tangent stays zero.
                S_SEED: begin
                    xdot[seed_idx] <= ONE_C;
                    cur_idx <= 8'd1;
                    state <= S_FWD_FETCH;
                end

                // ---------- forward (tangent) sweep, 1 .. N ----------
                S_FWD_FETCH: begin
                    if (cur_idx > tape_max_idx) begin
                        state <= S_REV_SEED;
                    end else begin
                        tape_read_addr <= cur_idx;
                        state <= S_FWD_WAIT;
                    end
                end
                S_FWD_WAIT: state <= S_FWD_ACC;

                S_FWD_ACC: begin
                    // Input nodes have no parents: their tangent is whatever
                    // the seed put there, so leave xdot[cur_idx] alone.
                    if (tape_parent_1 != 8'd0 || tape_parent_2 != 8'd0) begin
                        wp1 = $signed(tape_partial_1) * $signed(xdot[tape_parent_1]);
                        wp2 = $signed(tape_partial_2) * $signed(xdot[tape_parent_2]);
                        t_xdot = (tape_parent_1 != 8'd0 ? (wp1 >>> FL) : {WL{1'b0}})
                               + (tape_parent_2 != 8'd0 ? (wp2 >>> FL) : {WL{1'b0}});
                        xdot[cur_idx] <= t_xdot;
                    end
                    cur_idx <= cur_idx + 8'd1;
                    state <= S_FWD_FETCH;
                end

                // ---------- second-order reverse sweep, N .. 1 ----------
                S_REV_SEED: begin
                    abar[tape_max_idx] <= ONE_C; // d price / d price
                    bbar[tape_max_idx] <= 0;     // no second-order seed
                    cur_idx <= tape_max_idx;
                    state <= S_REV_FETCH;
                end

                S_REV_FETCH: begin
                    if (cur_idx == 8'd0) begin
                        state <= S_EXTRACT;
                    end else begin
                        tape_read_addr <= cur_idx;
                        state <= S_REV_WAIT;
                    end
                end
                S_REV_WAIT: state <= S_REV_ACC;

                S_REV_ACC: begin
                    t_a   = abar[cur_idx];
                    t_b   = bbar[cur_idx];
                    xd_p1 = xdot[tape_parent_1]; // index 0 holds zero
                    xd_p2 = xdot[tape_parent_2];

                    // SUM_l h_1l * xdot_l  and  SUM_l h_2l * xdot_l
                    wp1 = $signed(tape_h11) * $signed(xd_p1);
                    wp2 = $signed(tape_h12) * $signed(xd_p2);
                    cross1 = (wp1 >>> FL) + (wp2 >>> FL);

                    wp1 = $signed(tape_h12) * $signed(xd_p1);
                    wp2 = $signed(tape_h22) * $signed(xd_p2);
                    cross2 = (wp1 >>> FL) + (wp2 >>> FL);

                    // parent 1 contributions
                    wp1 = $signed(t_a) * $signed(tape_partial_1);
                    ca1 = wp1 >>> FL;
                    wp2 = $signed(t_b) * $signed(tape_partial_1);
                    wp3 = $signed(t_a) * $signed(cross1);
                    cb1 = (wp2 >>> FL) + (wp3 >>> FL);

                    // parent 2 contributions
                    wp1 = $signed(t_a) * $signed(tape_partial_2);
                    ca2 = wp1 >>> FL;
                    wp2 = $signed(t_b) * $signed(tape_partial_2);
                    wp3 = $signed(t_a) * $signed(cross2);
                    cb2 = (wp2 >>> FL) + (wp3 >>> FL);

                    // NOTE: when a node names the same parent twice (x*x is
                    // recorded with parent_1 == parent_2), both
                    // contributions must land in one accumulation — two
                    // separate nonblocking writes to the same array element
                    // in one cycle would drop the first. Summing them here
                    // also makes the x*x case come out exactly right:
                    // p1 = p2 = x and h12 = 1 gives 2*x*bbar + 2*abar*xdot,
                    // which is d/dx of (2x) as required.
                    if (tape_parent_1 != 8'd0 && tape_parent_1 == tape_parent_2) begin
                        abar[tape_parent_1] <= abar[tape_parent_1] + ca1 + ca2;
                        bbar[tape_parent_1] <= bbar[tape_parent_1] + cb1 + cb2;
                    end else begin
                        if (tape_parent_1 != 8'd0) begin
                            abar[tape_parent_1] <= abar[tape_parent_1] + ca1;
                            bbar[tape_parent_1] <= bbar[tape_parent_1] + cb1;
                        end
                        if (tape_parent_2 != 8'd0) begin
                            abar[tape_parent_2] <= abar[tape_parent_2] + ca2;
                            bbar[tape_parent_2] <= bbar[tape_parent_2] + cb2;
                        end
                    end

                    cur_idx <= cur_idx - 8'd1;
                    state <= S_REV_FETCH;
                end

                S_EXTRACT: begin
                    hess_S     <= bbar[1];
                    hess_K     <= bbar[2];
                    hess_T     <= bbar[3];
                    hess_r     <= bbar[4];
                    hess_sigma <= bbar[5];
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
