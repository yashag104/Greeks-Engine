"""Build the project report: docs/report/greeks_engine_report.pdf.

    cd "Greek Engine" && .venv/bin/python docs/report/make_report.py

Needs reportlab and pypdf in the venv, and the DejaVu / Noto fonts shipped
with most Linux distributions. The cycle and accuracy tables are read from
validation/results/*.csv, so they follow the data; every other number is
stated in the text with the file it comes from.
"""
import csv
import os

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (Image, KeepTogether, NextPageTemplate, PageBreak, PageTemplate, Paragraph,
                                Spacer, Table, TableStyle, Frame, BaseDocTemplate)
from reportlab.platypus.tableofcontents import TableOfContents

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
FIG = os.path.join(ROOT, "validation", "figures")
RES = os.path.join(ROOT, "validation", "results")
OUT = os.path.join(HERE, "greeks_engine_report.pdf")

# ---------------------------------------------------------------- fonts
F = "/usr/share/fonts/truetype"
for name, path in [("Serif", "dejavu/DejaVuSerif.ttf"), ("Serif-B", "dejavu/DejaVuSerif-Bold.ttf"),
                   ("Serif-I", "dejavu/DejaVuSerif-Italic.ttf"), ("Serif-BI", "dejavu/DejaVuSerif-BoldItalic.ttf"),
                   ("Head", "dejavu/DejaVuSansCondensed-Bold.ttf"), ("Sans", "dejavu/DejaVuSansCondensed.ttf"),
                   ("Mono", "noto/NotoSansMono-Regular.ttf"), ("Mono-B", "noto/NotoSansMono-Bold.ttf")]:
    pdfmetrics.registerFont(TTFont(name, os.path.join(F, path)))
pdfmetrics.registerFontFamily("Serif", normal="Serif", bold="Serif-B", italic="Serif-I", boldItalic="Serif-BI")

INK = colors.HexColor("#16202a")
MUTED = colors.HexColor("#56626b")
ACCENT = colors.HexColor("#0f6b5c")
RULE = colors.HexColor("#d5dbd3")
SUNK = colors.HexColor("#eef1ec")
HI = colors.HexColor("#dcefe9")

S = {
    "body": ParagraphStyle("body", fontName="Serif", fontSize=9.6, leading=14, textColor=INK, spaceAfter=6),
    "small": ParagraphStyle("small", fontName="Serif", fontSize=8.4, leading=11.5, textColor=MUTED, spaceAfter=4),
    "cap": ParagraphStyle("cap", fontName="Serif", fontSize=8.2, leading=11.2, textColor=MUTED, spaceBefore=3, spaceAfter=12),
    "h1": ParagraphStyle("h1", fontName="Head", fontSize=15, leading=19, textColor=INK, spaceBefore=14, spaceAfter=8),
    "h2": ParagraphStyle("h2", fontName="Head", fontSize=11.5, leading=15, textColor=ACCENT, spaceBefore=10, spaceAfter=5),
    "tochead": ParagraphStyle("tochead", fontName="Head", fontSize=11.5, leading=15, textColor=ACCENT, spaceBefore=10, spaceAfter=5),
    "bullet": ParagraphStyle("bullet", fontName="Serif", fontSize=9.6, leading=14, textColor=INK, leftIndent=12,
                             bulletIndent=2, spaceAfter=3),
    "td": ParagraphStyle("td", fontName="Serif", fontSize=8.2, leading=10.5, textColor=INK),
    "tdn": ParagraphStyle("tdn", fontName="Mono", fontSize=7.8, leading=10.5, textColor=INK, alignment=2),
    "th": ParagraphStyle("th", fontName="Head", fontSize=7.8, leading=10, textColor=MUTED),
    "thn": ParagraphStyle("thn", fontName="Head", fontSize=7.8, leading=10, textColor=MUTED, alignment=2),
    "toc1": ParagraphStyle("toc1", fontName="Serif", fontSize=9.6, leading=14, leftIndent=0),
    "toc2": ParagraphStyle("toc2", fontName="Serif", fontSize=8.8, leading=12, leftIndent=14, textColor=MUTED),
}

W = A4[0] - 40 * mm   # text width


class Doc(BaseDocTemplate):
    def __init__(self, path):
        super().__init__(path, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm, topMargin=20 * mm,
                         bottomMargin=20 * mm, title="Greeks Engine: project report", author="Yash Agrawal",
                         subject="FPGA reverse-mode AAD for Heston option Greeks")
        fr = Frame(self.leftMargin, self.bottomMargin, self.width, self.height, id="f")
        self.addPageTemplates([PageTemplate("cover", [fr], onPage=lambda c, d: None),
                               PageTemplate("body", [fr], onPage=self.chrome)])

    def chrome(self, c, d):
        c.saveState()
        c.setFont("Sans", 7.5)
        c.setFillColor(MUTED)
        c.drawString(20 * mm, A4[1] - 12 * mm, "Greeks Engine · project report · 29 September 2026")
        c.drawRightString(A4[0] - 20 * mm, 12 * mm, str(d.page))
        c.setStrokeColor(RULE)
        c.line(20 * mm, A4[1] - 14 * mm, A4[0] - 20 * mm, A4[1] - 14 * mm)
        c.restoreState()

    def afterFlowable(self, f):
        if isinstance(f, Paragraph) and f.style.name in ("h1", "h2"):
            lvl = 0 if f.style.name == "h1" else 1
            key = "h%d" % id(f)
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(f.getPlainText(), key, level=lvl, closed=False)
            self.notify("TOCEntry", (lvl, f.getPlainText(), self.page, key))


