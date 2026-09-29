# Novelty assessment: is "hardware AAD for option Greeks" new?

Checked 29 September 2026, before the paper claims priority. The aim was to find
anything that makes the idea not novel, not to confirm it. Every source below was
opened and its text searched; where only an abstract was reachable it says so.

## 1. Verdict

**The priority claim holds in a narrowed form, and it must be narrowed.**

- **Holds:** no published FPGA or custom-datapath implementation of adjoint
  (reverse-mode) algorithmic differentiation for option Greeks was found. No FPGA
  implementation of the COS method was found either. Every FPGA Greeks engine
  found computes Greeks by re-running the pricer (finite differences) or states no
  method at all.
- **Does not hold as a broad claim:** reverse-mode differentiation in hardware is
  not new (every neural-network training accelerator runs backpropagation, which
  is reverse-mode AD). Using AD to analyse fixed-point precision on FPGAs is not
  new (Gaffar et al., 2002), and reverse mode was *invented* for rounding-error
  analysis (Linnainmaa, 1970/1976). An "apparatus" computing adjoint Greeks is
  patented (Capriotti, Credit Suisse), though as software on general-purpose
  computers.
- **So the paper is a systems and application contribution**, not a new
  mathematical technique. Its novelty is the combination, demonstrated end to end:
  AAD for Greeks, as a statically scheduled fixed-point FPGA datapath, for a Fourier
  (COS) pricer, with a per-Greek error bound, verified bit-exact on silicon. That is
  a defensible contribution for an FPGA or reconfigurable-computing venue. It is
  not defensible to call any single ingredient new.

The biggest remaining risk is not novelty but **significance**: no CPU baseline
exists yet (section 6).

## 2. Recommended wording

Use:

> To our knowledge, this is the first FPGA implementation of adjoint (reverse-mode)
> differentiation for option Greeks, and the first FPGA implementation of the COS
> method. Because the COS pricer's operation graph does not depend on its
> inputs, the adjoint sweep is compiled into a statically scheduled fixed-point
> datapath with no runtime tape.

"AAD" is fine in finance usage, but the adjoint here is hand-derived as IR
operations, not produced by an AD tool (section 6, point 4): write "adjoint
differentiation" in the claim sentence, or automate the reverse sweep first.

Do not use:

- "first hardware implementation of reverse-mode AD" (false: training accelerators);
- "AAD has never been implemented in hardware" without "for option Greeks" and
  "to our knowledge";
- "the community has identified AAD on FPGA as an open problem" (no source says so;
  see section 5);
- "novel error-analysis method" (the method is Linnainmaa's; the application is new).

## 3. Claim by claim

| Claim | Status | What is new | Prior art that must be cited |
|---|---|---|---|
| **Priority:** first FPGA AAD for option Greeks | **Supported, "to our knowledge"** | No counterexample in any source in section 4 | Capriotti patent (adjoint Greeks apparatus, software); GPU AAD (Gremse et al. 2016); FPGA Greeks by other methods (Klaisoongnoen et al.; AMD Vitis) |
| **N1** Tape-free, static adjoint datapath | **Narrow it** | Recognising that COS pricing's input-independent graph lets the adjoint compile to a fixed schedule, and building it | Static adjoints of straight-line code are standard in source-transformation AD; ML accelerators and graph compilers run fixed backward graphs with no tape |
| **N2** Nine Greeks for 1.04 pricings | **Holds as a measured result** | The measurement, and the condition (CORDIC-bound II leaves multiplier slots idle); 1.55× when multipliers bind | Software AAD cost ratio 3–5 (Giles & Glasserman 2006; Capriotti 2011); modulo scheduling is standard HLS |
| **N4** Per-Greek fixed-point error bound | **Narrow it: new application, old method** | Applying first-order rounding-error analysis to a datapath that itself computes adjoints, bounding every Greek, validated against bit-exact RTL (≤ 0.103 of the bound) | Linnainmaa, BIT 16 (1976), Taylor expansion of accumulated rounding error; Gaffar, Mencer, Luk, Cheung, Shirazi, FPT 2002, bitwidth analysis via AD on FPGAs |
| **N3** Forward/reverse share reciprocals | Engineering detail | Consequence of common-subexpression elimination across the fused graph | Standard CSE |
| **N5** Transcendentals as shared multiplies | Engineering | Newton-Raphson, Tang's exp, CORDIC are textbook | Cite the algorithms; claim only the scheduling consequence |
| **N6** One description, several artifacts | Contribution of the tool, not novelty | Generator emitting emulator, bound and RTL from one graph | Pham, Aung, Kumar, ReConFig 2016: a generator of FPGA option-pricing accelerators (Monte Carlo, several models, no Greeks) |
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

### Searches that returned nothing relevant
AD/AAD + FPGA; AD + high-level synthesis; reverse-mode AD + ASIC/circuit; tape-free
adjoint + hardware pipeline; COS/Fourier-cosine + FPGA; Heston Fourier + FPGA
accelerator; FPGA pathwise/adjoint Monte Carlo; Maxeler + adjoint; 2025–2026 arXiv
FPGA + AD + Greeks.

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
   pricing graph (complex log, exp, square root and division, CORDIC), a guaranteed
   per-output error bound, and a financial workload whose alternative is
   bump-and-reprice. Cite a training accelerator to show awareness.
2. **"Heston Greeks have an analytic form; why AAD?"** Cui et al. (2017) derive the
   gradient of the Fourier price by hand. AAD derives it mechanically for any
   graph, so the same generator would handle another model or payoff; and the
   hardware result (1.04 pricings) is about cost, not about whether a gradient
   exists. Say this directly.
3. **"How fast is this against a CPU?"** Unanswered, and the most serious gap. A
   European Heston COS price with 128 terms is also cheap in software; if one CPU
   core with software AAD takes a similar time to 57.8 µs, the latency argument
   fails and the paper must argue throughput and energy (replicated engines, joules
   per Greek set). Measure it before writing the results section.
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

## 7. Limits of this check, and what to do before submission

- Web search and open full texts only. Paywalled IEEE/ACM papers were judged from
  abstracts where their full text was not reachable. Unpublished industry work
  (banks, Maxeler, which served JP Morgan and Citi) cannot be excluded; hence "to our
  knowledge".
- Repeat these queries in **Google Scholar, IEEE Xplore and the ACM Digital Library**
  in the final month, and set a Scholar alert:
  `"algorithmic differentiation" FPGA`, `"automatic differentiation" FPGA Greeks`,
  `adjoint FPGA option`, `"COS method" FPGA`, `Heston FPGA Fourier`,
  `"reverse mode" hardware accelerator finance`.
- Ask the guide whether any recent FPT, FCCM, FPL, HEART, H2RC or ReConFig paper is
  known to them.
