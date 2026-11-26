import sys
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
W=sys.argv[1]; out=sys.argv[2]
# --- minimal VCD parser
ids={}; data={}; scope=[]
t=0
with open(W+"/wave.vcd") as f:
    hdr=True
    for line in f:
        s=line.split()
        if not s: continue
        if hdr:
            if s[0]=="$scope": scope.append(s[2])
            elif s[0]=="$upscope": scope.pop()
            elif s[0]=="$var":
                name=".".join(scope[1:]+[s[4]]); ids.setdefault(s[3],[]).append(name); data.setdefault(name,[]); 
                data[name+"#w"]=int(s[2])
            elif s[0]=="$enddefinitions": hdr=False
            continue
        c=s[0]
        if c[0]=="#": t=int(c[1:]); continue
        if c[0] in "01xz" and len(s)==1:
            for n in ids.get(c[1:],[]): data[n].append((t,c[0]))
        elif c[0]=="b":
            for n in ids.get(s[1],[]): data[n].append((t,c[1:]))
        elif c[0]=="$": pass
T_END=t
def val(name,v):
    w=data[name+"#w"]
    if "x" in v or "z" in v: return None
    x=int(v,2)
    if name in SIGNED and x>>(w-1): x-= (1<<w)
    return x
SIGNED={"price","delta","vega","dut.acc_price"}
ns=1000.0  # ps per ns
clkper=10.0
T0=0.0; T1=T_END/1e6  # us
rows=[("clk","clk","clk"),("rst","",None),("start","start","bit"),("busy (running)","dut.running","bit"),
      ("in_setup","dut.in_setup","bit"),("in_term","dut.in_term","bit"),("in_fin","dut.in_fin","bit"),
      ("phase[15:0]","dut.ph","dense"),("k[15:0]","dut.kcur","kbus"),("acc_price[63:0]","dut.acc_price","dense"),
      ("price[63:0]","price","fx"),("delta[63:0]","delta","fx"),("vega[63:0]","vega","fx"),
      ("done","done","bit"),("range_err","range_err","bit")]
rows=[r for r in rows if r[2] is not None]
G="#33e033"; BG="black"
fig,ax=plt.subplots(figsize=(7.16,2.45),dpi=300)
fig.patch.set_facecolor(BG); ax.set_facecolor(BG)
n=len(rows); h=0.62
for i,(lab,sig,kind) in enumerate(rows):
    y=n-1-i
    ax.text(-0.4,y+h/2,lab,color="white",ha="right",va="center",fontsize=5.2,family="monospace")
    ax.axhline(y-0.19,color="#222",lw=0.3)
    if kind=="clk":
        ax.fill_between([T0,T1],y,y+h,color=G,alpha=0.85,lw=0); continue
    ev=[(tt/1e6,v) for tt,v in data[sig]]
    ev.append((T1,ev[-1][1]))
    if kind=="bit":
        xs=[];ys=[]
        for (a,v),(b,_) in zip(ev,ev[1:]):
            lv=y+(h if v=="1" else 0)
            xs+= [a,b]; ys+=[lv,lv]
        ax.plot(xs,ys,color=G,lw=0.6)
        for (a,v),(b,_) in zip(ev,ev[1:]):
            if v=="1" and b-a<0.15: ax.plot([a,a],[y,y+h],color=G,lw=0.9)
        continue
    # bus
    segs=[(a,b,v) for (a,v),(b,_) in zip(ev,ev[1:]) if b>a]
    for a,b,v in segs:
        x=val(sig,v)
        if kind=="dense" and b-a<0.2:
            continue
        ax.plot([a,b],[y+h,y+h],color=G,lw=0.5); ax.plot([a,b],[y,y],color=G,lw=0.5)
        ax.plot([a,a],[y,y+h],color=G,lw=0.3)
    if kind in ("dense","kbus"):
        # shade busy toggling regions
        start=None
        for a,b,v in segs:
            if b-a<0.2:
                if start is None: start=a
                end=b
            else:
                if start is not None: ax.fill_between([start,end],y,y+h,color=G,alpha=0.35,lw=0); start=None
        if start is not None: ax.fill_between([start,end],y,y+h,color=G,alpha=0.35,lw=0)
    for a,b,v in segs:
        x=val(sig,v)
        if x is None: continue
        if kind=="fx": s="%.6f"%(x/2**32)
        elif kind=="kbus": s=str(x)
        else: s=str(x) if abs(x)<1e6 else ""
        if b-a>1.6 and s:
            ax.text((a+b)/2,y+h/2,s,color="white",ha="center",va="center",fontsize=4.6,family="monospace")
    if kind=="kbus":
        for a,b,v in segs:
            x=val(sig,v)
            if x in (0,64,127) and b-a<0.2:
                ax.text(a,y+h+0.08,"k=%d"%x,color="#bbb",fontsize=3.8,ha="center",va="bottom",family="monospace")
ax.set_xlim(T0,T1); ax.set_ylim(-0.4,n)
ax.set_yticks([])
ax.tick_params(colors="white",labelsize=5,length=2)
for s in ax.spines.values(): s.set_color("#666")
ax.set_xlabel("time ($\\mu$s), 100 MHz clock",color="white",fontsize=5.5)
plt.subplots_adjust(left=0.15,right=0.99,top=0.985,bottom=0.16)
plt.savefig(out,facecolor=BG)
