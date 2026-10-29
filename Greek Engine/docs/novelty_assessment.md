# Novelty of the Greeks Engine

Literature check made on 29 September 2026 and repeated on 5 October 2026. Every
source in section 4 was opened and its text searched; where only an abstract was
reachable it says so.

## 1. Novelty points

1. **The first FPGA implementation of adjoint (reverse-mode) differentiation for
   option Greeks.** Every published FPGA Greeks engine re-runs the pricer once per
   sensitivity (Klaisoongnoen et al. 2022; AMD's Vitis Quantitative Finance
   Library, read from source). The 2024 survey of 99 FPGA option-pricing studies
   and the 2024 review of 15 years of AAD in finance (Capriotti & Giles) contain no
   FPGA adjoint implementation.
2. **The first FPGA implementation of the COS (Fourier-cosine) method.** COS
   pricing had run on CPUs and GPUs (Zhang & Oosterlee 2009); the only FPGA Fourier
   pricer (AMD `hcfEngine`) uses trapezoidal integration and returns the price
   alone.
3. **A co-scheduled adjoint datapath with a register-resident tape.** The hand-derived
   reverse sweep is scheduled into the forward pass's fixed-point datapath and shares
   its arithmetic units; forward values live in statically allocated rotating registers,
   not in tape memory, and there is no replay logic. This works because the COS pricer
   runs the same operations for every input. Static reverse sweeps for control-flow-free
   code are well known (source-transformation AD, training accelerators); the claim is
   the application to option Greeks on an FPGA, not the principle.
4. **Nine Greeks for 1.04× the cost of the price.** 4,733 cycles against 4,568 for
   the price alone on the same hardware; software AAD costs 5.7–7.6× on the
   measured CPU (`architecture.md` §4.6) and bump-and-reprice 19×. The 1.04× is
   reached because the CORDIC units set the pace and the reverse sweep fills idle
   multiplier slots; forward-mode datapaths from the same generator (6 Oct 2026,
   `validation/run_mode_baselines.py`) reach the same pace only with more
   multipliers. Per COS term: adjoint 250 multiplies, best hand-factored analytic
   313 (+25%), forward-mode AD style 802 (3.2×). With 8 multipliers on the
   Zynq-7020: 4,731 / 5,622 / 13,597 cycles; with 16 every variant but the dense one
   is CORDIC-bound (about 4,570). State the claim as fewer multipliers (DSP blocks)
   for the same speed, not as a unique 1.04×.
5. **A first-order rounding-error bound for every Greek of a fixed-point adjoint datapath.**
   Measured error never exceeds 0.103 of the bound over 21 cases, 0.378 over 10,500
   inputs including hard regimes (every unflagged result), and 0.199 over 50 random
   cases on silicon (6 Oct 2026 bitstream; 0.268 on the earlier one), and 0.255 over
   101 evaluations of the 64-bit engine on a ZCU102 (25 Oct 2026).
6. **Bit-exact Greeks on silicon, on two FPGA families.** 450 of 450 results identical
   to the model on a ZedBoard (Zynq-7020), 50 random cases back to back; and 1,010 of
   1,010 for the 64-bit engine (all outputs computed on chip) on a ZCU102 (Zynq
   UltraScale+): one vector, 50 random cases and 50 real NIFTY days.
7. **Bump-and-reprice on identical hardware:** 18.4× more cycles, and 32–560× less
   accurate than AAD even at the best bump size for each Greek. The hardware bump
   runs 19 independent pricings; an optimised bump that reuses the characteristic
   function needs about 10 pricings' worth of work (measured on the CPU, 10.7×), so
   quote the hardware advantage against both.

Against a CPU running the same algorithm (idle laptop, 23 Oct 2026), the ZedBoard
engine is 1.2–1.6× faster than the general AD methods, but **hand-derived analytic
Greeks on one CPU core are about 3.2× faster than it** (20.3 µs against 65.3 µs). The
64-bit engine on the ZCU102 (15.9 µs per whole evaluation, run bit-exact on the board)
is 4.9–6.5× faster than the AD methods but **not faster than the analytic method
vectorised across terms (13.6 µs)**, and four cores give more throughput. Measured CPU
package power puts energy per evaluation at parity (40 µJ FPGA chip-level vs 40.9 µJ
vectorised CPU). The FPGA's claims against a CPU are therefore the cost and accuracy of
its Greeks and the per-Greek bound, **not speed or energy** (`architecture.md` §4.6b).

