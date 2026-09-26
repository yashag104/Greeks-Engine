# ZedBoard 100 MHz oscillator on Y9 (bank 13, 3.3 V). This is the only pin the
# JTAG bring-up design needs: everything else reaches the engine over JTAG.
set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33} [get_ports clk_in100]
create_clock -name clk_in100 -period 10.000 [get_ports clk_in100]