story = []
P = lambda t, s="body": story.append(Paragraph(t, S[s]))
H1 = lambda t: story.append(Paragraph(t, S["h1"]))
H2 = lambda t: story.append(Paragraph(t, S["h2"]))


def bullets(items):
    for t in items:
        story.append(Paragraph(t, S["bullet"], bulletText="•"))


def table(head, rows, widths, num=(), hi=(), keep=True, cap=None, lead=None):
    """num: indices of numeric columns; hi: indices of highlighted rows"""
    data = [[Paragraph(h, S["thn"] if i in num else S["th"]) for i, h in enumerate(head)]]
    for r in rows:
        data.append([Paragraph(str(v), S["tdn"] if i in num else S["td"]) for i, v in enumerate(r)])
    t = Table(data, colWidths=[w * W for w in widths], repeatRows=1)
    st = [("BACKGROUND", (0, 0), (-1, 0), SUNK), ("LINEBELOW", (0, 0), (-1, -1), 0.4, RULE),
          ("BOX", (0, 0), (-1, -1), 0.6, RULE), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
          ("TOPPADDING", (0, 0), (-1, -1), 3.5), ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5)]
    for r in hi:
        st.append(("BACKGROUND", (0, r + 1), (-1, r + 1), HI))
    t.setStyle(TableStyle(st))
    parts = ([Paragraph(lead, S["body"])] if lead else []) + [t] + ([Paragraph(cap, S["cap"])] if cap else [Spacer(1, 10)])
    story.append(KeepTogether(parts) if keep else parts[0])
    if not keep and cap:
        story.append(parts[1])


def figure(path, cap, width=1.0):
    from reportlab.lib.utils import ImageReader
    iw, ih = ImageReader(path).getSize()
    w = W * width
    story.append(KeepTogether([Image(path, width=w, height=w * ih / iw), Paragraph(cap, S["cap"])]))


def fmt(n):
    return "{:,}".format(int(n))


# ================================================================ cover
story.append(Spacer(1, 50 * mm))
story.append(Paragraph("GREEKS ENGINE", ParagraphStyle("k", fontName="Mono", fontSize=9, textColor=ACCENT, leading=12)))
story.append(Spacer(1, 4 * mm))
story.append(Paragraph("Option Greeks in one hardware pass", ParagraphStyle("t", fontName="Head", fontSize=26, leading=31, textColor=INK)))
story.append(Spacer(1, 5 * mm))
story.append(Paragraph("A fixed-point FPGA datapath for the Heston model that computes the price and all nine "
                       "sensitivities with reverse-mode algorithmic differentiation, verified bit-exact in "
                       "simulation and on a Zynq-7020 board", ParagraphStyle("s", fontName="Serif-I", fontSize=12, leading=17, textColor=MUTED)))
story.append(Spacer(1, 18 * mm))
story.append(Paragraph("Project report and status", ParagraphStyle("r", fontName="Head", fontSize=11, textColor=INK, leading=15)))
story.append(Paragraph("Yash Agrawal · BITS Pilani", ParagraphStyle("a", fontName="Serif", fontSize=10.5, textColor=INK, leading=15)))
story.append(Paragraph("29 September 2026 · branch <font name='Mono'>pipeline-shared-mult</font>",
                       ParagraphStyle("d", fontName="Serif", fontSize=10, textColor=MUTED, leading=15)))
story.append(NextPageTemplate("body"))
story.append(PageBreak())

# ================================================================ abstract + contents
H1("Abstract")
P("Risk management of option portfolios needs not only prices but their sensitivities to every input, the Greeks. "
  "Under the Heston stochastic-volatility model the price has no closed form and is computed numerically, here by the "
  "Fourier-cosine (COS) method with 128 terms. The usual way to obtain Greeks from such a pricer, bump-and-reprice, "
  "costs 19 pricings for nine Greeks and its accuracy depends on an unsafe choice of bump size. Reverse-mode "
  "algorithmic differentiation (AAD) obtains all Greeks from one backward sweep, and is standard in software.")
