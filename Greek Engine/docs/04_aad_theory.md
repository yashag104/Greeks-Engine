# Algorithmic Adjoint Differentiation (AAD) Theory

## 1. The Problem: Computing Derivatives Efficiently

In finance, we need **derivatives** (in the calculus sense) of a pricing function $f$ with respect to its inputs:

$$\text{Greeks} = \left(\frac{\partial f}{\partial S}, \frac{\partial f}{\partial \sigma}, \frac{\partial f}{\partial r}, \ldots\right)$$

Three approaches:

| Method | Cost | Accuracy |
|--------|------|----------|
| **Finite differences** (bump-and-reprice) | $O(n)$ pricings for $n$ inputs | Approximate (truncation error) |
| **Forward-mode AD** | $O(n)$ passes for $n$ inputs | Machine precision |
| **Reverse-mode AD (AAD)** | $O(1)$ backward pass for ALL inputs | Machine precision |

AAD is the clear winner when $n$ (number of inputs) is large — and in Heston, $n = 7+$.

---

## 2. The Chain Rule — Foundation of All AD

Every computation $f(x_1, x_2, \ldots, x_n)$ can be decomposed into a sequence of elementary operations. The **chain rule** tells us how to propagate derivatives through this sequence.

For a composition $f = f_3 \circ f_2 \circ f_1$:

$$\frac{\partial f}{\partial x} = \frac{\partial f_3}{\partial f_2} \cdot \frac{\partial f_2}{\partial f_1} \cdot \frac{\partial f_1}{\partial x}$$

The question is: **in which order do we multiply these Jacobians?**

---

## 3. Computational Graphs

Any function $f$ can be represented as a **directed acyclic graph (DAG)** where:
- **Leaf nodes**: input variables $x_1, x_2, \ldots, x_n$
- **Internal nodes**: intermediate computations $v_1, v_2, \ldots, v_m$
- **Root node**: output $y = f(x_1, \ldots, x_n)$
- **Edges**: dependencies (which operations feed into which)

### Worked Example: $f(x, y) = xy + \sin(x)$

Decompose into elementary operations:

| Step | Variable | Operation | Value (at $x=2, y=3$) |
|------|----------|-----------|----------------------|
| Input | $x$ | input | 2 |
| Input | $y$ | input | 3 |
| 1 | $v_1 = x \cdot y$ | multiply | 6 |
| 2 | $v_2 = \sin(x)$ | sin | 0.9093 |
| 3 | $v_3 = v_1 + v_2$ | add | 6.9093 |
| Output | $f = v_3$ | — | 6.9093 |

The computational graph:

```
x ──┬──→ [× y] ──→ v1 ──┐
    │                     ├──→ [+] ──→ v3 = f
    └──→ [sin] ──→ v2 ──┘
y ──────→ [× x] ──→ v1 (same node)
```

---

## 4. Forward Mode AD

**Direction**: Propagate derivatives **forward** — from inputs to output.

We compute $\dot{v}_i = \frac{\partial v_i}{\partial x}$ for a chosen input $x$, alongside the forward evaluation:

| Step | Value | $\dot{v} = \frac{\partial}{\partial x}$ | $\dot{v} = \frac{\partial}{\partial y}$ |
|------|-------|----------------------------------------|----------------------------------------|
| $x = 2$ | 2 | $\dot{x} = 1$ (seed) | $\dot{x} = 0$ |
| $y = 3$ | 3 | $\dot{y} = 0$ | $\dot{y} = 1$ (seed) |
| $v_1 = xy$ | 6 | $\dot{v}_1 = \dot{x} \cdot y + x \cdot \dot{y} = 1 \cdot 3 + 2 \cdot 0 = 3$ | $\dot{v}_1 = 0 \cdot 3 + 2 \cdot 1 = 2$ |
| $v_2 = \sin(x)$ | 0.9093 | $\dot{v}_2 = \cos(x) \cdot \dot{x} = \cos(2) \cdot 1 = -0.4161$ | $\dot{v}_2 = \cos(2) \cdot 0 = 0$ |
| $v_3 = v_1 + v_2$ | 6.9093 | $\dot{v}_3 = \dot{v}_1 + \dot{v}_2 = 3 + (-0.4161) = 2.5839$ | $\dot{v}_3 = 2 + 0 = 2$ |

