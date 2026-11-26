# ============================================================================
# ZCU102 processor design: the Cortex-A53 drives the 64-bit engine over AXI.
#
#   cd hardware/vivado/zcu102
#   vivado -mode batch -nojournal -log bd_ps.log -source bd_ps.tcl [-tclargs dry]
#   (or ./run_board.sh ps | psdry)
#
# Zynq UltraScale+ PS with the ZCU102 board preset (DDR, UART, I2C) ->
# M_AXI_HPM0_FPD -> smartconnect -> heston_aad_zu_lite, all at the PS's PL
# clock 0 (100 MHz, the clock the JTAG design met with +1.6 ns). The ARM
# program (hardware/sw/zcu102) times the whole evaluation over the bus and
# reads the board's PL power monitors over I2C0.
# Writes heston_zcu102_ps.xsa (with the bitstream) for Vitis, base_addr_ps.txt,
# and util_ps.rpt / timing_ps.rpt / power_ps.rpt. "dry" stops after the block
# design validates.
# ============================================================================
set dry      [expr {[lindex $argv 0] eq "dry"}]
set clk_mhz  100
set core     heston_aad_zu
set wrapper  ${core}_lite
set bd_name  heston_ps
set proj     proj/heston_ps

set here [file dirname [file normalize [info script]]]
set vdir [file normalize "$here/../../verilog/gen"]

set board_part [lindex [get_board_parts -quiet -latest_file_version "*:zcu102:*"] 0]
if {$board_part eq ""} { puts "ERROR: no ZCU102 board files in this Vivado install"; exit 1 }
set part [get_property PART_NAME [get_board_parts $board_part]]
puts "RESULT: board $board_part, part $part"

create_project -force heston_ps $proj -part $part
set_property board_part $board_part [current_project]
read_verilog [list "$vdir/$wrapper.v"]
read_verilog [list "$vdir/$core.v"]
update_compile_order -fileset sources_1

create_bd_design $bd_name

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# one 32-bit master port (HPM0_FPD) and one PL clock
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clk_mhz \
] $ps
foreach {what prop} {I2C0 CONFIG.PSU__I2C0__PERIPHERAL__ENABLE UART0 CONFIG.PSU__UART0__PERIPHERAL__ENABLE \
                     DDR CONFIG.PSU__DDRC__ENABLE} {
  set v [get_property $prop $ps]
  puts "RESULT: PS $what enabled = $v"
  if {$v != 1} { puts "ERROR: the board preset did not enable $what, which the program needs"; exit 1 }
}
set act [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps]
puts "RESULT: PL clock 0 requested $clk_mhz MHz, actual $act MHz"

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_0]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set eng [create_bd_cell -type module -reference $wrapper engine]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
               [get_bd_pins rst_0/slowest_sync_clk] \
               [get_bd_pins smartconnect_0/aclk] \
               [get_bd_pins engine/aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
               [get_bd_pins smartconnect_0/aresetn] \
               [get_bd_pins engine/aresetn]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins engine/s_axi]

assign_bd_address
validate_bd_design
save_bd_design

set base [get_property OFFSET [lindex [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] 0]]
if {$base eq ""} { puts "ERROR: could not read the engine base address"; exit 1 }
puts "RESULT: engine base address = $base"
set fp [open "$here/base_addr_ps.txt" w]; puts $fp $base; close $fp
if {$dry} {
  puts "RESULT: dry run: block design valid, stopping before synthesis"
  exit 0
}

add_files -norecurse [list [make_wrapper -files [get_files $bd_name.bd] -top]]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "ERROR: implementation did not finish; see $proj/heston_ps.runs/impl_1/runme.log"
  exit 1
}
open_run impl_1
report_utilization    -file "$here/util_ps.rpt"
report_timing_summary -file "$here/timing_ps.rpt"
report_power          -file "$here/power_ps.rpt"
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT: WNS = $wns ns at ${clk_mhz} MHz"
if {$wns < 0} {
  puts "WARNING: timing FAILED. Board results from this bitstream can be wrong in ways"
  puts "         that look like datapath bugs; do not run it."
}
write_hw_platform -fixed -include_bit -force -file "$here/heston_zcu102_ps.xsa"
puts "RESULT: platform at $here/heston_zcu102_ps.xsa"
