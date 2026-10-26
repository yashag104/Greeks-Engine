# ============================================================================
# Run the end-to-end program on the ZCU102 over JTAG (no SD card) and save its
# output to zcu102_ps_run.log, no serial console needed:
#   xsdb run_app.tcl            (from this folder; or ../../vivado/zcu102/run_board.sh run)
# Resets the board, programs the bitstream of bd_ps.tcl, initialises the PS
# with psu_init from the XSA, downloads heston_app.elf and runs it. The program
# writes its output into a DDR buffer as well as the UART; once it has had time
# to finish (correctness, timing, then about a minute of power windows) the
# processor is stopped and the buffer saved. Boot-mode switch SW6: JTAG.
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
set LOG_ADDR 0x40000000
set first_wait_s 80          ;# 3 x (10 s idle + 10 s run) of power windows, plus the rest
foreach f [list $xsa $bit $elf $init] {
  if {![file exists $f]} { puts "ERROR: missing $f"; exit 1 }
}

connect
targets -set -nocase -filter {name =~ "APU*"}
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

# Stop only once the run should be over (stopping earlier would disturb the
# timing and power windows), then read the buffer through the stopped A53.
set done 0
for {set i 0} {$i < 12} {incr i} {
  stop
  set magic [mrd -value $LOG_ADDR]
  if {$magic == 0x444f4e45} { set done 1; break }
  puts "INFO: not finished yet (marker 0x[format %08x $magic]); waiting 10 s more"
  con
  after 10000
}
set len [mrd -value [expr {$LOG_ADDR + 4}]]
if {$len > 0 && $len < 200000} {
  mrd -bin -file $log [expr {$LOG_ADDR + 8}] [expr {($len + 3) / 4}]
  set fp [open $log rb]; set text [string range [read $fp] 0 [expr {$len - 1}]]; close $fp
  set fp [open $log wb]; puts -nonewline $fp $text; close $fp
  puts $text
  puts "RESULT: [expr {$done ? "finished" : "NOT finished"}]; output saved to $log"
} else {
  puts "ERROR: no output in the log buffer (length $len); check the UART"
}
