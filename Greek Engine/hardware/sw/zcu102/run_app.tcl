# ============================================================================
# Run the end-to-end program on the ZCU102 over JTAG (no SD card) and save its
# output to zcu102_ps_run.log, no serial console needed:
#   xsdb run_app.tcl            (from this folder; or ../../vivado/zcu102/run_board.sh run)
# Resets the board, programs the bitstream of bd_ps.tcl, initialises the PS
# with psu_init from the XSA, downloads heston_app.elf and runs it. The program
# runs from the on-chip memory (OCM) and writes its output into a buffer there as
# well as to the UART. The buffer is polled through the debug port while the
# processor runs (no halt, so the timing and power windows are undisturbed) and
# saved when the program marks it done. Boot-mode switch SW6: JTAG.
# psu_init also initialises the DDR; on the lab board that step reports a mask
# poll timeout at 0xFD080030 (DDR training), which the program does not need.
# ============================================================================
set here [file dirname [file normalize [info script]]]
set hw   [file normalize "$here/../../vivado/zcu102"]
set xsa  "$hw/heston_zcu102_ps.xsa"
set bit  "$hw/proj/heston_ps/heston_ps.runs/impl_1/heston_ps_wrapper.bit"
set ws   [file normalize "$here/../../../vitis_ws_zcu102"]
set elf  "$ws/heston_app/build/heston_app.elf"
# a program built elsewhere (e.g. with another Vitis version) and copied here takes precedence
if {[file exists "$here/heston_app.elf"]} { set elf "$here/heston_app.elf" }
puts "INFO: program $elf"
set init "$here/xsa_x/psu_init.tcl"
set log  "$here/zcu102_ps_run.log"
set LOG_ADDR 0xFFFC0000      ;# the first 16 KB of OCM (main.c, build_vitis.py)
set first_wait_s 60          ;# 3 x (10 s idle + 10 s run) of power windows take about 61 s
foreach f [list $xsa $bit $elf $init] {
  if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

connect
# The A53s are reachable only through the DAP's AXI/APB ports. If the PS bus is hung
# (e.g. a previous program stalled on memory), the DAP reports an AXI AP error and no
# APU appears: only a power cycle clears that.
set apu ""
for {set i 0} {$i < 10 && $apu eq ""} {incr i} {
  if {[catch {targets -set -nocase -filter {name =~ "APU*"}}]} { after 1000 } else { set apu ok }
}
if {$apu eq ""} {
  puts "ERROR: the processor (APU) is not reachable over JTAG; the debugger sees:"
  puts [targets]
  puts "ERROR: switch the ZCU102 off and on, check SW6 = JTAG (all four ON), then run again"
  exit 1
}
rst -system
after 3000
targets -set -nocase -filter {name =~ "PSU*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "APU*"}
loadhw -hw $xsa -mem-ranges [list {0x80000000 0xbfffffff} {0x400000000 0x5ffffffff} {0x1000000000 0x7fffffffff}] -regs
configparams force-mem-access 1
source $init
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $elf
mwr $LOG_ADDR 0
configparams force-mem-access 0
con
puts "INFO: running; output also on the UART (115200 8N1). Waiting $first_wait_s s"
after [expr {$first_wait_s * 1000}]

# Poll the marker through the APU's memory access port, without halting the A53.
# The program flushes the buffer from its cache when it finishes, so DONE and the
# text become visible together.
targets -set -nocase -filter {name =~ "APU*"}
proc rd {addr} { return [mrd -force -value $addr] }
set done 0
for {set i 0} {$i < 36} {incr i} {
  if {[catch {rd $LOG_ADDR} magic]} { puts "INFO: read failed ($magic); retrying"; after 5000; continue }
  if {$magic == 0x444f4e45} { set done 1; break }
  if {$i % 4 == 0} { puts "INFO: not finished yet (marker 0x[format %08x $magic]); polling every 5 s" }
  after 5000
}
if {!$done} {
  # last resort: halt the A53 and read through it
  targets -set -nocase -filter {name =~ "*A53*#0"}
  if {[catch {stop} err]} { puts "INFO: could not halt the A53: $err" }
  targets -set -nocase -filter {name =~ "APU*"}
}
set len [rd [expr {$LOG_ADDR + 4}]]
if {$len > 0 && $len < 16384} {
  mrd -force -bin -file $log [expr {$LOG_ADDR + 8}] [expr {($len + 3) / 4}]
  set fp [open $log rb]; set text [string range [read $fp] 0 [expr {$len - 1}]]; close $fp
  set fp [open $log wb]; puts -nonewline $fp $text; close $fp
  puts $text
  puts "RESULT: [expr {$done ? "finished" : "NOT finished"}]; output saved to $log"
} else {
  puts "ERROR: no output in the log buffer (length $len); check the UART"
}
