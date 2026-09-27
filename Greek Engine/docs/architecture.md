# Shared-Multiplier Datapath for Heston-COS AAD Greeks

This document covers the second-generation hardware architecture (`hardware/gen`,
`hardware/verilog/gen`), its verification, and its measured results. The
fixed-point precision analysis it inherits is in `docs/precision_bound.md`.

**Reproduce everything:** `./verify_all.sh` (all testbenches, ~3 min),
`python validation/run_gen_sweeps.py && python validation/make_figures.py` (data, figures, `validation/figures/tables.md`).

---

## 1. Why a second architecture

The first engine (`hardware/verilog/heston_*.v`) was a hand-written FSM. It
controlled a single set of arithmetic modules in sequence, but did **not** share
their datapaths. Every `*` inside a state inferred its own multiplier, so Yosys
counts 159 64×64 multipliers, which is well over 1,000 DSP slices. It also used
28 bit-serial divisions per COS term, 80 % of its 433,779-cycle latency. It could
not fit the Zynq-7020 (220 DSP48E1), and it had no pipelining across terms.

## 2. Architecture

**One description, four uses.** The Heston-COS price and its reverse-mode
adjoint sweep are written once as an operation graph (`hardware/gen/heston.py`).
The same graph gives:
- a bit-accurate fixed-point emulator (the golden model),
- a double-precision evaluation of the same algorithm,
- the first-order error bound for the price and each Greek,
- the scheduled and bound RTL.

**Divider-free arithmetic** (`prims.py`):

| function | implementation | cost |
|---|---|---|
| 1/x | normalize to [1,2), 8-bit ROM seed, 3 Newton steps | 6 multiplies |
| 1/√x, √x | normalize to [1,4), ROM seed, 3 Newton steps | 9 (+1) multiplies |
| e^x | Tang: 2^(n/32) table, degree-4 Taylor on \|r\| ≤ ln2/64 | 7 multiplies |
| ln x | 64-entry table, degree-4 Taylor on \|t\| ≤ 1/129 | 6 multiplies |
| cos, sin | 2π reduction (2 multiplies) + CORDIC rotation | 1 CORDIC |
| complex 1/b | scale so max(\|b_r\|,\|b_i\|) ∈ [0.5,1), \|b\|², reciprocal | ~10 multiplies |
| complex √, ln | CORDIC vectoring for \|z\| and arg (no squaring) | 1 CORDIC |

**Reuse.** Each complex denominator is inverted once, and the reverse sweep reuses it:
1/den, g/den, 1/omg, ratio/omg, 1/omge, dratio/omge, 1/ratio = omg/omge.
Everything independent of u_k is hoisted into a once-per-evaluation setup.

**One COS term** (forward + reverse sweep, adjoint normalization) costs 251
multiplies, 3 CORDIC rotations, 2 CORDIC vectorings, and ~380 add/shift/mux
operations.

**Modulo scheduling** (`sched.py`). Term k starts at S + k·II. Multipliers and
CORDIC units are shared resources, bound through a modulo reservation table,
so in steady state term k uses unit u at phase (t − S) mod II. II is set by M,
the number of multipliers, and by the CORDIC unit style. Glue logic is dedicated.
A term value consumed ≥ II cycles after it is produced gets a register chain.

**Narrow shifters** (`ranges.py`). Every data-dependent shift amount was measured
with the emulator over 150 random parameter sets in the verified domain. Each
barrel shifter covers only that range (+3 margin; shifts past the word width are
clamped, which is exact). A sticky `range_err` output flags any shift outside its
range.

**Host-setup variant.** On a Zynq, the per-evaluation setup and the final
discounting / chain rule run on the ARM cores. Their fixed-point specification
is `hardware/gen/host.py`. The FPGA runs only the 128-term loop, and
host + FPGA is bit-identical to the fully on-chip design.

## 3. Verification

`./verify_all.sh` — 21 checks, all passing:

