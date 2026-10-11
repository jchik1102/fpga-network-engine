param([string]$Source,[string]$Destination)
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes($Source)
[IO.File]::WriteAllBytes($Destination,$bytes)
$sha=[Security.Cryptography.SHA256]::Create()
try { [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Destination))).Replace('-','').ToLowerInvariant() }
finally { $sha.Dispose() }
