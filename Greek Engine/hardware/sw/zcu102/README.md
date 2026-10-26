# ZCU102 end to end: Cortex-A53 + the 64-bit engine, with timing and power

The JTAG runs (`hardware/vivado/zcu102`) proved the engine bit-exact on the ZCU102
but cannot time it or measure its power. This program runs on the board's
Cortex-A53 (bare metal), driving the engine through the processor design of
`hardware/vivado/zcu102/bd_ps.tcl` (M_AXI_HPM0_FPD -> AXI4-Lite, PL clock 100 MHz):

1. **correctness**: all 101 board cases (1 vector, 50-case sweep, 50 real NIFTY
   days) checked bit-exact, 10 outputs each;
2. **timing**: write 19 words, engine (start .. done), read 20 words, and the
   whole evaluation, best and mean of 1,000; then back-to-back throughput;
3. **power**: the board's INA226 monitors on the PL power rails (I2C0, mux 0x75
   channel 1, 0x40-0x47; shunts from the Linux device tree: 2 mOhm at 0x40, 5 mOhm
   elsewhere) read in three alternating 10 s IDLE / RUN windows. Engine power =
   RUN - IDLE; energy per evaluation = that power / evaluations per second.

Output goes to the UART and to a buffer in DDR (0x40000000) that `run_app.tcl`
saves as `zcu102_ps_run.log`, so no serial console is needed.

On the lab PC, from `hardware/vivado/zcu102`, with Vivado and Vitis in PATH:

| step | command | time |
|---|---|---|
| 0 | `./run_board.sh psdry` | minutes: board preset, I2C0, PL clock, address |
| 1 | `./run_board.sh ps` | 1-2 h: bitstream and `heston_zcu102_ps.xsa` |
| 2 | `./run_board.sh app` | minutes: platform and `heston_app.elf` |
| 3 | `./run_board.sh run` | about 2 min: program, run, save the log |

Files: `main.c` (the program), `generated/zu_cases.h` (from `gen_cases.py`, which
reads the JTAG runs' vectors in `hardware/gen/build`), `pc_test.h` (register and
monitor stand-ins: `gcc -DZU_PC_TEST -DPOWER_WINDOW_MS=200 -Igenerated main.c`,
also run by `verify_all.sh`), `build_vitis.py`, `run_app.tcl`.
