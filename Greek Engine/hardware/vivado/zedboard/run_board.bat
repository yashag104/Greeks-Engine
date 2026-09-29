@echo off
REM ZedBoard bring-up, run natively on Windows (no WSL), same reason as
REM ..\run_native.bat: runs launched from WSL have died without an error.
REM
REM   run_board.bat build        bd_jtag.tcl  -> bitstream        (takes hours)
REM   run_board.bat build 60     same, at 60 MHz if 70 fails timing
REM   run_board.bat test         run_jtag.tcl -> program board, check outputs
REM   run_board.bat sweep        run_sweep.tcl -> program once, 50 cases back to back
REM   run_board.bat ps           bd_lite.tcl  -> PS design + .xsa (phase 2)
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
) else if /i "%1"=="sweep" (
  call "%VIVADO%" -mode batch -nojournal -log run_sweep.log -source run_sweep.tcl
  findstr /b /c:"PASS" /c:"FAIL" /c:"ERROR" /c:"INFO:" /c:"CASE" run_sweep.log
) else if /i "%1"=="ps" (
  if "%2"=="" ( call "%VIVADO%" -mode batch -nojournal -log bd_lite.log -source bd_lite.tcl
  ) else ( call "%VIVADO%" -mode batch -nojournal -log bd_lite.log -source bd_lite.tcl -tclargs %2 )
  findstr /b /c:"RESULT:" /c:"WARNING: timing" /c:"ERROR:" /c:"INFO: FCLK" bd_lite.log
) else (
  echo usage: run_board.bat build [clk_mhz] ^| test ^| sweep ^| ps [clk_mhz]
)
pause
