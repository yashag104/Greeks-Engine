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

## Generated shared-multiplier datapaths: cycles per evaluation

| config | multipliers | II (AAD) | AAD | price only | bump-and-reprice | bump / AAD |
|---|---|---|---|---|---|---|
| z7 (WL56/FL28) | 2 | 126 | 16754 | 8724 | 165824 | 9.9 |
| z7 (WL56/FL28) | 4 | 63 | 8693 | 4610 | 87658 | 10.1 |
| z7 (WL56/FL28) | 8 | 32 | 4731 | 4565 | 86803 | 18.4 |
| z7 (WL56/FL28) | 16 | 32 | 4619 | 4560 | 86708 | 18.8 |
| zu (WL64/FL32) | 1 | 251 | 32936 | 16777 | 318831 | 9.7 |
| zu (WL64/FL32) | 2 | 126 | 16884 | 8705 | 165463 | 9.8 |
| zu (WL64/FL32) | 4 | 63 | 8701 | 4633 | 88095 | 10.1 |
| zu (WL64/FL32) | 8 | 32 | 4704 | 2570 | 48898 | 10.4 |
| zu (WL64/FL32) | 16 | 16 | 2612 | 1537 | 29271 | 11.2 |
| zu (WL64/FL32) | 32 | 8 | 1599 | 1023 | 19505 | 12.2 |
| zu (WL64/FL32) | 64 | 4 | 1071 | 885 | 16883 | 15.8 |
| zu (WL64/FL32) | 128 | 3 | 940 | 885 | 16883 | 18.0 |

## Generated datapaths: worst relative error over the parameter grid

| output | Zynq-7020 config (56-bit) | 64-bit config | max error / bound |
|---|---|---|---|
| price | 6.1e-07 | 5.9e-08 | 0.090 |
| delta | 1.3e-07 | 1.9e-08 | 0.106 |
| strike_sens | 1.4e-07 | 1.9e-08 | 0.101 |
| theta_greek | 9.5e-07 | 2.3e-08 | 0.089 |
| rho_greek | 1.4e-07 | 2.2e-08 | 0.101 |
| vega | 1.3e-06 | 2.1e-08 | 0.098 |
| kappa_sens | 6.4e-05 | 6.0e-06 | 0.095 |
| theta_sens | 2.0e-06 | 1.0e-07 | 0.102 |
| xi_sens | 1.9e-05 | 1.1e-06 | 0.100 |
| rho_corr | 2.4e-05 | 1.2e-06 | 0.115 |

## Yosys synth_xilinx cell counts (estimates; carry column = CARRY4, xc7 only)

| design | LUT | FF | SRL | CARRY4 | DSP | note |
|---|---|---|---|---|---|---|
| heston_aad_z7 (full-range shifters) | 90648 | 32878 | 3050 | 6302 | 96 | xc7; before shift-range analysis |
| heston_aad_z7 | 59024 | 32731 | 3058 | 5915 | 96 | xc7; fully on-chip, 56-bit, 8 multipliers |
| heston_aad_z7h | 45504 | 24856 | 2922 | 4965 | 96 | xc7; host setup; Zynq-7020 has 53200 LUT / 106400 FF / 220 DSP |
| heston_aad_zu | 108330 | 59953 | 6409 | 0 | 512 | xcup (DSP48E2); fully on-chip, 64-bit, 32 multipliers; ZCU104 xczu7ev has 230400 LUT / 460800 FF / 1728 DSP |

