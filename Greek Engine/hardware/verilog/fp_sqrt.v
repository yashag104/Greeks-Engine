`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Square Root — sqrt(x), x >= 0, Q(WL-FL, FL)
//============================================================================
// Digit-by-digit (restoring) integer square root of x * 2^(FL+2): one root
// bit per clock cycle, WL+1 bits, the last of which rounds the result to
// nearest (error <= 0.5 ULP, unbiased; the previous version floored, a
// -0.5 ULP bias per call).
//
// Latency: WL + 3 cycles.
//============================================================================

module fp_sqrt #(
    parameter WL = 32,       // Word length
    parameter FL = 16        // Fractional length
) (
    input  wire            clk,
    input  wire            rst,
    input  wire [WL-1:0]   x,
    input  wire            start,
    output reg  [WL-1:0]   result,
    output reg             done
);

    localparam integer RB = WL + 1;        // root bits (incl. rounding bit)
    localparam integer DB = 2 * RB;        // radicand bits

    localparam S_IDLE = 2'd0, S_COMPUTE = 2'd1, S_DONE = 2'd2;

    reg [1:0]    state;
    reg [DB-1:0] radicand;
    reg [DB-1:0] remainder;
    reg [RB-1:0] root;
    reg [7:0]    bit_idx;

    wire [DB-1:0] remainder_shifted = {remainder[DB-3:0], radicand[DB-1], radicand[DB-2]};
    wire [DB-1:0] trial = {root, 2'b01};

    always @(posedge clk) begin
        if (rst) begin
            state  <= S_IDLE;
            done   <= 1'b0;
            result <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        radicand  <= {{(DB-WL){1'b0}}, x} << (FL + 2);
                        remainder <= 0;
                        root      <= 0;
                        bit_idx   <= RB - 1;
                        state     <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    radicand <= radicand << 2;
                    if (remainder_shifted >= trial) begin
                        remainder <= remainder_shifted - trial;
                        root      <= {root[RB-2:0], 1'b1};
                    end else begin
                        remainder <= remainder_shifted;
                        root      <= {root[RB-2:0], 1'b0};
                    end
                    if (bit_idx == 0) state <= S_DONE;
                    else bit_idx <= bit_idx - 1'b1;
                end

                S_DONE: begin
                    result <= (root + 1'b1) >> 1;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
