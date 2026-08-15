# The COS (Fourier-Cosine) Method for Option Pricing

## 1. Why the COS Method?

To price options under Heston, we need to numerically invert the characteristic function $\phi(u)$ to recover the option price. Three main approaches exist:

| Method | Pros | Cons |
|--------|------|------|
| **Direct Fourier integration** (Carr-Madan) | Simple, well-known | Oscillatory integrand, slow convergence |
| **FFT-based** | Fast ($O(N \log N)$) | Computes prices for a grid of strikes simultaneously — wasteful if you need one strike |
| **COS method** (Fang & Oosterlee, 2008) | Exponential convergence, deterministic, no RNG | Requires truncation range selection |

The COS method is ideal for hardware because:
- **Deterministic**: No random number generation needed
- **Fixed computation**: Every step is a known arithmetic operation
- **Fast convergence**: Typically $N = 64–256$ terms suffice
- **Parallelizable**: Each cosine term is independent

---

## 2. Mathematical Foundation

### 2.1 The Key Idea

The COS method approximates the conditional density function $f(y|x)$ of $\ln(S_T)$ using a **Fourier-cosine series expansion** on a truncated interval $[a, b]$:

$$f(y|x) \approx \sum_{k=0}^{N-1} {}' A_k(x) \cos\left(k\pi \frac{y - a}{b - a}\right)$$

where $\sum'$ means the first term is halved, and:

$$A_k(x) = \frac{2}{b-a} \int_a^b f(y|x) \cos\left(k\pi \frac{y-a}{b-a}\right) dy$$

### 2.2 Connection to Characteristic Function

The key insight: the Fourier-cosine coefficients $A_k$ can be recovered from the **characteristic function** $\phi(u)$:

$$A_k \approx \frac{2}{b-a} \text{Re}\left[\phi\left(\frac{k\pi}{b-a}\right) \cdot \exp\left(-i \frac{k\pi a}{b-a}\right)\right]$$

This avoids computing the density $f$ entirely — we go directly from $\phi(u)$ to expansion coefficients.

### 2.3 Option Price Formula

The European call option price is:

$$V_{call} = e^{-rT} \sum_{k=0}^{N-1} {}' \text{Re}\left[\phi\left(\frac{k\pi}{b-a}\right) \cdot \exp\left(-i \frac{k\pi a}{b-a}\right)\right] \cdot V_k$$

where $V_k$ are the **payoff cosine coefficients** — the Fourier-cosine coefficients of the payoff function.

---

## 3. Payoff Coefficients $V_k$

For a **European call** with payoff $\max(S_T - K, 0) = K(\max(e^y - 1, 0))$ where $y = \ln(S_T/K)$:

$$V_k = \frac{2}{b-a} K \left[\chi_k(0, b) - \psi_k(0, b)\right]$$

where:

### $\chi_k$ — Exponential-cosine integral:

$$\chi_k(c, d) = \frac{1}{1 + \left(\frac{k\pi}{b-a}\right)^2} \left[e^d \cos\left(k\pi\frac{d-a}{b-a}\right) - e^c \cos\left(k\pi\frac{c-a}{b-a}\right) + \frac{k\pi}{b-a}\left(e^d \sin\left(k\pi\frac{d-a}{b-a}\right) - e^c \sin\left(k\pi\frac{c-a}{b-a}\right)\right)\right]$$

### $\psi_k$ — Cosine integral:

For $k = 0$:
$$\psi_0(c, d) = d - c$$

For $k \neq 0$:
$$\psi_k(c, d) = \frac{b-a}{k\pi} \left[\sin\left(k\pi\frac{d-a}{b-a}\right) - \sin\left(k\pi\frac{c-a}{b-a}\right)\right]$$

For a **European put** with payoff $\max(K - S_T, 0)$:

$$V_k = \frac{2}{b-a} K \left[\psi_k(a, 0) - \chi_k(a, 0)\right]$$

---

## 4. Truncation Range $[a, b]$

The infinite integration domain must be truncated to $[a, b]$. Fang & Oosterlee recommend using cumulants of $\ln(S_T/K)$:

$$a = c_1 - L\sqrt{c_2 + \sqrt{c_4}}, \quad b = c_1 + L\sqrt{c_2 + \sqrt{c_4}}$$

where $L \approx 10$ (conservative) or $L \approx 12$, and:

### Cumulants for Heston:

$$c_1 = (r - \frac{\theta}{2})T + \frac{(1 - e^{-\kappa T})(2\kappa\theta - v_0)}{2\kappa} - \frac{\theta T}{2} \quad \text{[simplified]}$$

More precisely, define $\mu = \ln(S_0/K)$ (the log-moneyness), then:

**First cumulant** (mean):
$$c_1 = \mu + \left(r - \frac{\theta}{2}\right)T + \frac{1 - e^{-\kappa T}}{2\kappa}(\theta - v_0)$$

Note: Some references fold $\mu$ into the range differently. For our implementation we set $x = \ln(S_0/K)$ and work in the log-moneyness space.

**Second cumulant** (variance):
$$c_2 = \frac{1}{8\kappa^3}\left[\xi^2 T \kappa e^{-\kappa T}(v_0 - \theta)(8\kappa\rho\xi - 4\xi^2) + \kappa\rho\xi\theta(1 - e^{-\kappa T})8\kappa^2(\theta + v_0e^{-\kappa T}) + 2\theta\kappa T(-2 + \kappa T) + \xi^2(1-e^{-\kappa T})(-2\theta + v_0(1 + e^{-\kappa T}))\right]$$

In practice, a simplified approximation often works:
$$c_2 \approx v_0 T + \frac{\theta T}{2}$$

**Fourth cumulant**: Often approximated or set to a small value. For the truncation range, the $\sqrt{c_4}$ term provides a safety margin.

In practice:
$$c_4 \approx 0 \quad \text{(simplified, contributes little to truncation range)}$$

---

## 5. Step-by-Step Algorithm

Here is every arithmetic step the COS method performs, in order:

### Step 1: Compute log-moneyness
```
x = ln(S0 / K)
```

### Step 2: Compute cumulants and truncation range
```
c1 = ... (first cumulant of ln(S_T/K))
c2 = ... (second cumulant)
L = 10 (or 12)
a = c1 - L * sqrt(c2)
b = c1 + L * sqrt(c2)
```

### Step 3: For each k = 0, 1, ..., N-1:

#### 3a: Compute the characteristic function argument
```
u_k = k * pi / (b - a)
```

#### 3b: Evaluate the Heston characteristic function φ(u_k)
```
# Heston char function at u = u_k (see Heston model document for full formula)
d_k = sqrt((rho*xi*i*u_k - kappa)^2 + xi^2*(i*u_k + u_k^2))
g_k = (kappa - rho*xi*i*u_k - d_k) / (kappa - rho*xi*i*u_k + d_k)
exp_d_k = exp(-d_k * T)

C_k = r*i*u_k*T + (kappa*theta/xi^2) * ((kappa - rho*xi*i*u_k - d_k)*T - 2*ln((1 - g_k*exp_d_k)/(1 - g_k)))
D_k = ((kappa - rho*xi*i*u_k - d_k)/xi^2) * (1 - exp_d_k)/(1 - g_k*exp_d_k)

phi_k = exp(C_k + D_k*v0 + i*u_k*x)
```

#### 3c: Compute the Fourier coefficient
```
F_k = Re[phi_k * exp(-i * u_k * a)]
```
(This is $\text{Re}[\phi(u_k) \cdot e^{-iu_k a}]$)

#### 3d: Compute the payoff coefficient V_k
```
# For European call with payoff range [0, b]:
chi_k = compute_chi(k, 0, b, a, b)
psi_k = compute_psi(k, 0, b, a, b)
V_k = (2 / (b-a)) * K * (chi_k - psi_k)
```

#### 3e: Accumulate the sum
```
# Apply the ' (prime) summation — halve the k=0 term
weight = 0.5 if k == 0 else 1.0
sum += weight * F_k * V_k
```

### Step 4: Multiply by discount factor
```
V_call = exp(-r*T) * sum
```

---

## 6. Computational Complexity

- **Per pricing**: $O(N)$ characteristic function evaluations
- Each evaluation involves: 1 sqrt, 2 exp, 1 log, several multiplications
- Total: ~$O(N)$ transcendental function evaluations + $O(N)$ trig evaluations
- Typical $N$: 64–256 for Heston (exponential convergence)

Compare to Monte Carlo: $O(M \times \text{steps})$ where $M$ = number of paths (10,000–1,000,000).

---

## 7. Why COS Is Ideal for Hardware

1. **Fixed iteration count**: $N$ is known at design time → fixed-length pipeline
2. **No branching**: Every step is pure arithmetic
3. **No RNG**: Deterministic → reproducible results
4. **Parallelizable**: Each $k$ term is independent → can process multiple $k$ in parallel
5. **Dominated by known operations**: sin, cos, exp, log, sqrt — all implementable as CORDIC or lookup tables in hardware

---

## 8. Relation to AAD

When we wrap the COS method in our AAD engine:
- Every arithmetic operation in Steps 1–4 is recorded on the **tape**
- The backward pass computes ∂V/∂(all inputs) in one sweep
- This gives us all Heston Greeks simultaneously
- The tape schema (a precise listing of every operation) becomes the blueprint for the hardware reverse pass
