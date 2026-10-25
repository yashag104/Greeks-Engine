# ============================================================================
# ZCU102 (Zynq UltraScale+ xczu9eg) bring-up of the 64-bit engine, no software.
#
#   cd hardware/vivado/zcu102
#   vivado -mode batch -nojournal -log bd_jtag.log -source bd_jtag.tcl [-tclargs <clk_mhz> | dry]
#   (or ./run_board.sh build [clk_mhz])
#
# The same design as ../zcu104/bd_jtag.tcl (jtag_axi -> smartconnect -> engine,
# no PS), which this file runs with the ZCU102's board file: the part
# (xczu9eg-ffvb1156-2-e) and the 300 MHz user_si570_sysclk input come from it.
# The ZU9EG needs a licensed Vivado edition (not the free Standard edition).
# "dry" stops after the block design validates (a minute, not a full build).
# ============================================================================
set ::BD_BOARD zcu102
set ::BD_DIR [file dirname [file normalize [info script]]]
source [file join $::BD_DIR ../zcu104/bd_jtag.tcl]
