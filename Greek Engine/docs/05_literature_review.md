# Literature Review: Positioning the Greeks Engine

Rewritten 29 September 2026 after a full novelty check. Every entry below was
opened and checked; `docs/novelty_assessment.md` records what was searched, what
each source contains, and six corrections to the previous version of this file.

## 1. The gap

Three bodies of work exist, and no published work was found that joins them:

| Area | Representative work | What it lacks for this project |
|---|---|---|
| **AAD for Greeks, in software** | Giles & Glasserman 2006; Capriotti 2011; Savine 2018; Capriotti & Giles 2024 (review) | Runs on CPUs and GPUs; no FPGA or custom datapath |
| **Greeks and Heston pricing on FPGAs** | Klaisoongnoen et al. 2022; AMD Vitis Quantitative Finance Library; De Schryver et al. 2011 | Greeks by re-running the pricer, or no stated method; no adjoints; no COS method |
| **AD for hardware precision analysis** | Linnainmaa 1976; Gaffar et al. 2002 | Analyses a design's rounding; does not build a datapath that computes adjoints |

**This project:** adjoint AD for option Greeks as a statically scheduled
fixed-point FPGA datapath, for a COS (Fourier-cosine) Heston pricer, with a
per-Greek error bound, verified bit-exact on a Zynq-7020. It is the first FPGA
implementation of adjoint differentiation for option Greeks and the first FPGA
implementation of the COS method; the novelty points are listed in
`novelty_assessment.md` §1.

## 2. AAD for Greeks (software)

**Giles & Glasserman, "Smoking adjoints: fast Monte Carlo Greeks", Risk, 2006.**
Adjoint pathwise sensitivities in Monte Carlo: all Greeks at a small constant
multiple of one pricing. The theoretical case for AAD over bumping.

**Capriotti, "Fast Greeks by algorithmic differentiation", Journal of
Computational Finance 14(3):3–35, 2011.** AD applied to the pathwise Monte Carlo
method, giving Greeks at machine precision. The standard software reference; the
3–5× cost of software AAD that this project compares against.

**Savickas et al., "Super fast Greeks: an application to counterparty valuation
adjustments", 2014.** AAD for XVA, where the number of sensitivities is large.

**Geeraert, Lehalle, Pearlmutter, Pironneau, Reghai, "Mini-symposium on automatic
differentiation and its applications in the financial industry", arXiv:1703.02311,
2017.** Overview of AAD use cases in finance.

**Savine, "Modern Computational Finance: AAD and Parallel Simulations", Wiley,
2018.** Production AAD (tape, memory management, parallel simulation) from Danske
Bank practice. The reference for how software AAD records and replays a tape,
which this design removes.

**Capriotti & Giles, "15 Years of Adjoint Algorithmic Differentiation in
Finance", 2024.** The field's review. It mentions FPGAs once, as an environment
pricing code may run in, and cites no FPGA or hardware AAD implementation and no
COS or Fourier AAD.

**Capriotti, US patent 9,058,449 (Credit Suisse; priority 2007, granted 2015).**
A "simulating machine" of adjoint payout and adjoint sample units for Monte Carlo
Greeks, described as hardware and software components with processors and memory.
No FPGA, ASIC or circuits; no Fourier methods. Cite it, and do not phrase the
contribution as an adjoint-computing apparatus in general.

**Cui, del Baño Rollin, Germano, "Full and fast calibration of the Heston
stochastic volatility model", EJOR 263(2), 2017.** An analytic gradient of the
Heston Fourier price with respect to the model parameters, about 10× faster than a
numerical gradient. The expected reviewer question ("why AAD, when the Heston
gradient is known?") is answered in `novelty_assessment.md` §6.

**Gremse et al., "GPU-accelerated adjoint algorithmic differentiation", Computer
Physics Communications, 2016.** AAD on GPUs (general purpose). Hardware-accelerated
AAD exists on GPUs; the claim here is specifically FPGA and a static datapath.

**Arsaguet & Bilokon, "Derivatives sensitivities computation under Heston model on
GPU", arXiv:2309.10477, 2023.** Heston Greeks by Monte Carlo on GPU.

## 3. Greeks and Heston pricing on FPGAs

**Klaisoongnoen, Brown, Thomson Brown, "Low-power option Greeks: efficiency-driven
market risk analysis using FPGAs", HEART 2022 (doi:10.1145/3535044.3535059,
arXiv:2206.03719); and "Fast and energy-efficient derivatives risk analysis:
streaming option Greeks on Xilinx and Intel FPGAs", H2RC 2022
(arXiv:2212.13977).** The STAC-A2 workload (Heston Monte Carlo with
Longstaff–Schwartz, multi-asset, early exercise) on Alveo U280 and Intel FPGAs,
focused on energy efficiency, with numerical precision explored by measurement.
Neither paper mentions adjoints or AD. The closest FPGA Greeks work, and the right
reference for energy-per-Greek methodology; not a latency baseline, since Monte
Carlo with early exercise is a different and far costlier problem than European
COS pricing.

