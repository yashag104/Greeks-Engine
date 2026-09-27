@echo off
REM Run the implementation flow natively on Windows, with no WSL in the loop.
REM Double-click, or from a cmd prompt:  run_native.bat
REM
REM Use this when the run keeps dying without an error message: it removes
REM both WSL and the agent harness as possible causes, and you can watch it.
setlocal
set VIVADO=D:\2025.2\Vivado\bin\vivado.bat
set OUT=runs\xc7z020clg400-1\heston_aad_z7h
cd /d "%~dp0"

if not exist "%VIVADO%" (
  echo Vivado not found at %VIVADO% - edit this file to point at your install.
  pause & exit /b 1
)

if exist "%OUT%\post_synth.dcp" (
  echo Resuming implementation from checkpoint...
  call "%VIVADO%" -mode batch -nojournal -log "%OUT%\impl.log" -source impl_from_dcp.tcl -tclargs "%OUT%" 10.0
) else (
  echo Running full synthesis + implementation...
  call "%VIVADO%" -mode batch -nojournal -log "%OUT%\vivado.log" -source synth_impl.tcl -tclargs heston_aad_z7h xc7z020clg400-1 10.0 "%OUT%"
)

echo.
echo ==== summary ====
if exist "%OUT%\summary.txt" (type "%OUT%\summary.txt") else (echo FAILED - see the log in %OUT%)
pause