| check | method |
|---|---|
| arithmetic library (FSM engine) | unit tests vs double precision |
| FSM engine: AAD, price-only, AXI; Black-Scholes | self-checking testbenches vs reference |
| generated AAD (Zynq-7020, 64-bit, host-setup), price-only pricers | every setup/finish register and every register of terms 0–2 at the cycle it becomes valid (1,254–1,993 checks) + all outputs for 3 parameter sets, **bit-exact** vs the emulator |
| schedule | measured cycles = predicted cycles, every configuration |
| `range_err` | stays 0 in-domain, raised for T = 0.01 |
| AXI4-Stream wrappers | bit-exact round trip, backpressure, return to idle |
| bump-and-reprice wrappers | bit-exact vs emulated 19 pricings |
| host split | host setup + FPGA sums + host finish == on-chip outputs |
| committed RTL | identical to fresh generator output |
| accuracy | emulator errors < 1e-5 and below the bound |

Beyond the scripted suite, the generator was also checked bit-exact on
48-bit/4-multiplier, 64-bit/16-multiplier and 60-bit/64-multiplier configurations.

## 4. Results

### 4.1 Latency (clock cycles, RTL simulation, 128 terms)

| design | AAD: price + 9 sensitivities | bump-and-reprice, same hardware | bump / AAD |
|---|---|---|---|
| FSM engine (64-bit) | 433,779 | 3,811,647 | 8.8× |
| generated, Zynq-7020 config (56-bit, 8 multipliers) | **4,731** (92× fewer than FSM) | 86,803 | **18.3×** |
| generated, host setup (56-bit, 8 multipliers) | 4,572 (loop only) | — | — |
| generated, 64-bit, 32 multipliers | **1,599** (271× fewer) | 19,505 | **12.2×** |

On the Zynq-7020 configuration, all 9 Greeks cost 1.04 pricings. The iterative
CORDIC units set the pace per term, so the reverse sweep's extra multiplies use
multiplier slots that a price-only design leaves idle.
`fig8_architecture_cycles`, `fig9_cycles_vs_mults`.

### 4.2 Accuracy

Worst relative error over the 21-case grid (S0 = 100, K 80–120, T 0.1–2,
ξ 0.2–1, ρ −0.9…0.5, calls and puts):

| design | price | Greeks (worst: ∂V/∂κ, ∂V/∂ρ) | max error / bound |
|---|---|---|---|
| Zynq-7020 config (56-bit) | 6.1e-7 | ≤ 6.4e-5 | 0.115 |
| 64-bit config | 5.9e-8 | ≤ 6.0e-6 | 0.115 |
| FSM engine (64-bit) | 3.0e-7 | ≤ 5.4e-5 | 0.21 |

Against bump-and-reprice on the same pricer and word length, sweeping h from 1e-8
to 1e-1, AAD is more accurate than the best h for every Greek
(`fig10_gen_bump_vs_aad`). `fig11_gen_accuracy`.

### 4.3 Area (Yosys `synth_xilinx`, generic mapping)

| design | target | LUT | + SRL (LUT-based) | FF | DSP | fits? |
|---|---|---|---|---|---|---|
| `heston_aad_z7`, full-range shifters | xc7 | 90,648 | 3,050 | 32,878 | 96 | no (Zynq-7020: 53,200 LUT) |
| `heston_aad_z7`, measured-range shifters | xc7 | 59,024 | 3,058 | 32,731 | 96 | no, ~11 % over |
| **`heston_aad_z7h`** (host setup) | xc7 | **45,504** | 2,922 | 24,856 | 96 / 220 | **yes: 91 % LUT incl. SRL, 23 % FF, 44 % DSP** |
| **`heston_aad_zu`** (64-bit, 32 multipliers) | xcup | **108,330** | 6,409 | 59,953 | 512 DSP48E2 | **ZCU104: 50 % LUT, 30 % DSP**; ZCU102: yes; ZU3EG: no |

### 4.4 Area (Vivado 2025.2, post-synthesis, out of context)

`heston_aad_z7h` on xc7z020clg400-1:

