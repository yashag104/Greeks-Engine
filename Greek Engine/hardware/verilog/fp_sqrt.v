`timescale 1ns / 1ps
//============================================================================
// Fixed-Point Square Root — Non-Restoring Digit-by-Digit Algorithm
//============================================================================
// Computes sqrt(x) for unsigned fixed-point numbers.
// Input:  Q(IL, FL) unsigned
// Output: Q(ceil(IL/2), FL + floor(IL/2)) adjusted to match output format
//
// The algorithm processes 2 bits per iteration (one bit of result per cycle).
// Total latency: WL/2 + 1 cycles.
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

    // Internal precision: we work with 2*WL bits for the radicand
    // and WL bits for the root
    localparam ITERATIONS = WL;

    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_DONE    = 2'd2;

    reg [1:0] state;

    // Working registers
    reg [2*WL-1:0] radicand;   // Left-shifted input
    reg [2*WL-1:0] remainder;
    reg [WL-1:0]   root;
    reg [6:0]      bit_idx;    // Current bit being computed

    // The radicand needs to be shifted so that the binary point
    // aligns with the output format.
    // For Q(IL, FL) input: we want sqrt to produce Q(ceil(IL/2), FL') output.
    // We shift x left by FL bits so that we're effectively taking
    // sqrt of an integer, then the result has FL fractional bits.

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
                        // Shift input left by FL to align binary point
                        radicand  <= {{WL{1'b0}}, x} << FL;
                        remainder <= 0;
                        root      <= 0;
                        bit_idx   <= WL - 1;
                        state     <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    // Non-restoring square root: process 2 bits at a time
                    // from the radicand, producing 1 bit of root per cycle.

                    // Bring down next 2 bits from radicand
                    remainder <= {remainder[2*WL-3:0], radicand[2*WL-1], radicand[2*WL-2]};
                    radicand  <= radicand << 2;

                    // Trial subtraction
                    if (remainder >= {root, 2'b01}) begin
                        remainder <= remainder - {root, 2'b01};
                        root      <= {root[WL-2:0], 1'b1};
                    end else begin
                        root <= {root[WL-2:0], 1'b0};
                    end

                    if (bit_idx == 0) begin
                        state <= S_DONE;
                    end else begin
                        bit_idx <= bit_idx - 1;
                    end
                end

                S_DONE: begin
                    result <= root;
                    done   <= 1'b1;
                    state  <= S_IDLE;
                end
            endcase
        end
    end

endmodule