## 2. What the novelty builds on

These are the established pieces the paper cites; none of them is the claim.

- **Reverse-mode differentiation** is established, including in hardware:
  neural-network training accelerators run backpropagation. The novelty is its use
  for option Greeks on an FPGA, as a fixed-point pricing datapath.
- **The error-bound method** is Linnainmaa's first-order rounding analysis (BIT,
  1976); Gaffar et al. (FPT 2002) used AD for FPGA word lengths. The novelty is
  bounding every Greek of a datapath that itself performs the adjoint.
- **Static adjoints of fixed graphs** exist in source-transformation AD tools. The
  novelty is seeing that the COS pricer has such a graph and compiling its adjoint
  into hardware.
- **Newton-Raphson, Tang's exp and CORDIC** are standard arithmetic; modulo
  scheduling is standard high-level synthesis.
- **An adjoint Greeks "simulating machine"** is patented (Capriotti, Credit Suisse,
  US 9,058,449), built from general-purpose processors running Monte Carlo; no FPGA
  or custom datapath.
- **A generator of FPGA pricing accelerators** exists (Pham, Aung, Kumar, ReConFig
  2016: Monte Carlo, several models, no Greeks).

## 3. Claim wording

> This work is the first FPGA implementation of adjoint (reverse-mode)
> differentiation for option Greeks, and the first FPGA implementation of the COS
> method. Because the COS pricer's operation graph does not depend on its inputs,
> the adjoint sweep is compiled into a statically scheduled fixed-point datapath
> with no runtime tape.

Keep "for option Greeks" and "FPGA" in the sentence: they are what makes it true
(reverse-mode differentiation in general has run in hardware). Write "adjoint
differentiation" rather than "algorithmic differentiation" while the reverse sweep
is hand-written (section 6, point 4). Do not say the community named AAD on FPGA
as an open problem; no source says so (section 5).

| Claim | Status | Evidence | Cite alongside |
|---|---|---|---|
| **First FPGA adjoint Greeks** | Holds | No FPGA adjoint work in any source of section 4 | Capriotti patent; GPU AAD (Gremse et al. 2016); FPGA Greeks by other methods (Klaisoongnoen et al.; AMD Vitis) |
| **First FPGA COS pricer** | Holds | COS only on CPU and GPU; FPGA Fourier pricing is trapezoidal, price only | Zhang & Oosterlee 2009; AMD `hcfEngine` |
| **N1** Tape-free, static adjoint datapath | Holds, for option pricing | The COS graph is input-independent; the adjoint compiles to a fixed schedule | Source-transformation AD; ML training hardware |
| **N2** Nine Greeks for 1.04 pricings | Holds, measured | CORDIC-bound II leaves multiplier slots idle; 1.55× when multipliers bind | Software AAD 3–5× (Giles & Glasserman 2006; Capriotti 2011) |
| **N4** Per-Greek error bound | Holds, new application | Bound every Greek of an adjoint datapath; ≤ 0.103 of the bound | Linnainmaa 1976; Gaffar et al. FPT 2002 |
| **N3** Forward/reverse share reciprocals | Engineering | The reverse sweep references the forward reciprocal nodes (`ir.simplify` does no CSE) | — |
| **N5** Transcendentals as shared multiplies | Engineering | Everything costed in one currency, so one scheduler trades it | Newton, Tang, CORDIC |
| **N6** One description, several artifacts | Tool contribution | Emulator, bound and RTL from one graph | Pham et al. ReConFig 2016 |
| **N7** Bump-and-reprice on the same hardware | Methodology | Fair baseline | — |

## 4. What was checked

