# What of this repo's verification runs in Questa Intel Starter FPGA Edition:
# the cocotb tests of the async FIFO, on the SystemVerilog FIFO and on its
# VHDL-2008 version, each with the one mutant that fails quickly (see below).
#
# The UVM benches do not run: the Starter licence has no SystemVerilog
# verification feature, so Questa refuses randomize() and covergroups (vsim-1),
# and every bench in tb/ uses them. One attempt (packet_tb) is kept as the
# record, in uvm_packet_attempt.log.
#
# cocotb runs from a Windows Python with cocotb 2.1.0 (the WSL venv's version),
# since Questa is the Windows install. Logs in build/questa/.
param(
    [string]$Questa='C:\intelFPGA_lite\24.1std\questa_fse',
    [string]$CocotbPython="$env:USERPROFILE\.venvs\cocotb-win\Scripts\python.exe"
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$bin=Join-Path $Questa 'win64'
$out=Join-Path $root 'build/questa'
New-Item -ItemType Directory -Force $out | Out-Null
$summary=Join-Path $out 'summary.txt'
Set-Content $summary ''
function Note([string]$Line) {Add-Content $summary $Line; Write-Host $Line}
function Quiet([string]$Exe,[string[]]$ToolArgs,[string]$Log) {
    $ErrorActionPreference='Continue'   # stderr lines are not failures
    & $Exe @ToolArgs 2>&1 | Out-File -Encoding utf8 $Log
    return $LASTEXITCODE
}

# The UVM attempt: the packet bench, compiled and loaded with UVM 1.2.
$uvmDir=Join-Path $out 'uvm_packet'
New-Item -ItemType Directory -Force $uvmDir | Out-Null
Push-Location $uvmDir
try {
    if(Test-Path work){Remove-Item -Recurse -Force work}
    Copy-Item (Join-Path $root 'build/packet/packets.txt') . -Force
    Quiet "$bin\vlib.exe" @('work') 'vlib.log' | Out-Null
    $src=@('rtl/packet_classifier.sv','rtl/capture_ingress.sv','tb/interfaces.sv','tb/stream_agent_pkg.sv','tb/packet_test.sv') | ForEach-Object {Join-Path $root $_}
    $uvm="$Questa/uvm-1.2"
    if((Quiet "$bin\vlog.exe" (@('-sv','-timescale','1ns/1ps','-L',$uvm,"+incdir+$Questa/verilog_src/uvm-1.2/src")+$src) 'compile.log') -ne 0){throw 'packet bench did not compile in Questa'}
    # -suppress 12003: interfaces.sv gives rst and tick initial values that the
    # bench's continuous assignments then drive, which Questa rejects by default.
    Quiet "$bin\vsim.exe" @('-c','-suppress','12003','-L',$uvm,'packet_tb','-sv_seed','17','+FIXTURE=packets.txt','-l','sim.log','-do','run -all; quit -f') 'sim.console.log' | Out-Null
    $text=Get-Content sim.log -Raw
    Copy-Item sim.log (Join-Path $out 'uvm_packet_attempt.log') -Force
    $refused=[regex]::Match($text,'\(vsim-1\)[^\r\n]*').Value
    if(!$refused){throw 'Expected the licence refusal in the UVM attempt; see build/questa/uvm_packet/sim.log'}
    Note ('{0,-34} NOT RUN (licence): {1}' -f 'UVM packet_tb',$refused.Trim())
} finally {Pop-Location}

# cocotb, through Questa
$env:COCOTB_SIM='questa'
$env:PATH="$bin;$env:PATH"
Push-Location $root
try {
    foreach($suite in @(@('tb/cocotb','sv'),@('tb/cocotb_vhdl','vhdl'))) {
        $dir,$lang=$suite
        Remove-Item Env:CDC_MUTANT -ErrorAction SilentlyContinue
        $log=Join-Path $out "cocotb_$lang.log"
        $code=Quiet $CocotbPython @('-m','pytest',$dir,'-v','-s') $log
        $tally=([regex]::Matches((Get-Content $log -Raw),'\*\* TESTS=\d+ PASS=\d+ FAIL=\d+ SKIP=\d+') | ForEach-Object {$_.Value}) -join '; '
        if($code -ne 0){throw "cocotb ($lang) failed in Questa, see build/questa/cocotb_$lang.log"}
        Note ('{0,-34} PASS {1}' -f "cocotb $lang FIFO",$tally)
        # Only the mutant that fails within the clean tests' length. The other
        # three hang the FIFO and fail on the tests' 20 ms and 60 ms timeouts;
        # Questa Starter with cocotb's VPI runs these benches at a few thousand
        # (SV) to about 19,000 (VHDL) simulated ns per second (the cocotb logs'
        # tallies), so each would take hours.
        # They stay on Icarus and GHDL (make cocotb, make vhdl).
        foreach($m in @('empty_misses_data')) {
            $env:CDC_MUTANT=$m
            $mlog=Join-Path $out "cocotb_${lang}_$m.log"
            if((Quiet $CocotbPython @('-m','pytest',$dir,'-q') $mlog) -eq 0){throw "cocotb ($lang) passes on mutant $m in Questa"}
            $failed=[regex]::Match((Get-Content $mlog -Raw),'\*\* TESTS=\d+ PASS=\d+ FAIL=\d+ SKIP=\d+').Value
            # A failing test, not a build error, must be what failed.
            if($failed -notmatch 'FAIL=[1-9]'){throw "Mutant $m ($lang): no failing cocotb test, see $mlog"}
            Note ('{0,-34} MUTANT_DETECTED {1}' -f "cocotb $lang $m",$failed)
        }
        Remove-Item Env:CDC_MUTANT
    }
} finally {Pop-Location}
Write-Host 'QUESTA_PASS'