**Result**: $\frac{\partial f}{\partial x} = 2.5839$, $\frac{\partial f}{\partial y} = 2$

**Verification**: $\frac{\partial f}{\partial x} = y + \cos(x) = 3 + \cos(2) = 3 - 0.4161 = 2.5839$ ✓

**Cost**: One forward pass per input → $n$ passes for $n$ inputs.

---

## 5. Reverse Mode AD (AAD) — The Core of This Project

**Direction**: Propagate derivatives **backward** — from output to inputs.

We define the **adjoint** of each variable:
$$\bar{v}_i = \frac{\partial f}{\partial v_i}$$

This answers: "how does the final output $f$ change if $v_i$ changes?"

### The Backward Pass

**Step 1**: Seed the output adjoint: $\bar{v}_3 = \bar{f} = 1$ (we want $\frac{\partial f}{\partial \cdot}$)

**Step 2**: Propagate backward through each operation:

For $v_3 = v_1 + v_2$:
$$\bar{v}_1 \mathrel{+}= \bar{v}_3 \cdot \frac{\partial v_3}{\partial v_1} = 1 \cdot 1 = 1$$
$$\bar{v}_2 \mathrel{+}= \bar{v}_3 \cdot \frac{\partial v_3}{\partial v_2} = 1 \cdot 1 = 1$$

For $v_2 = \sin(x)$:
$$\bar{x} \mathrel{+}= \bar{v}_2 \cdot \frac{\partial v_2}{\partial x} = 1 \cdot \cos(x) = \cos(2) = -0.4161$$

For $v_1 = x \cdot y$:
$$\bar{x} \mathrel{+}= \bar{v}_1 \cdot \frac{\partial v_1}{\partial x} = 1 \cdot y = 3$$
$$\bar{y} \mathrel{+}= \bar{v}_1 \cdot \frac{\partial v_1}{\partial y} = 1 \cdot x = 2$$

**Final adjoints**:
- $\bar{x} = -0.4161 + 3 = 2.5839 = \frac{\partial f}{\partial x}$ ✓
- $\bar{y} = 2 = \frac{\partial f}{\partial y}$ ✓

### Key Observation

**One backward pass gave us ALL partial derivatives simultaneously.** This is the power of AAD.

| Mode | Passes needed | Best when |
|------|--------------|-----------|
| Forward | $n$ (one per input) | Few inputs, many outputs |
| **Reverse (AAD)** | **1** (one per output) | **Many inputs, few outputs** (our case!) |

---

## 6. The Tape

In practice, AAD is implemented using a **tape** (also called a Wengert list or trace):

### What the tape records

For every elementary operation during the forward pass, the tape stores:

```
TapeEntry:
    - operation: the type of operation (add, mul, sin, exp, ...)
    - input_indices: indices of input variables on the tape
    - output_index: index of the output variable on the tape
    - local_partials: ∂(output) / ∂(each input), evaluated at current values
```

### Example tape for $f(x,y) = xy + \sin(x)$ at $(x=2, y=3)$:

| Index | Variable | Op | Input indices | Local partials |
|-------|----------|----|---------------|----------------|
| 0 | $x = 2$ | INPUT | — | — |
| 1 | $y = 3$ | INPUT | — | — |
| 2 | $v_1 = 6$ | MUL | [0, 1] | [$y=3$, $x=2$] |
| 3 | $v_2 = 0.909$ | SIN | [0] | [$\cos(2)=-0.416$] |
| 4 | $v_3 = 6.909$ | ADD | [2, 3] | [$1$, $1$] |

### Backward sweep on the tape

```python
adjoints = [0, 0, 0, 0, 0]
adjoints[4] = 1.0  # seed output

# Process tape in REVERSE order:
# Entry 4 (ADD): inputs are [2,3], partials are [1,1]
adjoints[2] += adjoints[4] * 1  # = 1
adjoints[3] += adjoints[4] * 1  # = 1

# Entry 3 (SIN): inputs are [0], partials are [cos(2)]
adjoints[0] += adjoints[3] * (-0.416)  # = -0.416

# Entry 2 (MUL): inputs are [0,1], partials are [3, 2]
adjoints[0] += adjoints[2] * 3  # = -0.416 + 3 = 2.584
adjoints[1] += adjoints[2] * 2  # = 2

# Result: adjoints[0] = ∂f/∂x = 2.584, adjoints[1] = ∂f/∂y = 2
```

