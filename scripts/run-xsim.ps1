param([switch]$SkipCompile)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\AMDDesignTools\2025.2\Vivado\bin'
$env:XILINX_VIVADO=Split-Path $bin -Parent
$run=Join-Path $root 'build/setup/xsim'
New-Item -ItemType Directory -Force $run | Out-Null
Push-Location $run
function Invoke-Tool($Name, $Arguments, $Log) {
  & "$bin\$Name.bat" @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
  if($LASTEXITCODE -ne 0) { throw "$Name failed: $LASTEXITCODE" }
}
try {
  if(-not $SkipCompile) {
    Invoke-Tool xvlog @('-sv','-L','uvm',"$root/setup_checks/qualification.sv","$root/setup_checks/assertion.sv") 'compile.log'
    Invoke-Tool xelab @('qualification','-L','uvm','-s','qualification','-debug','typical','-timescale','1ns/1ps','-mt','off') 'elaborate.log'
  }
  foreach($case in @(@('17','seed17a'),@('17','seed17b'),@('29','seed29'))) {
    $seed=$case[0]; $label=$case[1]
    "-sv_seed $seed`n-testplusarg SEED=$seed`n-testplusarg TRACE=$label.txt`n-cov_db_name $label" | Set-Content "$label.args" -Encoding ascii
    Invoke-Tool xsim @('qualification','-R','-f',"$label.args",'-log',"$label.log") "$label.console.log"
    $log=Get-Content "$label.log" -Raw
    foreach($marker in @('RANDOM_PASS','PACKED_QUEUE_PASS','UVM_VIF_RAL_PASS')) {
      if($log -notmatch $marker) {throw "Missing $marker in $label"}
    }
    if($log -match 'UVM_FATAL\s*:\s*[1-9]|UVM_ERROR\s*:\s*[1-9]|Fatal:|WATCHDOG') {throw "Simulation error in $label"}
  }
  if((Get-FileHash seed17a.txt).Hash -ne (Get-FileHash seed17b.txt).Hash) {throw 'Seed not reproducible'}
  if((Get-FileHash seed17a.txt).Hash -eq (Get-FileHash seed29.txt).Hash) {throw 'Different seeds identical'}
  & "$bin\xsim.bat" qualification -R -testplusarg UVM_FAIL -log uvm-fail.log 2>&1 | Tee-Object uvm-fail.console.log | Out-Host
  if((Get-Content uvm-fail.log -Raw) -notmatch 'EXPECTED_UVM_FAILURE') {throw 'Expected UVM fatal missing'}
  & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/check-xsim-log.ps1" -Log uvm-fail.log -Marker UVM_VIF_RAL_PASS
  if($LASTEXITCODE -ne 1) {throw 'Deliberate UVM failure did not propagate'}
  Invoke-Tool xcrg @('-cov_db_dir','.','-cov_db_name','seed17a','-report_format','all','-report_dir','coverage') 'coverage-export.log'
  Invoke-Tool xelab @('assertion_smoke','-s','assertion_smoke','-debug','typical') 'assert-elaborate.log'
  Invoke-Tool xsim @('assertion_smoke','-R','-log','assert-pass.log') 'assert-pass.console.log'
  if((Get-Content assert-pass.log -Raw) -notmatch 'SVA_PASS') {throw 'SVA pass missing'}
  & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/check-xsim-log.ps1" -Log assert-pass.log -Marker SVA_PASS
  if($LASTEXITCODE -ne 0) {throw 'Passing log rejected'}
  & "$bin\xsim.bat" assertion_smoke -R -testplusarg FAIL -log assert-fail.log 2>&1 | Tee-Object assert-fail.console.log | Out-Host
  $negativeExit=$LASTEXITCODE
  if((Get-Content assert-fail.log -Raw) -notmatch 'EXPECTED_SVA_FAILURE') {throw 'Negative assertion not detected'}
  & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/check-xsim-log.ps1" -Log assert-fail.log -Marker SVA_PASS
  if($LASTEXITCODE -ne 1) {throw 'Deliberate SVA failure did not propagate into runner failure'}
  # xsim can exit 0 after an hdl fatal, so the log is checked too
  "EXPECTED_NEGATIVE: SVA detected; native exit=$negativeExit; wrapper verdict=FAIL" | Set-Content negative-verdict.txt
  Invoke-Tool xvlog @('-sv',"$root/setup_checks/random_calls.sv") 'system-random-compile.log'
  Invoke-Tool xelab @('random_calls','-s','random_calls') 'system-random-elaborate.log'
  Invoke-Tool xsim @('random_calls','-R','-sv_seed','17','-log','system-random.log') 'system-random.console.log'
  & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/check-xsim-log.ps1" -Log system-random.log -Marker SYSTEM_RANDOM_PASS
  if($LASTEXITCODE -ne 0) {throw 'System random reproducer failed'}
  'PASS: UVM randomization/reproducibility, VIF/RAL model APIs, packed queue, coverage export, SVA positive and negative' | Set-Content result.txt
} finally { Pop-Location }