### FPGA and hardware finance
| Source | What it does | AD / adjoint? |
|---|---|---|
| O Mahony, Hanzon, Popovici, *The Role of FPGAs in Modern Option Pricing Techniques: A Survey*, Electronics 13(16):3186, Aug 2024 (99 studies) | Survey of FPGA option pricing | Full text searched: **zero** mentions of differentiation, adjoint, AAD, backpropagation, Fourier, FFT, COS or characteristic function. One Greeks study cited (Klaisoongnoen). |
| Klaisoongnoen, Brown, Thomson Brown, *Low-power option Greeks*, HEART 2022 (arXiv:2206.03719) | STAC-A2 Heston Monte Carlo + Longstaff–Schwartz on Alveo U280; precision explored empirically (ap_fixed, half, float, double) | Full text: no adjoint, AD, pathwise, finite difference or bump. |
| Klaisoongnoen et al., *Streaming option Greeks on Xilinx and Intel FPGAs*, H2RC 2022 (arXiv:2212.13977) | Streaming version of the above | Full text: none. |
| Klaisoongnoen et al., *Versal AI Engines for option price discovery*, FPGA 2024 (arXiv:2402.12111) | Pricing on AI Engines | Abstract only: none. |
| AMD/Xilinx **Vitis Quantitative Finance Library** | `MCEuropeanHestonGreeksEngine`; `hcfEngine` (Heston closed form) | Source read: Greeks by **central finite differences, re-running Monte Carlo** per bumped parameter. `hcfEngine`: price only, trapezoidal Fourier integration, float/double. |
| Pham, Aung, Kumar, *Automatic framework to generate reconfigurable accelerators for option pricing applications*, ReConFig 2016 | Accelerator generator, several models | Full text: no Greeks, adjoint or Fourier. |
| Diamantopoulos, Polig, Ringlein, Purandare, **Weiss**, Hagleitner, Lantz, Abel, *Acceleration-as-a-µService*, IEEE CLOUD 2021 | Cloud Monte Carlo pricing on CPU/GPU/FPGA | Pricing only. This is the only "Weiss" in the field (see section 5). |
| Tse, Thomas, Luk, *Design exploration of quadrature methods in option pricing* (TVLSI) and related | Quadrature pricing on FPGA and GPU, reduced precision | Pricing; the nearest FPGA relative of Fourier pricing. |
| De Schryver et al., *An energy efficient FPGA accelerator for Monte Carlo option pricing with the Heston model*, ReConFig 2011 | Heston Monte Carlo on FPGA | Pricing. |
| Echeverría Aramendi, PhD thesis, UPM 2011 | Monte Carlo LIBOR market model on FPGA | States explicitly that Greeks were **not** explored. |
| Maxeler (JP Morgan, Citi deployments) | FPGA risk analytics | No published method; see risks. |

### AAD in finance (software)
| Source | Relevance |
|---|---|
| Capriotti & Giles, *15 Years of Adjoint Algorithmic Differentiation in Finance*, Jan 2024 | The field's review. Full text: FPGA appears once, as an environment code may run in; **no FPGA or hardware AAD work cited**; no COS or Fourier AAD. |
| Giles & Glasserman, *Smoking Adjoints*, Risk 2006 | Adjoint pathwise Monte Carlo Greeks. |
| Capriotti, *Fast Greeks by algorithmic differentiation*, J. Comput. Finance 14(3):3–35, 2011 | AD for the pathwise Monte Carlo method. |
| Savickas et al., *Super fast Greeks: an application to counterparty valuation adjustments*, 2014 | AAD for XVA. |
| Geeraert, Lehalle, Pearlmutter, Pironneau, Reghai, *Mini-symposium on automatic differentiation and its applications in the financial industry*, arXiv:1703.02311, 2017 | Overview of AAD cases. |
| Gremse et al., *GPU-accelerated adjoint algorithmic differentiation*, Comput. Phys. Commun. 2016 | AAD on GPUs (general, not Greeks-specific). |
| Arsaguet & Bilokon, *Derivatives sensitivities computation under Heston model on GPU*, arXiv:2309.10477, 2023 | Heston Greeks by Monte Carlo on GPU; abstract does not describe AAD. |
| Cui, del Baño Rollin, Germano, *Full and fast calibration of the Heston stochastic volatility model*, EJOR 263(2), 2017 | **Analytic gradient** of the Heston Fourier price, ~10× faster than numerical. Software. Reviewers may ask why AAD rather than this; see section 6. |
| Capriotti, US patent 9,058,449 (Credit Suisse; priority 2007, granted 2015) | "Simulating machine" with adjoint payout and adjoint sample units for Monte Carlo Greeks. Text describes hardware *and software* components with processors and memory; **no FPGA, ASIC, GPU or circuit**; no Fourier. Cite it. |

