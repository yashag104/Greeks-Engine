# ============================================================================
# Run the end-to-end program on the ZedBoard over JTAG (no SD card):
#   D:\2025.2\Vitis\bin\xsdb.bat run_app.tcl          (from this folder)
# Programs the bitstream of bd_lite.tcl, initialises the PS from the platform
# build_vitis.py made, downloads heston_app.elf and runs it. Watch the board's
# USB-UART (J14) at 115200 baud: the program prints PASS/FAIL for 100 cases and
# a per-stage timing table. Boot-mode jumpers JP7-JP11 must be set to JTAG.
# ============================================================================
set here [file dirname [file normalize [info script]]]
set bit  [file normalize "$here/../../vivado/zedboard/proj/heston_zed/heston_zed.runs/impl_1/heston_bd_wrapper.bit"]
set ws   [file normalize "$here/../../../../vitis_ws_zedboard"]
set elf  "$ws/heston_app/build/heston_app.elf"
set init [lindex [glob -nocomplain "$ws/heston_zed_plat/**/ps7_init.tcl" \
                                   "$ws/heston_zed_plat/*/*/*/ps7_init.tcl" \
                                   "$ws/heston_zed_plat/*/*/*/*/ps7_init.tcl"] 0]
foreach f [list $bit $elf $init] {
  if {$f eq "" || ![file exists $f]} { puts "ERROR: missing [expr {$f eq "" ? "ps7_init.tcl" : $f}]"; exit 1 }
}
connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000
targets -set -nocase -filter {name =~ "xc7z*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "APU*"}
source $init
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf
con
puts "RESULT: running; read the results on the UART (115200 8N1)"
