# ZCU102: the 64-bit engine on a Zynq UltraScale+ (xczu9eg)

The same design as `../zcu104` (`heston_aad_zu` behind an AXI4-Lite register
file, driven over JTAG; no PS software), built for the ZCU102. `bd_jtag.tcl`
runs `../zcu104/bd_jtag.tcl` with the ZCU102's board file, which supplies the
part (`xczu9eg-ffvb1156-2-e`) and the clock (`user_si570_sysclk`, 300 MHz).
The ZU9EG needs a licensed Vivado edition, so this is built on the lab machine.

On Linux, in this folder, after `source <install>/Vivado/<version>/settings64.sh`:

| step | command | what it does |
|---|---|---|
| 0 | `./run_board.sh dry` | block design only (minutes): board files, part, clock, licence |
| 1 | `./run_board.sh build` | bitstream at 100 MHz; prints WNS and the implied Fmax |
| 2 | `./run_board.sh test` | program the board, one case, all 10 outputs bit-exact |
| 3 | `./run_board.sh sweep` | 50 cases back to back (2 fixed + 48 random, seed 2026) |
| 4 | `./run_board.sh nifty` | 50 real NIFTY inputs back to back |

Board setup: power, the JTAG micro-USB port, and the boot-mode switch SW6 set
to JTAG (ZCU102 user guide, UG1182). Close the Vivado GUI's Hardware Manager
before step 2, or disconnect it there, so the batch run can open the cable.

`tclsh mock/drive.tcl` tests the run scripts against a model of Vivado's
hardware manager. `make_bundle.py` packs everything the lab machine needs
(RTL, these scripts, the shared ones they source, the test vectors) into one
zip with a space-free top folder.