P("This project builds AAD as a hardware datapath. The Heston-COS price and its adjoint sweep are written once as an "
  "operation graph, from which a generator derives a bit-accurate emulator, a double-precision evaluation, a "
  "first-order error bound for every output, and a fixed-point, resource-shared, modulo-scheduled Verilog datapath. "
  "On a Zynq-7020-sized configuration the price and nine Greeks take 4,733 clock cycles, 1.04 times the cost of the "
  "price alone and 18.4 times fewer cycles than bump-and-reprice on identical hardware. Measured error never exceeds "
  "0.103 of the guaranteed bound on a 21-case grid. The design routes on a Zynq-7020 at about 79 MHz (57.8 µs per "
  "evaluation) and, on a ZedBoard, 50 random cases run back to back gave results bit-identical to the emulator. "
  "Pricing calls through put-call parity, found during the board work, cut the worst call price error 75-fold.")
story.append(Spacer(1, 8))
toc = TableOfContents()
toc.levelStyles = [S["toc1"], S["toc2"]]
story.append(Paragraph("Contents", S["tochead"]))
story.append(toc)
story.append(PageBreak())

# ================================================================ 1 motivation
H1("1  Motivation")
P("A bank holding options must know, continuously, how each price responds to spot, strike, maturity, interest rate "
  "and every parameter of its pricing model. These first derivatives, the Greeks, drive hedging and risk limits. For "
  "the Heston model, which lets volatility follow its own random process, the price has no closed form. It is computed "
  "by numerical integration; this project uses the COS method, which expands the payoff in a cosine series and needs "
  "only the model's characteristic function.")
P("Three problems motivate the work:")
bullets([
    "<b>Bump-and-reprice is expensive.</b> Nine Greeks by central differences cost 19 pricings. On the hardware built "
    "here that is 86,860 cycles against 4,733 for AAD.",
    "<b>Bump-and-reprice is inaccurate.</b> Its error is U-shaped in the bump size h: rounding dominates when h is small, "
    "truncation when h is large. There is no safe choice, and in fixed point the rounding floor is high.",
    "<b>AAD is fast and exact, but only in software.</b> Reverse-mode AAD returns every Greek from one backward sweep at a "
    "small multiple of one pricing, typically 3–5 in software because of tape traffic. No published FPGA "
    "implementation of it for option Greeks was found (section 2).",
])

# ================================================================ 2 related work
H1("2  Novelty and related work")
P("<b>Novelty.</b> This work is the first FPGA implementation of adjoint (reverse-mode) differentiation for option "
  "Greeks, and the first FPGA implementation of the COS method. Specifically:")
bullets([
    "<b>Adjoint Greeks on an FPGA.</b> Every published FPGA Greeks engine re-runs the pricer once per sensitivity; no "
    "FPGA adjoint implementation exists in the literature reviewed below.",
    "<b>The COS method on an FPGA.</b> COS had run on CPUs and GPUs only.",
    "<b>A tape-free adjoint datapath,</b> statically scheduled on arithmetic shared with the forward pass.",
    "<b>Nine Greeks for 1.04× the cost of the price,</b> against 5.3–6.7× for software AAD on the measured CPU.",
    "<b>A guaranteed error bound for every Greek</b> of a fixed-point adjoint datapath, never exceeded (≤ 0.103).",
    "<b>Bit-exact Greeks on silicon:</b> 450 of 450 results on a Zynq-7020.",
])
P("The literature check behind these points (29 September 2026, docs/novelty_assessment.md) found three bodies of "
  "work and nothing joining them.")
P("<b>AAD for Greeks in software.</b> Adjoint pathwise Monte Carlo (Giles and Glasserman, Risk 2006) and its "
  "implementation by algorithmic differentiation (Capriotti, J. Comput. Finance 14(3), 2011) made AAD the standard way "
  "to compute Greeks; production practice is described by Savine (Wiley, 2018). The 2024 review of the field by "
  "Capriotti and Giles cites no FPGA or hardware AAD, and nothing on COS or Fourier AAD. AAD has been accelerated on "
  "GPUs (Gremse et al., Comput. Phys. Commun. 2016), and Capriotti's US patent 9,058,449 (Credit Suisse, 2015) claims "
  "an adjoint Greeks simulator built from general-purpose processors. For Heston specifically, Cui, del Baño Rollin "
  "and Germano (EJOR 2017) derive the gradient of the Fourier price analytically.")
P("<b>Greeks and Heston pricing on FPGAs.</b> A 2024 survey of 99 FPGA option-pricing studies (O Mahony et al., "
  "Electronics 13(16)) never mentions automatic differentiation, adjoints or Fourier methods. The closest FPGA Greeks "
  "work (Klaisoongnoen et al., HEART 2022 and H2RC 2022) runs the STAC-A2 Heston Monte Carlo workload and does not use "
  "adjoints. AMD's Vitis Quantitative Finance Library computes Heston Greeks on FPGA by central finite differences, "
  "re-running Monte Carlo per bumped parameter, and prices the Heston closed form by trapezoidal integration without "
  "Greeks. The COS method has run on GPUs (Zhang and Oosterlee, 2009) but no FPGA implementation was found. An "
  "automatic generator of FPGA pricing accelerators exists (Pham, Aung and Kumar, ReConFig 2016), without Greeks.")
