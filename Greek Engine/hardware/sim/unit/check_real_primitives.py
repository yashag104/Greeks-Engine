"""Unit test: fp_exp, fp_log, CORDIC (rotation/vectoring), fp_div vs double precision, at Q16.16 and/or Q32.32.

Prints the worst error in ULPs over random inputs.  Usage: python check_real_primitives.py
"""
import os, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
V = os.path.normpath(os.path.join(HERE, "..", "..", "verilog"))
S = tempfile.mkdtemp()
import math, random, subprocess, sys

random.seed(1)
for WL,FL in [(32,16),(64,32)]:
    U=2.0**FL; lines=[]
    for _ in range(60):
        lines.append("exp %d 0"%int(random.uniform(-12,4.5 if WL==32 else 12)*U))
        lines.append("log %d 0"%int(math.exp(random.uniform(-9,9 if WL==32 else 20))*U))
        lines.append("rot %d 0"%int(random.uniform(-220,220)*U))
        xv=random.uniform(-5,5); yv=random.uniform(-5,5)
        lines.append("vec %d %d"%(int(xv*U), (int(yv*U)*2)|1))   # y[0]=1 selects vectoring; y>>>1 is y
        lines.append("div %d %d"%(int(random.uniform(-100,100)*U), int(random.choice([-1,1])*math.exp(random.uniform(-4,4))*U)))
    open(S+"/prim_in.txt","w").write("\n".join(lines)+"\n")
    subprocess.run(["iverilog","-g2005","-I",V,"-DINFILE=\"%s/prim_in.txt\""%S,"-Pprim_tb.WL=%d"%WL,"-Pprim_tb.FL=%d"%FL,"-o",S+"/prim.vvp",os.path.join(HERE, "prim_tb.v"),V+"/fp_exp.v",V+"/fp_log.v",V+"/cordic.v",V+"/fp_div.v"],check=True)
    out=subprocess.run(["vvp",S+"/prim.vvp"],capture_output=True,text=True).stdout.split("\n")
    err={}
    for l in out:
        p=l.split()
        if not p or p[0] not in ("exp","log","rot","vec","div"): continue
        v=[int(z) for z in p[1:]]
        if p[0]=="exp": e=abs(v[1]/U-math.exp(v[0]/U))/math.exp(v[0]/U)*U if math.exp(v[0]/U)>1 else abs(v[1]/U-math.exp(v[0]/U))*U
        if p[0]=="log": e=abs(v[1]/U-math.log(v[0]/U))*U
        if p[0]=="rot": e=max(abs(v[1]/U-math.cos(v[0]/U)),abs(v[2]/U-math.sin(v[0]/U)))*U
        if p[0]=="vec": e=abs(v[2]/U-math.atan2((v[1]>>1)/U,v[0]/U))*U
        if p[0]=="div": e=abs(v[2]/U-(v[0]/U)/(v[1]/U))*U
        err.setdefault(p[0],[]).append(e)
    print("WL=%d FL=%d  max error in ULPs (exp: relative ULPs for x>0):"%(WL,FL), {k:round(max(x),2) for k,x in err.items()}, {k:len(x) for k,x in err.items()})
