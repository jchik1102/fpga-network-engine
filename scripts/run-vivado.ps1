param(
    [ValidateSet('engine_axi', 'engine_pcie', 'engine_axi_cdc')][string]$Top = 'engine_axi',
    [string]$Vivado = 'C:\AMDDesignTools\2025.2\Vivado',
    [string]$Part = 'xc7a100tcsg324-1',
    # engine_axi_cdc only: build the async FIFO from rtl/vhdl/stream_cdc_fifo.vhd
    # (a mixed SystemVerilog and VHDL design), into build/vivado/engine_axi_cdc_vhdl/.
    [switch]$VhdlFifo
)
# Out-of-context Vivado implementation of a fit wrapper (the same registered
# tops Quartus builds) for a Xilinx Artix-7 at 50 MHz; engine_axi_cdc also has
# its 125 MHz packet clock (constraints/engine_cdc.xdc) and gets report_cdc.
# Writes build/vivado/<Top>/ and prints VIVADO_PASS or VIVADO_FAIL.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($VhdlFifo -and $Top -ne 'engine_axi_cdc') { throw '-VhdlFifo applies to engine_axi_cdc only' }
$outName = if ($VhdlFifo) { "${Top}_vhdl" } else { $Top }
$out = (Join-Path $root "build/vivado/$outName").Replace('\', '/')
New-Item -ItemType Directory -Force $out | Out-Null
$common = @('packet_classifier', 'capture_ingress', 'descriptor_validator', 'sg_transfer', 'engine_control', 'replay_policy',
    'replay_staging', 'dma_command_arbiter', 'capture_dma', 'replay_dma', 'engine_core', 'axi_burst_master')
$extra = if ($Top -eq 'engine_pcie') { @('pcie_requester', 'pcie_completer', 'pcie_msi', 'pcie_tx_arbiter', 'engine_pcie') }
         elseif ($Top -eq 'engine_axi_cdc') { @('stream_cdc_fifo') } else { @() }
$sources = (($common + $extra) | ForEach-Object { (Join-Path $root "rtl/$_.sv").Replace('\', '/') }) +
    @((Join-Path $root 'constraints/engine_fit.sv').Replace('\', '/'))
if ($VhdlFifo) { $sources = $sources -replace 'rtl/stream_cdc_fifo\.sv$', 'rtl/vhdl/stream_cdc_fifo.vhd' }
$xdc = 'none'
if ($Top -eq 'engine_axi_cdc') {
    $sources += @((Join-Path $root 'constraints/engine_cdc_fit.sv').Replace('\', '/'))
    $xdc = (Join-Path $root 'constraints/engine_cdc.xdc').Replace('\', '/')
}
Push-Location $out
try {
    & (Join-Path $Vivado 'bin/vivado.bat') -mode batch -nojournal -log vivado.log -source ((Join-Path $root 'scripts/vivado-impl.tcl').Replace('\', '/')) `
        -tclargs "${Top}_fit" $Part 20.0 $out none $xdc @sources
    if ($LASTEXITCODE -ne 0) { throw "Vivado failed: $LASTEXITCODE" }
    Get-Content (Join-Path $out 'result.txt')
} finally { Pop-Location }
