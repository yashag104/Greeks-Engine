`timescale 1ns / 1ps
//============================================================================
// Heston-COS AAD AXI4-Stream Wrapper
//============================================================================
// Wraps the top-level Heston engine in standard AXI4-Stream interfaces for
// seamless integration into a Zynq / Alveo FPGA system.
//
// In_Stream:  Receives parameter vector [S0, K, T, r, v0, kappa, theta, xi, rho, is_call]
// Out_Stream: Sends result vector [price, delta, vega, rho, theta, kappa_sens, theta_sens, xi_sens, rho_corr]
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
    output wire [287:0] m_axis_tdata, // 9 results * 32 bits = 288 bits
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // Unpack input data
    wire signed [WL-1:0] S0    = s_axis_tdata[31:0];
    wire signed [WL-1:0] K     = s_axis_tdata[63:32];
    wire signed [WL-1:0] T     = s_axis_tdata[95:64];
    wire signed [WL-1:0] r     = s_axis_tdata[127:96];
    wire signed [WL-1:0] v0    = s_axis_tdata[159:128];
    wire signed [WL-1:0] kappa = s_axis_tdata[191:160];
    wire signed [WL-1:0] theta = s_axis_tdata[223:192];
    wire signed [WL-1:0] xi    = s_axis_tdata[255:224];
    wire signed [WL-1:0] rho   = s_axis_tdata[287:256];
    wire                 is_call = s_axis_tdata[288];
    
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
        rho_corr, xi_sens, theta_sens, kappa_sens,
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
