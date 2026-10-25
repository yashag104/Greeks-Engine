@echo off
REM ZCU104 bring-up of the 64-bit engine, run natively on Windows.
REM
REM   run_board.bat build        bd_jtag.tcl  -> bitstream at 100 MHz
REM   run_board.bat build 150    same, at 150 MHz (once a first build shows the slack)
REM   run_board.bat test         run_jtag.tcl -> program board, check one case
REM   run_board.bat sweep        run_sweep.tcl -> program once, 50 cases back to back
REM   run_board.bat nifty        run_nifty.tcl -> 50 real NIFTY inputs back to back
setlocal
set VIVADO=D:\2025.2\Vivado\bin\vivado.bat
cd /d "%~dp0"

if not exist "%VIVADO%" (
  echo Vivado not found at %VIVADO% - edit this file to point at your install.
  pause & exit /b 1
)

if /i "%1"=="build" (
  if "%2"=="" ( call "%VIVADO%" -mode batch -nojournal -log bd_jtag.log -source bd_jtag.tcl
  ) else ( call "%VIVADO%" -mode batch -nojournal -log bd_jtag.log -source bd_jtag.tcl -tclargs %2 )
  findstr /b /c:"RESULT:" /c:"WARNING: timing" /c:"ERROR:" bd_jtag.log
) else if /i "%1"=="test" (
  call "%VIVADO%" -mode batch -nojournal -log run_jtag.log -source run_jtag.tcl
  findstr /b /c:"PASS" /c:"FAIL" /c:"ERROR" /c:"INFO:" /c:"  ok" run_jtag.log
) else if /i "%1"=="nifty" (
  call "%VIVADO%" -mode batch -nojournal -log run_nifty.log -source run_nifty.tcl
  findstr /b /c:"PASS" /c:"FAIL" /c:"ERROR" /c:"INFO:" /c:"CASE" run_nifty.log
) else if /i "%1"=="sweep" (
  call "%VIVADO%" -mode batch -nojournal -log run_sweep.log -source run_sweep.tcl
  findstr /b /c:"PASS" /c:"FAIL" /c:"ERROR" /c:"INFO:" /c:"CASE" run_sweep.log
) else (
  echo usage: run_board.bat build [clk_mhz] ^| test ^| sweep ^| nifty
)
pause
