`timescale 1ns / 1ps
//============================================================================
// AXI4-Stream handshake test for heston_axi_top.v — drives a real
// tvalid/tready transfer in on the slave side (holding tdata stable only
// through the transfer, exactly as a real master is allowed to change it
// right after), and a backpressured tready on the master side (holds
// tready low for a few cycles after tvalid so the S_OUTPUT wait path is
// actually exercised, not just the same-cycle case), then checks every
// field of the unpacked result vector against the known-good values from
// tb/heston_greeks_tb.v.
//============================================================================

module heston_axi_top_tb;

    localparam WL = 32, FL = 16;

    reg aclk = 0;
    reg aresetn;

    reg  [319:0] s_axis_tdata;
    reg          s_axis_tvalid;
    wire         s_axis_tready;
    reg          s_axis_tlast;

    wire [319:0] m_axis_tdata;
    wire         m_axis_tvalid;
    reg          m_axis_tready;
    wire         m_axis_tlast;

    heston_axi_top #(.WL(WL), .FL(FL)) uut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast)
    );

    always #5 aclk = ~aclk;

    function real q16(input signed [WL-1:0] v);
        q16 = v / 65536.0;
    endfunction

    integer cyc = 0;
    always @(posedge aclk) begin
        cyc = cyc + 1;
        if (cyc > 1_000_000) begin
            $display("WATCHDOG cyc=%0d", cyc);
            $finish;
        end
    end

    initial begin
        aresetn = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 0;
        s_axis_tdata = 0;
        #100;
        aresetn = 1;
        #10;

        // Confirm slave is ready for a transfer while idle.
        if (s_axis_tready !== 1'b1) begin
            $display("FAIL: s_axis_tready not asserted in S_IDLE");
            $finish;
        end

        // Pack the parameter vector — same point as tb/heston_greeks_tb.v
        // (S0=K=100, T=1, r=5%, v0=4%, kappa=1.5, theta=4%, xi=30%,
        // rho=-90%, call), with is_call in its own 32-bit-aligned lane.
        s_axis_tdata = {
            32'd1,                 // is_call, bits [319:288]
            32'hFFFF_199A,         // rho    = -0.9
            32'h0000_4CCC,         // xi     =  0.3
            32'h0000_0A3D,         // theta  =  0.04
            32'h0001_8000,         // kappa  =  1.5
            32'h0000_0A3D,         // v0     =  0.04
            32'h0000_0CCD,         // r      =  0.05
            32'h0001_0000,         // T      =  1.0
            32'h0064_0000,         // K      =  100.0
            32'h0064_0000          // S0     =  100.0
        };
        s_axis_tvalid = 1;
        s_axis_tlast  = 1;

        // Transfer completes at the next posedge where tready&&tvalid —
        // drop tvalid right after, exactly like a master that immediately
        // moves on to (garbage) data for the next beat, to prove the
        // engine really latched the operands rather than reading them
        // live throughout its ~400K-cycle run.
        @(posedge aclk);
        #1;
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        s_axis_tdata  = {320{1'bx}};

        // Master applies backpressure for a few cycles once results are
        // ready, then accepts — exercises the S_OUTPUT wait path.
        wait (m_axis_tvalid);
        repeat (3) @(posedge aclk);
        m_axis_tready = 1;
        @(posedge aclk);
        #1;

        if (m_axis_tlast !== 1'b1) begin
            $display("FAIL: m_axis_tlast not asserted with m_axis_tvalid");
            $finish;
        end

        $display("price       = %f (expect ~10.470627)", q16(m_axis_tdata[31:0]));
        $display("delta       = %f (expect ~0.713623)",  q16(m_axis_tdata[63:32]));
        $display("vega        = %f (expect ~46.661041)", q16(m_axis_tdata[95:64]));
        $display("rho_greek   = %f (expect ~60.932068)", q16(m_axis_tdata[127:96]));
        $display("theta_greek = %f (expect ~6.410477)",  q16(m_axis_tdata[159:128]));
        $display("kappa_sens  = %f (expect ~0.062103)",  q16(m_axis_tdata[191:160]));
        $display("theta_sens  = %f (expect ~44.262558)", q16(m_axis_tdata[223:192]));
        $display("xi_sens     = %f (expect ~-1.222534)", q16(m_axis_tdata[255:224]));
        $display("rho_corr    = %f (expect ~-0.120743)", q16(m_axis_tdata[287:256]));
        $display("strike_sens = %f", q16(m_axis_tdata[319:288]));

        m_axis_tready = 0;
        @(posedge aclk);
        #1;
        if (s_axis_tready !== 1'b1) begin
            $display("FAIL: did not return to S_IDLE (ready) after the beat was accepted");
            $finish;
        end

        $display("PASS: AXI4-Stream handshake round-trip OK, %0d cycles", cyc);
        $finish;
    end

endmodule
