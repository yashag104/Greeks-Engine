"""Greeks Engine: the complete technical dossier as one self-contained HTML file.

    .venv/bin/python docs/make_dossier.py
    -> docs/greeks_engine_dossier.html   (figures embedded; opens offline anywhere)

Everything in one place: motivation, the mathematical system model, the
architecture, the novelty claims with their evidence and limits, every result,
the comparison with the baselines and with published work, limitations, status
and how to reproduce each number. Figures are read from docs/report/latex/figures
and embedded, so regenerate this file whenever results change.
"""
import base64
import datetime
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FIG = os.path.join(HERE, "report", "latex", "figures")
OUT = os.path.join(HERE, "greeks_engine_dossier.html")


def img(name, alt):
    path = os.path.join(FIG, name)
    b64 = base64.b64encode(open(path, "rb").read()).decode()
    return '<img src="data:image/png;base64,%s" alt="%s">' % (b64, alt)


CSS = r"""
:root{--bg:#fbfbf8;--fg:#1d2321;--muted:#5d6763;--line:#d9ded8;--card:#ffffff;--accent:#1f6f5c;
--accent-soft:#e3f1ec;--warn:#9a5b00;--warn-soft:#fbefd9;--bad:#a23a2e;--bad-soft:#f8e4e0;--good:#1f6f5c;
--code:#f1f3ef;--hi:#eef6f2}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#141816;--fg:#e4e8e5;--muted:#9aa5a0;
--line:#2c3330;--card:#1b201e;--accent:#6cc4a8;--accent-soft:#1f3a32;--warn:#e3a54a;--warn-soft:#3a2d17;
--bad:#ec8b7d;--bad-soft:#3b2220;--good:#6cc4a8;--code:#222826;--hi:#1e2b26}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 "Segoe UI",system-ui,-apple-system,sans-serif}
a{color:var(--accent)}
.wrap{display:grid;grid-template-columns:250px minmax(0,1fr);max-width:1240px;margin:0 auto;gap:36px;padding:0 16px}
nav{position:sticky;top:0;align-self:start;max-height:100vh;overflow:auto;padding:28px 0;font-size:14px}
nav b{display:block;margin:0 0 8px;color:var(--muted);font-size:12px;letter-spacing:.06em;text-transform:uppercase}
nav a{display:block;padding:3px 0;color:var(--fg);text-decoration:none;opacity:.85}
nav a.sub{padding-left:14px;font-size:13px;opacity:.7}
nav a:hover{color:var(--accent);opacity:1}
main{padding:28px 0 80px;min-width:0}
header.top{border-bottom:1px solid var(--line);padding-bottom:18px;margin-bottom:8px}
h1{font-size:30px;line-height:1.2;margin:0 0 6px}
h2{font-size:23px;margin:48px 0 10px;padding-top:8px;border-top:1px solid var(--line)}
h3{font-size:18px;margin:28px 0 8px}
p{margin:8px 0 12px}
.meta{color:var(--muted);font-size:14px}
.lede{font-size:17px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:18px 0}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.kpi .v{font-size:24px;font-weight:650;color:var(--accent)}
.kpi .l{font-size:13px;color:var(--muted)}
.kpi .d{font-size:13px;margin-top:4px}
table{border-collapse:collapse;width:100%;margin:10px 0 6px;font-size:14px;background:var(--card)}
.tbl{overflow-x:auto;margin:10px 0}
th,td{border:1px solid var(--line);padding:6px 9px;text-align:left;vertical-align:top}
th{background:var(--code);font-weight:600}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
tr.hi td{background:var(--hi);font-weight:600}
.cap{font-size:13px;color:var(--muted);margin:4px 0 16px}
.pill{display:inline-block;font-size:12px;padding:1px 8px;border-radius:99px;font-weight:600;white-space:nowrap}
.ok{background:var(--accent-soft);color:var(--good)} .wn{background:var(--warn-soft);color:var(--warn)}
.no{background:var(--bad-soft);color:var(--bad)}
.box{border-left:4px solid var(--accent);background:var(--card);padding:10px 14px;margin:12px 0;border-radius:0 8px 8px 0}
.box.warn{border-color:var(--warn)} .box.bad{border-color:var(--bad)}
.math{font-family:"Cambria Math","STIX Two Math","Times New Roman",serif;font-size:17px;background:var(--code);
padding:10px 14px;border-radius:8px;overflow-x:auto;margin:8px 0 12px;line-height:1.9}
.math i{font-style:italic}
code,.mono{font-family:Consolas,"Cascadia Mono",monospace;font-size:13.5px;background:var(--code);padding:1px 5px;border-radius:4px}
pre{background:var(--code);padding:10px 14px;border-radius:8px;overflow-x:auto;font-size:13px}
figure{margin:14px 0}
figure img{max-width:100%;height:auto;border:1px solid var(--line);border-radius:8px;background:#fff}
figcaption{font-size:13px;color:var(--muted);margin-top:4px}
svg.diag{width:100%;height:auto;max-width:900px;display:block;margin:10px 0}
svg.diag .bx{fill:var(--card);stroke:var(--accent);stroke-width:1.5}
svg.diag .bx2{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1.5}
svg.diag .bx3{fill:var(--code);stroke:var(--line);stroke-width:1.2}
svg.diag text{fill:var(--fg);font:13px "Segoe UI",system-ui,sans-serif}
svg.diag text.t{font-weight:650} svg.diag text.s{font-size:11.5px;fill:var(--muted)}
svg.diag .ar{stroke:var(--muted);stroke-width:1.6;fill:none;marker-end:url(#arw)}
svg.diag #arw path{fill:var(--muted)}
ol.claims>li{margin-bottom:12px}
.two{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media (max-width:860px){.wrap{grid-template-columns:1fr}nav{position:static;max-height:none;border-bottom:1px solid var(--line);padding:16px 0}.two{grid-template-columns:1fr}h1{font-size:25px}}
@media print{nav{display:none}.wrap{display:block}h2{break-before:page}}
"""

SVG_FLOW = r"""
<svg class="diag" viewBox="0 0 900 330" role="img" aria-label="Design flow from the operation graph to the boards">
<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z"/></marker></defs>
<rect class="bx2" x="10" y="120" width="190" height="90" rx="8"/>
<text class="t" x="24" y="146">Operation graph</text>
<text class="s" x="24" y="166">heston.py: setup, COS term</text>
<text class="s" x="24" y="182">(forward + adjoint), finish</text>
<text class="s" x="24" y="198">fixed-point formats per node</text>
<rect class="bx" x="270" y="10" width="200" height="56" rx="8"/><text class="t" x="284" y="34">Bit-accurate emulator</text><text class="s" x="284" y="52">integer model = the RTL's values</text>
<rect class="bx" x="270" y="80" width="200" height="56" rx="8"/><text class="t" x="284" y="104">First-order error bound</text><text class="s" x="284" y="122">AD of the rounding model</text>
<rect class="bx" x="270" y="150" width="200" height="56" rx="8"/><text class="t" x="284" y="174">Modulo scheduler</text><text class="s" x="284" y="192">shared multipliers, CORDIC, II</text>
<rect class="bx" x="270" y="220" width="200" height="56" rx="8"/><text class="t" x="284" y="244">Host C generator</text><text class="s" x="284" y="262">setup/finish for the ARM</text>
<rect class="bx" x="540" y="150" width="160" height="56" rx="8"/><text class="t" x="554" y="174">Verilog generator</text><text class="s" x="554" y="192">RTL + AXI wrappers</text>
<rect class="bx3" x="540" y="40" width="160" height="70" rx="8"/><text class="t" x="554" y="64">verify_all.sh</text><text class="s" x="554" y="82">25 checks: RTL == emulator,</text><text class="s" x="554" y="97">bound holds, C == model</text>
<rect class="bx2" x="748" y="120" width="146" height="110" rx="8"/><text class="t" x="760" y="146">Vivado</text><text class="s" x="760" y="166">ZedBoard (Zynq-7020)</text><text class="s" x="760" y="182">ZCU102 / ZCU104 (US+)</text><text class="s" x="760" y="198">bitstreams, power</text>
<path class="ar" d="M200,150 C235,150 235,38 268,38"/><path class="ar" d="M200,160 C240,160 240,108 268,108"/>
<path class="ar" d="M200,170 L268,178"/><path class="ar" d="M200,190 C240,190 240,248 268,248"/>
<path class="ar" d="M470,178 L538,178"/><path class="ar" d="M700,178 L746,175"/>
<path class="ar" d="M470,38 L538,64"/><path class="ar" d="M620,150 L620,112"/><path class="ar" d="M470,248 C600,248 700,240 746,215"/>
</svg>"""

