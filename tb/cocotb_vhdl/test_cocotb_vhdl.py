"""Run the cocotb tests of the async FIFO (tb/cocotb/cdc_fifo_tests.py) on
its VHDL-2008 version, rtl/vhdl/stream_cdc_fifo.vhd, with GHDL.

    python -m pytest tb/cocotb_vhdl -v       (make vhdl; needs ghdl on PATH)

The test module is the same file the SystemVerilog FIFO runs under Icarus,
unchanged. cocotb writes results to
tb/cocotb_vhdl/sim_build/<build>/test_cdc_fifo_vhdl.result.xml and fails the pytest case if any cocotb test failed.

CDC_MUTANT=<name> builds a copy of the VHDL with one of the defects below:
the VHDL versions of the four mutants in tb/cocotb/test_cocotb.py, to show
the tests fail on it.
"""
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TESTS = ROOT / "tb/cocotb"
sys.path.insert(0, str(TESTS))   # the runner passes sys.path to the simulator as PYTHONPATH

MUTANTS = {
    "full_misses_lap": (
        "full <= '1' when w_gray = ((not r_sync2(ADDR downto ADDR-1)) & r_sync2(ADDR-2 downto 0)) else '0';",
        "full <= '0';"),
    "write_ignores_full": ("s_ready_i <= not s_rst and not full;", "s_ready_i <= not s_rst;"),
    "read_ignores_ready": ("if m_valid_i = '1' and m_ready = '1' then", "if m_valid_i = '1' then"),
    "empty_misses_data": ("empty <= '1' when r_gray = w_sync2 else '0';", "empty <= '0';"),
}


# COCOTB_SIM=questa runs the same tests in Questa (scripts/run-questa.ps1).
SIM = os.environ.get("COCOTB_SIM", "ghdl")


def test_cdc_fifo_vhdl():
    source = ROOT / "rtl/vhdl/stream_cdc_fifo.vhd"
    mutant = os.environ.get("CDC_MUTANT")
    build = HERE / "sim_build" / ((f"{SIM}_" if SIM != "ghdl" else "") + ("stream_cdc_fifo_" + mutant if mutant else "stream_cdc_fifo"))
    if mutant:
        old, new = MUTANTS[mutant]
        text = source.read_text()
        assert text.count(old) == 1, f"mutant {mutant} does not apply"
        build.mkdir(parents=True, exist_ok=True)
        source = build / "stream_cdc_fifo_mutant.vhd"
        source.write_text(text.replace(old, new))
    runner = get_runner(SIM)
    runner.build(sources=[source], hdl_toplevel="stream_cdc_fifo", build_dir=build,
                 build_args=["--std=08"] if SIM == "ghdl" else ["-2008"], always=True)
    # GHDL's LLVM back end elaborates to an executable in the build directory,
    # which "ghdl -r" runs from its working directory, so the tests run there.
    runner.test(hdl_toplevel="stream_cdc_fifo", test_module="cdc_fifo_tests", test_dir=build,
                build_dir=build, test_args=["--std=08"] if SIM == "ghdl" else ["-t", "1ps"])   # the clocks need ps resolution
