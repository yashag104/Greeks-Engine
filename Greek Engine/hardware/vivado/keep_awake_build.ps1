# Run a Vivado batch job and keep Windows awake while it runs (no settings changed):
#   powershell -ExecutionPolicy Bypass -File keep_awake_build.ps1 <workdir> <tcl> <log> [tclargs...]
# SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) asks Windows not to
# sleep for as long as this script runs; it ends when Vivado exits. A closed lid
# can still sleep the machine, depending on the lid-close setting.
param([string]$WorkDir, [string]$Tcl, [string]$Log, [Parameter(ValueFromRemainingArguments=$true)][string[]]$TclArgs)
Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
$vivado = 'D:\2025.2\Vivado\bin\vivado.bat'
# Start-Process joins arguments with spaces and does not quote them: quote any
# argument that contains a space (this repository lives under "Greek Engine").
function Q([string]$a) { if ($a -match '\s') { '"' + $a + '"' } else { $a } }
$args = @('-mode', 'batch', '-nojournal', '-log', (Q $Log), '-source', (Q $Tcl))
if ($TclArgs) { $args += '-tclargs'; foreach ($t in $TclArgs) { $args += (Q $t) } }
[Win32.Power]::SetThreadExecutionState([uint32]'0x80000001') | Out-Null
try {
  $p = Start-Process -FilePath $vivado -ArgumentList $args -WorkingDirectory $WorkDir -WindowStyle Minimized -PassThru
  $p.WaitForExit()
} finally {
  [Win32.Power]::SetThreadExecutionState([uint32]'0x80000000') | Out-Null
}