SVG_ENGINE = r"""
<svg class="diag" viewBox="0 0 900 300" role="img" aria-label="Inside the engine: setup, pipelined term loop, finish">
<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z"/></marker></defs>
<rect class="bx3" x="10" y="100" width="120" height="90" rx="8"/><text class="t" x="22" y="126">9 inputs</text><text class="s" x="22" y="146">S0 K T r v0</text><text class="s" x="22" y="162">kappa theta xi rho</text><text class="s" x="22" y="178">+ call/put</text>
<rect class="bx" x="160" y="100" width="140" height="90" rx="8"/><text class="t" x="172" y="126">Setup (once)</text><text class="s" x="172" y="146">range [a,b], grid,</text><text class="s" x="172" y="162">hoisted constants</text><text class="s" x="172" y="178">(on host for z7h)</text>
<rect class="bx2" x="330" y="30" width="330" height="230" rx="10"/>
<text class="t" x="344" y="54">Term loop: 128 COS terms, one every II cycles</text>
<rect class="bx" x="346" y="70" width="140" height="70" rx="6"/><text class="t" x="356" y="92">Forward</text><text class="s" x="356" y="110">payoff coeff. V_k,</text><text class="s" x="356" y="126">char. function phi</text>
<rect class="bx" x="502" y="70" width="142" height="70" rx="6"/><text class="t" x="512" y="92">Adjoint sweep</text><text class="s" x="512" y="110">reverse chain rule,</text><text class="s" x="512" y="126">8 parameter adjoints</text>
<rect class="bx3" x="346" y="156" width="298" height="88" rx="6"/><text class="t" x="356" y="178">Shared units (Zynq-7020 config.)</text><text class="s" x="356" y="198">8 multipliers 56x56 (9 DSP each), 3 CORDIC rotate,</text><text class="s" x="356" y="214">2 CORDIC vector; II = 32, ~16 terms in flight;</text><text class="s" x="356" y="230">no tape: the schedule is fixed at build time</text>
<rect class="bx" x="690" y="70" width="90" height="70" rx="8"/><text class="t" x="700" y="96">9 sums</text><text class="s" x="700" y="116">accumulated</text><text class="s" x="700" y="130">per term</text>
<rect class="bx" x="690" y="160" width="200" height="90" rx="8"/><text class="t" x="702" y="186">Finish (once)</text><text class="s" x="702" y="206">discount, chain rule, parity</text><text class="s" x="702" y="222">-> price + 9 Greeks</text><text class="s" x="702" y="238">(on host for z7h)</text>
<path class="ar" d="M130,145 L158,145"/><path class="ar" d="M300,145 L328,145"/><path class="ar" d="M486,105 L500,105"/><path class="ar" d="M660,105 L688,105"/><path class="ar" d="M735,140 L765,158"/>
</svg>"""

SVG_SYSTEMS = r"""
<svg class="diag" viewBox="0 0 900 330" role="img" aria-label="The three board systems">
<defs><marker id="arw" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L10,5 L0,10 z"/></marker></defs>
<text class="t" x="10" y="22">A. ZedBoard, JTAG system (run on silicon: 450/450 bit-exact)</text>
<rect class="bx3" x="10" y="34" width="150" height="54" rx="8"/><text x="20" y="56">PC: Vivado Tcl</text><text class="s" x="20" y="74">host steps (Python)</text>
<rect class="bx" x="200" y="34" width="130" height="54" rx="8"/><text x="210" y="56">JTAG-to-AXI</text><text class="s" x="210" y="74">master</text>
<rect class="bx" x="370" y="34" width="150" height="54" rx="8"/><text x="380" y="56">AXI4-Lite</text><text class="s" x="380" y="74">register file</text>
<rect class="bx2" x="560" y="34" width="200" height="54" rx="8"/><text x="570" y="56">engine heston_aad_z7h</text><text class="s" x="570" y="74">56-bit loop, 70 MHz</text>
<path class="ar" d="M160,61 L198,61"/><path class="ar" d="M330,61 L368,61"/><path class="ar" d="M520,61 L558,61"/>
<text class="t" x="10" y="128">B. ZedBoard, processor system (built; board run pending)</text>
<rect class="bx3" x="10" y="140" width="320" height="54" rx="8"/><text x="20" y="162">ARM Cortex-A9: hc_setup / hc_finish in C</text><text class="s" x="20" y="180">bit-exact with the model; times every stage</text>
<rect class="bx" x="370" y="140" width="150" height="54" rx="8"/><text x="380" y="162">M_AXI_GP0</text><text class="s" x="380" y="180">AXI4-Lite, 71.4 MHz</text>
<rect class="bx2" x="560" y="140" width="200" height="54" rx="8"/><text x="570" y="162">engine heston_aad_z7h</text><text class="s" x="570" y="180">51 words in, 18 out</text>
<path class="ar" d="M330,167 L368,167"/><path class="ar" d="M520,167 L558,167"/>
<text class="t" x="10" y="234">C. ZCU102, JTAG system (100 MHz; run bit-exact on the board)</text>
<rect class="bx3" x="10" y="246" width="150" height="54" rx="8"/><text x="20" y="268">PC: Vivado Tcl</text><text class="s" x="20" y="286">no host steps</text>
<rect class="bx" x="200" y="246" width="130" height="54" rx="8"/><text x="210" y="268">JTAG-to-AXI</text><text class="s" x="210" y="286">300 MHz board clock</text>
<rect class="bx" x="370" y="246" width="150" height="54" rx="8"/><text x="380" y="268">AXI4-Lite</text><text class="s" x="380" y="286">19 words in, 20 out</text>
<rect class="bx2" x="560" y="246" width="200" height="54" rx="8"/><text x="570" y="268">engine heston_aad_zu</text><text class="s" x="570" y="286">64-bit, all on chip</text>
<path class="ar" d="M160,273 L198,273"/><path class="ar" d="M330,273 L368,273"/><path class="ar" d="M520,273 L558,273"/>
</svg>"""


def build():
    today = datetime.date.today().strftime("%d %B %Y").lstrip("0")
    F = {
        "cycles": img("fig8_architecture_cycles.png", "Cycles per evaluation, adjoint against bump-and-reprice"),
        "mults": img("fig9_cycles_vs_mults.png", "Cycles against number of shared multipliers"),
        "bump": img("fig10_gen_bump_vs_aad.png", "Bump-and-reprice error against bump size, adjoint as flat lines"),
        "acc": img("fig11_gen_accuracy.png", "Relative error of every output for both designs"),
        "hedge": img("fig12_hedge_risk.png", "Risk left after each hedge on real NIFTY trades"),
        "device": img("vivado_device.png", "Placed design on the Zynq-7020"),
    }
    nav = [("summary", "Summary"), ("problem", "1. Problem and motivation"),
           ("model", "2. System model"), ("m-heston", "Heston model", 1), ("m-cos", "COS pricing", 1),
           ("m-greeks", "The Greeks", 1), ("m-adjoint", "Adjoint differentiation", 1),
           ("m-fixed", "Fixed point and the bound", 1),
           ("arch", "3. Architecture"), ("a-flow", "Design flow", 1), ("a-engine", "Inside the engine", 1),
           ("a-config", "Configurations", 1), ("a-systems", "Board systems", 1), ("a-verify", "Verification", 1),
           ("novelty", "4. Novelty claims"), ("results", "5. Results"), ("r-speed", "Speed and Greeks cost", 1),
           ("r-modes", "Adjoint vs forward mode", 1), ("r-acc", "Accuracy and the bound", 1),
           ("r-method", "COS method error", 1), ("r-bump", "Against bump-and-reprice", 1),
           ("r-wl", "Word length", 1), ("r-impl", "Implementation", 1), ("r-silicon", "On silicon", 1),
           ("r-power", "Power and energy", 1), ("r-cpu", "Against a CPU", 1), ("r-chain", "Strike chains", 1),
           ("r-hedge", "Hedging illustration", 1), ("r-gen1", "Against generation 1", 1),
           ("baselines", "6. Scorecard vs baselines"), ("literature", "7. Comparison with published work"),
           ("limits", "8. Limitations"), ("status", "9. Status and next steps"),
           ("repro", "10. Reproducing the results"), ("refs", "References")]
    navhtml = "<b>Contents</b>" + "".join(
        '<a href="#%s"%s>%s</a>' % (n[0], ' class="sub"' if len(n) > 2 else "", n[1]) for n in nav)
    body = BODY.format(today=today, flow=SVG_FLOW, engine=SVG_ENGINE, systems=SVG_SYSTEMS, **F)
    html = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Greeks Engine Dossier</title><style>%s</style></head><body>'
            '<div class="wrap"><nav>%s</nav><main>%s</main></div></body></html>') % (CSS, navhtml, body)
    open(OUT, "w", encoding="utf-8").write(html)
    print("wrote %s (%.0f KB)" % (OUT, os.path.getsize(OUT) / 1024))


