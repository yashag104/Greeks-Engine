# Options Pricing & the Black-Scholes Model

## 1. What Is an Option?

An **option** is a financial derivative — a contract that gives the holder the *right* (but not the obligation) to buy or sell an underlying asset at a predetermined **strike price** $K$ on or before a specified **expiry date** $T$.

- **Call option**: right to *buy* at strike $K$. Payoff at expiry: $\max(S_T - K, 0)$
- **Put option**: right to *sell* at strike $K$. Payoff at expiry: $\max(K - S_T, 0)$

where $S_T$ is the spot price of the underlying at expiry.

---

## 2. The Black-Scholes Model

### Assumptions
1. The stock price follows a **geometric Brownian motion**: $dS = \mu S \, dt + \sigma S \, dW$
2. **Constant volatility** $\sigma$ (this is the key assumption Heston relaxes)
3. **Constant risk-free rate** $r$
4. No dividends, no transaction costs, continuous trading
5. Log-normal distribution of stock prices

### The Black-Scholes Formula

For a **European call option**:

$$V_{call} = S \cdot N(d_1) - K e^{-rT} \cdot N(d_2)$$

For a **European put option** (via put-call parity):

$$V_{put} = K e^{-rT} \cdot N(-d_2) - S \cdot N(-d_1)$$

where:

$$d_1 = \frac{\ln(S/K) + (r + \sigma^2/2) \cdot T}{\sigma \sqrt{T}}$$

$$d_2 = d_1 - \sigma \sqrt{T} = \frac{\ln(S/K) + (r - \sigma^2/2) \cdot T}{\sigma \sqrt{T}}$$

and $N(\cdot)$ is the standard normal cumulative distribution function (CDF), and $n(\cdot) = N'(\cdot) = \frac{1}{\sqrt{2\pi}} e^{-x^2/2}$ is the standard normal PDF.

### Intuition

- $N(d_2)$ ≈ risk-neutral probability that the option expires in-the-money
- $N(d_1)$ ≈ probability-weighted exposure to the stock (Delta)
- $S \cdot N(d_1)$: expected value of receiving the stock, weighted by exercise probability
- $K e^{-rT} \cdot N(d_2)$: present value of paying the strike, weighted by exercise probability

---

## 3. The Five Greeks

Greeks measure the **sensitivity** of the option price to changes in underlying parameters. They are first (and second) order partial derivatives of the option value $V$ with respect to model inputs.

### Why Greeks Matter to a Trading Desk

A trading desk holds a **portfolio** of options. To manage risk, they need to know:
- **How much does our portfolio value change if the stock moves 1%?** → Delta, Gamma
- **How much do we lose just from time passing?** → Theta
- **How exposed are we to volatility changing?** → Vega
- **What if interest rates move?** → Rho

Without Greeks, a desk is flying blind — they can't hedge, can't size positions, and can't report risk.

---

### 3.1 Delta ($\Delta$) — Sensitivity to Spot Price

$$\Delta_{call} = \frac{\partial V}{\partial S} = N(d_1)$$

$$\Delta_{put} = N(d_1) - 1$$

**Economic meaning:** If the stock price increases by $1, the call option price increases by approximately $\Delta$ dollars.

**Trading use:**
- **Delta hedging**: To neutralize exposure, a desk holding 100 call options with $\Delta = 0.6$ would short $100 \times 0.6 = 60$ shares.
- Delta ranges from 0 (deep OTM) to 1 (deep ITM) for calls.
- ATM options have $\Delta \approx 0.5$.

---

### 3.2 Gamma ($\Gamma$) — Sensitivity of Delta to Spot Price

$$\Gamma = \frac{\partial^2 V}{\partial S^2} = \frac{n(d_1)}{S \sigma \sqrt{T}}$$

(Same for calls and puts.)

**Economic meaning:** How fast Delta changes as the stock moves. High Gamma means the hedge needs frequent rebalancing.

**Trading use:**
- Gamma is highest for ATM, near-expiry options.
- **Gamma risk**: If you're short options (sold them), high Gamma means your Delta hedge can get stale very quickly in a fast market — you lose money from rebalancing lag.
- Long Gamma positions profit from large moves in either direction.