---

## 7. Implementation via Operator Overloading

The most elegant way to implement AAD is via **operator overloading**:

1. Define an `AADVariable` class that wraps a float value
2. Overload `+`, `*`, `sin`, etc. to:
   - Compute the value (forward pass, as normal)
   - Record the operation and local partials on the tape
3. After the forward pass, call `backward()` to sweep the tape in reverse

This approach is **non-intrusive**: the pricing function is written in normal mathematical notation, and AAD happens automatically.

```python
# User writes this:
def f(x, y):
    return x * y + sin(x)

# But x, y are AADVariable objects, so every operation is recorded.
x = AADVariable(2.0)
y = AADVariable(3.0)
result = f(x, y)  # Forward pass + tape recording
result.backward()  # Reverse sweep
print(x.adjoint)   # ∂f/∂x = 2.584
print(y.adjoint)   # ∂f/∂y = 2.0
```

---

## 8. Local Partial Derivatives for Common Operations

| Operation | $v = $ | $\frac{\partial v}{\partial a}$ | $\frac{\partial v}{\partial b}$ |
|-----------|--------|--------------------------------|--------------------------------|
| $a + b$ | $a + b$ | $1$ | $1$ |
| $a - b$ | $a - b$ | $1$ | $-1$ |
| $a \times b$ | $ab$ | $b$ | $a$ |
| $a / b$ | $a/b$ | $1/b$ | $-a/b^2$ |
| $\sin(a)$ | $\sin(a)$ | $\cos(a)$ | — |
| $\cos(a)$ | $\cos(a)$ | $-\sin(a)$ | — |
| $\exp(a)$ | $e^a$ | $e^a$ | — |
| $\ln(a)$ | $\ln(a)$ | $1/a$ | — |
| $\sqrt{a}$ | $\sqrt{a}$ | $\frac{1}{2\sqrt{a}}$ | — |
| $a^b$ | $a^b$ | $b \cdot a^{b-1}$ | $a^b \ln(a)$ |
| $N(a)$ (normal CDF) | $N(a)$ | $n(a) = \frac{1}{\sqrt{2\pi}}e^{-a^2/2}$ | — |

---

## 9. AAD for Option Pricing — The Big Picture

1. **Forward pass**: Evaluate the pricing function (BS formula or Heston-COS) using `AADVariable` inputs. The tape records every operation.

2. **Backward pass**: Sweep the tape in reverse. Each intermediate variable's adjoint is accumulated by propagating from the output.

3. **Result**: The adjoints of the input variables ARE the Greeks:
   - $\bar{S} = \frac{\partial V}{\partial S} = \Delta$
   - $\bar{\sigma} = \frac{\partial V}{\partial \sigma} = \mathcal{V}$ (Vega)
   - $\bar{r} = \frac{\partial V}{\partial r} = \rho$ (Rho)
   - etc.

4. **Cost**: ONE backward pass gives ALL Greeks simultaneously, regardless of how many inputs there are.

---

## 10. Why AAD on Hardware Is Novel

| Existing work | What it does | Limitation |
|---------------|-------------|------------|
| AAD in software (Capriotti, Smoking Adjoints) | Computes Greeks via AAD efficiently | Runs on CPU — limited throughput |
| FPGA pricing (Weiss, Klaisoongnoen) | Accelerates Monte Carlo or COS pricing | Greeks via bump-and-reprice — needs $n$ re-pricings |
| FPGA + bump-and-reprice | Hardware-accelerated Greeks | $O(n)$ latency multiplier |
| **This project: FPGA + AAD** | **Hardware-accelerated AAD** | **All Greeks in one pipelined backward pass** |

The gap: nobody has implemented AAD's reverse pass as a hardware pipeline. This project fills that gap.

---

## 11. Challenges for Hardware AAD

1. **Backward dependencies**: The reverse pass must process operations in reverse order, accessing values stored during the forward pass. This creates a data dependency chain.

2. **Tape storage**: The tape (all intermediate values and partial derivatives) must be stored and accessed during the backward pass. On an FPGA, this means on-chip BRAM/URAM.

3. **Variable tape length**: For COS method, the tape length is fixed (determined by $N$), which is a significant advantage over Monte Carlo AAD.

4. **Fixed-point precision**: AAD accumulates adjoints through many operations — quantization errors compound. Careful bit-width analysis is essential.