P("<b>Reverse mode and precision analysis.</b> Reverse-mode differentiation was introduced to expand accumulated "
  "rounding error (Linnainmaa, BIT 1976), and AD has been used to choose FPGA word lengths (Gaffar, Mencer, Luk et "
  "al., FPT 2002). Every neural-network training accelerator executes backpropagation, which is reverse mode on a "
  "fixed graph.")
P("<b>What the novelty builds on.</b> Static adjoints, modulo scheduling and first-order rounding analysis are "
  "established techniques, cited above; the contribution is their use for option Greeks as a fixed-point, "
  "complex-valued FPGA pricing datapath with a per-Greek error bound, demonstrated bit-exact on silicon.")
table(["Work", "Method", "Platform", "Greeks by"], [
    ["Giles & Glasserman 2006; Capriotti 2011", "Monte Carlo", "CPU", "Adjoint / AD"],
    ["Gremse et al. 2016", "General", "GPU", "AAD"],
    ["Cui et al. 2017", "Heston, Fourier", "CPU", "Hand-derived gradient"],
    ["Klaisoongnoen et al. 2022", "Heston Monte Carlo (STAC-A2)", "FPGA", "Not adjoint"],
    ["AMD Vitis library", "Heston Monte Carlo; Fourier (price only)", "FPGA", "Finite differences"],
    ["Zhang & Oosterlee 2009", "COS", "GPU", "None (price only)"],
    ["This work", "Heston, COS", "FPGA, on silicon", "AAD, static datapath, error bound"],
], [0.3, 0.3, 0.15, 0.25], hi=(6,), cap="Table 1. Position relative to the closest prior work.")

# ================================================================ 3 aim
H1("3  Aim and contributions")
P("<b>Aim.</b> Build a generator that turns the Heston-COS price and its adjoint sweep into a single fixed-point, "
  "resource-shared, modulo-scheduled Verilog datapath that fits a Zynq-7020, is provably accurate for every output, "
  "and runs on a real board.")
table(["", "Claim", "Evidence"], [
    ["N1", "<b>AAD with no tape.</b> The COS pricer performs the same operations for every input, so the reverse sweep is "
           "unrolled at design time into a fixed datapath: no tape memory, write port or replay sequencer.",
     "RTL bit-exact on 5 designs; 50 cases on silicon. Static adjoints of fixed graphs are known in AD and ML "
     "hardware; the new step is applying them to this pricer."],
    ["N2", "<b>Nine Greeks for 1.04 pricings.</b> Iterative CORDIC units set the pace, leaving multiplier slots idle that "
           "the adjoint's extra multiplies fill.",
     "4,733 vs 4,568 cycles on the Zynq-7020 design; 1.55× on the 64-bit design, where multipliers bind."],
    ["N4", "<b>A guaranteed error bound for every Greek</b>, computed by applying reverse-mode differentiation to the "
           "hardware's own rounding model.",
     "Error ≤ 0.103 of the bound on 21 cases, ≤ 0.199 on 50. The method is Linnainmaa's (1976); its application to "
     "an adjoint datapath is new."],
    ["N3, N5", "Forward and reverse passes share reciprocals; every transcendental is reduced to a countable number of "
               "shared multiplies (250 per COS term).", "Per-term operation bill; schedule verification."],
    ["N6, N7", "One description yields emulator, error bound and RTL, which cannot drift; the baseline is "
               "bump-and-reprice on the same hardware.", "Byte-identical regeneration check; 18.4× on identical hardware."],
], [0.08, 0.55, 0.37], cap="Table 2. Contribution claims. N1, N2 and N4 carry the paper.")

# ================================================================ 3 architecture
H1("4  Architecture")
H2("4.1  One description, five uses")
P("The price and its reverse-mode adjoint are written once as an operation graph in <font name='Mono'>hardware/gen/heston.py</font>. "
  "The graph is split into a <i>setup</i> part evaluated once per pricing (truncation range, grid spacing, "
  "characteristic-function constants), a <i>term</i> part evaluated for each of the 128 COS terms and accumulated, and a "
  "<i>finish</i> part (discounting and the final chain rule). From it the generator produces a bit-accurate emulator, "
  "a double-precision evaluation, the first-order error bound, the scheduled RTL, and testbenches that check every "
  "register at the cycle it becomes valid.")
H2("4.2  Shared arithmetic and the modulo schedule")
P("There are no dividers. Reciprocals and inverse square roots use Newton-Raphson iterations on a normalised mantissa "
  "seeded from an 8-bit table; exp uses Tang's method; log a table plus a short series; sine and cosine a CORDIC. "
  "One COS term then costs exactly 250 multiplies, 3 CORDIC rotations and 2 CORDIC vectorings, and a modulo scheduler "
  "overlaps consecutive terms on shared units. A new term starts every II cycles (the initiation interval). On the "
  "Zynq-7020 configuration (56-bit words, 28 fractional bits, 8 multipliers, 3 rotation and 2 vectoring units), all "
  "three resource classes give II = 32: ⌈250/8⌉ = 32 for multipliers and 3·32/3 = 32 for iterative CORDICs. Cycles per "
  "evaluation are S + 127·II + L + F + 2, with setup length S, term latency L and finish length F; for this design "
  "113 + 4,064 + 506 + 48 + 2 = 4,733.")
