# ============================================================================
# Phase 1 bring-up: prove the datapath on real silicon with NO software.
#
#   cd "Greek Engine/hardware/vivado/zedboard"
#   PATH="../win:$PATH" vivado -mode batch -nojournal -log bd_jtag.log \
#        -source bd_jtag.tcl
#
# Block design: jtag_axi master -> smartconnect -> engine (AXI4-Lite).
# No Zynq PS, no DDR, no MIO, no board file, no Vitis, no boot image. Vivado
# drives AXI transactions down the JTAG cable from its own Tcl console, so the
# only thing under test is the engine itself. Use run_jtag.tcl afterwards to
# program the board and replay a test vector.
#
# Phase 2 (bd_lite.tcl) puts the same engine behind the PS for a
# self-contained system; do that once this passes.
# ============================================================================
set part     xc7z020clg484-1
set clk_mhz  100
set core     heston_aad_z7h
set wrapper  ${core}_lite
set bd_name  heston_jtag
set proj     proj/heston_jtag

set here [file dirname [file normalize [info script]]]
set vdir [file normalize "$here/../../verilog/gen"]

create_project -force heston_jtag $proj -part $part
read_verilog [list "$vdir/$wrapper.v"]
read_verilog [list "$vdir/$core.v"]
update_compile_order -fileset sources_1

create_bd_design $bd_name

# A free-running clock. With no PS there is no FCLK, so synthesise one from
# the on-board 100 MHz oscillator via an MMCM; see jtag.xdc for the pin.
set clkw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0]
set_property -dict [list \
  CONFIG.PRIM_IN_FREQ {100.000} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.3f $clk_mhz] \
  CONFIG.USE_LOCKED {true} \
  CONFIG.USE_RESET {false} \
  CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
] $clkw
make_bd_pins_external -name clk_in100 [get_bd_pins clk_wiz_0/clk_in1]

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

set base [get_property OFFSET [get_bd_addr_segs -of_objects [get_bd_intf_pins engine/s_axi]]]
puts "RESULT: engine base address = $base"

add_files -fileset constrs_1 -norecurse "$here/jtag.xdc"

make_wrapper -files [get_files "$proj/heston_jtag.srcs/sources_1/bd/$bd_name/$bd_name.bd"] -top
add_files -norecurse "$proj/heston_jtag.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v"
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
puts "RESULT: WNS = [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] ns at ${clk_mhz} MHz"
puts "RESULT: bitstream at $proj/heston_jtag.runs/impl_1/${bd_name}_wrapper.bit"