BODY = r"""
<header class="top">
<h1>Greeks Engine: adjoint-differentiated option Greeks on FPGAs</h1>
<p class="meta">Complete technical dossier &middot; Yash Agrawal, Birla Institute of Technology and Science, Pilani &middot;
Supervisor: Prof. Govind Prasad &middot; Course registered under: Prof. Natasha Hazarika &middot; {today}</p>
</header>

<section id="summary">
<p class="lede">A fixed-point FPGA engine that computes the Heston option price <b>and all nine of its sensitivities
(the Greeks)</b> in one forward and one reverse (adjoint) pass of the COS Fourier pricer. It is produced by a
generator that, from one description of the computation, emits a bit-accurate model, a first-order rounding-error
bound for every output, a modulo-scheduled Verilog datapath and the host code. The engine has run on a
ZedBoard (Zynq-7020) and, as a 64-bit configuration computing everything on chip, on a ZCU102 (Zynq UltraScale+),
with every output bit-exact against the model on both.</p>
<div class="kpis">
<div class="kpi"><div class="l">Greeks cost, equal throughput</div><div class="v">1.03&times;</div><div class="d">cycles of a right-sized price-only engine, at 1.68&times; its LUTs and 2&times; its DSPs (Vivado, Zynq-7020)</div></div>
<div class="kpi"><div class="l">Against bump-and-reprice</div><div class="v">18.4&times;</div><div class="d">fewer cycles on the same hardware, and 32&ndash;560&times; more accurate</div></div>
<div class="kpi"><div class="l">On silicon</div><div class="v">1,460 / 1,460</div><div class="d">outputs bit-exact: 450 on the ZedBoard, 1,010 on the ZCU102 (incl. 50 real NIFTY days); worst 0.255 of the error bound</div></div>
<div class="kpi"><div class="l">ZCU102 latency</div><div class="v">15.9 &micro;s</div><div class="d">whole evaluation at 100 MHz (computed); not faster than vectorised analytic Greeks on one CPU core (13.6 &micro;s)</div></div>
<div class="kpi"><div class="l">Error bound</div><div class="v">&le; 0.378</div><div class="d">worst measured error / first-order bound over 10,500 inputs; never exceeded</div></div>
<div class="kpi"><div class="l">Energy</div><div class="v">40&ndash;44 &micro;J</div><div class="d">per evaluation (simulated activity, chip level); parity with the vectorised CPU (40.9 &micro;J, measured)</div></div>
</div>
<div class="box"><b>Verified:</b> bit-exact RTL against the emulator (25 automated checks); bit-exact on the ZedBoard
(1 + 50 cases, twice) and on the ZCU102 (1 + 50 cases + 50 real NIFTY days); error bound over 10,500 + 10,500 held-out
inputs and on every board output; 50-digit check of the bound; routed designs on three devices; activity-based power from
bit-exact gate-level simulation; CPU timings on an idle machine.
<br><b>Pending (needs the ZedBoard or a meter):</b> the ZedBoard end-to-end ARM run (bus-transfer timing) and its NIFTY run,
a board supply-power measurement, and CPU package power.</div>
</section>

<section id="problem">
<h2>1. Problem and motivation</h2>
<p>A desk that holds options needs not only their prices but their <b>Greeks</b>: the derivatives of the price with
respect to every input (spot, strike, maturity, rate and the model's parameters). They drive hedging, risk limits
and model calibration, and must be recomputed whenever the market moves.</p>
<p>Under the <b>Heston</b> stochastic-volatility model there is no closed-form price; it is computed numerically,
here by the <b>COS</b> Fourier-cosine method. The standard way to get Greeks is <b>bump-and-reprice</b>: change one input
slightly and price again. Nine Greeks by central differences cost 19 pricings, and the result depends on a bump size
with no safe choice (too small and rounding dominates, too large and truncation does).</p>
<p><b>Adjoint (reverse-mode) differentiation</b> computes every derivative of one output in a single backward sweep, at a
small constant multiple of one pricing, independent of the number of inputs. In software it is the industry standard
for Greeks, but it records a tape of the computation and replays it, which costs 3&ndash;7 pricings in practice
and is memory-bound. Published FPGA Greeks engines do not use adjoints at all: they re-run the pricer once per
sensitivity (Section 7).</p>
<p><b>The idea:</b> the COS pricer performs exactly the same operations for every input, so its adjoint can be
written once, compiled into a fixed hardware schedule with no tape, and executed on arithmetic units that the forward
pass leaves idle.</p>
</section>

<section id="model">
<h2>2. System model</h2>
<h3 id="m-heston">2.1 The Heston model</h3>
<p>The asset price <i>S</i> and its instantaneous variance <i>v</i> evolve under the risk-neutral measure as</p>
<div class="math">d<i>S<sub>t</sub></i> = <i>r S<sub>t</sub></i> d<i>t</i> + &radic;<i>v<sub>t</sub></i> <i>S<sub>t</sub></i> d<i>W</i><sub>1</sub>,
&nbsp;&nbsp; d<i>v<sub>t</sub></i> = <i>&kappa;</i>(<i>&theta;</i> &minus; <i>v<sub>t</sub></i>) d<i>t</i> + <i>&xi;</i> &radic;<i>v<sub>t</sub></i> d<i>W</i><sub>2</sub>,
&nbsp;&nbsp; d<i>W</i><sub>1</sub> d<i>W</i><sub>2</sub> = <i>&rho;</i> d<i>t</i></div>
<p>with nine inputs: spot <i>S</i><sub>0</sub>, strike <i>K</i>, maturity <i>T</i>, rate <i>r</i>, initial variance
<i>v</i><sub>0</sub>, mean-reversion speed <i>&kappa;</i>, long-run variance <i>&theta;</i>, volatility of variance
<i>&xi;</i> and correlation <i>&rho;</i>. The verified input domain is <i>S</i><sub>0</sub> = 100, <i>K</i> &isin; [60, 150],
<i>T</i> &isin; [0.1, 3], <i>r</i> &isin; [0, 0.1], <i>v</i><sub>0</sub>, <i>&theta;</i> &isin; [0.005, 0.25],
<i>&kappa;</i> &isin; [0.2, 6], <i>&xi;</i> &isin; [0.1, 1], <i>&rho;</i> &isin; [&minus;0.95, 0.6]; outside it the hardware
raises <code>range_err</code> instead of returning a wrong value.</p>
<p>The log-price characteristic function, in the numerically stable form used throughout, with <i>x</i> = ln(<i>S</i><sub>0</sub>/<i>K</i>):</p>
<div class="math"><i>d</i> = &radic;[ (<i>&kappa;</i> &minus; i<i>&rho;&xi;u</i>)<sup>2</sup> + <i>&xi;</i><sup>2</sup>(<i>u</i><sup>2</sup> + i<i>u</i>) ],
&nbsp;&nbsp; <i>g</i> = (<i>&kappa;</i> &minus; i<i>&rho;&xi;u</i> &minus; <i>d</i>) / (<i>&kappa;</i> &minus; i<i>&rho;&xi;u</i> + <i>d</i>)<br>
<i>&phi;</i>(<i>u</i>) = exp{{ i<i>u</i>(<i>x</i> + <i>rT</i>) + (<i>&kappa;&theta;</i>/<i>&xi;</i><sup>2</sup>)[ (<i>&kappa;</i> &minus; i<i>&rho;&xi;u</i> &minus; <i>d</i>)<i>T</i> &minus; 2 ln((1 &minus; <i>g</i>e<sup>&minus;<i>dT</i></sup>)/(1 &minus; <i>g</i>)) ]
+ (<i>v</i><sub>0</sub>/<i>&xi;</i><sup>2</sup>)(<i>&kappa;</i> &minus; i<i>&rho;&xi;u</i> &minus; <i>d</i>)(1 &minus; e<sup>&minus;<i>dT</i></sup>)/(1 &minus; <i>g</i>e<sup>&minus;<i>dT</i></sup>) }}</div>

<h3 id="m-cos">2.2 COS pricing</h3>
<p>The COS method (Fang &amp; Oosterlee) expands the density on a truncation range [<i>a</i>, <i>b</i>] in a cosine series whose
coefficients come from the characteristic function:</p>
<div class="math"><i>V</i> &asymp; <i>K</i> e<sup>&minus;<i>rT</i></sup> &Sigma;&prime;<sub><i>k</i>=0</sub><sup><i>N</i>&minus;1</sup>
Re[ <i>&phi;</i>(<i>u<sub>k</sub></i>) e<sup>&minus;i<i>u<sub>k</sub>a</i></sup> ] <i>V<sub>k</sub></i>,
&nbsp;&nbsp; <i>u<sub>k</sub></i> = <i>k&pi;</i>/(<i>b</i> &minus; <i>a</i>),
&nbsp;&nbsp; [<i>a</i>, <i>b</i>] = <i>c</i><sub>1</sub> &plusmn; 10&radic;<i>c</i><sub>2</sub>,
&nbsp;&nbsp; <i>N</i> = 128</div>
<p>where &Sigma;&prime; halves the first term, <i>c</i><sub>1</sub>, <i>c</i><sub>2</sub> are the first two cumulants and
<i>V<sub>k</sub></i> are the cosine coefficients of the put payoff (closed form in &chi;<sub>k</sub>, &psi;<sub>k</sub>).
<b>Calls are priced as puts plus put-call parity</b>, <i>C</i> = <i>P</i> + <i>S</i><sub>0</sub> &minus; <i>K</i>e<sup>&minus;<i>rT</i></sup>,
because a call's coefficients carry e<sup><i>b</i></sup>, which grows and then cancels and loses precision in fixed point.</p>

<h3 id="m-greeks">2.3 The Greeks</h3>
<p>The engine returns the price and nine sensitivities: delta &part;<i>V</i>/&part;<i>S</i><sub>0</sub>, &part;<i>V</i>/&part;<i>K</i>,
theta &part;<i>V</i>/&part;<i>T</i>, rho &part;<i>V</i>/&part;<i>r</i>, vega &part;<i>V</i>/&part;<i>v</i><sub>0</sub>, and
&part;<i>V</i>/&part;<i>&kappa;</i>, &part;<i>V</i>/&part;<i>&theta;</i>, &part;<i>V</i>/&part;<i>&xi;</i>, &part;<i>V</i>/&part;<i>&rho;</i>.
As is standard for COS, the derivatives are of the COS approximation with the truncation range [<i>a</i>, <i>b</i>] held fixed.
Each term contributes Re[&phi;(<i>u<sub>k</sub></i>)&middot;...]; the parameters enter only through the exponent of &phi;,
so the adjoint sweep is seeded by the adjoint of that exponent and runs back through <i>d</i>, <i>g</i>, the logarithm and the
exponentials to the eight inputs <i>T</i>, <i>r</i>, <i>v</i><sub>0</sub>, <i>&kappa;</i>, <i>&theta;</i>, <i>&xi;</i>,
<i>&rho;</i> and <i>x</i>; delta and &part;<i>V</i>/&part;<i>K</i> follow from &part;<i>V</i>/&part;<i>x</i> in the finish step.</p>

<h3 id="m-adjoint">2.4 Adjoint (reverse-mode) differentiation</h3>
<p>Write the computation as a sequence of elementary operations <i>v<sub>j</sub></i> = <i>f<sub>j</sub></i>(<i>v<sub>i</sub></i>, ...).
The adjoint of each intermediate, <i>v&#772;<sub>i</sub></i> = &part;<i>y</i>/&part;<i>v<sub>i</sub></i>, is accumulated backwards:</p>
<div class="math"><i>y&#772;</i> = 1, &nbsp;&nbsp; <i>v&#772;<sub>i</sub></i> = &Sigma;<sub><i>j</i>: <i>i</i>&rarr;<i>j</i></sub> <i>v&#772;<sub>j</sub></i> &part;<i>f<sub>j</sub></i>/&part;<i>v<sub>i</sub></i>,
&nbsp;&nbsp; &nabla;<i>y</i> = (<i>x&#772;</i><sub>1</sub>, ..., <i>x&#772;<sub>n</sub></i>)</div>
<p>so one backward sweep gives the derivative with respect to every input, at a cost that is a small constant
multiple of the forward pass whatever the number of inputs. Software tools record the operations on a tape and replay it.
Here the graph is the same for every input, so the reverse sweep is written once as operations of the same graph
(<code>hardware/gen/heston.py</code>), shares reciprocals and other values with the forward pass, and is scheduled
statically: <b>no tape and no replay logic</b>. The adjoint is derived by hand at the complex-arithmetic level and verified
against forward mode and finite differences; making the generator derive it automatically is planned work.</p>

<h3 id="m-fixed">2.5 Fixed-point arithmetic and the first-order error bound</h3>
<p>Every value is an integer times 2<sup>&minus;FL</sup>: the Zynq-7020 engine uses 56-bit words with 28 fraction bits,
the 64-bit engine 64-bit words with 32. Normalised quantities (reciprocals, logarithms, CORDIC) use their own mantissa
formats; data-dependent shifts are built only as wide as the ranges measured over the verified domain (with margin),
which saves about a third of the logic, and any input that would exceed them sets <code>range_err</code>. Division,
square root, exponential and logarithm are built from shared multipliers (Newton&ndash;Raphson reciprocals, Tang-style
exponentials) and CORDIC units.</p>
<p>Each operation <i>i</i> rounds its result by at most <i>&epsilon;<sub>i</sub></i> (half a unit in its last place).
To first order the error of an output <i>y</i> is bounded by</p>
<div class="math">| <i>y&#770;</i> &minus; <i>y</i> | &le; &Sigma;<sub><i>i</i></sub> | &part;<i>y</i>/&part;<i>v<sub>i</sub></i> | <i>&epsilon;<sub>i</sub></i> &nbsp;&nbsp; (products of rounding errors, O(2<sup>&minus;2FL</sup>), dropped)</div>
<p>The sensitivities &part;<i>y</i>/&part;<i>v<sub>i</sub></i> come from a second reverse sweep over the rounding model of the
whole datapath, <b>including the hardware's own adjoint</b>, so every Greek gets its own bound in about 0.1 s per parameter set.
The bound covers fixed-point rounding against the same algorithm computed exactly; the COS method's own truncation error
is a separate term (Section 5.4).</p>
</section>

<section id="arch">
<h2>3. Architecture</h2>
<h3 id="a-flow">3.1 Design flow</h3>
{flow}
<p class="cap">One description of the computation (an operation graph with a fixed-point format on every node) produces the
emulator, the bound, the schedule, the Verilog and the host C; <code>verify_all.sh</code> checks each artifact against the others.</p>

<h3 id="a-engine">3.2 Inside the engine</h3>
{engine}
<p>The per-evaluation <b>setup</b> computes the truncation range, grid spacing and every quantity that does not depend on the
term index. The <b>term loop</b> runs the 128 COS terms through one pipelined datapath: each term computes its payoff
coefficient and characteristic function (forward), then the adjoint sweep, and adds its contribution to nine sums.
A <b>modulo scheduler</b> starts a new term every II cycles on a fixed set of shared units; term <i>k</i> uses unit <i>u</i>
at phase (<i>t</i> &minus; <i>S</i>) mod II, values living longer than II get register chains, and about 16 terms are in
flight at once. On the Zynq-7020 configuration the CORDIC units set II = 32, which leaves multiplier slots idle in the
forward pass; the adjoint's multiplies fill them, so the Greeks cost only 165 extra cycles. The <b>finish</b> discounts the
sums, applies the chain rule for delta and &part;<i>V</i>/&part;<i>K</i>, and adds put-call parity for calls.</p>

<h3 id="a-config">3.3 Configurations</h3>
<div class="tbl"><table>
<tr><th>Design</th><th>Word</th><th class="n">Multipliers</th><th>CORDIC</th><th>Setup/finish</th><th class="n">Cycles</th><th>Target</th></tr>
<tr><td><code>heston_aad_z7</code></td><td>56-bit, Q28</td><td class="n">8</td><td>3 rot., 2 vec., iterative</td><td>on chip</td><td class="n">4,733</td><td>Zynq-7020 (not routed)</td></tr>
<tr class="hi"><td><code>heston_aad_z7h</code></td><td>56-bit, Q28</td><td class="n">8</td><td>3 rot., 2 vec., iterative</td><td>host (Python or ARM C)</td><td class="n">4,572 (loop)</td><td>ZedBoard, on silicon</td></tr>
<tr class="hi"><td><code>heston_aad_zu</code></td><td>64-bit, Q32</td><td class="n">32</td><td>1 rot., 1 vec., pipelined</td><td>on chip</td><td class="n">1,593</td><td>ZCU102, on silicon at 100 MHz</td></tr>
</table></div>
<p class="cap">One parameter (the number of shared multipliers) moves the design between a small engine for a low-cost FPGA and a fast one for a large FPGA (Section 5.1).</p>

<h3 id="a-systems">3.4 Board systems</h3>
{systems}
<p>All three systems use generated AXI4-Lite register files around the engine (the AXI4-Stream wrappers, up to 1,456 bits
wide, are too wide for any Zynq processor port). In A and C the PC drives the bus over JTAG through Vivado, so the only thing
under test is the engine. In B the ARM computes the setup and finish steps as C generated from the same graph, bit-exact with
the model on 300 inputs including the portable 64&times;64&rarr;128-bit multiply the 32-bit ARM needs, and times every stage
with the Cortex-A9 global timer.</p>

<h3 id="a-verify">3.5 Verification</h3>
<p><code>verify_all.sh</code> runs 25 automated checks: arithmetic primitives within 2.5&ndash;4 ULP; the first-generation
engines; every generated datapath bit-exact against the emulator at the register level and its cycle count equal to the
schedule; out-of-domain inputs raising <code>range_err</code>; every AXI wrapper bit-exact; host steps + FPGA loop equal to the
on-chip design; the committed RTL equal to the generator's output; the host C bit-exact with two arithmetic paths; the ARM
program on a register model (100 cases); and the emulator's accuracy and bound. Board scripts are tested against a model of
Vivado's hardware manager with injected faults.</p>
</section>

<section id="novelty">
<h2>4. Novelty claims</h2>
<p>Literature checks on 29 September and 6 October 2026 (full texts searched where available;
<code>docs/novelty_assessment.md</code>) found no prior work for claims 1 and 2.</p>
<ol class="claims">
<li><b>The first FPGA implementation of adjoint (reverse-mode) differentiation for option Greeks.</b> Every published FPGA
Greeks engine re-runs the pricer once per sensitivity; the 2024 survey of 99 FPGA option-pricing studies and the 2024 review of
fifteen years of adjoint differentiation in finance contain no FPGA adjoint implementation. <span class="pill wn">Wording</span>
keep &ldquo;adjoint&rdquo; and &ldquo;for option Greeks&rdquo;: forward-mode AD has run in an FPGA soft processor (Schoder &amp; B&uuml;cker),
so &ldquo;first AD on an FPGA&rdquo; would be false.</li>
<li><b>The first FPGA implementation of the COS method.</b> COS had run on CPUs and GPUs; the only FPGA Fourier pricer (AMD's
<code>hcfEngine</code>) uses trapezoidal integration and returns the price alone.</li>
<li><b>A co-scheduled adjoint datapath with a register-resident tape.</b> The hand-derived reverse sweep is scheduled into the
forward pass's fixed-point datapath and shares its units; forward values live in statically allocated rotating registers, possible
because the COS pricer's graph does not depend on its inputs.</li>
<li><b>All nine Greeks for 1.04 pricings on the same hardware; 1.03&times; the cycles and ~1.7&times; the area of a price-only engine of equal throughput; fewer resources than forward mode.</b> Forward-mode datapaths built by the same generator need
more multiplies for the same Greeks: 313 per term hand-factored like analytic Greeks and 802 as an AD tool would build them,
against the adjoint's 250; reaching the same pace takes 10 and 26 multipliers against 8. <span class="pill wn">Wording</span>
the 1.04&times; itself is not unique (with 16 multipliers the factored forward method also reaches it); the claim is fewer
DSP blocks for the same speed.</li>
<li><b>A first-order rounding-error bound for every Greek of a fixed-point adjoint datapath</b>, never exceeded: worst 0.103 of the
bound over 21 cases, 0.378 over 10,500 inputs, 0.356 over 10,500 held-out inputs, 0.24 against a 50-digit evaluation, 0.199 on the ZedBoard and 0.255 on the ZCU102.
<span class="pill wn">Wording</span> &ldquo;first-order&rdquo; and &ldquo;rounding only&rdquo;; the method builds on Linnainmaa (1976).</li>
<li><b>Bit-exact Greeks on silicon, on two FPGA families:</b> 450 of 450 outputs of 50 random cases on a ZedBoard, run twice on successive designs; 1,010 of 1,010 for the 64-bit engine on a ZCU102 (1 vector, 50 random cases, 50 real NIFTY days).</li>
<li><b>A generator for fixed-point adjoint datapaths</b> that emits the emulator, bound, schedule, Verilog, wrappers and host C from one
description (tool contribution; Pham et al. 2016 generated Monte Carlo pricers without Greeks).</li>
</ol>
<div class="box warn"><b>Not claimed:</b> any speed or energy advantage over a CPU: vectorised analytic Greeks take 13.6 &micro;s on one laptop core
(the ZCU102 engine's computed latency is 15.9 &micro;s), four cores give 216,000 evaluations/s, and energy is at parity
(40 vs 40.9 &micro;J); a statistical hedging result.</div>
</section>

<section id="results">
<h2>5. Results</h2>
<h3 id="r-speed">5.1 Speed and the cost of the Greeks</h3>
<div class="tbl"><table>
<tr><th>Design</th><th class="n">Price + 9 Greeks</th><th class="n">Price only</th><th class="n">Bump-and-reprice</th><th class="n">Bump &divide; adjoint</th><th class="n">Greeks cost</th></tr>
<tr><td>First generation (hand-written, 64-bit)</td><td class="n">433,779</td><td class="n">200,562</td><td class="n">3,811,647</td><td class="n">8.8&times;</td><td class="n">2.16&times;</td></tr>
<tr class="hi"><td>Generated, Zynq-7020 (56-bit, 8 multipliers)</td><td class="n">4,733</td><td class="n">4,568</td><td class="n">86,860</td><td class="n">18.4&times;</td><td class="n">1.04&times;</td></tr>
<tr><td>Generated, board design (loop on FPGA)</td><td class="n">4,572</td><td class="n">&ndash;</td><td class="n">&ndash;</td><td class="n">&ndash;</td><td class="n">&ndash;</td></tr>
<tr class="hi"><td>Generated, 64-bit (32 multipliers)</td><td class="n">1,593</td><td class="n">1,026</td><td class="n">19,562</td><td class="n">12.3&times;</td><td class="n">1.55&times;</td></tr>
</table></div>
<p class="cap">Clock cycles per evaluation from cycle-exact RTL simulation (128 COS terms). Greeks cost = cycles with Greeks / cycles for the price alone.</p>
<div class="two"><figure>{cycles}<figcaption>Cycles per evaluation, adjoint against bump-and-reprice on the same hardware (log scale).</figcaption></figure>
<figure>{mults}<figcaption>Cycles against shared multipliers (64-bit); circled points simulated as RTL and matched the schedule.</figcaption></figure></div>

<h3 id="r-modes">5.2 Adjoint against forward mode on the same hardware</h3>
<div class="tbl"><table>
<tr><th>Datapath (same generator, primitives, scheduler)</th><th class="n">Multiplies / term</th><th class="n">Z7, 8 mult.</th><th class="n">Z7, 16 mult.</th><th class="n">64-bit, 32 mult.</th><th class="n">Mult. for II 32</th></tr>
<tr><td>Price only</td><td class="n">126</td><td class="n">4,566</td><td class="n">4,561</td><td class="n">1,024</td><td class="n">4</td></tr>
<tr class="hi"><td>Adjoint (this work)</td><td class="n">250</td><td class="n">4,731</td><td class="n">4,619</td><td class="n">1,591</td><td class="n">8</td></tr>
<tr><td>Forward, factored (hand-derived analytic)</td><td class="n">313</td><td class="n">5,622</td><td class="n">4,571</td><td class="n">1,795</td><td class="n">10</td></tr>
<tr><td>Forward, sparse</td><td class="n">396</td><td class="n">6,968</td><td class="n">4,571</td><td class="n">2,171</td><td class="n">13</td></tr>
<tr><td>Forward, dense (as an AD tool)</td><td class="n">802</td><td class="n">13,597</td><td class="n">7,150</td><td class="n">3,822</td><td class="n">26</td></tr>
</table></div>
<p class="cap">All variants agree with the adjoint to 6&times;10<sup>&minus;14</sup> in double precision (<code>validation/run_mode_baselines.py</code>).
The forward datapaths lack the tangent rescaling a fixed-point engine would need, so their counts are lower bounds.</p>

<h3 id="r-acc">5.3 Accuracy and the first-order bound</h3>
<div class="tbl"><table>
<tr><th>Output</th><th class="n">Zynq-7020 (56-bit)</th><th class="n">64-bit</th><th class="n">Worst error &divide; bound</th></tr>
<tr><td>Price</td><td class="n">6.1e-7</td><td class="n">2.8e-8</td><td class="n">0.074</td></tr>
<tr><td>Delta</td><td class="n">2.0e-7</td><td class="n">6.9e-9</td><td class="n">0.049</td></tr>
<tr><td>&part;V/&part;K</td><td class="n">2.5e-7</td><td class="n">6.6e-9</td><td class="n">0.051</td></tr>
<tr><td>&part;V/&part;T</td><td class="n">3.1e-7</td><td class="n">6.0e-9</td><td class="n">0.093</td></tr>
<tr><td>Rho</td><td class="n">2.4e-7</td><td class="n">8.9e-9</td><td class="n">0.049</td></tr>
<tr><td>Vega</td><td class="n">6.2e-7</td><td class="n">2.0e-8</td><td class="n">0.103</td></tr>
<tr><td>&part;V/&part;&kappa;</td><td class="n">7.8e-6</td><td class="n">4.1e-7</td><td class="n">0.098</td></tr>
<tr><td>&part;V/&part;&theta;</td><td class="n">7.9e-7</td><td class="n">3.4e-8</td><td class="n">0.102</td></tr>
<tr><td>&part;V/&part;&xi;</td><td class="n">2.7e-6</td><td class="n">2.2e-7</td><td class="n">0.099</td></tr>
<tr><td>&part;V/&part;&rho;</td><td class="n">1.2e-5</td><td class="n">7.4e-7</td><td class="n">0.087</td></tr>
</table></div>
<p class="cap">Worst relative error against the same algorithm in double precision over 21 parameter sets spanning moneyness, maturity, vol-of-vol, correlation, calls and puts.</p>
<div class="two"><div>
<p><b>Over the whole domain</b> (<code>validation/run_domain_sweep.py</code>): 6,000 uniform inputs, 500 in each of seven hard regimes
(Feller-violating, extreme correlation, deep strikes, short and long maturities, high vol-of-vol, very low variance) and 1,000
out-of-domain inputs. The bound held in every unflagged result (worst 0.378), with no overflow. A <b>held-out</b> sweep of the
same size with a fresh seed (the ranges were refitted after the first) gave no in-domain flag and a worst of 0.356.</p>
<p><b>Significant figures</b> against double precision (9,500 held-out in-domain inputs): price, delta, strike, theta, rho and vega
&ge; 5.3 in 99% of inputs (median 7.6&ndash;8.1, worst 3.3&ndash;4.4); &part;V/&part;&theta;, &part;V/&part;&rho; 4.9;
&part;V/&part;&kappa; and &part;V/&part;&xi; only 3.5 and 3.0 (worst 2.2 and 1.4 where they are small).</p>
<p><b>The bound is first order.</b> A 50-digit evaluation of the same graph on 100 held-out inputs put the hardware's error at most 0.24
of the bound, identical to three decimals to the figure against double precision; the bound also held at 44 bits, where
second-order terms are relatively 4,096 times larger.</p></div>
<figure>{acc}<figcaption>Relative error of every output for both designs over the 21 parameter sets.</figcaption></figure></div>

<h3 id="r-method">5.4 COS truncation error, a separate term</h3>
<div class="tbl"><table>
<tr><th>Output</th><th class="n">Method error, median</th><th class="n">Method error, worst</th><th class="n">Rounding, worst</th><th class="n">Rounding bound, worst</th></tr>
<tr><td>Price</td><td class="n">2.1e-11</td><td class="n">4.4e-5</td><td class="n">1.5e-5</td><td class="n">2.8e-4</td></tr>
<tr><td>Delta</td><td class="n">6.9e-10</td><td class="n">8.3e-5</td><td class="n">1.1e-7</td><td class="n">1.6e-6</td></tr>
<tr><td>Vega</td><td class="n">1.3e-9</td><td class="n">7.8e-3</td><td class="n">1.4e-5</td><td class="n">2.0e-4</td></tr>
<tr><td>&part;V/&part;&theta;</td><td class="n">5.6e-9</td><td class="n">2.5e-3</td><td class="n">7.0e-5</td><td class="n">1.8e-3</td></tr>
<tr><td>&part;V/&part;&xi;</td><td class="n">1.3e-9</td><td class="n">1.8e-3</td><td class="n">2.1e-4</td><td class="n">4.5e-3</td></tr>
</table></div>
<p class="cap">Absolute errors over the 50 board cases: COS (128 terms, double) against an independent Fourier integral. Of the five worst cases
three need more terms (256 matches the integral) and two a wider range (1.5&times; matches). Total error against the model &le; rounding bound + method error.</p>

<h3 id="r-bump">5.5 Against bump-and-reprice</h3>
<figure>{bump}<figcaption>Bump-and-reprice error is U-shaped in the bump size with no safe setting for every Greek; the adjoint Greeks (flat lines)
are 32&ndash;560 times more accurate than bumping at the best bump size for each Greek (median 145&times;), with nothing to tune.</figcaption></figure>

<h3 id="r-wl">5.6 Accuracy against word length</h3>
<div class="tbl"><table>
<tr><th>Word (fraction bits)</th><th class="n">Worst price error</th><th class="n">Worst Greek error</th><th class="n">Error &divide; bound</th></tr>
<tr><td>44-bit (16)</td><td class="n">1.5e-3</td><td class="n">2.8e-1</td><td class="n">0.167</td></tr>
<tr><td>48-bit (20)</td><td class="n">1.8e-4</td><td class="n">9.1e-3</td><td class="n">0.121</td></tr>
<tr><td>52-bit (24)</td><td class="n">5.0e-6</td><td class="n">5.8e-4</td><td class="n">0.113</td></tr>
<tr class="hi"><td>56-bit (28), this design</td><td class="n">6.1e-7</td><td class="n">1.2e-5</td><td class="n">0.103</td></tr>
<tr><td>64-bit (32)</td><td class="n">2.8e-8</td><td class="n">7.4e-7</td><td class="n">0.099</td></tr>
</table></div>
<p class="cap">Every four bits removed costs roughly 10&ndash;50&times; in Greek accuracy; the bound held at every width, so it predicts the trade-off without building each design.</p>

<h3 id="r-impl">5.7 Implementation</h3>
<div class="tbl"><table>
<tr><th>Build</th><th class="n">LUT</th><th class="n">Registers</th><th class="n">DSP</th><th class="n">Clock</th><th class="n">Slack</th></tr>
<tr><td>Zynq-7020 engine alone, current design (xc7z020clg484-1)</td><td class="n">35,782 (67%)</td><td class="n">27,204</td><td class="n">72 (33%)</td><td class="n">70 MHz</td><td class="n">+0.109 ns</td></tr>
<tr><td>Zynq-7020 engine alone, 29 Sep design, 100 MHz target</td><td class="n">36,499 (69%)</td><td class="n">28,559</td><td class="n">72</td><td class="n">Fmax ~79 MHz</td><td class="n">&minus;2.639 ns</td></tr>
<tr class="hi"><td>ZedBoard JTAG system (on silicon)</td><td class="n">38,752 (73%)</td><td class="n">32,134</td><td class="n">72 (33%)</td><td class="n">70 MHz</td><td class="n">+0.458 ns</td></tr>
<tr><td>ZedBoard processor system</td><td class="n">&ndash;</td><td class="n">&ndash;</td><td class="n">72</td><td class="n">71.4 MHz</td><td class="n">+0.080 ns</td></tr>
<tr class="hi"><td>ZCU102 JTAG system (xczu9eg, on silicon)</td><td class="n">77,515 (28%)</td><td class="n">63,547</td><td class="n">510 (20%)</td><td class="n">100 MHz</td><td class="n">+1.601 ns</td></tr>
<tr><td>ZCU104 JTAG system (xczu7ev)</td><td class="n">77,863 (34%)</td><td class="n">63,796</td><td class="n">510 (30%)</td><td class="n">100 MHz</td><td class="n">+1.469 ns</td></tr>
<tr><td>ZCU104 engine alone</td><td class="n">77,128 (33%)</td><td class="n">59,942</td><td class="n">&ndash;</td><td class="n">100 MHz</td><td class="n">+2.189 ns</td></tr>
</table></div>
<figure style="max-width:520px">{device}<figcaption>The placed ZedBoard design: the engine fills about three quarters of the Zynq-7020's logic.</figcaption></figure>
<p>The 64-bit carry chains limit the Zynq-7020 to about 79 MHz (Vivado suggests the DSP blocks' internal registers as the route to 100 MHz).
On the ZCU104 the engine alone reaches about 128 MHz and the system about 117 MHz; the ZCU102 system reaches about 119 MHz. The board ran at 100 MHz, with margin.</p>

<h3 id="r-silicon">5.8 On silicon (ZedBoard and ZCU102)</h3>
<div class="tbl"><table>
<tr><th>Run</th><th class="n">Cases</th><th class="n">Bit-exact</th><th class="n">range_err</th><th class="n">Worst error &divide; bound</th></tr>
<tr><td>ZedBoard, first vector (6 Oct 2026)</td><td class="n">1</td><td class="n">9 / 9</td><td class="n">0</td><td class="n">0.049</td></tr>
<tr class="hi"><td>ZedBoard, sweep, back to back</td><td class="n">50</td><td class="n">450 / 450</td><td class="n">0</td><td class="n">0.199</td></tr>
<tr><td>ZCU102 (64-bit), first vector (25 Oct 2026)</td><td class="n">1</td><td class="n">10 / 10</td><td class="n">0</td><td class="n">0.099</td></tr>
<tr class="hi"><td>ZCU102, sweep, back to back</td><td class="n">50</td><td class="n">500 / 500</td><td class="n">0</td><td class="n">0.243</td></tr>
<tr class="hi"><td>ZCU102, 50 real NIFTY days, back to back</td><td class="n">50</td><td class="n">500 / 500</td><td class="n">0</td><td class="n">0.255</td></tr>
</table></div>
<p class="cap">2 reference + 48 random cases (22 calls, 28 puts), no reset between cases. Worst price error against double precision 1.5&times;10<sup>&minus;5</sup>,
down from 2.3&times;10<sup>&minus;3</sup> before put-call parity (the 29 Sep bitstream was also 450/450 bit-exact, worst 0.268). On the ZCU102 the
64-bit engine computes all ten outputs on chip; its worst price error is 7.3&times;10<sup>&minus;7</sup>. The ZCU102 was built and run in Vivado 2026.1 on a
lab PC; the board run checks every output but cannot time the engine (JTAG is far slower than an evaluation).</p>

<h3 id="r-power">5.9 Power and energy</h3>
<div class="tbl"><table>
<tr><th>Engine alone (routed)</th><th class="n">Default guess</th><th class="n">Simulated activity</th><th class="n">Latency</th><th class="n">Energy / evaluation</th></tr>
<tr class="hi"><td>ZedBoard engine, 70 MHz</td><td class="n">0.204 W</td><td class="n">0.676 W</td><td class="n">65.3 &micro;s (loop)</td><td class="n">44 &micro;J</td></tr>
<tr class="hi"><td>64-bit engine (xczu7ev), 100 MHz</td><td class="n">1.288 W</td><td class="n">2.485 W</td><td class="n">15.9 &micro;s (whole)</td><td class="n">40 &micro;J</td></tr>
</table></div>
<p class="cap">Each routed netlist was simulated gate by gate on four evaluations (two board cases, two real NIFTY days; all outputs bit-exact) and the
activity read back into Vivado's power analysis (confidence High). The default 12.5% toggle rate underestimated dynamic power 3&ndash;6&times;. Engine only;
a board supply measurement is pending (the ARM program has idle/run windows for it). The ZCU102's xczu9eg adds 0.03 W of static power, so the
64-bit engine's energy stays at about 40 &micro;J there.</p>

<h3 id="r-cpu">5.10 Against a CPU (same algorithm)</h3>
<div class="tbl"><table>
<tr><th>Price + 9 Greeks</th><th class="n">&micro;s / evaluation</th><th class="n">Cost vs one price</th><th class="n">Evaluations / s</th></tr>
<tr><td>CPU, price only (1 core)</td><td class="n">13.7</td><td class="n">1&times;</td><td class="n">&ndash;</td></tr>
<tr><td>CPU, bump-and-reprice</td><td class="n">238.1</td><td class="n">17.4&times;</td><td class="n">&ndash;</td></tr>
<tr><td>CPU, adjoint with CoDiPack</td><td class="n">103.8</td><td class="n">7.6&times;</td><td class="n">26,900 (4 cores)</td></tr>
<tr><td>CPU, forward mode, 9 directions</td><td class="n">78.0</td><td class="n">5.7&times;</td><td class="n">34,000 (4 cores)</td></tr>
<tr><td>CPU, optimised bump</td><td class="n">146.6</td><td class="n">10.7&times;</td><td class="n">&ndash;</td></tr>
<tr><td>CPU, hand-derived analytic Greeks</td><td class="n">20.3</td><td class="n">1.5&times;</td><td class="n">158,000 (4 cores)</td></tr>
<tr class="hi"><td>FPGA, ZedBoard at 70 MHz (loop only)</td><td class="n">65.3</td><td class="n">1.04&times;</td><td class="n">15,300 (1 engine)</td></tr>
<tr class="hi"><td>FPGA, ZCU102 at 100 MHz (whole evaluation; bit-exact on the board)</td><td class="n">15.9</td><td class="n">1.55&times;</td><td class="n">62,800 (1 engine)</td></tr>
</table></div>
<p class="cap">Intel Core i5-1155G7 laptop, C++ double precision, g++ -O3 -march=native, CoDiPack v2.3.2; every method matches the reference. All CPU rows
are from one run on an idle machine (23 Oct 2026; throughput from 8 processes on the 4 cores). The CPU's work outside its 128-term loop is about 0.03 &micro;s,
so loop-to-loop comparison is fair; the FPGA figures exclude only the bus transfers, which the ARM program will measure.</p>

<h3 id="r-chain">5.11 Many strikes at once (design study)</h3>
<p>All strikes of one expiry share the COS grid, so one characteristic function and one adjoint sweep per term serve every strike; each
extra strike costs 16 multiplies and one rotation per term (about 7% of one option). Scheduled and emulated, not built:</p>
<div class="tbl"><table>
<tr><th class="n">Strikes</th><th class="n">Z7-style cycles</th><th class="n">per strike</th><th class="n">64-bit cycles</th><th class="n">per strike</th></tr>
<tr><td class="n">1</td><td class="n">4,662</td><td class="n">4,662</td><td class="n">1,577</td><td class="n">1,577</td></tr>
<tr><td class="n">4</td><td class="n">5,436</td><td class="n">1,359</td><td class="n">1,829</td><td class="n">457</td></tr>
<tr><td class="n">16</td><td class="n">8,767</td><td class="n">548</td><td class="n">2,854</td><td class="n">178</td></tr>
<tr><td class="n">32</td><td class="n">12,860</td><td class="n">402</td><td class="n">4,892</td><td class="n">153</td></tr>
</table></div>
<p class="cap">The same sharing helps a CPU as much (2.3 &micro;s per strike at 32 strikes on one idle core), and pricing many strikes from one
characteristic function is standard COS practice, so this is a design result, not a novelty claim.</p>

<h3 id="r-hedge">5.12 Illustration: hedging on real NIFTY data</h3>
<div class="two"><div><p>Twelve short at-the-money NIFTY call trades (Sep 2025 &ndash; Sep 2026, NSE end-of-day data, real quotes only), hedged
daily with futures after every Indian charge and 30% tax, with the Heston model calibrated each day to about 170 real option prices.
Spread of profit and loss per trade: unhedged &#8377;5.55 L, Black&ndash;Scholes delta &#8377;2.05 L, Heston delta &#8377;2.50 L, and the
<b>minimum-variance hedge</b> (delta plus &rho;&xi;/S&middot;vega, two Greeks from the same pass) &#8377;1.26 L.</p>
<div class="box warn">An illustration, not evidence for the hardware: the hedge decisions come from the hedging formula, are insensitive to word
length (48-bit deltas trade the same lots), and a double-precision CPU would trade the same lots. Twelve trades give about 88% bootstrap
confidence. The 50 trading days' calibrated parameters are ready as board vectors for both boards.</div></div>
<figure>{hedge}<figcaption>Risk left after each hedge, including rebalancing every 2 or 5 days and 48/44-bit engines.</figcaption></figure></div>

<h3 id="r-gen1">5.13 Against the first generation</h3>
<div class="tbl"><table>
<tr><th></th><th>First generation (hand-written FSM)</th><th>Generated engine</th></tr>
<tr><td>Cycles, price + 9 Greeks</td><td>433,779</td><td><b>4,733</b> (92&times; fewer)</td></tr>
<tr><td>Cost of the Greeks</td><td>2.16 pricings</td><td><b>1.04</b> pricings</td></tr>
<tr><td>Multipliers</td><td>159 dedicated 64&times;64 (over 1,000 DSP)</td><td><b>8 shared</b> (72 DSP)</td></tr>
<tr><td>Dividers</td><td>28 bit-serial per term, 80% of latency</td><td><b>none</b></td></tr>
<tr><td>Terms</td><td>one after another</td><td><b>about 16 overlapping</b></td></tr>
<tr><td>Fits a Zynq-7020 / on silicon</td><td>no / no</td><td><b>yes</b> (73% LUT) / <b>yes</b>, bit-exact</td></tr>
</table></div>
</section>

<section id="baselines">
<h2>6. Scorecard against the baselines</h2>
<div class="tbl"><table>
<tr><th>Baseline</th><th>Measure</th><th>Result</th><th></th></tr>
<tr><td rowspan="2">Bump-and-reprice, same hardware</td><td>Cycles</td><td>18.4&times; fewer (Zynq-7020); 12.3&times; (64-bit)</td><td><span class="pill ok">better</span></td></tr>
<tr><td>Accuracy</td><td>32&ndash;560&times; more accurate (median 145&times;), nothing to tune</td><td><span class="pill ok">better</span></td></tr>
<tr><td rowspan="2">Forward mode, same generator and hardware</td><td>Multiplies per term</td><td>250 against 313 (best analytic, +25%) and 802 (AD tool, 3.2&times;)</td><td><span class="pill ok">better</span></td></tr>
<tr><td>Speed at equal multipliers</td><td>4,731 vs 5,622 and 13,597 cycles (8 mult.); equal once CORDIC-bound with 16</td><td><span class="pill ok">better</span> / <span class="pill wn">equal</span></td></tr>
<tr><td rowspan="6">CPU, same algorithm (i5-1155G7)</td><td>Greeks overhead</td><td>1.04 pricings vs 1.5 (analytic), 5.7&ndash;7.6 (AD tools), 17.4 (bump)</td><td><span class="pill ok">better</span></td></tr>
<tr><td>Latency, Zynq-7020</td><td>65.3 &micro;s vs 20.3 &micro;s analytic (CPU 3.2&times; faster); 1.2&ndash;3.6&times; faster than AD tools and bumping</td><td><span class="pill no">worse</span> vs analytic</td></tr>
<tr><td>Latency, ZCU102</td><td>15.9 &micro;s (computed) vs 20.3 &micro;s scalar / 13.6 &micro;s vectorised analytic; 4.9&ndash;15&times; faster than AD tools and bumping</td><td><span class="pill no">worse</span> vs vectorised</td></tr>
<tr><td>Throughput</td><td>4 CPU cores 216k/s (vectorised) vs one engine 15.3k/s (Zynq) or 62.8k/s (ZCU102)</td><td><span class="pill no">worse</span></td></tr>
<tr><td>Energy</td><td>40&ndash;44 &micro;J (chip level, simulated) vs 40.9 &micro;J vectorised / 54.6 &micro;J scalar (measured package power)</td><td><span class="pill wn">parity</span></td></tr>
<tr><td>Accuracy</td><td>Fixed point is less precise than double, but rounding sits below the COS method's own error in typical cases, and only the FPGA gives a per-Greek bound</td><td><span class="pill wn">trade-off</span></td></tr>
<tr><td>First generation (hand-written)</td><td>Cycles, area</td><td>92&times; fewer cycles; fits a Zynq-7020; bit-exact on silicon</td><td><span class="pill ok">better</span></td></tr>
</table></div>
</section>

<section id="literature">
<h2>7. Comparison with published work</h2>
<p>Published FPGA finance work is mostly Monte Carlo pricing over large batches, reported as batch runtime or energy against multi-core
servers; this work evaluates one option at a time by a Fourier method. Those numbers measure different things and are <b>not directly
comparable</b>; the table positions the works by what they compute and how, with each paper's own headline figure where it was read
from the source.</p>
<div class="tbl"><table>
<tr><th>Work</th><th>Platform</th><th>Model / pricing</th><th>How the Greeks are computed</th><th>Accuracy guarantee</th><th>Reported result</th></tr>
<tr class="hi"><td><b>This work</b></td><td>Zynq-7020 (ZedBoard), Zynq UltraScale+ (ZCU102)</td><td>Heston, COS (128 terms), fixed point 56/64-bit</td><td><b>Adjoint datapath</b>, all 9 in one pass, no tape</td><td><b>First-order bound per Greek</b>, never exceeded</td><td>4,733 / 1,593 cycles; 1.04&times; price; 1,460/1,460 outputs bit-exact on silicon; 15.9 &micro;s (ZCU102)</td></tr>
<tr><td>Klaisoongnoen, Brown &amp; Thomson Brown, HEART 2022</td><td>Alveo U280 (300 MHz) vs 2&times; 24-core Xeon Platinum 8260M</td><td>STAC-A2: Heston Monte Carlo paths + Longstaff&ndash;Schwartz, up to 1.6&times;10<sup>9</sup> path elements</td><td>Not adjoint or AD; the benchmark re-runs simulation for sensitivities</td><td>None; precision (double, single, half, fixed) explored empirically</td><td>8&ndash;185&times; efficiency improvement over the CPUs</td></tr>
<tr><td>Klaisoongnoen et al., H2RC 2022</td><td>Xilinx and Intel FPGAs</td><td>Streaming version of the above</td><td>Not adjoint or AD</td><td>None</td><td>Streaming throughput and energy (batch)</td></tr>
<tr><td>AMD Vitis Quantitative Finance Library</td><td>Alveo (HLS)</td><td>Heston Monte Carlo; Heston closed form (<code>hcfEngine</code>, trapezoidal integration)</td><td>Central finite differences, re-running Monte Carlo per bump; closed form gives the price only</td><td>None</td><td>Library, no Greeks study</td></tr>
<tr><td>De Schryver et al., ReConFig 2011</td><td>FPGA</td><td>Heston Monte Carlo</td><td>Price only</td><td>None</td><td>Energy-efficient pricing</td></tr>
<tr><td>Pham, Aung &amp; Kumar, ReConFig 2016</td><td>FPGA (generated)</td><td>Monte Carlo, several models</td><td>No Greeks</td><td>None</td><td>Generator of pricing accelerators</td></tr>
<tr><td>Zhang &amp; Oosterlee, 2009</td><td>GPU</td><td>COS</td><td>Price only</td><td>None</td><td>COS on an accelerator</td></tr>
<tr><td>Gremse et al., 2016</td><td>GPU</td><td>General</td><td>Taped AAD (tape built on the CPU)</td><td>None</td><td>AAD on GPUs</td></tr>
<tr><td>de Beer (UCT), 2017</td><td>GPU (GTX 950 / K40) vs Xeon CPU</td><td>Heston Monte Carlo, 3-asset rainbow option</td><td>Hand-written pathwise adjoint, 6 Greeks</td><td>None</td><td>422&times; over the CPU, 13 M paths/s</td></tr>
<tr><td>Arsaguet &amp; Bilokon, 2023</td><td>GPU</td><td>Heston Monte Carlo</td><td>Simulation-based sensitivities</td><td>None</td><td>GPU Greeks</td></tr>
<tr><td>Cui, del Ba&ntilde;o Rollin &amp; Germano, EJOR 2017</td><td>CPU</td><td>Heston Fourier</td><td>Analytic gradient by hand</td><td>&ndash;</td><td>About 10&times; faster than numerical gradients</td></tr>
<tr><td>Capriotti, US patent 9,058,449</td><td>General-purpose processors</td><td>Monte Carlo</td><td>Adjoint &ldquo;simulating machine&rdquo;</td><td>&ndash;</td><td>No FPGA or custom datapath</td></tr>
<tr><td>Schoder &amp; B&uuml;cker, 2024/25</td><td>Alveo U50 (RISC-V soft core)</td><td>General programs</td><td><b>Forward-mode</b> AD in the processor</td><td>&ndash;</td><td>AD in FPGA hardware, no finance</td></tr>
<tr><td>Boudaoud et al. (DaCe AD), 2025</td><td>CPU, GPU (FPGA back end not evaluated)</td><td>General</td><td>Reverse-mode AD framework</td><td>&ndash;</td><td>No finance</td></tr>
<tr><td>O Mahony et al., survey 2024 (99 studies); Capriotti &amp; Giles, review 2024</td><td>&ndash;</td><td>&ndash;</td><td>No FPGA adjoint implementation in either</td><td>&ndash;</td><td>Establish the gap</td></tr>
</table></div>
<div class="box"><b>Where this work stands:</b> it is the only entry that computes Greeks on an FPGA by an adjoint, the only FPGA COS
implementation, and the only one with a guaranteed per-Greek rounding bound and a bit-exact silicon result. It does not compete on batch
throughput with large Alveo Monte Carlo designs; its comparable quantities are the cost of the Greeks relative to a price, their accuracy,
and latency and energy per evaluation.</div>
</section>

<section id="limits">
<h2>8. Limitations</h2>
<ul>
<li><b>Board runs pending</b> for the ZedBoard processor system (bus-transfer timing) and its NIFTY run. The ZCU102 latency is the cycle count at the clock: the board run checks every output but JTAG cannot time the engine.</li>
<li><b>CPU power measured</b> with HWiNFO (package power, 29 Oct); CPU timings measured on an idle machine.</li>
<li><b>Power is simulated, engine only</b>: no clock generator, bus or board; a supply measurement is pending. 57% of nets were matched by name, the rest propagated.</li>
<li><b>Latency</b>: on the Zynq-7020 one laptop core with hand-derived Greeks is 3.2&times; faster (timing does not close at 100 MHz there, Fmax ~79 MHz); on the ZCU102 the engine is slower than vectorised analytic Greeks on one core (13.6 &micro;s), and four cores give 3.4&times; its throughput.</li>
<li><b>The bound is first order and covers rounding only</b>; the COS method's own error is separate and reaches 7.8&times;10<sup>&minus;3</sup> on vega in the worst board case.</li>
<li><b>&part;V/&part;&kappa; and &part;V/&part;&xi;</b> carry only about 3 significant figures at the 99th percentile.</li>
<li><b>The adjoint is hand-derived</b> (verified, not generated by an AD tool); say &ldquo;adjoint differentiation&rdquo;.</li>
<li><b>Bounded input domain</b>; outside it the hardware raises <code>range_err</code>.</li>
<li><b>Hedging</b> is an illustration with 12 trades; charge rates still to be checked with a broker.</li>
</ul>
</section>

<section id="status">
<h2>9. Status and next steps</h2>
<div class="tbl"><table>
<tr><th>Item</th><th>Status</th></tr>
<tr><td>Generated engine, emulator, bound, scheduler, RTL, wrappers, host C; 25 automated checks</td><td><span class="pill ok">done</span></td></tr>
<tr><td>ZedBoard on silicon, 450/450 bit-exact (current design)</td><td><span class="pill ok">done</span></td></tr>
<tr><td>Forward-mode baselines; 50-digit check; held-out sweep; COS method error; claims corrected</td><td><span class="pill ok">done</span></td></tr>
<tr><td>ZCU104 bitstream (100 MHz); ZedBoard processor design + ARM program; NIFTY vectors; simulated-activity power</td><td><span class="pill ok">done</span></td></tr>
<tr><td>ZCU102 build and board runs: test, 50-case sweep, 50 NIFTY days, 1,010/1,010 bit-exact (25 Oct)</td><td><span class="pill ok">done</span></td></tr>
<tr><td>CPU timings on an idle machine (23 Oct)</td><td><span class="pill ok">done</span></td></tr>
<tr><td>ZedBoard ARM end-to-end run (bus-transfer timing) and NIFTY run</td><td><span class="pill wn">needs the board</span></td></tr>
<tr><td>Board supply power; CPU package power</td><td><span class="pill wn">needs measurement</span></td></tr>
<tr><td>Paper: venue, template, authors; writing; supervisor review; final literature check</td><td><span class="pill wn">next</span></td></tr>
<tr><td>Generator derives the adjoint automatically; more engines per device; 100 MHz on the Zynq-7020</td><td><span class="pill no">after the paper</span></td></tr>
</table></div>
</section>

<section id="repro">
<h2>10. Reproducing the results</h2>
<pre>cd "Greek Engine"
./verify_all.sh                                    # 25 checks: RTL, wrappers, host C, bound
.venv/bin/python validation/run_mode_baselines.py  # adjoint vs forward mode
.venv/bin/python validation/run_domain_sweep.py [--heldout]   # 10,500-input sweeps
.venv/bin/python validation/sigfig_report.py       # significant figures
.venv/bin/python validation/run_mp_check.py 100    # 50-digit check of the bound
.venv/bin/python validation/run_method_error.py    # COS method error
.venv/bin/python validation/cpu_baseline/run_baseline.py      # CPU comparison
hardware/vivado/zedboard/run_board.bat build | test | sweep | nifty | ps
hardware/vivado/zcu104/run_board.bat   build | test | sweep | nifty
hardware/vivado/zcu102/run_board.sh    dry | build | test | sweep | nifty   (Linux; make_bundle.py packs it)
.venv/bin/python validation/board_report.py &lt;log&gt; --design zu [--cases-csv ...]   # error vs bound on silicon
hardware/sw/zedboard: vitis -s build_vitis.py ; xsdb run_app.tcl
hardware/vivado/power: run_engine_power.tcl &lt;top&gt; &lt;part&gt; &lt;clk_ns&gt;</pre>
<p>Key files: <code>hardware/gen/</code> (graph, emulator, bound, scheduler, generators), <code>hardware/verilog/gen/</code> (generated RTL),
<code>validation/results/</code> (every number above), <code>docs/report/latex/</code> (the project report), <code>docs/architecture.md</code>
and <code>docs/novelty_assessment.md</code> (detailed notes).</p>
</section>

<section id="refs">
<h2>References</h2>
<ol style="font-size:14px">
<li>S. L. Heston, &ldquo;A closed-form solution for options with stochastic volatility&rdquo;, Rev. Financial Studies 6(2), 1993.</li>
<li>F. Fang, C. W. Oosterlee, &ldquo;A novel pricing method for European options based on Fourier-cosine series expansions&rdquo;, SIAM J. Sci. Comput. 31(2), 2008.</li>
<li>M. Giles, P. Glasserman, &ldquo;Smoking adjoints: fast Monte Carlo Greeks&rdquo;, Risk, 2006.</li>
<li>L. Capriotti, M. Giles, &ldquo;15 years of adjoint algorithmic differentiation in finance&rdquo;, 2024.</li>
<li>S. Linnainmaa, &ldquo;Taylor expansion of the accumulated rounding error&rdquo;, BIT 16, 1976.</li>
<li>M. Klaisoongnoen, N. Brown, O. Thomson Brown, &ldquo;Low-power option Greeks: efficiency-driven market risk analysis using FPGAs&rdquo;, HEART 2022 (arXiv:2206.03719).</li>
<li>M. Klaisoongnoen et al., &ldquo;Fast and energy-efficient derivatives risk analysis: streaming option Greeks on Xilinx and Intel FPGAs&rdquo;, H2RC 2022.</li>
<li>AMD (Xilinx), Vitis Quantitative Finance Library (open source).</li>
<li>C. de Schryver et al., &ldquo;An energy efficient FPGA accelerator for Monte Carlo option pricing with the Heston model&rdquo;, ReConFig 2011.</li>
<li>T. Pham, K. Aung, A. Kumar, &ldquo;Automatic framework to generate reconfigurable accelerators for option pricing applications&rdquo;, ReConFig 2016.</li>
<li>B. Zhang, C. W. Oosterlee, &ldquo;Option pricing with COS method on graphics processing units&rdquo;, IEEE IPDPS workshops, 2009.</li>
<li>F. Gremse et al., &ldquo;GPU-accelerated adjoint algorithmic differentiation&rdquo;, Comput. Phys. Commun., 2016.</li>
<li>J. de Beer, &ldquo;Accelerated adjoint algorithmic differentiation with applications in finance&rdquo;, MPhil dissertation, University of Cape Town, 2017.</li>
<li>Arsaguet, Bilokon, &ldquo;Derivatives sensitivities computation under Heston model on GPU&rdquo;, arXiv:2309.10477, 2023.</li>
<li>Y. Cui, S. del Ba&ntilde;o Rollin, G. Germano, &ldquo;Full and fast calibration of the Heston stochastic volatility model&rdquo;, EJOR 263(2), 2017.</li>
<li>L. Capriotti, US patent 9,058,449 (adjoint Greeks simulating machine).</li>
<li>J. Schoder, M. B&uuml;cker, &ldquo;Scaling an augmented RISC-V processor design with high-level synthesis&rdquo;, RISC-V for HPC, ISC 2024 (Springer 2025).</li>
<li>A. Boudaoud et al., &ldquo;DaCe AD&rdquo;, arXiv:2509.02197, 2025.</li>
<li>A. O Mahony, B. Hanzon, E. Popovici, &ldquo;The role of FPGAs in modern option pricing techniques: a survey&rdquo;, Electronics 13(16):3186, 2024.</li>
<li>CoDiPack v2.3.2 (SciCompKL), operator-overloading AD for C++.</li>
</ol>
</section>
"""

if __name__ == "__main__":
    build()