**Klaisoongnoen et al., "Evaluating Versal AI Engines for option price discovery
in market risk analysis", FPGA 2024 (arXiv:2402.12111).** The same group on
Versal AI Engines.

**AMD/Xilinx Vitis Quantitative Finance Library.** `MCEuropeanHestonGreeksEngine`
computes Heston Greeks by central finite differences, re-running the Monte Carlo
engine once per bumped parameter (read from the source). `hcfEngine` prices the
Heston closed form by trapezoidal Fourier integration in float or double, price
only. The industrial baseline: FPGA Heston Greeks exist, by bumping.

**De Schryver et al., "An energy efficient FPGA accelerator for Monte Carlo option
pricing with the Heston model", ReConFig 2011; De Schryver (ed.), "FPGA Based
Accelerators for Financial Applications", Springer, 2015.** Heston Monte Carlo
pricing on FPGA, and the standard book on the area.

**Tse, Thomas, Luk, "Design exploration of quadrature methods in option pricing"
(and related work on reduced precision).** Quadrature pricing on FPGA and GPU; the
nearest FPGA relative of Fourier pricing.

**Pham, Aung, Kumar, "Automatic framework to generate reconfigurable accelerators
for option pricing applications", ReConFig 2016.** A generator of FPGA pricing
accelerators across models. No Greeks, adjoints or Fourier methods. Relevant to the
"generator" part of this project, which should therefore be presented as a
contribution of the tool, not as new in itself.

**Diamantopoulos, Polig, Ringlein, Purandare, Weiss, Hagleitner, Lantz, Abel,
"Acceleration-as-a-µService: a cloud-native Monte-Carlo option pricing engine on
CPUs, GPUs and disaggregated FPGAs", IEEE CLOUD 2021.** Pricing only. (The earlier
"Weiss et al. 2016" entry referred to no real paper; this is the only matching
author in the field.)

**O Mahony, Hanzon, Popovici, "The role of FPGAs in modern option pricing
techniques: a survey", Electronics 13(16):3186, 2024.** 99 studies. Its text never
mentions automatic differentiation, adjoints, Fourier, FFT or COS methods, and it
cites one Greeks paper (Klaisoongnoen). It does not name AAD on FPGA as an open
problem; its silence supports the gap.

## 4. Fourier and COS pricing on accelerators

**Fang & Oosterlee, "A novel pricing method for European options based on
Fourier-cosine series expansions", SIAM J. Sci. Comput., 2008.** The COS method.

**Zhang & Oosterlee, "Option pricing with COS method on graphics processing
units", IEEE IPDPS workshops, 2009.** COS pricing on GPU, price only. No FPGA
implementation of the COS method was found.

## 5. AD and precision analysis

**Linnainmaa, "Taylor expansion of the accumulated rounding error", BIT 16:146–160,
1976 (master's thesis 1970).** Reverse-mode differentiation was introduced to
compute how local rounding errors accumulate. The error bound in this project
(`docs/precision_bound.md`) is this method applied to a fixed-point AAD datapath.

**Gaffar, Mencer, Luk, Cheung, Shirazi, "Floating-point bitwidth analysis via
automatic differentiation", FPT 2002; and "Unifying bit-width optimisation for
fixed-point and floating-point designs", FCCM 2004.** AD-based sensitivity analysis
to choose FPGA word lengths. The closest hardware prior art for the error bound;
this project's addition is bounding the Greeks produced by a datapath that itself
performs the adjoint, validated against bit-exact RTL.

## 6. Hardware reverse mode outside finance

Every neural-network training accelerator executes backpropagation, the reverse
mode of AD, on a fixed graph with no tape. The paper must acknowledge this and
cite a representative FPGA training accelerator. What differs here is the graph (a
fixed-point, complex-valued, transcendental-heavy pricing computation), the
guaranteed per-output error bound, and the workload's alternative
(bump-and-reprice).

## 7. Positioning

| Work | Model / method | Platform | Greeks by |
|---|---|---|---|
| Giles & Glasserman 2006; Capriotti 2011 | Monte Carlo | CPU | Adjoint / AD |
| Gremse et al. 2016 | General | GPU | AAD |
| Cui et al. 2017 | Heston, Fourier | CPU | Hand-derived analytic gradient |
| Klaisoongnoen et al. 2022 | Heston Monte Carlo + LSM (STAC-A2) | FPGA | Not adjoint (method not stated) |
| AMD Vitis library | Heston Monte Carlo; Heston Fourier (price only) | FPGA | Finite differences |
| Zhang & Oosterlee 2009 | COS | GPU | None (price only) |
| Gaffar et al. 2002 | DFT, FIR (precision analysis) | FPGA | AD for bit widths |
| **This project** | **Heston, COS** | **FPGA (Zynq-7020, on silicon)** | **AAD, static datapath, per-Greek bound** |

## 8. Venues

FPGA-focused: FPT, FPL, FCCM, the ACM/SIGDA FPGA symposium, ReConFig, HEART, and
the H2RC workshop (where the closest FPGA Greeks work appeared). Journals: IEEE
TVLSI, ACM TRETS. Finance-practitioner outlets (Journal of Computational Finance)
only with a CPU comparison.
