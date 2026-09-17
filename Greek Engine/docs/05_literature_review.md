# Literature Review — Positioning the Greeks Engine Project

## 1. The Gap This Project Fills

The existing literature sits in two camps that have never been combined:

| Camp | Key Papers | What They Do | What They Don't Do |
|------|-----------|-------------|-------------------|
| **AAD in software** | Capriotti (2011), Smoking Adjoints (Giles & Glasserman, 2006), Savickas (2014) | Efficient Greeks computation via AAD on CPUs/GPUs | Not on FPGAs — limited by CPU throughput |
| **FPGA-accelerated finance** | Klaisoongnoen et al. (HEART 2022; streaming follow-up, arXiv:2212.13977), De Schryver et al. (2015), Weiss et al. (unverified, see 2.5) | Hardware-accelerated pricing and/or bump-and-reprice Greeks | Don't use AAD — multiply latency by $n$ for $n$ Greeks |

**Our novelty**: AAD's reverse-mode differentiation implemented as a pipelined hardware engine on FPGA. One backward pass computes ALL Greeks, in hardware.

---

## 2. Paper-by-Paper Review

### 2.1 "Smoking Adjoints" — Giles & Glasserman (2006)

**What it does**: Foundational paper connecting the adjoint (reverse-mode) approach to computing Greeks in Monte Carlo simulations. Shows that pathwise sensitivities computed via adjoint methods achieve the same accuracy as forward-mode but at $O(1)$ cost per path (independent of the number of Greeks).

**Key contribution**: Proved that adjoint methods are optimal for computing Greeks when the number of risk factors exceeds the number of output prices — which is virtually always the case in practice.

**Relevance to us**: Theoretical foundation for why AAD is the right approach. Our work extends this from software Monte Carlo to a deterministic (COS-based) hardware pipeline.

---

### 2.2 Capriotti (2011) — "Fast Greeks by Algorithmic Differentiation"

**What it does**: Demonstrates AAD applied to the full pricing pipeline of interest rate derivatives, achieving speedups of 10-100x over bump-and-reprice in software.

**Key contribution**: Showed that AAD's constant overhead factor (typically 3-5x the cost of one pricing) is far better than the $O(n)$ factor for bump-and-reprice when $n$ is large.

**Relevance to us**: This paper's software implementation is what we're translating to hardware. Our tape schema is directly inspired by the operation-by-operation recording approach Capriotti describes.

---

### 2.3 Geeraert et al. — AAD for XVA and CVA

**What it does**: Applies AAD to XVA (credit/funding/margin valuation adjustments), where the number of sensitivities can be in the thousands. Shows that AAD makes otherwise intractable risk calculations feasible.

**Key contribution**: Demonstrates the practical scalability of AAD — the more Greeks you need, the bigger the advantage over alternatives.

**Relevance to us**: Motivates the hardware acceleration angle — if AAD is already the best software approach but still bottlenecks on throughput, hardware acceleration is the logical next step.

---

### 2.4 Danske Bank / CompatibL Slides — Production AAD Systems

**What it does**: Industry presentations showing AAD deployed in production risk engines at scale. Demonstrates real-world speedups and implementation patterns.

**Key contribution**: Validates that AAD is not just academic — it's used in production. But even in production, throughput is limited by CPU speed.

**Relevance to us**: Our FPGA implementation addresses the throughput bottleneck these production systems face.

---

### 2.5 Weiss et al. (2016) — "FPGA Pricing of Heston Model"  ⚠️ citation not verified

> **Verify before citing.** A search (Sept 2026) did not locate a paper matching
> this title/year. Find the actual publication (authors, venue, what it
> implements) or remove this entry; do not use it as a benchmark number.

**Claimed content (unverified)**: Heston pricing on FPGA, possibly via a Fourier
method, in fixed point, pricing only (no Greeks).

---

### 2.6 Klaisoongnoen, Brown & Thomson Brown (2022) — "Low-power option Greeks: Efficiency-driven market risk analysis using FPGAs"

**Venue**: HEART 2022 (ACM), doi:10.1145/3535044.3535059; arXiv:2206.03719.
Follow-up: "Fast and energy-efficient derivatives risk analysis: Streaming option
Greeks on Xilinx and Intel FPGAs", arXiv:2212.13977.

> **Correction:** an earlier version of this document cited this work as
> "Klaisoongnoen et al. (2019) — FPGA-based Greeks for Heston" and described it
> as a Heston-COS bump-and-reprice engine. It is neither 2019 nor COS-based.

