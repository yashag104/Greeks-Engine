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
# run_sweep.tcl sets ::JTAG_VEC to the sweep file; it is unset at once so a
# later plain run in the same GUI session gets the single vector again.
if {[info exists ::JTAG_VEC]} {
  set vec $::JTAG_VEC; unset ::JTAG_VEC
} else {
  set vec "$here/../../gen/build/heston_aad_z7h_lite_vector.tcl"
}

foreach f [list $bit $vec] {
  if {![file exists $f]} { puts "ERROR: missing $f"; stop }
}
# clear what an earlier run in this GUI session may have left defined
foreach v {VEC_CASES VEC_WRITES VEC_EXPECT} { if {[info exists $v]} { unset $v } }
source $vec
# a single-vector file is a sweep of one
if {![info exists VEC_CASES]} {
  set VEC_CASES [list [list "single vector" $VEC_WRITES $VEC_EXPECT]]
}
set VEC_WRITES [lindex $VEC_CASES 0 1]
set VEC_EXPECT [lindex $VEC_CASES 0 2]
puts "INFO: [llength $VEC_CASES] case(s) from [file tail $vec]"
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
  # braced expr cannot splice "0x" onto $v (a parse error, not a bad value).
  # scan %x yields a SIGNED 32-bit int: mask it, or a low word with bit 31 set
  # sign-extends over the high word (first board run: 4 outputs off by k*2^32).
  return [expr {[scan $v %x] & 0xffffffff}]
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

# ---- drive each case ------------------------------------------------------
# Programming happens once; cases run back to back with no reset in between,
# so a pass also shows the engine carries nothing over from the previous case.
set sign [expr {1 << ($VEC_WL - 1)}]
set mod  [expr {1 << $VEC_WL}]
set ncase [llength $VEC_CASES]
set bad_cases 0
set t0 [clock milliseconds]
for {set c 0} {$c < $ncase} {incr c} {
  lassign [lindex $VEC_CASES $c] label writes expect
  puts "CASE [expr {$c + 1}]/$ncase $label"
  set errors 0
  foreach w $writes { axi_w [lindex $w 0] [lindex $w 1] }

  # readback of the first word catches a wrong base address or dead design
  set first [lindex $writes 0]
  set rb [axi_r [lindex $first 0]]
  if {$rb != [lindex $first 1]} {
    puts "FAIL: readback 0x[format %08x $rb] != written 0x[format %08x [lindex $first 1]]"
    puts "      Wrong base address, or the design is not responding. Stopping."
    stop
  }
  # done stays set from the previous case until the next start, so this
  # check only means something straight after programming
  if {$c == 0 && ([axi_r $VEC_STAT] & 1) != 0} { puts "FAIL: done set before start"; incr errors }
  axi_w $VEC_CTRL 1

  set st 0
  for {set i 0} {$i < 1000} {incr i} {
    set st [axi_r $VEC_STAT]
    if {$st & 1} break
  }
  if {!($st & 1)} { puts "FAIL: done never asserted (STAT=0x[format %08x $st])"; stop }
  if {$st & 2} { puts "FAIL: range_err set for an in-domain case"; incr errors }

  foreach e $expect {
    lassign $e name off want
    set lo [axi_r $off]
    set hi [axi_r [expr {$off + 4}]]
    set raw [expr {(($hi & ((1 << ($VEC_WL - 32)) - 1)) << 32) | $lo}]
    if {$raw >= $sign} { set raw [expr {$raw - $mod}] }
    if {$raw != $want} {
      puts [format "FAIL %-12s got %ld want %ld (diff %ld)" $name $raw $want [expr {$raw - $want}]]
      incr errors
    } else {
      puts [format "  ok %-12s %ld  (%.10f)" $name $raw [expr {double($raw) / (1 << $VEC_FL)}]]
    }
  }
  if {$errors} { incr bad_cases; puts "CASE [expr {$c + 1}]: FAIL ($errors)" } else { puts "CASE [expr {$c + 1}]: ok" }
}
set secs [expr {([clock milliseconds] - $t0) / 1000.0}]

if {$bad_cases == 0} {
  puts [format "PASS: ZedBoard outputs bit-exact vs the emulator, %d case(s) x %d outputs (%.1f s)" \
        $ncase [llength $VEC_EXPECT] $secs]
} else {
  puts "FAIL: $bad_cases of $ncase case(s) had mismatches"
}
close_hw_manager
