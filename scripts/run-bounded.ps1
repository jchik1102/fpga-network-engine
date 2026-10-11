param(
  [ValidateSet('XSim','Quartus','Packet','Axi','Sg','Control','Replay','EngineAxi','EnginePcie','Pcie','FitAxi','FitPcie','TimeoutProbe','ExitProbe')][string]$Check='XSim',
  [ValidateRange(1,14400)][int]$TimeoutSeconds=600,
  [string[]]$Extra=@()
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$logdir=Join-Path $root 'build/setup'
New-Item -ItemType Directory -Force $logdir | Out-Null
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=(Get-Process -Id $PID).Path
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true
$info.RedirectStandardError=$true
$info.WorkingDirectory=$root
$info.ArgumentList.Add('-NoProfile')
if($Check -eq 'TimeoutProbe') {
  $info.ArgumentList.Add('-Command'); $info.ArgumentList.Add('Start-Sleep -Seconds 30')
} elseif($Check -eq 'ExitProbe') {
  $info.ArgumentList.Add('-Command'); $info.ArgumentList.Add('exit 23')
} else {
  $info.ArgumentList.Add('-File')
  $script=switch($Check) {'XSim' {'run-xsim.ps1'} 'Quartus' {'run-quartus.ps1'} 'FitAxi' {'run-fit.ps1'} 'FitPcie' {'run-fit.ps1'} default {'run-rtl.ps1'}}
  $info.ArgumentList.Add((Join-Path $PSScriptRoot $script))
  $test=@{Axi='axi';Sg='sg';Control='control';Replay='replay';EngineAxi='engine_axi';EnginePcie='engine_pcie';Pcie='pcie'}[$Check]
  if($test) {$info.ArgumentList.Add('-Test');$info.ArgumentList.Add($test)}
  if($Check -eq 'FitAxi') {$info.ArgumentList.Add('-Top');$info.ArgumentList.Add('engine_axi')}
  if($Check -eq 'FitPcie') {$info.ArgumentList.Add('-Top');$info.ArgumentList.Add('engine_pcie')}
  foreach($argument in $Extra) {$info.ArgumentList.Add($argument)}
}
$proc=[Diagnostics.Process]::new(); $proc.StartInfo=$info
[void]$proc.Start()
$out=$proc.StandardOutput.ReadToEndAsync(); $err=$proc.StandardError.ReadToEndAsync()
if(-not $proc.WaitForExit($TimeoutSeconds*1000)) {
  $proc.Kill($true); $proc.WaitForExit()
  [IO.File]::WriteAllText((Join-Path $logdir "$Check.stdout.log"),$out.GetAwaiter().GetResult())
  [IO.File]::WriteAllText((Join-Path $logdir "$Check.stderr.log"),$err.GetAwaiter().GetResult())
  Write-Output "ENVIRONMENTAL_TIMEOUT: $Check after $TimeoutSeconds seconds"
  exit 124
}
[IO.File]::WriteAllText((Join-Path $logdir "$Check.stdout.log"),$out.GetAwaiter().GetResult())
[IO.File]::WriteAllText((Join-Path $logdir "$Check.stderr.log"),$err.GetAwaiter().GetResult())
Write-Output "$Check exit=$($proc.ExitCode); logs in $logdir"
exit $proc.ExitCode