**What it does**: Ports the STAC-A2 market-risk benchmark — **Monte Carlo** Heston
paths with Longstaff–Schwartz path reduction — to a Xilinx Alveo U280, with a
focus on energy efficiency; the follow-up streams the Greeks workload on Xilinx
and Intel FPGAs. Greeks come from finite differences (re-simulation), as STAC-A2
specifies.

**Relevance to us**: The closest FPGA work on Heston Greeks and the right
reference for *energy-efficiency* framing. **Not** an apples-to-apples latency
baseline: Monte Carlo + LSM (American-style, path-based) solves a different and
far more expensive problem than European COS pricing, so a raw latency
comparison would mostly measure COS vs Monte Carlo, not AAD vs bump. The fair
AAD-vs-bump comparison is on the *same* pricing core (this project's
`heston_bump_top.v` vs `heston_top_level.v`); cite Klaisoongnoen et al. for
context and for energy-per-Greek methodology.

---

### 2.7 De Schryver et al. (2015) — "FPGA Acceleration of Monte Carlo"

**What it does**: Surveys FPGA acceleration techniques for Monte Carlo simulation in finance, including random number generation, path generation, and payoff evaluation.

**Relevance to us**: Background context. Our COS-based approach avoids Monte Carlo entirely, which sidesteps the RNG hardware problem but limits us to models with known characteristic functions.

---

### 2.8 The 2024 FPGA Survey — "FPGA Acceleration in Computational Finance"

**What it does**: Comprehensive survey of FPGA applications in finance, covering pricing, risk, and Greeks computation. Identifies open problems and future directions.

**Key observation**: The survey identifies AAD on FPGA as an **open research direction** — it's mentioned as a potential future approach but no existing implementation is cited.

**Relevance to us**: Directly positions our work as filling a gap identified by the community.

---

### 2.9 February 2026 Paper — "AAD vs. Finite Differences on FPGA"

**What it does**: Theoretical comparison of AAD and finite-difference (bump-and-reprice) approaches for FPGA implementation. Analyzes computational complexity, memory requirements, and expected speedups.

**Key contribution**: Provides the theoretical framework for why AAD should be more efficient than bump-and-reprice on FPGA, along with estimates of expected hardware resource usage.

**Relevance to us**: Our work is the **empirical validation** of this paper's theoretical predictions.

---

## 3. Positioning Matrix

| Paper | Pricing Model | Platform | Greeks Method | Our Relationship |
|-------|--------------|----------|---------------|-----------------|
| Giles & Glasserman (2006) | General MC | Theory | Adjoint (theory) | Theoretical foundation |
| Capriotti (2011) | IR derivatives | CPU | AAD (software) | Software precursor |
| Geeraert et al. | XVA/CVA | CPU | AAD (software) | Motivation for scale |
| Weiss et al. (2016) ⚠️ unverified | Heston (method unverified) | FPGA | None (pricing only) | Verify or drop |
| Klaisoongnoen et al. (2022) | Heston Monte Carlo + LSM (STAC-A2) | FPGA (Alveo U280) | Finite differences | Closest FPGA Greeks work; energy framing, not a latency baseline |
| 2024 Survey | Various | FPGA | Survey | Identifies our gap |
| Feb 2026 paper | General | Theory/FPGA | AAD vs. FD analysis | Theoretical validation |
| **This project** | **Heston-COS** | **FPGA** | **AAD (hardware)** | **Fills the gap** |

---

## 4. Our Specific Contribution

> First hardware implementation of Algorithmic Adjoint Differentiation for option Greeks computation. Using the Heston stochastic volatility model with COS method pricing, we implement a pipelined AAD engine that computes all Greeks in a single backward pass, achieving $O(1)$ scaling with the number of Greeks versus $O(n)$ for existing FPGA-based bump-and-reprice approaches.

### What makes this publishable:
1. **Novel combination**: AAD + FPGA has never been done
2. **Clear advantage**: $O(1)$ vs $O(n)$ Greeks scaling
3. **Practical model**: Heston is industry-standard
4. **Rigorous validation**: fixed-point error analysis + head-to-head comparison
5. **Identified gap**: Community has explicitly flagged this as missing work

### Appropriate venues:
- **H2RC** (Workshop on Heterogeneous High-performance Reconfigurable Computing)
- **ReConFig** (International Conference on Reconfigurable Computing)
- **HEART** (International Symposium on Highly Efficient Accelerators and Reconfigurable Technologies)
- **IEEE TCAD** / **IEEE TVLSI** (journals, if results are strong)
- **Risk.net** / **Wilmott** (if targeting finance practitioners)