| resource | used | available | util. | Yosys had estimated |
|---|---|---|---|---|
| LUT (incl. SRL) | **37,738** | 53,200 | **70.9 %** | 48,426 (91 %) |
| of which shift-register LUTs | 2,781 | 17,400 | 16.0 % | 2,922 |
| FF | 27,255 | 106,400 | 25.6 % | 24,856 |
| DSP48E1 | **72** | 220 | **32.7 %** | 96 |
| BRAM tile | 4 | 140 | 2.9 % | — |

Yosys' generic mapping overstated LUTs by 28 % and DSPs by a third. The Zynq-7020 fit
is comfortable rather than marginal, and the fallbacks previously recommended here —
sharing storage registers into SRLs, or 48-bit words (`check_accuracy.py 24`) — are
not needed. Use the Yosys figures only to rank configurations against each other, not
as an area result.

### 4.5 Routed (Vivado 2025.2, xc7z020clg400-1, 10 ns target, out of context)

| resource | routed | available | % |
|---|---|---|---|
| LUT | 36,499 | 53,200 | 68.6 % |
| of which shift-register LUTs | 1,401 | 17,400 | 8.1 % |
| FF | 28,559 | 106,400 | 26.8 % |
| DSP48E1 | 72 | 220 | 32.7 % |
| BRAM tile | 4 | 140 | 2.9 % |

| timing / power | value |
|---|---|
| WNS at 100 MHz | **−2.639 ns** (8,172 of 64,408 endpoints fail); WHS +0.037 ns |
| Critical path | 12.31 ns, 29 levels (21 CARRY4), `t_reg[16]` → `cr2_inst/z_reg[63]` |
| Fmax | ≈ 79.1 MHz (1 / (10 + 2.639) ns) |
| AAD latency | 433,779 cycles / 79.1 MHz ≈ **5.48 ms** |
| Power (vectorless, 12.5 % toggle, at the 100 MHz constraint) | 0.258 W (0.153 dynamic + 0.105 static) |
| Energy per evaluation | ≤ 1.41 mJ (0.258 W × 5.48 ms; an upper bound, since power was estimated at 100 MHz) |

The design fits and routes but does not close at 100 MHz. The failing paths are 64-bit
carry chains; pipelining them, or running at ≤ 79 MHz, are the options. The ZedBoard
bring-up designs run the engine at 70 MHz for margin.

## 5. Limitations and open items

- **Timing does not close at 100 MHz** (§4.5): WNS −2.639 ns, Fmax ≈ 79 MHz. Routing
  was reached after three obstacles: Vivado ML Enterprise refused to launch without a
  licence (resolved by moving to ML Standard 2025.2); `read_verilog`, `read_xdc` and
  `-include_dirs` take Tcl *lists*, so the space in the repository path tore every
  filename in two (fixed by wrapping in `[list ...]`); and two runs were killed
  mid-flow with no error message, most likely memory pressure (the flow now
  checkpoints after placement, `impl_from_dcp.tcl` resumes from a checkpoint, and
  `run_native.bat` runs the flow outside WSL). Power is vectorless; activity-based
  (SAIF) power is still open.
- **Nothing has run on a board yet.** The AXI4-Stream wrappers are up to 1,624 bits
  wide, which no Zynq PS-PL port can carry; `wrappers.py lite` now generates an
  AXI4-Lite register file instead (bit-exact, in `verify_all.sh`), and
  `hardware/vivado/zedboard/` holds a JTAG-to-AXI bring-up design, a PS design, and a
  scripted board test that compares every output bit-exact against the emulator. The
  first JTAG build stopped on the same Tcl list-splitting bug in `add_files`, now
  fixed; the bitstream has not been built yet.
- **Verified input domain**: S0 = 100, K ∈ [60, 150], T ∈ [0.1, 3],
  r ∈ [0, 0.1], v0, θ ∈ [0.005, 0.25], κ ∈ [0.2, 6], ξ ∈ [0.1, 1], ρ ∈ [−0.95, 0.6].
  Outside it, `range_err` reports rather than silently returning wrong values.
- **The truncation range [a, b] is held fixed when differentiating** (standard COS
  convention, same as the software reference).
- **Register sharing across values** (fewer flip-flops) is not implemented. Each
  long-lived value has its own register chain.
