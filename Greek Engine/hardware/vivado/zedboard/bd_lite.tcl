# ============================================================================
# ZedBoard block design + bitstream for the AXI4-Lite Heston AAD engine.
#
#   cd "Greek Engine/hardware/vivado/zedboard"
#   PATH="../win:$PATH" vivado -mode batch -nojournal -log bd_lite.log \
#        -source bd_lite.tcl [-tclargs <clk_mhz>]
#
# Produces:
#   proj/heston_zed.runs/impl_1/heston_bd_wrapper.bit
#   heston_zed.xsa                 (hardware handoff for Vitis / PYNQ)
#
# The design is deliberately minimal: PS -> AXI4-Lite -> engine. No DMA, no
# interrupts, no external pins. The engine is driven by register writes from
# the ARM cores, which is enough to validate the datapath on real silicon; the
# AXI4-Stream wrapper (1624 bits wide) is what a throughput-oriented design
# would use, but nothing on a Zynq-7000 can carry a stream that wide.
#
# PREREQUISITE: the ZedBoard board file. Vivado 2025.2 ships none, so install
# it via Tools -> Vivado Store -> Boards -> ZedBoard (or drop the Digilent
# board_files tree into <install>/Vivado/data/boards/board_files). Without it
# the PS would need its DDR3 part, MIO map and clocks entered by hand, which
# is error-prone; this script refuses rather than guessing.
# ============================================================================
set part       xc7z020clg484-1
# 70 MHz, not 100: the routed engine fails 100 MHz by 2.639 ns (Fmax ~79 MHz);
# see bd_jtag.tcl. The PS derives FCLK0 by integer division, so the frequency
# it actually delivers is printed below and is the one timing is closed at.
set clk_mhz    [expr {[llength $argv] > 0 ? [lindex $argv 0] : 70}]
set core       heston_aad_z7h
set wrapper    ${core}_lite
set bd_name    heston_bd
set proj       proj/heston_zed

set here [file dirname [file normalize [info script]]]
set vdir [file normalize "$here/../../verilog/gen"]

# ---- board file check, with a message that says what to do -----------------
set bp [get_board_parts -quiet *zedboard*]
if {[llength $bp] == 0} {
  puts "ERROR: no ZedBoard board part is installed."
  puts "       Install it: Vivado GUI -> Tools -> Vivado Store -> Boards -> ZedBoard,"
  puts "       then re-run this script. Checked: [get_property BOARD_PART_REPO_PATHS [current_project -quiet]]"
  exit 1
}
set board_part [lindex [lsort -decreasing $bp] 0]
puts "INFO: using board part $board_part"

create_project -force heston_zed $proj -part $part
set_property board_part $board_part [current_project]

read_verilog [list "$vdir/$wrapper.v"]
read_verilog [list "$vdir/$core.v"]
update_compile_order -fileset sources_1

# ---- block design ----------------------------------------------------------
create_bd_design $bd_name

# Zynq PS, configured from the board preset (DDR3, MIO, clocks)
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $clk_mhz \
  CONFIG.PCW_EN_CLK0_PORT {1} \
] $ps
puts "INFO: FCLK0 requested ${clk_mhz} MHz, actual [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps] MHz"

# Our engine as an RTL module. Vivado infers the AXI4-Lite slave from the
# s_axi_* port names and associates it with aclk/aresetn.
set eng [create_bd_cell -type module -reference $wrapper engine]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc

# clocks and resets
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
               [get_bd_pins rst_ps/slowest_sync_clk] \
               [get_bd_pins ps7/M_AXI_GP0_ACLK] \
               [get_bd_pins smartconnect_0/aclk] \
               [get_bd_pins engine/aclk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_ps/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn] \
               [get_bd_pins smartconnect_0/aresetn] \
               [get_bd_pins engine/aresetn]

# data path: PS master -> smartconnect -> engine slave
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins engine/s_axi]

assign_bd_address
validate_bd_design
save_bd_design

# OFFSET lives on the segment in the master's address space, not on s_axi
set base [get_property OFFSET [lindex [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] 0]]
puts "RESULT: engine base address = $base"
set fp [open "$here/base_addr_ps.txt" w]; puts $fp $base; close $fp

# ---- implement -------------------------------------------------------------
# [list ...]: a bare path string is split at the space in "Greek Engine"
add_files -norecurse [list [make_wrapper -files [get_files $bd_name.bd] -top]]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "ERROR: implementation did not finish; see $proj/heston_zed.runs/impl_1/runme.log"
  exit 1
}

open_run impl_1
report_utilization    -file "$here/util_zed.rpt"
report_timing_summary -file "$here/timing_zed.rpt"
report_power          -file "$here/power_zed.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT: WNS = $wns ns at ${clk_mhz} MHz"
if {$wns < 0} { puts "WARNING: timing FAILED; rebuild with a lower clock (-tclargs 60)" }

write_hw_platform -fixed -include_bit -force -file "$here/heston_zed.xsa"
puts "RESULT: bitstream + XSA written"
