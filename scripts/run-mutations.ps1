param([string[]]$Only=@())
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$pwsh=(Get-Process -Id $PID).Path
$out=Join-Path $root 'build/mutations'
New-Item -ItemType Directory -Force $out | Out-Null
$mutants=@(
  @{Name='BAD_FINAL_STROBE';Test='engine_axi';Args=@();Expect='capture capacity/BAD_DESC byte unchanged|OWNERSHIP|captured byte'},
  @{Name='WRONG_SG_BYTE';Test='engine_axi';Args=@();Expect='captured byte frame=|is not the next expected replay'},
  @{Name='EARLY_DEPARTURE';Test='engine_axi';Args=@();Expect='replay departed early'},
  @{Name='EARLY_COMPLETION';Test='engine_axi';Args=@();Expect='replay completion precedes observed departure|ring [4-7] seq \d+ record tick='},
  @{Name='LOSS_IGNORES_QUEUE';Test='engine_axi';Args=@();Expect='record status=|is not the next expected replay'},
  @{Name='WRONG_BE';Test='engine_pcie';Args=@();Expect='capture capacity/BAD_DESC byte unchanged|OWNERSHIP|outside host aperture'},
  @{Name='WRONG_TAG';Test='engine_pcie';Args=@('FOUR_TAG');Expect='reused tag'},
  @{Name='EARLY_TAG_REUSE';Test='pcie';Args=@();Expect='reused tag|read-after-write byte'},
  @{Name='PREMATURE_PUBLICATION';Test='engine_pcie';Args=@();Expect='before it is host visible'},
  @{Name='BYPASS_BYTE_CHECK';Test='engine_axi';Args=@();Expect='byte checker compared'}
)
$Only=@($Only | ForEach-Object {$_ -split ','} | Where-Object {$_})
$rows=@()
foreach($m in $mutants) {
  if($Only.Count -and -not ($Only -contains $m.Name)) {continue}
  $label="mut_$($m.Name.ToLower())"
  $log=Join-Path $root "build/$($m.Test)_$label/seed17.log"
  $launch=@('-Test',$m.Test,'-Label',$label,'-Defines',"MUTATION_$($m.Name)")
  if($m.Args.Count) {$launch+=@('-Plusargs',($m.Args -join ','))}
  & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-rtl.ps1') @launch *> (Join-Path $out "$label.console.txt")
  $exit=$LASTEXITCODE
  $text=if(Test-Path $log){Get-Content $log -Raw}else{''}
  $fatal=([regex]::Match($text,'UVM_FATAL [^\r\n]*\[[A-Z_]+\] [^\r\n]*')).Value
  $detected=$exit -ne 0 -and $text -match $m.Expect
  $verdict=if($detected){'DETECTED'}else{'NOT_DETECTED'}
  $rows+="{0,-22} {1,-12} exit={2} {3} :: {4}" -f $m.Name,$m.Test,$exit,$verdict,($fatal -replace '^UVM_FATAL \S+ ','')
  Write-Output $rows[-1]
}
$rows | Set-Content (Join-Path $out 'summary.txt')
if($rows | Where-Object {$_ -match 'NOT_DETECTED'}) {exit 1}
exit 0
