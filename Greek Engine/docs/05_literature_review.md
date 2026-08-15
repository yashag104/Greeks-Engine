# Literature Review — Positioning the Greeks Engine Project

## 1. The Gap This Project Fills

The existing literature sits in two camps that have never been combined:

| Camp | Key Papers | What They Do | What They Don't Do |
|------|-----------|-------------|-------------------|
| **AAD in software** | Capriotti (2011), Smoking Adjoints (Giles & Glasserman, 2006), Savickas (2014) | Efficient Greeks computation via AAD on CPUs/GPUs | Not on FPGAs — limited by CPU throughput |
| **FPGA-accelerated finance** | Weiss et al. (2016), Klaisoongnoen et al. (2019), De Schryver et al. (2015) | Hardware-accelerated pricing and/or bump-and-reprice Greeks | Don't use AAD — multiply latency by $n$ for $n$ Greeks |

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

### 2.5 Weiss et al. (2016) — "FPGA Pricing of Heston Model"

**What it does**: Implements the Heston model pricing via COS method on an FPGA, using fixed-point arithmetic. Achieves significant speedup over CPU.

**Key contribution**: Proves the COS method is implementable in fixed-point hardware with acceptable precision. Provides reference fixed-point bit-width choices.

**Relevance to us**: Direct precursor — we use the same forward pricing core (Heston-COS) but add the AAD reverse pass on top. Their bit-width analysis informs our fixed-point budget. Their results are our primary benchmark comparison.

**What they DON'T do**: Greeks. Their FPGA prices options but doesn't compute sensitivities. To get Greeks, you'd need to do bump-and-reprice — running their core $n+1$ times.

---

### 2.6 Klaisoongnoen et al. (2019) — "FPGA-based Greeks for Heston"

**What it does**: Implements bump-and-reprice Greeks on FPGA for the Heston model. Achieves hardware-accelerated Greeks, but via the brute-force finite-difference approach.

**Key contribution**: Demonstrates that FPGA Greeks for Heston are feasible. Provides latency and throughput benchmarks.

**Relevance to us**: Our direct competitor/comparison point. They compute $n$ Greeks by running the forward pricer $n+1$ times. We compute all $n$ Greeks in a single backward pass (after one forward pass). Our expected advantage:
- Latency: ~$2\times$ (forward + backward) vs. $(n+1)\times$ (their approach)
- Throughput: higher, since pipeline resources are shared between forward and backward
- Area: potentially larger (we store the tape), but amortized by fewer passes

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
| Weiss et al. (2016) | Heston-COS | FPGA | None (pricing only) | Forward core reference |
| Klaisoongnoen et al. (2019) | Heston | FPGA | Bump-and-reprice | Direct competitor |
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
