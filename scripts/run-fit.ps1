param([ValidateSet('engine_axi','engine_pcie','engine_axi_cdc')][string]$Top='engine_axi')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\intelFPGA_lite\24.1std\quartus\bin64'
$run=Join-Path $root "build/fit/$Top"
New-Item -ItemType Directory -Force $run | Out-Null
$common=@('packet_classifier','capture_ingress','descriptor_validator','sg_transfer','engine_control','replay_policy',
  'replay_staging','dma_command_arbiter','capture_dma','replay_dma','engine_core','axi_burst_master')
$extra=if($Top -eq 'engine_pcie'){@('pcie_requester','pcie_completer','pcie_msi','pcie_tx_arbiter','engine_pcie')}elseif($Top -eq 'engine_axi_cdc'){@('stream_cdc_fifo')}else{@()}
$sources=(($common+$extra) | ForEach-Object {(Join-Path $root "rtl/$_.sv") -replace '\\','/'})+@((Join-Path $root 'constraints/engine_fit.sv') -replace '\\','/')
if($Top -eq 'engine_axi_cdc'){$sources+=@((Join-Path $root 'constraints/engine_cdc_fit.sv') -replace '\\','/')}
$wrapper="${Top}_fit"
Push-Location $run
try {
  'RUNNING' | Set-Content result.txt
  & "$bin\quartus_sh.exe" -t "$root/constraints/engine.tcl" $wrapper @sources 2>&1 | Tee-Object create.log | Out-Host
  if($LASTEXITCODE -ne 0) {throw 'Quartus project creation failed'}
  & "$bin\quartus_sh.exe" --flow compile $wrapper 2>&1 | Tee-Object compile.log | Out-Host
  if($LASTEXITCODE -ne 0) {throw 'Quartus compile failed'}
  & "$bin\quartus_sta.exe" -t "$root/constraints/report_paths.tcl" $wrapper 2>&1 | Tee-Object sta-paths.log | Out-Null
  & "$bin\quartus_sta.exe" -t "$root/constraints/slack_by_entity.tcl" $wrapper 2>&1 | Tee-Object sta-entity.log | Out-Null
  if($Top -eq 'engine_axi_cdc'){
    & "$bin\quartus_sta.exe" -t "$root/constraints/report_cdc.tcl" $wrapper 2>&1 | Tee-Object sta-cdc.log | Out-Null
  }
  'PASS' | Set-Content result.txt
} finally { Pop-Location }
