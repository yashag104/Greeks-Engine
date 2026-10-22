# ZCU104: the 64-bit engine on a Zynq UltraScale+ (xczu7ev)

The 64-bit design (`heston_aad_zu`: 64-bit words, 32 shared multipliers, setup and
finish on chip, 1,593 cycles per evaluation) behind an AXI4-Lite register file,
driven over JTAG exactly as on the ZedBoard. No PS software, no SD card.

From a Windows Command Prompt in this folder:

| step | command | what it does |
|---|---|---|
| 1 | `run_board.bat build` | bitstream at 100 MHz; prints WNS and the implied Fmax |
| 1b | `run_board.bat build <mhz>` | rebuild at the clock the slack allows |
| 2 | `run_board.bat test` | program the board, one case, all 10 outputs bit-exact |
| 3 | `run_board.bat sweep` | 50 cases back to back (2 fixed + 48 random, seed 2026) |
| 4 | `run_board.bat nifty` | 50 real NIFTY inputs back to back |

Board setup: power, the JTAG micro-USB port, and the boot-mode switch SW6 set to
JTAG (see the ZCU104 user guide, UG1267). The clock comes from the board's 300 MHz
system clock via Vivado's board file, so no pin is typed by hand.

Vectors: `hardware/gen/board_vectors.py ... --name heston_aad_zu` (single and
`--sweep 48`), and `--cases-csv validation/hedging/results/board_cases.csv` for the
NIFTY run. The checking logic is shared with the ZedBoard (`../zedboard/run_jtag.tcl`);
`tclsh mock/drive.tcl` tests it against a model of Vivado's hardware manager.
