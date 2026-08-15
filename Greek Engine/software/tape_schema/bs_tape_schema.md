# Black-Scholes Tape Schema

## Overview

This document is a precise, ordered list of every operation the hardware needs to replicate for the Black-Scholes pricing formula and its AAD reverse pass. It is detailed enough that someone could implement the RTL/MATLAB pipeline from it without asking questions.

## Inputs (Leaf Variables on Tape)

| Tape Index | Variable | Description |
|-----------|----------|-------------|
| 0 | S | Spot price |
| 1 | K | Strike price |
| 2 | T | Time to maturity |
| 3 | r | Risk-free rate |
| 4 | σ | Volatility |

## Forward Pass — Operation Sequence

The BS call price formula: `V = S·N(d1) - K·exp(-rT)·N(d2)`

### Stage 1: Compute sqrt(T)
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 5 | SQRT | T(2) | √T | ∂/∂T = 1/(2√T) |

### Stage 2: Compute σ·√T
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 6 | MUL | σ(4), √T(5) | σ√T | ∂/∂σ = √T, ∂/∂√T = σ |

### Stage 3: Compute S/K
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 7 | DIV | S(0), K(1) | S/K | ∂/∂S = 1/K, ∂/∂K = -S/K² |

### Stage 4: Compute ln(S/K)
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 8 | LOG | S/K(7) | ln(S/K) | ∂/∂(S/K) = K/S |

### Stage 5: Compute σ²
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 9 | MUL | σ(4), σ(4) | σ² | ∂/∂σ = 2σ |

### Stage 6: Compute σ²/2
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 10 | MUL | σ²(9), 0.5 | σ²/2 | ∂/∂σ² = 0.5 |

### Stage 7: Compute r + σ²/2
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 11 | ADD | r(3), σ²/2(10) | r+σ²/2 | ∂/∂r = 1, ∂/∂(σ²/2) = 1 |

### Stage 8: Compute (r + σ²/2)·T
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 12 | MUL | (r+σ²/2)(11), T(2) | (r+σ²/2)T | ∂/∂(r+σ²/2) = T, ∂/∂T = r+σ²/2 |

### Stage 9: Compute numerator = ln(S/K) + (r+σ²/2)T
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 13 | ADD | ln(S/K)(8), (r+σ²/2)T(12) | num | ∂/∂ln(S/K) = 1, ∂/∂(...) = 1 |

### Stage 10: Compute d1 = num / (σ√T)
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 14 | DIV | num(13), σ√T(6) | d1 | ∂/∂num = 1/(σ√T), ∂/∂(σ√T) = -num/(σ√T)² |

### Stage 11: Compute d2 = d1 - σ√T
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 15 | SUB | d1(14), σ√T(6) | d2 | ∂/∂d1 = 1, ∂/∂(σ√T) = -1 |

### Stage 12: Compute -r·T
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 16 | MUL | r(3), T(2) | rT | ∂/∂r = T, ∂/∂T = r |
| 17 | NEG | rT(16) | -rT | ∂/∂rT = -1 |

### Stage 13: Compute exp(-rT)
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 18 | EXP | -rT(17) | e^(-rT) | ∂/∂(-rT) = e^(-rT) |

### Stage 14: Compute N(d1) and N(d2)
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 19 | NCDF | d1(14) | N(d1) | ∂/∂d1 = n(d1) |
| 20 | NCDF | d2(15) | N(d2) | ∂/∂d2 = n(d2) |

### Stage 15: Compute price components
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 21 | MUL | S(0), N(d1)(19) | S·N(d1) | ∂/∂S = N(d1), ∂/∂N(d1) = S |
| 22 | MUL | K(1), e^(-rT)(18) | K·e^(-rT) | ∂/∂K = e^(-rT), ∂/∂e^(-rT) = K |
| 23 | MUL | K·e^(-rT)(22), N(d2)(20) | K·e^(-rT)·N(d2) | ∂/∂(Ke^-rT) = N(d2), ∂/∂N(d2) = Ke^-rT |

### Stage 16: Final price
| Step | Op | Inputs | Output | Local Partials |
|------|-----|--------|--------|---------------|
| 24 | SUB | S·N(d1)(21), K·e^(-rT)·N(d2)(23) | V | ∂/∂(S·N(d1)) = 1, ∂/∂(K·e^(-rT)·N(d2)) = -1 |

## Total Operation Count

| Operation | Count |
|-----------|-------|
| ADD/SUB | 4 |
| MUL | 7 |
| DIV | 2 |
| SQRT | 1 |
| LOG | 1 |
| EXP | 1 |
| NEG | 1 |
| NCDF | 2 |
| **Total** | **19** |

## Backward Pass — Adjoint Sweep

Starting from output V (index 24), sweep in reverse order through indices 24 → 0.

For each entry: `adjoint[parent] += adjoint[output] × local_partial`

### Pipeline Design Notes

1. **Fixed tape length**: Exactly 25 entries (indices 0-24) — completely deterministic
2. **No branches**: Every operation in the chain is unconditional
3. **Key dependencies for pipeline**: d1 feeds both N(d1) and d2; σ√T feeds both d1 and d2
4. **NCDF implementation**: Can use CORDIC + polynomial approximation, or LUT + interpolation
5. **Storage**: Need to store all 25 values during forward pass for backward access
6. **Critical path**: LOG → d1 → NCDF is the longest dependency chain (~3 stages)

## Data Flow Diagram

```
Inputs: S(0), K(1), T(2), r(3), σ(4)
                                    
T ──→ [SQRT] ──→ √T                 
                  │                  
σ, √T ──→ [MUL] ──→ σ√T             
                      │              
S, K ──→ [DIV] ──→ S/K              
                    │                
S/K ──→ [LOG] ──→ ln(S/K)           
                                     
σ ──→ [MUL σ] ──→ σ²                
σ² ──→ [×0.5] ──→ σ²/2              
r, σ²/2 ──→ [ADD] ──→ r+σ²/2        
(r+σ²/2), T ──→ [MUL] ──→ (r+σ²/2)T
                                     
ln(S/K), (r+σ²/2)T ──→ [ADD] ──→ num
num, σ√T ──→ [DIV] ──→ d1           
d1, σ√T ──→ [SUB] ──→ d2            
                                     
d1 ──→ [NCDF] ──→ N(d1)             
d2 ──→ [NCDF] ──→ N(d2)             
                                     
r, T ──→ [MUL] ──→ rT               
rT ──→ [NEG] ──→ -rT                
-rT ──→ [EXP] ──→ e^{-rT}           
                                     
S, N(d1) ──→ [MUL] ──→ S·N(d1)      
K, e^{-rT} ──→ [MUL] ──→ Ke^{-rT}   
Ke^{-rT}, N(d2) ──→ [MUL] ──→ Ke^{-rT}N(d2)
                                     
S·N(d1), Ke^{-rT}N(d2) ──→ [SUB] ──→ V (OUTPUT)
```
