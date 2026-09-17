## Accuracy of the Heston AAD RTL (Q32.32), 21 parameter sets

| output | max rel. error vs double | median rel. error | max error / bound | bits lost (worst case, bound) |
|---|---|---|---|---|
| price | 2.98e-07 | 7.54e-09 | 0.141 | 16.5 |
| delta | 2.92e-07 | 1.01e-08 | 0.092 | 13.9 |
| strike_sens | 3.07e-07 | 1.04e-08 | 0.084 | 13.9 |
| theta_greek | 3.46e-07 | 1.66e-08 | 0.131 | 17.9 |
| rho_greek | 3.06e-07 | 8.74e-09 | 0.092 | 17.6 |
| vega | 8.91e-07 | 1.73e-08 | 0.144 | 20.8 |
| kappa_sens | 1.92e-05 | 4.92e-08 | 0.211 | 15.7 |
| theta_sens | 1.28e-06 | 1.76e-08 | 0.143 | 19.8 |
| xi_sens | 3.70e-06 | 7.04e-08 | 0.132 | 18.7 |
| rho_corr | 5.35e-05 | 1.67e-07 | 0.128 | 17.2 |

Cycles per AAD evaluation: 433779

## Bump-and-reprice (RTL, Q32.32) vs AAD, base case

| output | AAD rel. error | best bump rel. error | at relative h | worst bump rel. error |
|---|---|---|---|---|
| delta | 9.04e-10 | 4.99e-07 | 0.0001 | 2.14e-02 |
| strike_sens | 4.78e-09 | 3.29e-06 | 0.001 | 1.17e-02 |
| theta_greek | 8.49e-09 | 4.75e-06 | 0.01 | 8.83e-01 |
| rho_greek | 5.52e-09 | 1.18e-06 | 0.01 | 1.73e-01 |
| vega | 1.73e-08 | 4.62e-06 | 0.01 | 6.96e+00 |
| kappa_sens | 1.57e-06 | 8.87e-06 | 0.01 | 3.96e+01 |
| theta_sens | 8.45e-09 | 8.80e-07 | 0.01 | 5.40e+00 |
| xi_sens | 3.75e-08 | 8.50e-06 | 0.01 | 1.24e+01 |
| rho_corr | 6.85e-07 | 5.50e-05 | 0.01 | 1.41e+01 |

Cycles: AAD 433779, bump-and-reprice 3811647 (8.8x)

