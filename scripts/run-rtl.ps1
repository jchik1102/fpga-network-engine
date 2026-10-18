param([ValidateSet('packet','axi','sg','control','replay','engine_axi','engine_pcie','pcie')][string]$Test='packet',[int]$Seed=17,[switch]$SkipCompile,
  [string[]]$Plusargs=@(),[string]$Label='',[string[]]$Defines=@())
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin='C:\AMDDesignTools\2025.2\Vivado\bin'
$env:XILINX_VIVADO=Split-Path $bin -Parent
$run=Join-Path $root ("build/$Test"+$(if($Label){"_$Label"}else{''}))
New-Item -ItemType Directory -Force $run | Out-Null
$moduleFixture=@{packet='packets.txt';sg='dma.txt';replay='policy.txt'}[$Test]
if($Label -and $moduleFixture) {Copy-Item (Join-Path $root "build/$Test/$moduleFixture") $run -Force}
Push-Location $run
function Invoke-Tool($Name,$Arguments,$Log) {
  & "$bin\$Name.bat" @Arguments 2>&1 | Tee-Object -FilePath $Log | Out-Host
  if($LASTEXITCODE -ne 0) {throw "$Name failed: $LASTEXITCODE"}
}
$engineRtl=@('packet_classifier','capture_ingress','axi_burst_master','descriptor_validator','sg_transfer','engine_control',
  'replay_policy','replay_staging','dma_command_arbiter','capture_dma','replay_dma','engine_core') | ForEach-Object {"rtl/$_.sv"}
$pcieRtl=@('pcie_requester','pcie_completer','pcie_msi','pcie_tx_arbiter','engine_pcie') | ForEach-Object {"rtl/$_.sv"}
$fixture='packets.txt'
# Design instances in each bench, for the code coverage summary.
$dut=@{packet='packet_tb.dut';axi='axi_burst_tb.dut';replay='replay_tb.policy,replay_tb.staging';control='control_tb.dut';
  engine_axi='engine_axi_tb.dut';engine_pcie='engine_pcie_tb.dut';pcie='pcie_tb.dut,pcie_tb.arbiter';
  sg='sg_tb.validator,sg_tb.transfer,sg_tb.master'}[$Test]
try {
  'RUNNING' | Set-Content result.txt
  if($Test -eq 'packet') {
    $top='packet_tb';$marker='PACKET_PASS'
    $relativeSources=@('rtl/packet_classifier.sv','rtl/capture_ingress.sv','tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/packet_test.sv')
  } elseif($Test -eq 'axi') {
    $top='axi_burst_tb';$marker='AXI_BURST_PASS'
    $relativeSources=@('rtl/axi_burst_master.sv','tb/interfaces.sv','tb/axi_memory_agent_pkg.sv','tb/axi_burst_test.sv')
  } elseif($Test -eq 'replay') {
    $top='replay_tb';$marker='REPLAY_PASS'
    $relativeSources=@('rtl/replay_policy.sv','rtl/replay_staging.sv','tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/replay_test.sv')
  } elseif($Test -eq 'control') {
    $top='control_tb';$marker='CONTROL_PASS'
    $relativeSources=@('rtl/engine_control.sv','tb/interfaces.sv','tb/axil_agent_pkg.sv','tb/control_test.sv')
  } elseif($Test -eq 'engine_axi') {
    $top='engine_axi_tb';$marker='ENGINE_AXI_PASS';$fixture='../engine/engine.txt'
    $relativeSources=$engineRtl+@('tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/axi_memory_agent_pkg.sv','tb/axil_agent_pkg.sv','tb/host_software_pkg.sv','tb/engine_axi_test.sv')
  } elseif($Test -eq 'engine_pcie') {
    $top='engine_pcie_tb';$marker='ENGINE_PCIE_PASS';$fixture='../engine/engine.txt'
    $relativeSources=$engineRtl+$pcieRtl+@('tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/axi_memory_agent_pkg.sv','tb/host_software_pkg.sv','tb/pcie_host_pkg.sv','tb/engine_pcie_test.sv')
  } elseif($Test -eq 'pcie') {
    $top='pcie_tb';$marker='PCIE_REQUESTER_PASS'
    $relativeSources=@('rtl/pcie_requester.sv','rtl/pcie_tx_arbiter.sv','tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/axi_memory_agent_pkg.sv','tb/host_software_pkg.sv','tb/pcie_host_pkg.sv','tb/pcie_test.sv')
  } else {
    $top='sg_tb';$marker='SG_PASS'
    $relativeSources=@('rtl/axi_burst_master.sv','rtl/descriptor_validator.sv','rtl/sg_transfer.sv','tb/interfaces.sv','tb/axi_memory_agent_pkg.sv','tb/sg_test.sv')
  }
  if(-not $SkipCompile) {
    $sources=$relativeSources | ForEach-Object {Join-Path $root $_}
    $defineArgs=@($Defines | ForEach-Object {@('-d',$_)})
    Invoke-Tool xvlog (@('-sv','-L','uvm')+$defineArgs+$sources) 'compile.log'
    # Statement, branch and condition code coverage in xsim.codeCov/code (toggle
    # is left out: xcrg 2025.2 crashed reporting it on the riscv-soc core).
    Invoke-Tool xelab @($top,'-L','uvm','-s',$top,'-timescale','1ns/1ps','-debug','typical','-mt','off',
      '-cc_type','sbc','-cov_db_dir','.','-cov_db_name','code') 'elaborate.log'
  }
  # pwsh -File joins arrays into one comma string
  $extraArgs=($Plusargs | ForEach-Object {$_ -split ','} | Where-Object {$_} | ForEach-Object {"`n-testplusarg $_"}) -join ''
  "-sv_seed $Seed`n-testplusarg FIXTURE=$fixture`n-cov_db_name seed$Seed$extraArgs" | Set-Content run.args -Encoding ascii
  Invoke-Tool xsim @($top,'-R','-f','run.args','-log',"seed$Seed.log") "seed$Seed.console.log"
  & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot/check-xsim-log.ps1" -Log "seed$Seed.log" -Marker $marker
  if($LASTEXITCODE -ne 0) {throw "$Test test failed"}
  if($Test -ne 'sg') {Invoke-Tool xcrg @('-cov_db_dir','.','-cov_db_name',"seed$Seed",'-report_format','all','-report_dir',"coverage$Seed") 'coverage-export.log'}
  if(Test-Path "code-coverage$Seed") {Remove-Item -Recurse -Force "code-coverage$Seed"}
  Invoke-Tool xcrg @('-cov_db_dir','.','-cov_db_name','code','-report_format','html','-report_dir',"code-coverage$Seed") 'code-coverage-export.log'
  $linuxRoot=((& wsl -d Ubuntu --exec wslpath -a $root) | Out-String).Trim()
  $linuxRun=((& wsl -d Ubuntu --exec wslpath -a $run) | Out-String).Trim()
  $dutArgs=@($dut -split ',' | ForEach-Object {@('--dut',$_)})
  & wsl -d Ubuntu --cd $linuxRoot --exec .venv/bin/python scripts/code_coverage_summary.py "$linuxRun/code-coverage$Seed" @dutArgs `
    --label (Split-Path $run -Leaf) --root $root.Replace('\','/') --out "$linuxRun/code-coverage$Seed.txt"
  if($LASTEXITCODE -ne 0) {throw "code coverage summary failed"}
  'PASS' | Set-Content result.txt
} finally {Pop-Location}