H2("4.3  Host split and board interface")
P("The configuration built for the board (<font name='Mono'>heston_aad_z7h</font>) moves setup and finish to the host "
  "processor, leaving the 128-term loop on the FPGA: 4,572 cycles. The host supplies 16 precomputed constants. An "
  "AXI4-Lite register file (51 input words, a control and a status register, 9 result pairs) makes the core reachable "
  "from a Zynq; the 1,456-bit AXI4-Stream alternative is wider than any Zynq port. A sticky "
  "<font name='Mono'>range_err</font> output flags any input outside the verified domain instead of returning a wrong value.")
H2("4.4  Calls through put-call parity")
P("Priced directly, a call's COS coefficients contain e<super>b</super> for the upper truncation bound b, which grows large "
  "over a wide range and then cancels; in fixed point this lost up to 2.3·10<super>−3</super> on the price. The term loop "
  "now always computes the put, and the finish step adds S<sub>0</sub> − K e<super>−rT</super> and its derivatives in "
  "S<sub>0</sub>, K, T and r when a call is requested (section 6.3).")

# ================================================================ 4 verification
H1("5  Verification method")
bullets([
    "<b>Bit-exact RTL.</b> Icarus Verilog simulations compare 1,213 to 1,962 registers per design against the emulator at "
    "the cycle each becomes valid, plus all outputs; measured cycle counts equal the scheduler's prediction.",
    "<b>22 automated checks</b> in <font name='Mono'>verify_all.sh</font>: arithmetic unit tests, both hardware generations, "
    "all generated designs and wrappers, the host split, out-of-domain detection, a byte-for-byte check that committed "
    "RTL equals fresh generator output, and the error bound. All pass.",
    "<b>Accuracy</b> against two independent double-precision references: the COS method itself (the algorithm the "
    "hardware implements) and adaptive quadrature of the Heston Fourier integral (the model itself).",
    "<b>On silicon</b> over JTAG: inputs written, engine started, done polled, all results read and compared bit for bit. "
    "The test script was itself tested against a software model of the board with injected faults.",
])

# ================================================================ 5 results
story.append(PageBreak())
H1("6  Results")
H2("6.1  Speed")
figure(os.path.join(FIG, "fig8_architecture_cycles.png"),
       "Figure 1. Clock cycles for price + 9 Greeks, AAD against bump-and-reprice on the same hardware (RTL simulation, "
       "128 COS terms, log scale).")
cyc = list(csv.DictReader(open(os.path.join(RES, "gen_cycles.csv"))))
rows, hi = [], []
for r in cyc:
    fam = "Zynq-7020 (56/28)" if r["family"] == "z7" else "64-bit (64/32)"
    if (r["family"], r["mults"]) in (("z7", "8"), ("zu", "32")):
        hi.append(len(rows))
    rows.append([fam, r["mults"], r["ii_aad"], fmt(r["cycles_aad"]), fmt(r["cycles_price"]), fmt(r["cycles_bump"]),
                 "%.1f×" % (int(r["cycles_bump"]) / int(r["cycles_aad"]))])
table(["Configuration", "Multipliers", "II", "AAD", "Price only", "Bump", "Bump ÷ AAD"], rows,
      [0.25, 0.12, 0.08, 0.13, 0.13, 0.15, 0.14], num=(1, 2, 3, 4, 5, 6), hi=hi,
      cap="Table 3. Cycles per evaluation against the number of shared multipliers (validation/results/gen_cycles.csv). "
          "Highlighted: the configurations used. Generation 1, the hand-written FSM engine, needed 433,779 cycles "
          "(3,811,647 for bump-and-reprice).")
figure(os.path.join(FIG, "fig9_cycles_vs_mults.png"),
       "Figure 2. Cycles against shared multipliers, 64-bit datapath. Circled points were simulated as RTL and matched "
       "the scheduler exactly.", width=0.62)
P("On the Zynq-7020 configuration a 16th multiplier buys only 2% because II is already pinned at 32 by the CORDIC units. "
  "The advantage over bump-and-reprice exceeds the ~9.6× ratio of work (2,394 against 250 multiplies per term) because "
  "the price-only pricer leaves multiplier slots idle that AAD fills.")

H2("6.2  Accuracy")
figure(os.path.join(FIG, "fig11_gen_accuracy.png"),
       "Figure 3. Relative error of the generated designs against the double-precision COS reference over 21 parameter "
       "sets (moneyness, maturity, vol-of-vol, correlation; calls and puts).")
