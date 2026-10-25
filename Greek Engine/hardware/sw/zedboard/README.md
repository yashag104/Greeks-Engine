# End-to-end on the ZedBoard: ARM host steps + FPGA loop

`main.c` runs the whole evaluation on the board: the per-evaluation constants on the
ARM (`hc_setup`), 51 words to the engine over AXI4-Lite, the 128-term loop on the
FPGA, 18 words back, and the final step on the ARM (`hc_finish`). It checks all 10
outputs of 100 cases (50 board-sweep, 50 real NIFTY days) bit-exact against the
emulator and times each stage with the Cortex-A9 global timer, which gives the
end-to-end latency including the bus transfers.

`generated/` comes from `hardware/gen/cgen.py`: the host steps as C, bit-exact with
`host.py` (checked on 300 inputs with native 128-bit integers and with the portable
64x64->128 multiply the 32-bit ARM uses), the register map, and the test cases
(`cgen.py --cases validation/hedging/results/board_cases.csv`).

Steps (Windows, from the listed folder):

1. `hardware/vivado/zedboard`: `run_board.bat ps`  -> bitstream + `heston_zed.xsa`
2. here: `D:\2025.2\Vitis\bin\vitis.bat -s build_vitis.py`  -> `heston_app.elf`
3. open a serial terminal on the board's USB-UART (115200 8N1), then
   here: `D:\2025.2\Vitis\bin\xsdb.bat run_app.tcl`

After the tests and the timing table it runs three power windows of 30 s each:
`IDLE` (engine idle) then `RUN` (evaluations back to back, the engine busy almost all
the time), announced on the UART. Read the board's supply power with a meter in each
window; engine power = RUN - IDLE. Set the length with `-DPOWER_WINDOW_S=<s>`.

Without a board: `gcc -O2 -std=gnu99 -DHC_PC_TEST -Igenerated main.c generated/heston_host.c -o pc_test && ./pc_test`
runs the same program against a model of the engine's registers (`pc_test.h`);
`verify_all.sh` does this on every run.
