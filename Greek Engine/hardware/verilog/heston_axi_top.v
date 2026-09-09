`timescale 1ns / 1ps
//============================================================================
// Heston-COS AAD AXI4-Stream Wrapper
//============================================================================
// Wraps the top-level Heston engine in standard AXI4-Stream interfaces for
// seamless integration into a Zynq / Alveo FPGA system.
//
// In_Stream:  Receives parameter vector [S0, K, T, r, v0, kappa, theta, xi, rho, is_call]
// Out_Stream: Sends result vector [price, delta, vega, rho, theta, kappa_sens, theta_sens, xi_sens, rho_corr, strike_sens]
//============================================================================

module heston_axi_top #(
    parameter WL = 32,
    parameter FL = 16
) (
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Stream Slave (Input Parameters)
    input  wire [319:0] s_axis_tdata, // 10 parameters * 32 bits = 320 bits
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI4-Stream Master (Output Results)
    output wire [319:0] m_axis_tdata, // 10 results * 32 bits = 320 bits
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // Unpack input data. NOTE: is_call now occupies its own full 32-bit
    // aligned lane ([319:288]) rather than a single stray bit at [288] —
    // that matches this module's own documented "10 parameters * 32 bits
    // = 320 bits" layout above, whereas the single-bit packing left bits
    // [319:289] as unexplained padding and put is_call in a position no
    // AXI master built to the documented layout would expect.
    wire signed [WL-1:0] S0_w    = s_axis_tdata[31:0];
    wire signed [WL-1:0] K_w     = s_axis_tdata[63:32];
    wire signed [WL-1:0] T_w     = s_axis_tdata[95:64];
    wire signed [WL-1:0] r_w     = s_axis_tdata[127:96];
    wire signed [WL-1:0] v0_w    = s_axis_tdata[159:128];
    wire signed [WL-1:0] kappa_w = s_axis_tdata[191:160];
    wire signed [WL-1:0] theta_w = s_axis_tdata[223:192];
    wire signed [WL-1:0] xi_w    = s_axis_tdata[255:224];
    wire signed [WL-1:0] rho_w   = s_axis_tdata[287:256];
    wire                 is_call_w = s_axis_tdata[288];

    // NOTE: latched into registers on the transfer edge (s_axis_tvalid &&
    // s_axis_tready), rather than wiring the engine straight off
    // s_axis_tdata — AXI-Stream lets the master change tdata as soon as
    // the transfer completes (tvalid && tready), but the engine underneath
    // is a many-hundred-thousand-cycle multi-stage pipeline that keeps
    // referencing these signals for its *entire* run, not just at the
    // moment `start` pulses, so leaving them as live combinational wires
    // let the master silently corrupt an in-flight computation.
    reg signed [WL-1:0] S0, K, T, r, v0, kappa, theta, xi, rho;
    reg                 is_call;

    // Core engine interface
    reg  engine_start;
    wire engine_done;
    
    wire signed [WL-1:0] price;
    wire signed [WL-1:0] delta;
    wire signed [WL-1:0] vega;
    wire signed [WL-1:0] rho_greek;
    wire signed [WL-1:0] theta_greek;
    wire signed [WL-1:0] kappa_sens;
    wire signed [WL-1:0] theta_sens;
    wire signed [WL-1:0] xi_sens;
    wire signed [WL-1:0] rho_corr;
    wire signed [WL-1:0] strike_sens;

    // Instantiate Core
    heston_top_level #(.WL(WL), .FL(FL)) core (
        .clk(aclk),
        .rst(~aresetn),
        .S0(S0), .K(K), .T(T), .r(r), .v0(v0),
        .kappa(kappa), .theta(theta), .xi(xi), .rho(rho),
        .is_call(is_call),
        .start(engine_start),
        .price(price),
        .delta(delta),
        .vega(vega),
        .rho_greek(rho_greek),
        .theta_greek(theta_greek),
        .kappa_sens(kappa_sens),
        .theta_sens(theta_sens),
        .xi_sens(xi_sens),
        .rho_corr(rho_corr),
        .strike_sens(strike_sens),
        .done(engine_done)
    );
    
    // Simple state machine to manage AXI handshake
    localparam S_IDLE    = 2'd0;
    localparam S_BUSY    = 2'd1;
    localparam S_OUTPUT  = 2'd2;
    
    reg [1:0] state;
    
    assign s_axis_tready = (state == S_IDLE);
    assign m_axis_tvalid = (state == S_OUTPUT);
    assign m_axis_tlast  = 1'b1; // Single beat response
    
    assign m_axis_tdata = {
        strike_sens, rho_corr, xi_sens, theta_sens, kappa_sens,
        theta_greek, rho_greek, vega, delta, price
    };
    
    always @(posedge aclk) begin
        if (~aresetn) begin
            state <= S_IDLE;
            engine_start <= 0;
        end else begin
            engine_start <= 0;
            case (state)
                S_IDLE: begin
                    if (s_axis_tvalid) begin
                        // s_axis_tready is asserted throughout S_IDLE (see
                        // the assign below), so tvalid here is exactly the
                        // AXI-Stream transfer condition (tvalid && tready)
                        // — latch the whole parameter vector now, since
                        // s_axis_tdata is only guaranteed valid up to and
                        // including this cycle.
                        S0    <= S0_w;    K     <= K_w;     T   <= T_w;
                        r     <= r_w;     v0    <= v0_w;
                        kappa <= kappa_w; theta <= theta_w; xi  <= xi_w;
                        rho   <= rho_w;   is_call <= is_call_w;
                        engine_start <= 1'b1;
                        state <= S_BUSY;
                    end
                end
                
                S_BUSY: begin
                    if (engine_done) begin
                        state <= S_OUTPUT;
                    end
                end
                
                S_OUTPUT: begin
                    if (m_axis_tready) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
