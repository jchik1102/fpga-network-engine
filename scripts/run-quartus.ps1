$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\intelFPGA_lite\24.1std\quartus\bin64'
$run=Join-Path $root 'build/setup/quartus'
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
try {
  & "$bin\quartus_sh.exe" -t "$root/setup_checks/quartus.tcl" 2>&1 | Tee-Object create.log | Out-Host
  if($LASTEXITCODE -ne 0) {throw 'Quartus project creation failed'}
  & "$bin\quartus_sh.exe" --flow compile ram_smoke 2>&1 | Tee-Object compile.log | Out-Host
  if($LASTEXITCODE -ne 0) {throw 'Quartus compile failed'}
} finally { Pop-Location }
