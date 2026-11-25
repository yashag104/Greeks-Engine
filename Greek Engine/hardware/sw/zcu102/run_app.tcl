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
# The PS is initialised from the XSA's psu_init.tcl without its DDR steps: on the
# lab board the preset's DDR training fails (a mask poll timeout at 0xFD080030, or
# a poll loop of 10^8 JTAG reads that never ends), and the program does not use DDR.
# ============================================================================
set here [file dirname [file normalize [info script]]]
set hw   [file normalize "$here/../../vivado/zcu102"]
set xsa  "$hw/heston_zcu102_ps.xsa"
set bit  "$hw/proj/heston_ps/heston_ps.runs/impl_1/heston_ps_wrapper.bit"
set ws   [file normalize "$here/../../../vitis_ws_zcu102"]
set elf  "$ws/heston_app/build/heston_app.elf"
# Every step is printed with a timestamp as it starts (stdout line-buffered, so a pipe or
# log file shows the step a hang is in). Version 2 (Nov 2026) after a hang on the lab board:
#  - no loadhw by default: every psu_init access is forced, the program sits in OCM, and
#    loadhw (hsi) was the step that stopped. Set GREEKS_LOADHW=1 to use it (without -regs).
#  - no SERDES/GTR initialisation (init_serdes, serdes data, resetin/resetout): the program
#    uses no transceiver (USB3, SATA, PCIe, DP), and those steps poll lane PLLs in loops.
fconfigure stdout -buffering line
set ::t_start [clock seconds]
proc step {msg} { puts [format "STEP %4ds  %s" [expr {[clock seconds] - $::t_start}] $msg]; flush stdout }
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

step "connect to hw_server"
connect
step "targets: [join [split [targets] \n] { | }]"
# The A53s are reachable only through the DAP's AXI/APB ports. If the PS bus is hung
# (e.g. a previous program stalled on memory), the DAP reports an AXI AP error and no
# APU appears: only a power cycle clears that.
proc find_apu {} {
  for {set i 0} {$i < 10} {incr i} {
    if {![catch {targets -set -nocase -filter {name =~ "APU*"}}]} { return 1 }
    after 1000
  }
  return 0
}
set apu [find_apu]
if {!$apu} {
  # recover a hung PS bus the way that worked on the lab board: reset the DAP, then the system
  puts "INFO: APU not reachable; resetting the debug port and the system"
  catch {targets -set -nocase -filter {name =~ "DAP*"}; rst -dap; after 1000; rst -system; after 3000}
  set apu [find_apu]
}
if {!$apu} {
  puts "ERROR: the processor (APU) is not reachable over JTAG; the debugger sees:"
  puts [targets]
  puts "ERROR: switch the ZCU102 off and on, check SW6 = JTAG (all four ON), then run again"
  exit 1
}
step "system reset"
rst -system
after 3000
targets -set -nocase -filter {name =~ "PSU*"}
step "program the PL: [file tail $bit]"
fpga -file $bit
targets -set -nocase -filter {name =~ "APU*"}
if {[info exists ::env(GREEKS_LOADHW)] && $::env(GREEKS_LOADHW)} {
  step "loadhw (GREEKS_LOADHW=1)"
  loadhw -hw $xsa -mem-ranges [list {0x80000000 0xbfffffff} {0x400000000 0x5ffffffff} {0x1000000000 0x7fffffffff}]
} else {
  step "memory map: OCM only (no loadhw)"
  catch {memmap -addr 0xFFFC0000 -size 0x40000 -flags 3}
}
configparams force-mem-access 1
step "read [file tail $init]"
source $init
# The PS blocks this program needs: MIO (UART0, I2C0 pins), PLLs, clocks, peripherals
# (UART0, I2C0, the timestamp counter), the AFI ports. Not DDR, not the SERDES lanes.
proc psu_init_minimal {} {
  set saved_mode [configparams force-mem-accesses]
  configparams force-mem-accesses 1
  foreach v {psu_mio_init_data psu_peripherals_pre_init_data psu_pll_init_data psu_clock_init_data
             psu_peripherals_init_data psu_peripherals_powerdwn_data psu_afi_config} { variable $v }
  step "PS init: MIO";                 init_ps [subst {$psu_mio_init_data}]
  step "PS init: peripherals (pre)";   init_ps [subst {$psu_peripherals_pre_init_data}]
  step "PS init: PLLs (polls lock)";   init_ps [subst {$psu_pll_init_data}]
  step "PS init: clocks";              init_ps [subst {$psu_clock_init_data}]
  step "PS init: peripherals";         init_ps [subst {$psu_peripherals_init_data}]
  step "PS init: SMMU interrupt";      init_peripheral
  step "PS init: power-down data";     init_ps [subst {$psu_peripherals_powerdwn_data}]
  step "PS init: AFI";                 init_ps [subst {$psu_afi_config}]
  configparams force-mem-accesses $saved_mode
}
psu_init_minimal
step "PS initialised"
after 1000
step "PS-PL isolation removal (PL power-up request to the PMU)"
psu_ps_pl_isolation_removal
after 1000
step "PL reset"
psu_ps_pl_reset_config
catch {psu_protection}
targets -set -nocase -filter {name =~ "*A53*#0"}
step "reset A53 #0, download [file tail $elf]"
rst -processor
dow $elf
mwr $LOG_ADDR 0
configparams force-mem-access 0
step "start the program"
con
step "running"
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
