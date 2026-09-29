# ============================================================================
# Program the ZedBoard and run one evaluation over JTAG, checking every output
# against the emulator. No PS software involved.
#
#   cd "Greek Engine/hardware/vivado/zedboard"
#   PATH="../win:$PATH" vivado -mode batch -nojournal -log run_jtag.log \
#        -source run_jtag.tcl -tclargs [<base_addr_hex>] [<bitfile>]
#
# <base_addr_hex> defaults to what bd_jtag.tcl wrote to base_addr.txt (the
# 2025.2 build assigned 0x00000000). If the reads all come back 0xffffffff or
# the script reports a decode error, this is the first thing to check.
#
# Prerequisites: board powered, JTAG (USB) connected, JP7-JP11 set to JTAG
# boot, and bd_jtag.tcl already run to produce the bitstream.
#
# Also runs from the Vivado GUI Tcl console (cd to this folder, then
# `source run_jtag.tcl`), reusing a Hardware Manager connection if one is open.
# ============================================================================
set here [file dirname [file normalize [info script]]]
# Stop with a Tcl error, not `exit`: from the GUI console `exit` would quit
# Vivado itself. In batch mode an uncaught error ends the run just the same.
proc stop {} { error "run_jtag.tcl stopped; see the messages above" }
# In the GUI, argv is one global shared by everything sourced in the session,
# so a leftover value (bd_jtag.tcl's clock, 70) was once taken as the base
# address: 0x46. Only a hex literal is accepted as an address.
if {![info exists argv]} { set argv {} }
if {[regexp {^0[xX][0-9a-fA-F]+$} [lindex $argv 0]]} {
  set base [lindex $argv 0]
  puts "INFO: base address from argv"
} elseif {[file exists "$here/base_addr.txt"]} {
  set fp [open "$here/base_addr.txt"]; set base [string trim [read $fp]]; close $fp
  puts "INFO: base address from base_addr.txt"
} else {
  puts "ERROR: no base address given and no base_addr.txt; run bd_jtag.tcl first"; stop
}
if {$base % 4096 != 0} {
  puts "ERROR: base address $base is not 4 KB aligned; the engine's register map is 4 KB"; stop
}
set bit  [expr {[llength $argv] > 1 && [file exists [lindex $argv 1]] ? [lindex $argv 1] \
                : "$here/proj/heston_jtag/heston_jtag.runs/impl_1/heston_jtag_wrapper.bit"}]
set vec  "$here/../../gen/build/heston_aad_z7h_lite_vector.tcl"

foreach f [list $bit $vec] {
  if {![file exists $f]} { puts "ERROR: missing $f"; stop }
}
source $vec
puts "INFO: base 0x[format %08x $base] ; [llength $VEC_WRITES] input words ; [llength $VEC_EXPECT] outputs"

proc axi_w {off data} {
  global base axi
  create_hw_axi_txn -quiet _w $axi -address [format %08x [expr {$base + $off}]] \
                    -data [format %08x $data] -type write -len 1
  run_hw_axi -quiet _w
  delete_hw_axi_txn [get_hw_axi_txns _w]
}
proc axi_r {off} {
  global base axi
  create_hw_axi_txn -quiet _r $axi -address [format %08x [expr {$base + $off}]] -type read -len 1
  run_hw_axi -quiet _r
  set v [get_property DATA [get_hw_axi_txns _r]]
  delete_hw_axi_txn [get_hw_axi_txns _r]
  # -quiet hides a failed transaction; an empty DATA is how it shows up
  if {$v eq ""} {
    puts "ERROR: AXI read at 0x[format %08x [expr {$base + $off}]] returned no data"
    puts "       (bus error: wrong base address, or the engine is not responding)"
    stop
  }
  # braced expr cannot splice "0x" onto $v (a parse error, not a bad value)
  return [scan $v %x]
}

# ---- connect and program ---------------------------------------------------
open_hw_manager
if {[llength [get_hw_servers -quiet]] == 0} { connect_hw_server -quiet }
if {[llength [get_hw_devices -quiet]] == 0} { open_hw_target }
# The Zynq JTAG chain is arm_dap_0 first, then the FPGA (xc7z020_1): select
# the FPGA by name, not by position.
set devs [get_hw_devices -quiet xc7z*]
if {[llength $devs] == 0} {
  puts "ERROR: no xc7z FPGA on the JTAG chain; found: [get_hw_devices -quiet]"
  stop
}
set dev [lindex $devs 0]
current_hw_device $dev
puts "INFO: device [get_property PART $dev]"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev

set axis [get_hw_axis -quiet]
if {[llength $axis] == 0} {
  puts "ERROR: no JTAG-to-AXI master found after programming."
  puts "       The bitstream in $bit does not contain jtag_axi, or programming failed."
  stop
}
set axi [lindex $axis 0]
reset_hw_axi -quiet $axi
# a run that stopped mid-transaction leaves _w/_r behind in a GUI session;
# create_hw_axi_txn -quiet would then silently reuse the stale one
set old [get_hw_axi_txns -quiet]
if {[llength $old]} { delete_hw_axi_txn -quiet $old }

# ---- drive one evaluation --------------------------------------------------
set errors 0
foreach w $VEC_WRITES { axi_w [lindex $w 0] [lindex $w 1] }

# readback check on the first word, to catch a wrong base address early
set first [lindex $VEC_WRITES 0]
set rb [axi_r [lindex $first 0]]
if {$rb != [lindex $first 1]} {
  puts "FAIL: readback 0x[format %08x $rb] != written 0x[format %08x [lindex $first 1]]"
  puts "      Wrong base address, or the design is not responding. Stopping."
  stop
}
puts "INFO: readback ok, wrote [llength $VEC_WRITES] words"

if {[expr {[axi_r $VEC_STAT] & 1}] != 0} { puts "FAIL: done set before start"; incr errors }
axi_w $VEC_CTRL 1

set st 0
for {set i 0} {$i < 1000} {incr i} {
  set st [axi_r $VEC_STAT]
  if {$st & 1} break
}
if {!($st & 1)} { puts "FAIL: done never asserted (STAT=0x[format %08x $st])"; stop }
puts "INFO: done after [expr {$i + 1}] status polls"
if {$st & 2} { puts "FAIL: range_err set for an in-domain case"; incr errors }

# ---- read back and compare -------------------------------------------------
set sign [expr {1 << ($VEC_WL - 1)}]
set mod  [expr {1 << $VEC_WL}]
foreach e $VEC_EXPECT {
  set name [lindex $e 0]
  set off  [lindex $e 1]
  set want [lindex $e 2]
  set lo [axi_r $off]
  set hi [axi_r [expr {$off + 4}]]
  set raw [expr {(($hi & ((1 << ($VEC_WL - 32)) - 1)) << 32) | $lo}]
  if {$raw >= $sign} { set raw [expr {$raw - $mod}] }
  if {$raw != $want} {
    puts [format "FAIL %-12s got %d want %d (diff %d)" $name $raw $want [expr {$raw - $want}]]
    incr errors
  } else {
    puts [format "  ok %-12s %d  (%.10f)" $name $raw [expr {double($raw) / (1 << $VEC_FL)}]]
  }
}

if {$errors == 0} {
  puts "PASS: ZedBoard outputs bit-exact vs the emulator, [llength $VEC_EXPECT] outputs"
} else {
  puts "FAIL: $errors mismatch(es)"
}
close_hw_manager