### Fourier / COS on accelerators
| Source | Relevance |
|---|---|
| Zhang & Oosterlee, *Option pricing with COS method on graphics processing units*, IEEE IPDPS workshops 2009 | COS pricing on GPU (price only). COS on an accelerator exists; COS on an FPGA was not found. |

### Precision analysis
| Source | Relevance |
|---|---|
| Linnainmaa, *Taylor expansion of the accumulated rounding error*, BIT 16:146–160, 1976 (thesis 1970) | Reverse mode originated as rounding-error analysis. N4's method. |
| Gaffar, Mencer, Luk, Cheung, Shirazi, *Floating-point bitwidth analysis via automatic differentiation*, FPT 2002 (and FCCM 2004 fixed/floating unification) | AD-based sensitivity for FPGA precision. N4's closest hardware prior art. |

### AD in hardware outside finance (added 5 Oct 2026)
| Source | Relevance |
|---|---|
| Schoder & Bücker (Jena), *Scaling an Augmented RISC-V Processor Design with High-Level Synthesis*, RISC-V for HPC workshop, ISC 2024 (Springer LNCS 2025) | **Forward-mode** AD built into a RISC-V soft processor (custom instructions, HLS) on an Alveo U50 FPGA. Slides read in full: forward mode only, a processor not a datapath, test functions like Rosenbrock, no finance. Cite it: AD has run on an FPGA, so never claim "first AD on an FPGA". |
| Boudaoud, Calotoiu, Copik, Hoefler (ETH), *DaCe AD*, arXiv:2509.02197, Sept 2025 | Reverse-mode AD in the DaCe framework, whose code generator can target FPGAs, but every result is on CPU and GPU; no finance. Cite as reverse-mode AD for accelerators. |
| de Beer, *Accelerated Adjoint Algorithmic Differentiation with Applications in Finance*, MPhil thesis, UCT 2017 | Hand-written adjoint Greeks of a Heston Monte Carlo rainbow option on a **GPU**; full text has no FPGA. Another GPU AAD reference. |

### Searches that returned nothing relevant
AD/AAD + FPGA; AD + high-level synthesis; reverse-mode AD + ASIC/circuit; tape-free
adjoint + hardware pipeline; COS/Fourier-cosine + FPGA; Heston Fourier + FPGA
accelerator; FPGA pathwise/adjoint Monte Carlo; Maxeler + adjoint; 2025–2026 arXiv
FPGA + AD + Greeks. Repeated 5 Oct 2026 (FPGA adjoint Greeks; COS + FPGA; reverse-mode
AD + FPGA/HLS; FPGA Heston Greeks 2025–2026; FPGA Greeks + fixed-point error bound):
nothing that does adjoint Greeks or COS on an FPGA.

## 5. Corrections to the earlier literature review

`docs/05_literature_review.md` contained claims that do not survive checking:

1. **"The 2024 survey identifies AAD on FPGA as an open research direction."**
   False. The survey never mentions AD, adjoints or AAD. Its silence supports the
   gap; it does not state it.
2. **"February 2026 paper: AAD vs finite differences on FPGA."** Not found by any
   search; no authors or venue were ever recorded. Removed.
3. **"Weiss et al. (2016), FPGA pricing of the Heston model."** No such paper. The
   only Weiss in FPGA option pricing is a co-author of Diamantopoulos et al. (IEEE
   CLOUD 2021), Monte Carlo pricing as a cloud service.
4. **"Geeraert et al. apply AAD to XVA."** It is a mini-symposium overview; the XVA
   application is Savickas et al. (2014).
5. **"Capriotti (2011): interest-rate derivatives, 10–100× speed-ups."** The paper
   applies AD to the pathwise Monte Carlo method; describe it as that.
6. **"Greeks by finite differences, as STAC-A2 specifies."** Neither Klaisoongnoen
   paper states a method, and the public STAC-A2 description does not either. Say
   only that neither uses adjoints or AD.

## 6. What reviewers will push on

1. **"Backpropagation accelerators already do reverse mode in hardware."** Yes.
   Answer with what differs: a fixed-point, transcendental-heavy, complex-valued
   pricing graph (complex log, exp, square root and division, CORDIC), a first-order
   per-output error bound, and a financial workload whose alternative is
   bump-and-reprice. Cite a training accelerator to show awareness.
