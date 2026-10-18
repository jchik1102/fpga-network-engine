"""Build and run the cocotb testbenches with Icarus Verilog.

    python -m pytest tb/cocotb -v        (make cocotb; needs iverilog on PATH)

Put the Python that has cocotb first on PATH (OSS CAD Suite bundles its own).
cocotb writes results to tb/cocotb/test_<name>.result.xml and fails the
pytest case if any cocotb test failed.

CDC_MUTANT=<name> builds a copy of rtl/stream_cdc_fifo.sv with one of the
defects below (the same ones scripts/formal-cdc-mutants.sh uses), to show
the tests fail on it.
"""
import os
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MUTANTS = {
    "full_misses_lap": ("wire full = w_gray == {~r_sync2[ADDR:ADDR-1], r_sync2[ADDR-2:0]};", "wire full = 1'b0;"),
    "write_ignores_full": ("assign s_ready = !s_rst && !full;", "assign s_ready = !s_rst;"),
    "read_ignores_ready": ("if (m_valid && m_ready) begin", "if (m_valid) begin"),
    "empty_misses_data": ("wire empty = r_gray == w_sync2;", "wire empty = 1'b0;"),
}


# COCOTB_SIM=questa runs the same tests in Questa (scripts/run-questa.ps1).
SIM = os.environ.get("COCOTB_SIM", "icarus")


def test_cdc_fifo():
    source = ROOT / "rtl/stream_cdc_fifo.sv"
    build = HERE / "sim_build" / ("stream_cdc_fifo" if SIM == "icarus" else f"{SIM}_stream_cdc_fifo")
    mutant = os.environ.get("CDC_MUTANT")
    if mutant:
        old, new = MUTANTS[mutant]
        text = source.read_text()
        assert text.count(old) == 1, f"mutant {mutant} does not apply"
        build.mkdir(parents=True, exist_ok=True)
        source = build / "stream_cdc_fifo_mutant.sv"
        source.write_text(text.replace(old, new))
    runner = get_runner(SIM)
    runner.build(sources=[source], hdl_toplevel="stream_cdc_fifo", build_dir=build,
                 build_args=["-g2012"] if SIM == "icarus" else ["-timescale", "1ns/1ps"], timescale=("1ns", "1ps"), always=True)
    # Questa finds the compiled library in its working directory, so it runs in the build directory.
    runner.test(hdl_toplevel="stream_cdc_fifo", test_module="cdc_fifo_tests", test_dir=HERE if SIM == "icarus" else build,
                build_dir=build)
