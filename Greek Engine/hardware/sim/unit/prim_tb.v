`timescale 1ns/1ps
module prim_tb;
  parameter WL=64, FL=32;
  reg clk=0, rst=1; always #5 clk=~clk;
  reg signed [WL-1:0] x, y; reg st_e=0, st_l=0, st_c=0, st_d=0;
  wire [WL-1:0] er; wire signed [WL-1:0] lr, cx, cy; wire [WL-1:0] dr; wire signed [WL-1:0] cz;
  wire de, dl, dc, dd;
  fp_exp #(.WL(WL),.FL(FL)) E(.clk(clk),.rst(rst),.x(x),.start(st_e),.result(er),.done(de));
  fp_log #(.WL(WL),.FL(FL)) L(.clk(clk),.rst(rst),.x(x),.start(st_l),.result(lr),.done(dl),.err_nonpositive());
  cordic #(.WL(WL),.AL(WL),.AF(FL)) C(.clk(clk),.rst(rst),.start(st_c),.mode(y[0]),.x_in(y[0]? x : q), .y_in(y[0]? y>>>1 : 0), .z_in(x), .x_out(cx),.y_out(cy),.z_out(cz),.done(dc));
  fp_div #(.WL(WL),.FL(FL)) D(.clk(clk),.rst(rst),.a(x),.b(y),.start(st_d),.result(dr),.ready(dd),.divide_by_zero(),.overflow());
  localparam integer XFL = FL;
  wire signed [WL-1:0] q = $signed(64'sh09B74EDA8435E5A6 >>> (60-FL));
  integer f, r; real xv, yv; reg [8*8-1:0] op;
  initial begin
    f=$fopen(`INFILE,"r"); #20 rst=0;
    while (!$feof(f)) begin
      r=$fscanf(f,"%s %d %d\n",op,x,y);
      @(negedge clk);
      if (op=="exp") begin st_e=1; @(negedge clk) st_e=0; wait(de); $display("exp %0d %0d", x, er); end
      if (op=="log") begin st_l=1; @(negedge clk) st_l=0; wait(dl); $display("log %0d %0d", x, lr); end
      if (op=="rot") begin st_c=1; @(negedge clk) st_c=0; wait(dc); $display("rot %0d %0d %0d", x, cx, cy); end
      if (op=="vec") begin st_c=1; @(negedge clk) st_c=0; wait(dc); $display("vec %0d %0d %0d", x, y, cz); end
      if (op=="div") begin st_d=1; @(negedge clk) st_d=0; wait(dd); $display("div %0d %0d %0d", x, y, $signed(dr)); end
    end
    $finish;
  end
endmodule
