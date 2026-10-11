param([Parameter(Mandatory=$true)][string]$Log,[Parameter(Mandatory=$true)][string]$Marker)
$ErrorActionPreference='Stop'
$text=Get-Content -LiteralPath $Log -Raw
if($text -match 'Fatal:|ERROR:|WATCHDOG|UVM_FATAL\s*:\s*[1-9]|UVM_ERROR\s*:\s*[1-9]' -or $text -notmatch [regex]::Escape($Marker)) {
  Write-Output 'FAIL: XSim log contains an error or lacks the success marker'
  exit 1
}
Write-Output 'PASS: XSim log checked'
exit 0
