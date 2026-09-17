`timescale 1ns/1ps
module cplx_tb;
  parameter WL=64, FL=32;
  reg clk=0, rst=1; always #5 clk=~clk;
  reg signed [WL-1:0] ar, ai, br, bi; reg sd=0, ss=0, sl=0, se=0;
  wire signed [WL-1:0] dr, di, qr, qi, lr, li, er, ei; wire dd, sdn, ld, ed;
  complex_div  #(.WL(WL),.FL(FL)) D(.clk(clk),.rst(rst),.a_r(ar),.a_i(ai),.b_r(br),.b_i(bi),.start(sd),.res_r(dr),.res_i(di),.done(dd));
  complex_sqrt #(.WL(WL),.FL(FL)) Q(.clk(clk),.rst(rst),.a_r(ar),.a_i(ai),.start(ss),.res_r(qr),.res_i(qi),.done(sdn));
  complex_log  #(.WL(WL),.FL(FL)) L(.clk(clk),.rst(rst),.a_r(ar),.a_i(ai),.start(sl),.res_r(lr),.res_i(li),.done(ld));
  complex_exp  #(.WL(WL),.FL(FL)) E(.clk(clk),.rst(rst),.a_r(ar),.a_i(ai),.start(se),.res_r(er),.res_i(ei),.done(ed));
  integer f, r; reg [8*8-1:0] op;
  initial begin
    f=$fopen(`INFILE,"r"); #20 rst=0;
    while (!$feof(f)) begin
      r=$fscanf(f,"%s %d %d %d %d\n",op,ar,ai,br,bi);
      @(negedge clk);
      if (op=="div") begin sd=1; @(negedge clk) sd=0; wait(dd); $display("div %0d %0d %0d %0d %0d %0d",ar,ai,br,bi,dr,di); end
      if (op=="sqrt") begin ss=1; @(negedge clk) ss=0; wait(sdn); $display("sqrt %0d %0d %0d %0d",ar,ai,qr,qi); end
      if (op=="log") begin sl=1; @(negedge clk) sl=0; wait(ld); $display("log %0d %0d %0d %0d",ar,ai,lr,li); end
      if (op=="exp") begin se=1; @(negedge clk) se=0; wait(ed); $display("exp %0d %0d %0d %0d",ar,ai,er,ei); end
      @(negedge clk);
    end
    $finish;
  end
endmodule