---

### 3.3 Vega ($\mathcal{V}$) — Sensitivity to Volatility

$$\mathcal{V} = \frac{\partial V}{\partial \sigma} = S \cdot n(d_1) \cdot \sqrt{T}$$

(Same for calls and puts.)

**Economic meaning:** If implied volatility increases by 1 percentage point, the option price increases by approximately $\mathcal{V}/100$ dollars.

**Trading use:**
- **Vega is the most traded Greek** — volatility trading (buying/selling vol) is a massive market.
- A desk long Vega profits when vol increases (e.g., during a crash).
- Longer-dated options have higher Vega (more time for vol to affect them).
- Vega is NOT one of the original Greek letters — it's sometimes called "kappa" in older texts.

---

### 3.4 Theta ($\Theta$) — Sensitivity to Time (Time Decay)

$$\Theta_{call} = \frac{\partial V}{\partial t} = -\frac{S \cdot n(d_1) \cdot \sigma}{2\sqrt{T}} - r K e^{-rT} N(d_2)$$

$$\Theta_{put} = -\frac{S \cdot n(d_1) \cdot \sigma}{2\sqrt{T}} + r K e^{-rT} N(-d_2)$$

Note: Theta is usually quoted as $\partial V / \partial T$ with a sign convention that makes it *negative* for long option positions (options lose value as time passes, all else equal).

**Economic meaning:** The option loses approximately $|\Theta|$ dollars per day just from the passage of time (assuming 1 day = 1/365 of a year).

**Trading use:**
- Option sellers (writers) collect Theta — they want time to pass with nothing happening.
- Option buyers pay Theta — they need the stock to move enough to offset time decay.
- Theta accelerates near expiry, especially for ATM options.

---

### 3.5 Rho ($\rho$) — Sensitivity to Interest Rate

$$\rho_{call} = \frac{\partial V}{\partial r} = K T e^{-rT} N(d_2)$$

$$\rho_{put} = -K T e^{-rT} N(-d_2)$$

**Economic meaning:** If the risk-free rate increases by 1 percentage point, the call option price increases by approximately $\rho/100$ dollars.

**Trading use:**
- Usually the least important Greek for equity options (rate changes are small and slow).
- Much more important for interest-rate derivatives and long-dated options.
- Higher rates increase call values (lower PV of strike) and decrease put values.

---

## 4. Summary Table — Closed-Form Greeks (European Call)

| Greek | Symbol | Formula | Measures |
|-------|--------|---------|----------|
| Delta | $\Delta$ | $N(d_1)$ | Price sensitivity to spot |
| Gamma | $\Gamma$ | $\frac{n(d_1)}{S\sigma\sqrt{T}}$ | Convexity / hedge stability |
| Vega | $\mathcal{V}$ | $S \cdot n(d_1) \cdot \sqrt{T}$ | Volatility exposure |
| Theta | $\Theta$ | $-\frac{Sn(d_1)\sigma}{2\sqrt{T}} - rKe^{-rT}N(d_2)$ | Time decay |
| Rho | $\rho$ | $KTe^{-rT}N(d_2)$ | Interest rate exposure |

---

## 5. Key Relationships

1. **Put-Call Parity**: $C - P = S - Ke^{-rT}$ (model-independent for Europeans)
2. **Delta relationship**: $\Delta_{put} = \Delta_{call} - 1$
3. **Gamma and Theta relationship**: For a delta-hedged portfolio, $\Theta + \frac{1}{2}\sigma^2 S^2 \Gamma + rS\Delta = rV$ (the Black-Scholes PDE)

---

## 6. Limitations of Black-Scholes

The constant-$\sigma$ assumption is the model's greatest weakness:
- **Volatility smile/skew**: Market-implied volatilities vary by strike and maturity — BS predicts they should be flat.
- **Fat tails**: Real returns have heavier tails than the log-normal distribution.
- **Volatility clustering**: Real volatility is time-varying and mean-reverting.

These limitations motivate the **Heston model** (next document).
