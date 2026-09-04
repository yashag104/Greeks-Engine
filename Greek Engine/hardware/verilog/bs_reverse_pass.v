`timescale 1ns / 1ps
//============================================================================
// Black-Scholes AAD Reverse Pass — Fixed-Point Pipeline
//============================================================================
// Generic reverse-mode adjoint sweep over the tape written by
// bs_forward_core: walk tape addresses tape_max_idx downto 1, and for each
// entry accumulate adj[parent] += adj[i] * local_partial for each of its
// up to two parents. Seeding adj[tape_max_idx] = 1.0 and sweeping backward
// like this computes d(price)/d(x) for every tape entry x in one pass —
// this is a direct RTL port of hardware/matlab/bs_reverse_pass.m.
//
// Assumes tape_max_idx <= 31 (bs_forward_core always writes exactly 25
// entries, addresses 1-25).
//============================================================================

module bs_reverse_pass #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [7:0]  tape_max_idx,

    // Tape Read Interface
    output reg  [7:0]  tape_read_addr,
    input  wire signed [WL-1:0] tape_val,           // unused (kept for interface stability)
    input  wire signed [WL-1:0] tape_partial_1,
    input  wire signed [WL-1:0] tape_partial_2,
    input  wire [7:0]  tape_parent_1,
    input  wire [7:0]  tape_parent_2,

    // Outputs (Greeks) — 48-bit, sign-extended from the internal Q16.16
    // adjoints below (kept 48-bit wide for interface stability / headroom).
    output reg  [47:0] delta_out,
    output reg  [47:0] vega_out,
    output reg  [47:0] theta_out,
    output reg  [47:0] rho_out,
    output reg  [47:0] strike_sens_out,

    output reg         done
);

    localparam signed [WL-1:0] ONE_C = 32'sd65536;

    // Local adjoint memory. Index 0 unused (tape addresses start at 1).
    reg signed [WL-1:0] adjoints [0:31];

    localparam S_IDLE   = 3'd0;
    localparam S_CLEAR  = 3'd1;
    localparam S_SEED   = 3'd2;
    localparam S_FETCH  = 3'd3;
    localparam S_WAIT   = 3'd4;
    localparam S_ACCUM  = 3'd5;
    localparam S_EXTRACT= 3'd6;

    reg [2:0] state;
    reg [7:0] cur_idx;
    integer i;

    reg signed [WL-1:0] adj_i;
    reg signed [2*WL-1:0] wp1, wp2;
    reg signed [WL-1:0] contrib1, contrib2;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            done  <= 1'b0;
            tape_read_addr <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        i <= 0;
                        state <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    for (i = 0; i < 32; i = i + 1) adjoints[i] <= 0;
                    state <= S_SEED;
                end

                S_SEED: begin
                    // Seed the output adjoint to 1.0 (d(price)/d(price) = 1)
                    adjoints[tape_max_idx] <= ONE_C;
                    cur_idx <= tape_max_idx;
                    state <= S_FETCH;
                end

                S_FETCH: begin
                    if (cur_idx == 0) begin
                        state <= S_EXTRACT;
                    end else begin
                        tape_read_addr <= cur_idx;
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    // 1 cycle for the (registered) tape/BRAM read latency.
                    state <= S_ACCUM;
                end

                S_ACCUM: begin
                    adj_i = adjoints[cur_idx];
                    wp1 = $signed(adj_i) * $signed(tape_partial_1);
                    wp2 = $signed(adj_i) * $signed(tape_partial_2);
                    contrib1 = wp1 >>> FL;
                    contrib2 = wp2 >>> FL;

                    // NOTE: if parent_1 == parent_2 (e.g. a squaring step
                    // like sigma*sigma, whose two "parents" are both
                    // sigma), both contributions must land in the *same*
                    // nonblocking assignment — two separate nonblocking
                    // assignments to the same array element in one cycle
                    // would just have the second overwrite the first,
                    // silently dropping the sigma_sq_reg accumulation.
                    if (tape_parent_1 != 0 && tape_parent_1 == tape_parent_2) begin
                        adjoints[tape_parent_1] <= adjoints[tape_parent_1] + contrib1 + contrib2;
                    end else begin
                        if (tape_parent_1 != 0)
                            adjoints[tape_parent_1] <= adjoints[tape_parent_1] + contrib1;
                        if (tape_parent_2 != 0)
                            adjoints[tape_parent_2] <= adjoints[tape_parent_2] + contrib2;
                    end

                    cur_idx <= cur_idx - 1;
                    state <= S_FETCH;
                end

                S_EXTRACT: begin
                    // Input indices: 1=S, 2=K, 3=T, 4=r, 5=sigma
                    delta_out       <= {{(48-WL){adjoints[1][WL-1]}}, adjoints[1]};
                    strike_sens_out <= {{(48-WL){adjoints[2][WL-1]}}, adjoints[2]};
                    theta_out       <= {{(48-WL){adjoints[3][WL-1]}}, adjoints[3]};
                    rho_out         <= {{(48-WL){adjoints[4][WL-1]}}, adjoints[4]};
                    vega_out        <= {{(48-WL){adjoints[5][WL-1]}}, adjoints[5]};

                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
