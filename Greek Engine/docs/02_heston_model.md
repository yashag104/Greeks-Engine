# The Heston Stochastic Volatility Model

## 1. Why Black-Scholes' Constant-σ Breaks

In Black-Scholes, volatility $\sigma$ is a **constant**. But in real markets:

1. **Volatility Smile**: If you back out implied volatilities from observed option prices across different strikes, you get a "smile" or "skew" shape — not a flat line. Deep OTM puts have higher implied vol than ATM options.

2. **Volatility Clustering**: Periods of high volatility tend to follow other periods of high volatility (and vice versa). Today's realized vol is correlated with yesterday's.

3. **Fat Tails / Excess Kurtosis**: Stock returns exhibit heavier tails than the log-normal distribution predicts. Extreme moves (crashes) happen more often than BS implies.

4. **Leverage Effect**: When stock prices drop, volatility tends to increase (negative correlation between returns and volatility changes).

**Bottom line**: Volatility is not constant — it is itself a random process. The Heston model treats it as such.

---

## 2. The Heston Model Dynamics

The Heston model (1993) describes the joint dynamics of the stock price $S_t$ and its instantaneous variance $v_t$:

### Stock price process:
$$dS_t = r S_t \, dt + \sqrt{v_t} \, S_t \, dW_t^S$$

### Variance process (CIR process):
$$dv_t = \kappa(\theta - v_t) \, dt + \xi \sqrt{v_t} \, dW_t^v$$

### Correlation:
$$dW_t^S \cdot dW_t^v = \rho \, dt$$

### Parameters

| Parameter | Symbol | Meaning | Typical Range |
|-----------|--------|---------|---------------|
| Initial spot | $S_0$ | Current stock price | Market observed |
| Initial variance | $v_0$ | Current instantaneous variance | 0.01–0.09 (vol 10%–30%) |
| Risk-free rate | $r$ | Continuously compounded | 0.01–0.05 |
| Strike | $K$ | Option strike price | Varies |
| Maturity | $T$ | Time to expiry (years) | 0.1–2.0 |
| Mean-reversion speed | $\kappa$ | How fast $v_t$ reverts to $\theta$ | 0.5–5.0 |
| Long-run variance | $\theta$ | Equilibrium level of $v_t$ | 0.01–0.09 |
| Vol-of-vol | $\xi$ | Volatility of the variance process | 0.1–1.0 |
| Correlation | $\rho$ | Correlation between $W^S$ and $W^v$ | −0.9 to −0.3 (typically negative) |

---

## 3. Key Features of the Heston Model

### 3.1 Mean Reversion ($\kappa$, $\theta$)

The term $\kappa(\theta - v_t)$ is a **mean-reverting drift**:
- When $v_t > \theta$: drift is negative → variance is pulled back down
- When $v_t < \theta$: drift is positive → variance is pulled back up
- $\kappa$ controls the speed: higher $\kappa$ = faster reversion

This captures the empirical observation that volatility tends to oscillate around a long-term average.

### 3.2 The Feller Condition

For the variance process to remain strictly positive (never hit zero):

$$2\kappa\theta > \xi^2$$

If violated, $v_t$ can touch zero — the process reflects but creates numerical issues. In practice, many calibrated parameter sets violate Feller, requiring careful numerical handling.

### 3.3 Negative Correlation ($\rho < 0$)

Negative $\rho$ captures the **leverage effect**: when stocks drop ($dW^S < 0$), volatility tends to rise ($dW^v > 0$, and with $\rho < 0$ this is correlated). This produces:
- **Volatility skew**: OTM puts have higher implied vol (consistent with market observation)
- **Asymmetric return distributions**: left-skewed

### 3.4 Vol-of-Vol ($\xi$)

$\xi$ controls how "noisy" the variance process is:
- High $\xi$ → more volatile volatility → fatter tails in returns → more pronounced smile
- Low $\xi$ → variance process is nearly deterministic → closer to BS

---

## 4. Why There Is No Closed-Form Option Price

In Black-Scholes, the option price has a simple closed-form formula because:
- The stock price SDE has an explicit solution: $S_T = S_0 \exp\left((r - \sigma^2/2)T + \sigma W_T\right)$
- The integral $E[\max(S_T - K, 0)]$ can be evaluated analytically via the normal CDF

