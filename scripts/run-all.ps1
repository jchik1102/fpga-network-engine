param([switch]$Mutations,[switch]$Fit,[string]$Seeds='17')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pwsh=(Get-Process -Id $PID).Path
$out=Join-Path $root 'build/regression'
New-Item -ItemType Directory -Force $out | Out-Null
$rows=New-Object System.Collections.Generic.List[string]
function Step($Name,[scriptblock]$Body) {
  $start=Get-Date
  & $Body *> (Join-Path $out "$Name.log")
  $code=$LASTEXITCODE
  $line="{0,-30} {1,-5} exit={2,-4} {3,6:n0}s" -f $Name,$(if($code -eq 0){'PASS'}else{'FAIL'}),$code,((Get-Date)-$start).TotalSeconds
  $rows.Add($line);Write-Output $line
}
Push-Location $root
try {
  Step 'fixtures' {wsl -d Ubuntu -- bash -c ".venv/bin/python -m host.generate_packet_vectors && .venv/bin/python -m host.generate_dma_vectors && .venv/bin/python -m host.generate_replay_vectors && .venv/bin/python -m host.generate_engine_vectors"}
  Step 'models' {wsl -d Ubuntu -- bash scripts/run-models.sh}
  foreach($seed in ($Seeds -split ',' | ForEach-Object {[int]$_.Trim()})) {
    foreach($t in 'packet','axi','sg','control','replay','pcie','engine_axi') {
      Step "${t}_seed$seed" {& $pwsh -NoProfile -File scripts/run-rtl.ps1 -Test $t -Seed $seed -Label "s$seed"}
    }
    Step "engine_pcie_seed$seed" {& $pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie -Seed $seed -Label "s$seed"}
    Step "engine_pcie_stress_seed$seed" {& $pwsh -NoProfile -File scripts/run-rtl.ps1 -Test engine_pcie -Seed $seed -Label "stress_s$seed" -Plusargs FOUR_TAG,RCB128,HIGH_APERTURE,HIGH_BAR}
    Step "compare_seed$seed" {wsl -d Ubuntu -- .venv/bin/python -m host.export_observations --axi "build/engine_axi_s$seed" --pcie "build/engine_pcie_s$seed" "build/engine_pcie_stress_s$seed" --output "build/comparison_s$seed.json"}
  }
  if($Mutations) {Step 'mutations' {& $pwsh -NoProfile -File scripts/run-mutations.ps1}}
  if($Fit) {
    Step 'fit_engine_axi' {& $pwsh -NoProfile -File scripts/run-fit.ps1 -Top engine_axi}
    Step 'fit_engine_pcie' {& $pwsh -NoProfile -File scripts/run-fit.ps1 -Top engine_pcie}
  }
} finally {
  Pop-Location
  $rows | Set-Content (Join-Path $out 'summary.txt')
}
if($rows | Where-Object {$_ -match ' FAIL '}) {exit 1}
exit 0
