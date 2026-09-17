`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Signed Divider — a / b in Q(WL-FL, FL)
//============================================================================
// Sequential restoring division on magnitudes: one quotient bit per clock
// cycle, WL+FL+1 cycles (one extra bit, used to round the magnitude to
// nearest: error <= 0.5 ULP, unbiased), then sign correction. `overflow`
// flags quotients that do not fit WL bits (result then saturates).
//
// NOTE (previous version): waited WL+FL cycles and then computed the
// quotient with a behavioral `/` on a 2*WL-bit dividend — cycle-accurate
// in simulation, but it synthesizes to one enormous combinational divider
// (the `$div` cells in the old Yosys report), not a sequential one, and
// would never close timing on an FPGA.
//
// Latency: WL + FL + 3 cycles from start to ready.
//============================================================================

module fp_div #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [WL-1:0] a,         // Dividend
    input  wire [WL-1:0] b,         // Divisor
    input  wire          start,
    output reg  [WL-1:0] result,
    output reg           ready,
    output reg           divide_by_zero,
    output reg           overflow
);

    localparam integer NB = WL + FL + 1;   // quotient bits (incl. 1 rounding bit)

    localparam IDLE = 2'd0, DIVIDE = 2'd1, DONE = 2'd2;

    reg [1:0]    state;
    reg [NB-1:0] dividend;   // shifts out MSB-first
    reg [NB-1:0] quotient, qround;
    reg [WL:0]   remainder;
    reg [WL-1:0] divisor;
    reg [7:0]    count;
    reg          sign_res;

    wire [WL:0] rem_shift = {remainder[WL-1:0], dividend[NB-1]};
    wire [WL:0] rem_sub   = rem_shift - {1'b0, divisor};

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            ready <= 1'b0;
            result <= 0;
            divide_by_zero <= 1'b0;
            overflow <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    ready <= 1'b0;
                    if (start) begin
                        if (b == 0) begin
                            divide_by_zero <= 1'b1;
                            overflow <= 1'b0;
                            ready  <= 1'b1;
                            result <= 0;
                        end else begin
                            divide_by_zero <= 1'b0;
                            sign_res  <= a[WL-1] ^ b[WL-1];
                            divisor   <= b[WL-1] ? -b : b;
                            dividend  <= {(a[WL-1] ? -a : a), {(FL+1){1'b0}}};
                            remainder <= 0;
                            quotient  <= 0;
                            count     <= NB;
                            state     <= DIVIDE;
                        end
                    end
                end

                DIVIDE: begin
                    if (!rem_sub[WL]) begin          // rem_shift >= divisor
                        remainder <= rem_sub;
                        quotient  <= {quotient[NB-2:0], 1'b1};
                    end else begin
                        remainder <= rem_shift;
                        quotient  <= {quotient[NB-2:0], 1'b0};
                    end
                    dividend <= dividend << 1;
                    count    <= count - 1'b1;
                    if (count == 1) state <= DONE;
                end

                DONE: begin
                    ready <= 1'b1;
                    qround = (quotient + 1'b1) >> 1;
                    if (|qround[NB-1:WL-1]) begin
                        overflow <= 1'b1;
                        result   <= sign_res ? {1'b1, {(WL-1){1'b0}}} : {1'b0, {(WL-1){1'b1}}};
                    end else begin
                        overflow <= 1'b0;
                        result   <= sign_res ? -qround[WL-1:0] : qround[WL-1:0];
                    end
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
