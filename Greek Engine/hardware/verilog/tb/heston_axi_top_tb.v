`timescale 1ns / 1ps
//============================================================================
// AXI4-Stream handshake test for heston_axi_top.v — drives a real
// tvalid/tready transfer in on the slave side (holding tdata stable only
// through the transfer, exactly as a real master is allowed to change it
// right after), and a backpressured tready on the master side (holds
// tready low for a few cycles after tvalid so the S_OUTPUT wait path is
// actually exercised, not just the same-cycle case), then checks every
// field of the unpacked result vector against the double-precision
// reference (same values and tolerance as tb/heston_greeks_tb.v).
//============================================================================

module heston_axi_top_tb;

    localparam WL = 64, FL = 32;

    reg aclk = 0;
    reg aresetn;

    reg  [10*WL-1:0] s_axis_tdata;
    reg          s_axis_tvalid;
    wire         s_axis_tready;
    reg          s_axis_tlast;

    wire [10*WL-1:0] m_axis_tdata;
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

    integer failures = 0;
    // |rtl - ref| <= tol * max(1, |ref|)
    task check(input [8*12-1:0] name, input signed [WL-1:0] v, input real ref, input real tol);
        real got, err, scale;
        begin
            got = v / 4294967296.0;
            err = got - ref; if (err < 0) err = -err;
            scale = (ref < 0 ? -ref : ref); if (scale < 1.0) scale = 1.0;
            if (err > tol * scale) begin
                $display("FAIL %s rtl=%.10f ref=%.10f err=%.3e", name, got, ref, err);
                failures = failures + 1;
            end else
                $display("ok   %s rtl=%.10f ref=%.10f err=%.3e", name, got, ref, err);
        end
    endtask


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
            64'd1, // is_call
            -64'sd3865470566, // rho
            64'sd1288490189, // xi
            64'sd171798692, // theta
            64'sd6442450944, // kappa
            64'sd171798692, // v0
            64'sd214748365, // r
            64'sd4294967296, // T
            64'sd429496729600, // K
            64'sd429496729600 // S0
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
        s_axis_tdata  = {(10*WL){1'bx}};

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

        check("price", m_axis_tdata[1*WL-1:0*WL], 10.387139265110, 1e-6);
        check("delta", m_axis_tdata[2*WL-1:1*WL], 0.714149030000, 1e-6);
        check("vega", m_axis_tdata[3*WL-1:2*WL], 46.600078345200, 1e-6);
        check("rho_greek", m_axis_tdata[4*WL-1:3*WL], 61.027763732000, 1e-6);
        check("theta_greek", m_axis_tdata[5*WL-1:4*WL], 6.414380938900, 1e-6);
        check("kappa_sens", m_axis_tdata[6*WL-1:5*WL], 0.061943319000, 1e-6);
        check("theta_sens", m_axis_tdata[7*WL-1:6*WL], 44.186415478200, 1e-6);
        check("xi_sens", m_axis_tdata[8*WL-1:7*WL], -1.204606597800, 1e-6);
        check("rho_corr", m_axis_tdata[9*WL-1:8*WL], -0.116698662000, 1e-6);
        check("strike_sens", m_axis_tdata[10*WL-1:9*WL], -0.610277637300, 1e-6);

        m_axis_tready = 0;
        @(posedge aclk);
        #1;
        if (s_axis_tready !== 1'b1) begin
            $display("FAIL: did not return to S_IDLE (ready) after the beat was accepted");
            $finish;
        end

        if (failures != 0) begin
            $display("FAIL: %0d result field(s) out of tolerance", failures);
            $finish;
        end
        $display("PASS: AXI4-Stream handshake round-trip OK, %0d cycles", cyc);
        $finish;
    end

endmodule
