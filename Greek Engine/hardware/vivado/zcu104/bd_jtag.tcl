# ============================================================================
# ZCU104 (Zynq UltraScale+ xczu7ev) bring-up of the 64-bit engine, no software.
#
#   cd "Greek Engine/hardware/vivado/zcu104"
#   vivado -mode batch -nojournal -log bd_jtag.log -source bd_jtag.tcl [-tclargs <clk_mhz>]
#   (or run_board.bat build [clk_mhz] from a Windows Command Prompt)
#
# Same structure as zedboard/bd_jtag.tcl: jtag_axi master -> smartconnect ->
# engine (AXI4-Lite), clocked from a clock wizard. No Zynq PS, DDR, boot image
# or Vitis: Vivado drives AXI transactions down the JTAG cable, so the only
# thing under test is the engine. Then run_jtag.tcl / run_sweep.tcl.
#
# The engine is heston_aad_zu: 64-bit words (32 fraction bits), 32 shared
# multipliers, pipelined CORDIC, setup and finish on chip (19 input words,
# 10 outputs, 1,593 cycles per evaluation). It has never been through Vivado
# before this script, so its clock is unknown: build first at the default
# 100 MHz, read the WNS, then rebuild at the clock the slack allows.
#
# Clock: the board's 300 MHz differential system clock (Si5341, board
# interface clk_300mhz), connected by Vivado's board automation, so no pin is
# typed by hand.
# ============================================================================
set part       xczu7ev-ffvc1156-2-e
set board_part xilinx.com:zcu104:part0:1.1
set clk_mhz  [expr {[llength $argv] > 0 ? [lindex $argv 0] : 100}]
set core     heston_aad_zu
set wrapper  ${core}_lite
set bd_name  heston_jtag
set proj     proj/heston_jtag

set here [file dirname [file normalize [info script]]]
set vdir [file normalize "$here/../../verilog/gen"]

create_project -force heston_jtag $proj -part $part
set_property board_part $board_part [current_project]
# File arguments go through [list ...]: this repository lives under "Greek Engine".
read_verilog [list "$vdir/$wrapper.v"]
read_verilog [list "$vdir/$core.v"]
update_compile_order -fileset sources_1

create_bd_design $bd_name

set clkw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
set_property -dict [list \
  CONFIG.CLK_IN1_BOARD_INTERFACE {clk_300mhz} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.3f $clk_mhz] \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {false} \
] $clkw
apply_board_connection -board_interface "clk_300mhz" -ip_intf "clk_wiz_0/CLK_IN1_D" -diagram $bd_name

set jt [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0]
set_property -dict [list CONFIG.PROTOCOL {2}] $jt      ;# 2 = AXI4-Lite

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc

set eng [create_bd_cell -type module -reference $wrapper engine]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
               [get_bd_pins rst_0/slowest_sync_clk] \
               [get_bd_pins jtag_axi_0/aclk] \
               [get_bd_pins smartconnect_0/aclk] \
               [get_bd_pins engine/aclk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins rst_0/dcm_locked]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
               [get_bd_pins jtag_axi_0/aresetn] \
               [get_bd_pins smartconnect_0/aresetn] \
               [get_bd_pins engine/aresetn]
# no external reset button needed: hold ext_reset_in released
set cst [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const_1]
set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $cst
connect_bd_net [get_bd_pins const_1/dout] [get_bd_pins rst_0/ext_reset_in]

connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins engine/s_axi]

assign_bd_address
validate_bd_design
save_bd_design

set base [get_property OFFSET [lindex [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data]] 0]]
if {$base eq ""} { puts "ERROR: could not read the engine base address"; exit 1 }
puts "RESULT: engine base address = $base"
set fp [open "$here/base_addr.txt" w]; puts $fp $base; close $fp

add_files -norecurse [list [make_wrapper -files [get_files $bd_name.bd] -top]]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "ERROR: implementation did not finish; see $proj/heston_jtag.runs/impl_1/runme.log"
  exit 1
}
open_run impl_1
report_utilization    -file "$here/util_jtag.rpt"
report_timing_summary -file "$here/timing_jtag.rpt"
report_power          -file "$here/power_jtag.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set period [expr {1000.0 / $clk_mhz}]
puts "RESULT: WNS = $wns ns at ${clk_mhz} MHz (Fmax about [format %.1f [expr {1000.0 / ($period - $wns)}]] MHz)"
if {$wns < 0} {
  puts "WARNING: timing FAILED. Board results from this bitstream can be wrong in ways"
  puts "         that look like datapath bugs. Rebuild with a lower clock: -tclargs <mhz>"
}
puts "RESULT: bitstream at $proj/heston_jtag.runs/impl_1/${bd_name}_wrapper.bit"