acc = list(csv.DictReader(open(os.path.join(RES, "gen_accuracy.csv"))))
NAMES = {"price": "Price", "delta": "Delta ∂V/∂S<sub>0</sub>", "strike_sens": "∂V/∂K", "theta_greek": "∂V/∂T",
         "rho_greek": "Rho ∂V/∂r", "vega": "Vega ∂V/∂v<sub>0</sub>", "kappa_sens": "∂V/∂κ", "theta_sens": "∂V/∂θ",
         "xi_sens": "∂V/∂ξ", "rho_corr": "∂V/∂ρ"}
rows = []
for o, label in NAMES.items():
    def worst(d):
        return max(abs(float(r["fixed"]) - float(r["ref_cos"])) / max(abs(float(r["ref_cos"])), 1e-12)
                   for r in acc if r["design"] == d and r["output"] == o)
    ratio = max(abs(float(r["fixed"]) - float(r["float_alg"])) / float(r["bound"]) for r in acc if r["output"] == o)
    rows.append([label, "%.1e" % worst("heston_aad_z7"), "%.1e" % worst("heston_aad_zu"), "%.3f" % ratio])
table(["Output", "Zynq-7020 worst rel. error", "64-bit worst rel. error", "Worst error ÷ bound"], rows,
      [0.31, 0.23, 0.23, 0.23], num=(1, 2, 3),
      cap="Table 4. Worst relative error over the 21-case grid, and the largest measured error as a fraction of the "
          "first-order bound (validation/results/gen_accuracy.csv). Every ratio is below 1: the bound held.")
figure(os.path.join(FIG, "fig10_gen_bump_vs_aad.png"),
       "Figure 4. Every Greek: bump-and-reprice error against bump size (curves) and AAD (flat lines), on the same "
       "pricer and word length. AAD beats the best bump size chosen in hindsight in every panel.", width=0.9)

H2("6.3  Calls through put-call parity")
table(["Worst absolute error, 22 calls", "Direct call", "Put + parity", "Gain"], [
    ["Price", "2.3e-3", "3.1e-5", "75×"], ["Price, median", "4.8e-5", "5.4e-7", "~90×"],
    ["∂V/∂κ", "2.4e-3", "3.9e-4", "6×"], ["∂V/∂θ", "1.7e-2", "2.5e-3", "7×"], ["∂V/∂ξ", "1.3e-2", "1.8e-3", "7×"],
    ["∂V/∂ρ", "8.3e-3", "4.7e-4", "18×"], ["Delta, ∂V/∂K, ∂V/∂T, rho, vega", "", "", "2–2.5×"],
], [0.4, 0.2, 0.2, 0.2], num=(1, 2, 3), hi=(0,),
      lead="The 50-case board sweep (section 6.5) exposed calls carrying about 180 times the rounding error of puts. "
           "Scored against the independent Fourier-integral price on the 22 calls of that sweep:",
      cap="Table 5. Effect of put-call parity. Cost: 4,731 → 4,733 cycles (Zynq-7020), 1,599 → 1,593 (64-bit), one "
          "multiply per term fewer. With parity the fixed-point error matches the double-precision COS method's own "
          "error, so rounding is no longer the limit. All 22 verification checks pass before and after.")

H2("6.4  Implementation on the Zynq-7020")
table(["Build", "LUT", "FF", "DSP", "Clock", "WNS", "Power"], [
    ["Engine alone, out of context, xc7z020clg400-1", "36,499 (68.6%)", "28,559 (26.8%)", "72 (32.7%)", "100 MHz",
     "−2.639 ns", "0.258 W"],
    ["ZedBoard system, xc7z020clg484-1", "38,358 (72.1%)", "32,206 (30.3%)", "72 (32.7%)", "70 MHz", "+0.404 ns", "0.341 W"],
], [0.3, 0.13, 0.13, 0.1, 0.09, 0.12, 0.13], num=(1, 2, 3, 4, 5, 6), hi=(1,),
      cap="Table 6. Vivado 2025.2 results (validation/results/vivado/). Fmax is about 79 MHz alone and 72 MHz inside the "
          "board system, limited by 64-bit carry chains and multiplier outputs. Power is Vivado's vectorless estimate; "
          "0.121 W of the board figure is the clock generator. Both builds predate put-call parity.")
P("At the measured 79.1 MHz one evaluation of the host-split design takes 57.8 µs (65.3 µs at the board's 70 MHz), and "
  "vectorless energy is at most 14.9 µJ. Vivado's 67 DRC warnings contain no errors: 56 suggest using the DSP blocks' "
  "internal output registers, the most direct route to 100 MHz.")
from reportlab.platypus import Table as T
from reportlab.lib.utils import ImageReader
figure(os.path.join(RES, "vivado", "Design.png"),
       "Figure 5. The placed design fills most of the Zynq-7020's programmable logic (Vivado device view).", width=0.7)