2. **"Heston Greeks have an analytic form; why AAD?"** Cui et al. (2017) derive the
   gradient of the Fourier price by hand, and this project now measures that
   approach (1 Oct 2026, `analytic` in `validation/cpu_baseline/heston_cpu.cpp`):
   price and 9 Greeks in one pass at 1.5 pricings on a CPU. In this project the
   hardware adjoint is also hand-written (point 4), so "AAD derives it
   mechanically" is only true once the generator derives the reverse sweep. The
   honest answer today: the hardware result is the cost, 1.04 pricings for all
   Greeks with a first-order rounding-error bound on each, against 1.5 for the best hand-written
   software; and the IR adjoint is a general reverse-mode construction that a later
   generator can produce automatically, while the analytic form is specific to
   this characteristic function.
3. **"How fast is this against a CPU?"** Measured on an idle laptop, 23 Oct 2026
   (`docs/architecture.md` §4.6). Hand-derived analytic Greeks on one core take
   20.3 µs against 65.3 µs for the ZedBoard's loop, so **on the Zynq-7020 the CPU
   wins latency by about 3.2×** and throughput by more; the ZedBoard beats only the
   general methods: forward mode (78.0 µs, 1.2×), CoDiPack AAD (103.8 µs, 1.6×) and
   bump-and-reprice (238.1 µs, 3.6×). The 64-bit engine on the ZCU102 (15.9 µs, run
   bit-exact on the board) is 1.3× faster than the scalar analytic method but slower
   than the same method vectorised across terms (13.6 µs, 29 Oct), 4.9–15× faster than
   the others, and slower in throughput than four cores (216,000/s vectorised). Energy
   per evaluation, with measured CPU package power, is at parity (40 vs 40.9 µJ).
   Do not argue latency, throughput or energy. Argue the cost of the Greeks at equal
   throughput (1.03× cycles, ~1.7× area of a price-only engine; less area and 6× more
   accurate than a factored forward datapath), the per-Greek error bound, and bit-exact
   silicon.
   Strike sharing (`architecture.md` §4.7) cuts the cost per extra strike to
   about 7% of one option in hardware, but the same sharing makes the CPU about 9×
   cheaper per strike too (2.3 µs per strike at 32 strikes, one idle core), and
   pricing many strikes from one characteristic function is standard COS practice
   (Fang & Oosterlee 2008). It is a design result, not a novelty claim.
4. **"Is this algorithmic differentiation, or a hand-written adjoint?"** In this
   project the reverse sweep is written by hand as IR operations in
   `hardware/gen/heston.py`; no AD tool derives it. In finance "AAD" usually names
   the adjoint method however it is produced, but a reviewer from the AD community
   will object to "algorithmic". Either say "adjoint (reverse-mode) differentiation"
   and state that the adjoint is hand-derived and verified, or make the generator
   derive the reverse sweep from the forward graph (a source transformation over
   the IR). The second would strengthen N1 and the generality answer to point 2.
5. **"Your Greeks freeze the truncation range."** Standard COS convention; state it
   and report distance to the Fourier-integral Greeks as method error.
6. **"50 cases is a sample."** It is; the emulator equivalence and the bound carry
   the generality, and the board confirms the emulator.

## 7. Keeping it current

- Novelty is judged against the published record, and against it the claims in
  section 1 hold. Proprietary industry systems (banks; Maxeler, which built FPGA
  risk systems for JP Morgan and Citi) publish no methods and are not prior art a
  reviewer can cite.
- This check used web search and open full texts; paywalled IEEE/ACM papers were
  judged from abstracts where the full text was not reachable.
- New papers appear every month. In the month before submission, repeat these
  queries in **Google Scholar, IEEE Xplore and the ACM Digital Library**, and set a
  Scholar alert: `"algorithmic differentiation" FPGA`, `"automatic
  differentiation" FPGA Greeks`, `adjoint FPGA option`, `"COS method" FPGA`,
  `Heston FPGA Fourier`, `"reverse mode" hardware accelerator finance`.
- Ask the supervisor about any recent FPT, FCCM, FPL, HEART, H2RC or ReConFig paper
  they know of.