In Heston, **neither of these works**:
1. The stock price SDE does **not** have an explicit solution because $\sqrt{v_t}$ is itself stochastic — you can't "solve" $dS$ without knowing the entire path of $v_t$.
2. The joint distribution of $(S_T, v_T)$ is **not** a simple known distribution — it involves the integral of the CIR process.

### What Heston *does* have: a Characteristic Function

Although there's no closed-form price, Heston derived the **characteristic function** of $\ln(S_T)$ in closed form. The characteristic function is:

$$\phi(u) = E[e^{iu \ln(S_T)}] = \exp\left(C(u,T) + D(u,T) \cdot v_0 + iu \ln(S_0)\right)$$

where:

$$d(u) = \sqrt{(\rho \xi u i - \kappa)^2 + \xi^2(ui + u^2)}$$

$$g(u) = \frac{\kappa - \rho \xi u i - d(u)}{\kappa - \rho \xi u i + d(u)}$$

$$C(u,T) = r \cdot u \cdot i \cdot T + \frac{\kappa \theta}{\xi^2} \left[(\kappa - \rho \xi u i - d) T - 2 \ln\left(\frac{1 - g \cdot e^{-dT}}{1 - g}\right)\right]$$

$$D(u,T) = \frac{\kappa - \rho \xi u i - d}{\xi^2} \cdot \frac{1 - e^{-dT}}{1 - g \cdot e^{-dT}}$$

### The Pricing Connection

Once you have $\phi(u)$, you can recover the option price via **Fourier inversion**:

$$V_{call} = S_0 - \frac{1}{2} K e^{-rT} + \frac{K e^{-rT}}{\pi} \int_0^{\infty} \text{Re}\left[\frac{e^{-iu\ln(K)} \phi(u)}{iu}\right] du$$

Or via the **COS method** (next document), which is faster and more numerically stable.

---

## 5. Greeks Under Heston

Since there's no closed-form price, there are **no closed-form Greeks** either. Greeks must be computed via:

1. **Bump-and-reprice** (finite differences): Shift each parameter by $\epsilon$, reprice, compute $\Delta V / \Delta \text{param}$. Requires $n+1$ pricings for $n$ Greeks. Slow.

2. **Pathwise / likelihood ratio methods** (for Monte Carlo): Differentiate through the simulation paths. Complex to implement.

3. **AAD (Algorithmic Adjoint Differentiation)**: Differentiate through the pricing algorithm itself. Computes ALL Greeks in a single backward pass. This is our approach.

### Heston Greeks to Compute

| Greek | With respect to | Notation |
|-------|----------------|----------|
| Delta | $S_0$ (spot price) | $\partial V / \partial S_0$ |
| Vega | $v_0$ (initial variance) | $\partial V / \partial v_0$ |
| Rho | $r$ (risk-free rate) | $\partial V / \partial r$ |
| Kappa sensitivity | $\kappa$ (mean reversion speed) | $\partial V / \partial \kappa$ |
| Theta sensitivity | $\theta$ (long-run variance) | $\partial V / \partial \theta$ |
| Xi sensitivity | $\xi$ (vol-of-vol) | $\partial V / \partial \xi$ |
| Rho_corr sensitivity | $\rho$ (correlation) | $\partial V / \partial \rho$ |

Under Heston, we have **7 Greeks** (sensitivities to 7 model parameters), compared to BS's 5. AAD computes all 7 in one backward pass — bump-and-reprice would need 8 pricings.

---

## 6. Summary

| Feature | Black-Scholes | Heston |
|---------|--------------|--------|
| Volatility | Constant $\sigma$ | Stochastic $v_t$ (CIR process) |
| Closed-form price | Yes | No (but has characteristic function) |
| Closed-form Greeks | Yes | No |
| Captures smile/skew | No | Yes (via $\rho$, $\xi$) |
| Mean-reverting vol | No | Yes (via $\kappa$, $\theta$) |
| Pricing method | Direct formula | Fourier inversion / COS / MC |
| Number of Greeks | 5 | 7+ |