figure(os.path.join(RES, "vivado", "Timing.png"),
       "Figure 6. Timing summary of the ZedBoard build: all constraints met at 70 MHz, 0 failing endpoints.")

H2("6.5  On silicon")
P("The engine was driven over the ZedBoard's JTAG cable through a JTAG-to-AXI master, with no processor software. After "
  "one test vector (9 of 9 results bit-exact), a sweep of 50 cases ran back to back without a reset: the two reference "
  "cases plus 48 random draws over the verified domain, 22 calls and 28 puts, from a random seed the hardware's shifter "
  "ranges were not fitted on.")
table(["Run", "Cases", "Bit-exact results", "range_err", "Worst error ÷ bound", "Wall time"], [
    ["First vector", "1", "9 / 9", "0", "0.031", "–"],
    ["Sweep", "50", "450 / 450", "0", "0.268", "56.9 s"],
], [0.2, 0.1, 0.2, 0.14, 0.2, 0.16], num=(1, 2, 3, 4, 5), hi=(1,),
      cap="Table 7. ZedBoard results, 29 September 2026 (validation/results/board_*). Nearly all of the 56.9 s is JTAG "
          "register traffic; each case computes in about 65 µs. These runs used the bitstream built before put-call "
          "parity; the re-run with the current design is predicted to reach a worst error ÷ bound of 0.199.")

H2("6.6  Against a CPU")
table(["Price + 9 Greeks", "µs per evaluation", "Cost vs one price", "Evaluations / s"], [
    ["CPU, price only (1 core)", "17.2", "1×", "–"],
    ["CPU, bump-and-reprice (1 core)", "257.6", "15×", "–"],
    ["CPU, AAD with CoDiPack (1 core)", "114.9", "6.7×", "23,100 on 4 cores"],
    ["CPU, forward mode, 9 directions (1 core)", "91.5", "5.3×", "33,900 on 4 cores"],
    ["FPGA, one engine, ZedBoard at 70 MHz", "65.3", "1.04×", "15,300"],
], [0.4, 0.18, 0.18, 0.24], num=(1, 2, 3), hi=(4,),
      lead="The same algorithm in C++ double precision (g++ 13, -O3 -march=native) on an Intel Core i5-1155G7 laptop "
           "CPU (4 cores, 8 threads), with AAD by CoDiPack v2.3.2. Every method matches the reference at the base case "
           "(AAD to 1.3e-10 relative).",
      cap="Table 8. FPGA against a CPU (validation/results/cpu_baseline.csv). The FPGA is 1.4× faster than the best "
          "software method on one core (1.6× at 79 MHz) and 1.8× faster than taped AAD; four cores give 2.2× more "
          "throughput than one FPGA engine. Energy per evaluation is an estimated 16–37× lower on the FPGA (CPU power not "
          "measured; FPGA power is Vivado's vectorless estimate). Pricing alone is faster on the CPU; the FPGA's lead is "
          "that its Greeks cost 1.04 pricings instead of 5–7.")

H2("6.7  Generation 1: the hand-written engine")
P("The first engine, a hand-written finite-state machine in 64-bit fixed point, established the error model and the "
  "bump-and-reprice comparison. It was accurate (price 3.0·10<super>−7</super>, Greeks ≤ 5.4·10<super>−5</super>) but took "
  "433,779 cycles, 80% of them in 28 bit-serial divisions per term, and needed far more multipliers than a Zynq-7020 has.")
figure(os.path.join(FIG, "fig3_bound_tightness.png"),
       "Figure 7. Generation 1: measured error as a fraction of the first-order bound, every output and case; all below 1.")
figure(os.path.join(FIG, "fig5_cost_vs_greeks.png"),
       "Figure 8. Generation 1: cycles against the number of Greeks, flat for AAD and linear for bump-and-reprice.",
       width=0.6)
figure(os.path.join(FIG, "fig4_precision_vs_fl.png"),
       "Figure 9. Generation 1: error against the number of fractional bits. The 1-sigma form of the bound predicts the "
       "measured error from 16 to 40 fractional bits.")

# ================================================================ 6 work
H1("7  Work done")
P("The project ran from 15 August to 29 September 2026: 39 commits over 46 days.")
table(["Period", "Milestone"], [
    ["15 Aug", "Black-Scholes and Heston models, software AAD engine, MATLAB and C++ prototypes."],
    ["21 Aug – 9 Sep", "Generation 1: hand-written FSM engine for Heston AAD in 64-bit fixed point; RTL validation report."],
    ["17 Sep", "Fixed-point precision fixes, first-order error bound, bump-and-reprice baseline; the datapath generator "
               "(IR, emulator, modulo scheduler, RTL writer); fits the Zynq-7020."],
    ["22 – 24 Sep", "Vivado implementation flow; viva study guide and a full course document."],
    ["26 – 27 Sep", "AXI4-Lite register file, ZedBoard JTAG and processor designs; first complete route (68.6% LUT, ~79 MHz)."],
    ["29 Sep", "ZedBoard bitstream at 70 MHz; one vector then 50 cases bit-exact on silicon; calls through put-call parity."],
], [0.18, 0.82])
table(["Component", "Size"], [
    ["Datapath generator (Python)", "3,069 lines, 11 files"],
    ["Generated Verilog", "22,924 lines, 11 designs and wrappers"],
    ["Hand-written Verilog (generation 1 and arithmetic library)", "5,351 lines, 25 files"],
    ["Validation (references, sweeps, figures, board report)", "2,046 lines"],
    ["Software models and AAD engine (Python)", "2,359 lines"],
    ["Vivado Tcl (implementation, board build and test)", "683 lines"],
    ["Documentation", "3,806 lines"],
    ["Automated verification", "22 checks, all passing"],
], [0.62, 0.38], cap="Table 9. Size of the work, measured from the repository.")

