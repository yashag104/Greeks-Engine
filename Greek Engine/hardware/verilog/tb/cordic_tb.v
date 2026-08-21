`timescale 1ns / 1ps

module cordic_tb;

    // Parameters
    localparam WL = 32;
    localparam AL = 32;
    localparam AF = 28;
    localparam FL = 16;
    localparam N_ITER = 30;

    // Inputs
    reg clk;
    reg rst;
    reg start;
    reg mode;
    reg signed [WL-1:0] x_in;
    reg signed [WL-1:0] y_in;
    reg signed [AL-1:0] z_in;

    // Outputs
    wire signed [WL-1:0] x_out;
    wire signed [WL-1:0] y_out;
    wire signed [AL-1:0] z_out;
    wire done;

    // Instantiate the Unit Under Test (UUT)
    cordic #(
        .WL(WL), .AL(AL), .N_ITER(N_ITER), .AF(AF)
    ) uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .mode(mode),
        .x_in(x_in),
        .y_in(y_in),
        .z_in(z_in),
        .x_out(x_out),
        .y_out(y_out),
        .z_out(z_out),
        .done(done)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test sequence
    initial begin
        // Initialize Inputs
        rst = 1;
        start = 0;
        mode = 0;
        x_in = 0;
        y_in = 0;
        z_in = 0;

        // Wait for global reset
        #100;
        rst = 0;
        #10;

        // -----------------------------------------------------
        // Test 1: Rotation Mode (sin/cos of Pi/4)
        // -----------------------------------------------------
        $display("--- Test 1: Rotation Mode (Angle = Pi/4) ---");
        mode = 0; // Rotation
        
        // CORDIC gain 1/K ≈ 0.6072529350 
        // In Q16: 0.6072529350 * 65536 ≈ 39796
        x_in = 39796;
        y_in = 0;
        
        // Angle = Pi/4 ≈ 0.785398
        // In Q(32, 28): 0.785398 * 2^28 ≈ 210828714
        z_in = 210828714;
        
        start = 1;
        #10;
        start = 0;
        
        wait(done);
        #10;
        
        $display("Input: x = 1/K, y = 0, z (angle) = Pi/4");
        // Expected cos(pi/4) = 0.7071 => in Q16: ~46340
        // Expected sin(pi/4) = 0.7071 => in Q16: ~46340
        $display("Output x (cos): %d (Expected: ~46340)", x_out);
        $display("Output y (sin): %d (Expected: ~46340)", y_out);
        $display("---------------------------------------------\n");
        
        // -----------------------------------------------------
        // Test 2: Vectoring Mode (atan2 and magnitude)
        // -----------------------------------------------------
        $display("--- Test 2: Vectoring Mode (x=1.0, y=1.0) ---");
        mode = 1; // Vectoring
        
        // In Q16: 1.0 * 65536 = 65536
        x_in = 65536;
        y_in = 65536;
        z_in = 0;
        
        start = 1;
        #10;
        start = 0;
        
        wait(done);
        #10;
        
        $display("Input: x = 1.0, y = 1.0");
        // Magnitude = sqrt(2) * 1.64676 = 1.414 * 1.64676 = 2.328
        // Angle = Pi/4 ≈ 0.785398 => In Q28: 210828714
        $display("Output x (mag * K): %d", x_out);
        $display("Output z (angle): %d (Expected: ~210828714)", z_out);
        $display("---------------------------------------------\n");
        
        $finish;
    end
      
endmodule
