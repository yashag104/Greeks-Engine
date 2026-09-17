"""Unit test: complex_div, complex_sqrt, complex_log, complex_exp vs double precision, at Q16.16 and/or Q32.32.

Prints the worst error in ULPs over random inputs.  Usage: python check_complex_primitives.py
"""
import os, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
V = os.path.normpath(os.path.join(HERE, "..", "..", "verilog"))
S = tempfile.mkdtemp()
import cmath, math, random, subprocess, sys

random.seed(3); FL=32; U=2.0**FL
q=lambda v:int(round(v*U))
def rc(lo,hi): return complex(random.uniform(lo,hi)*random.choice([-1,1]), random.uniform(lo,hi)*random.choice([-1,1]))
L=[]
for _ in range(40):
    a=rc(0.001,50); b=rc(0.01,30)
    if random.random()<.3: b=complex(b.real,0)
    L.append("div %d %d %d %d"%(q(a.real),q(a.imag),q(b.real),q(b.imag)))
    z=rc(0.0001,600); 
    if random.random()<.3: z=complex(abs(z.real)+2, z.imag*1e-3)
    L.append("sqrt %d %d 0 0"%(q(z.real),q(z.imag)))
    w=rc(0.05,3); L.append("log %d %d 0 0"%(q(w.real),q(w.imag)))
    e=complex(random.uniform(-15,1), random.uniform(-200,200)); L.append("exp %d %d 0 0"%(q(e.real),q(e.imag)))
open(S+"/cplx_in.txt","w").write("\n".join(L)+"\n")
srcs=[V+"/"+m for m in ["complex_div.v","complex_sqrt.v","complex_log.v","complex_exp.v","fp_div.v","fp_sqrt.v","fp_log.v","fp_exp.v","cordic.v"]]
subprocess.run(["iverilog","-g2005","-I",V,"-DINFILE=\"%s/cplx_in.txt\""%S,"-o",S+"/cplx.vvp",os.path.join(HERE, "cplx_tb.v")]+srcs,check=True)
out=subprocess.run(["vvp","-n",S+"/cplx.vvp"],capture_output=True,text=True).stdout.splitlines()
worst={}
for l in out:
    p=l.split()
    if not p or p[0] not in("div","sqrt","log","exp"): continue
    v=[int(x)/U for x in p[1:]]
    if p[0]=="div": ref=complex(v[0],v[1])/complex(v[2],v[3]); got=complex(v[4],v[5])
    else:
        z=complex(v[0],v[1]); got=complex(v[2],v[3])
        ref={"sqrt":cmath.sqrt,"log":cmath.log,"exp":cmath.exp}[p[0]](z)
    e=abs(got-ref)*U
    rel_ulp = e/ max(abs(ref),1.0)
    if rel_ulp > worst.get(p[0],(0,))[0]: worst[p[0]]=(rel_ulp, e, v)
for k,(r,e,v) in worst.items(): print("%-5s worst err %.1f ULP (abs %.1f ULP) at %s"%(k,r,e,[round(x,6) for x in v[:4]]))