# ================================================================ 7 limits
H1("8  Limitations")
bullets([
    "<b>79 MHz, not 100 MHz.</b> The engine misses 100 MHz by 2.6 ns; latencies are quoted at the measured Fmax.",
    "<b>The board bitstream is one change behind.</b> Silicon results used the design before put-call parity; the "
    "current RTL passes all simulation checks and awaits a rebuild.",
    "<b>Host steps run on the PC.</b> Setup and finish are Python, not C on the ARM; the processor-based system is "
    "scripted but not built.",
    "<b>Power is a vectorless estimate</b> at a 12.5% toggle rate; no activity-based figure or measurement yet.",
    "<b>The literature check should be repeated before submission</b> in Google Scholar, IEEE Xplore and the ACM "
    "Digital Library, to catch papers published after 29 September 2026.",
    "<b>Bounded input domain:</b> S<sub>0</sub> = 100, K 60–150, T 0.1–3, r 0–0.1, v<sub>0</sub> and θ 0.005–0.25, "
    "κ 0.2–6, ξ 0.1–1, ρ −0.95–0.6. Outside it the hardware raises range_err.",
    "<b>The adjoint is hand-written.</b> The reverse sweep is written as operations in the IR "
    "(hardware/gen/heston.py) and verified bit-exact and against independent references, but no AD tool derives "
    "it. The paper should say \"adjoint differentiation\" in its claim, or the generator should derive the sweep.",
    "<b>Greeks hold the truncation range fixed</b> when differentiating, the standard COS convention; their distance "
    "from the model's true Greeks is part of the method error.",
])

# ================================================================ 8 next
H1("9  Next steps")
table(["", "Step", "Why", "Status"], [
    ["1", "Rebuild the ZedBoard bitstream; repeat the 50-case sweep", "Bring the silicon result up to the current design", "Ready: ~40 min build"],
    ["2", "Derive the adjoint automatically in the generator", "Turns the tool into a compiler; answers the hand-written-adjoint objection", "Next"],
    ["3", "Repeat the literature search before submission", "Catch anything published since 29 Sep 2026", "Done once"],
    ["4", "Close timing at 100 MHz", "DSP output registers, pipelined carry chains", "Open"],
    ["5", "Port host steps to C; build the processor design", "No PC in the loop", "Open"],
    ["6", "Activity-based power or board measurement", "A defensible energy figure", "Open"],
    ["7", "Merge into main", "After step 1", "Pending"],
], [0.05, 0.4, 0.37, 0.18], hi=(0,), cap="Table 10. Next steps in order of value for the paper.")

# ================================================================ 9 conclusion
H1("10  Conclusion")
P("Reverse-mode AAD for the Heston model has been built as a fixed-point hardware datapath with no tape. Generated "
  "from one description, it computes the price and nine Greeks in 4,733 cycles, 1.04 pricings and 18.4 times fewer "
  "cycles than bump-and-reprice on the same hardware, within a guaranteed error bound for every output. It fits a "
  "Zynq-7020, meets timing on a ZedBoard at 70 MHz, and reproduced the emulator bit for bit on 50 cases in silicon. "
  "Against a laptop CPU it is 1.4× faster per evaluation and uses an estimated 16–37× less energy, though four "
  "CPU cores give more throughput. The immediate work is to rebuild the board with the put-call parity design and "
  "to make the generator derive the adjoint automatically.")

H2("Reproducing the results")
P("<font name='Mono'>./verify_all.sh</font> (all 22 checks, about 4 minutes) · "
  "<font name='Mono'>python validation/run_gen_sweeps.py</font> (cycles, bump and accuracy data) · "
  "<font name='Mono'>python validation/make_figures.py</font> (figures and tables) · "
  "<font name='Mono'>zedboard/run_board.bat build | sweep</font> (board) · "
  "<font name='Mono'>python validation/board_report.py &lt;log&gt;</font> (board accuracy). "
  "Status dashboard: <font name='Mono'>dashboard.html</font>.", "small")


doc = Doc(OUT)
doc.multiBuild(story)
print("wrote", OUT)
