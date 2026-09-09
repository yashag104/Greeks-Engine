`timescale 1ns / 1ps
//============================================================================
// Black-Scholes AAD Top Level
//============================================================================
// Sequences the three passes that share one recorded tape:
//   1. bs_forward_core   — price, and the tape (values, first partials,
//                          second partials, parent indices)
//   2. bs_reverse_pass   — first-order Greeks, one reverse sweep
//   3. bs_second_order   — second-order Greeks, forward-over-reverse; run
//                          once per seed direction (S, then sigma) to fill
//                          in gamma / vanna / volga
// The tape read port is shared between (2) and (3); only one of them is
// ever active, so a simple owner mux is enough.
//============================================================================

module bs_top_level (
    input  wire        clk,
    input  wire        rst,

    // Inputs
    input  wire [31:0] S,
    input  wire [31:0] K,
    input  wire [31:0] T,
    input  wire [31:0] r,
    input  wire [31:0] sigma,
    input  wire        is_call,
    input  wire        start,

    // Outputs — first order
    output wire [31:0] price,
    output wire [47:0] delta,
    output wire [47:0] vega,
    output wire [47:0] theta,
    output wire [47:0] rho,
    output wire [47:0] strike_sens,

    // Outputs — second order (from the forward-over-reverse sweeps)
    output reg  signed [31:0] gamma,   // d2V/dS2
    output reg  signed [31:0] vanna,   // d2V/dS dsigma
    output reg  signed [31:0] volga,   // d2V/dsigma2
    output reg  signed [31:0] charm,   // d2V/dS dT

    output reg         done
);

    // Tape BRAM signals
    wire        tape_we;
    wire [7:0]  tape_waddr;
    wire [31:0] tape_wval;
    wire [31:0] tape_wp1;
    wire [31:0] tape_wp2;
    wire [7:0]  tape_wparent1;
    wire [7:0]  tape_wparent2;
    wire [31:0] tape_wh11;
    wire [31:0] tape_wh12;
    wire [31:0] tape_wh22;

    wire [7:0]  tape_raddr;
    reg  [31:0] tape_rval;
    reg  [31:0] tape_rp1;
    reg  [31:0] tape_rp2;
    reg  [7:0]  tape_rparent1;
    reg  [7:0]  tape_rparent2;
    reg  [31:0] tape_rh11;
    reg  [31:0] tape_rh12;
    reg  [31:0] tape_rh22;

    // BRAM Instantiation (behavioral)
    reg [31:0] mem_val [0:255];
    reg [31:0] mem_p1 [0:255];
    reg [31:0] mem_p2 [0:255];
    reg [7:0]  mem_parent1 [0:255];
    reg [7:0]  mem_parent2 [0:255];
    reg [31:0] mem_h11 [0:255];
    reg [31:0] mem_h12 [0:255];
    reg [31:0] mem_h22 [0:255];

    always @(posedge clk) begin
        if (tape_we) begin
            mem_val[tape_waddr]     <= tape_wval;
            mem_p1[tape_waddr]      <= tape_wp1;
            mem_p2[tape_waddr]      <= tape_wp2;
            mem_parent1[tape_waddr] <= tape_wparent1;
            mem_parent2[tape_waddr] <= tape_wparent2;
            mem_h11[tape_waddr]     <= tape_wh11;
            mem_h12[tape_waddr]     <= tape_wh12;
            mem_h22[tape_waddr]     <= tape_wh22;
        end
        tape_rval     <= mem_val[tape_raddr];
        tape_rp1      <= mem_p1[tape_raddr];
        tape_rp2      <= mem_p2[tape_raddr];
        tape_rparent1 <= mem_parent1[tape_raddr];
        tape_rparent2 <= mem_parent2[tape_raddr];
        tape_rh11     <= mem_h11[tape_raddr];
        tape_rh12     <= mem_h12[tape_raddr];
        tape_rh22     <= mem_h22[tape_raddr];
    end

    wire fwd_done;

    bs_forward_core fwd_inst (
        .clk(clk),
        .rst(rst),
        .S_in(S), .K_in(K), .T_in(T), .r_in(r), .sigma_in(sigma), .is_call(is_call),
        .start(start),
        .price_out(price),
        .done(fwd_done),
        .tape_we(tape_we), .tape_addr(tape_waddr),
        .tape_val(tape_wval), .tape_partial_1(tape_wp1), .tape_partial_2(tape_wp2),
        .tape_parent_1(tape_wparent1), .tape_parent_2(tape_wparent2),
        .tape_h11(tape_wh11), .tape_h12(tape_wh12), .tape_h22(tape_wh22)
    );

    // ------------------------------------------------------------------
    // Pass sequencer: forward -> first-order reverse -> two second-order
    // sweeps (seed = S, then seed = sigma).
    // ------------------------------------------------------------------
    localparam P_IDLE    = 3'd0;
    localparam P_FWD     = 3'd1;
    localparam P_REV     = 3'd2;
    localparam P_SO_S    = 3'd3;
    localparam P_SO_SIG  = 3'd4;
    localparam P_DONE    = 3'd5;

    reg [2:0] phase;
    reg rev_start;
    reg so_start;
    reg [7:0] so_seed;

    wire rev_done;
    wire so_done;

    wire [7:0]  rev_raddr;
    wire [7:0]  so_raddr;
    // Only one consumer reads the tape at a time.
    assign tape_raddr = (phase == P_SO_S || phase == P_SO_SIG) ? so_raddr : rev_raddr;

    bs_reverse_pass rev_inst (
        .clk(clk),
        .rst(rst),
        .start(rev_start),
        .tape_max_idx(tape_waddr), // Last written address is max
        .tape_read_addr(rev_raddr),
        .tape_val(tape_rval), .tape_partial_1(tape_rp1), .tape_partial_2(tape_rp2),
        .tape_parent_1(tape_rparent1), .tape_parent_2(tape_rparent2),
        .delta_out(delta), .vega_out(vega), .theta_out(theta), .rho_out(rho),
        .strike_sens_out(strike_sens),
        .done(rev_done)
    );

    wire signed [31:0] hess_S, hess_K, hess_T, hess_r, hess_sigma;

    bs_second_order so_inst (
        .clk(clk),
        .rst(rst),
        .start(so_start),
        .tape_max_idx(tape_waddr),
        .seed_idx(so_seed),
        .tape_read_addr(so_raddr),
        .tape_partial_1(tape_rp1), .tape_partial_2(tape_rp2),
        .tape_h11(tape_rh11), .tape_h12(tape_rh12), .tape_h22(tape_rh22),
        .tape_parent_1(tape_rparent1), .tape_parent_2(tape_rparent2),
        .hess_S(hess_S), .hess_K(hess_K), .hess_T(hess_T),
        .hess_r(hess_r), .hess_sigma(hess_sigma),
        .done(so_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            phase     <= P_IDLE;
            rev_start <= 1'b0;
            so_start  <= 1'b0;
            done      <= 1'b0;
        end else begin
            rev_start <= 1'b0;
            so_start  <= 1'b0;
            done      <= 1'b0;

            case (phase)
                P_IDLE: if (start) phase <= P_FWD;

                P_FWD: if (fwd_done) begin
                    rev_start <= 1'b1;
                    phase <= P_REV;
                end

                P_REV: if (rev_done) begin
                    so_seed  <= 8'd1;   // seed on S -> gamma, vanna, charm
                    so_start <= 1'b1;
                    phase <= P_SO_S;
                end

                P_SO_S: if (so_done) begin
                    gamma <= hess_S;     // d2V/dS2
                    vanna <= hess_sigma; // d2V/dS dsigma
                    charm <= hess_T;     // d2V/dS dT
                    so_seed  <= 8'd5;   // seed on sigma -> volga
                    so_start <= 1'b1;
                    phase <= P_SO_SIG;
                end

                P_SO_SIG: if (so_done) begin
                    volga <= hess_sigma; // d2V/dsigma2
                    phase <= P_DONE;
                end

                P_DONE: begin
                    done  <= 1'b1;
                    phase <= P_IDLE;
                end

                default: phase <= P_IDLE;
            endcase
        end
    end

endmodule
