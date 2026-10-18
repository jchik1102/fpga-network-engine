# Thin wrapper around the existing flows. Run from WSL in the repository root:
#   make test     full regression: fixtures, model tests, every RTL test for
#                 seeds 17 and 29, AXI-vs-PCIe comparison, mutation campaign
#   make fpga     Quartus fits of both transport tops
#   make formal   SymbiYosys checks listed in formal/tasks.txt
# XSim and Quartus run on Windows through PowerShell 7. Console output is saved
# under results/; per-step logs stay in build/regression/.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

PWSH_FALLBACK := /mnt/c/Users/jonat/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe
PWSH ?= $(or $(shell command -v pwsh.exe 2>/dev/null),$(PWSH_FALLBACK))
PS := "$(PWSH)" -NoProfile -File
SEEDS ?= 17,29
RESULTS := results
# pwsh.exe launched from WSL reports exit code 0 even when a script fails, so
# every PowerShell step is judged by the pass marker it prints, like the
# XSim logs are.
require = grep -qE '$(1)' $(2) || { echo "FAIL: '$(1)' not found in $(2)"; exit 1; }
LOG = 2>&1 | tee $(RESULTS)/$@.log

.PHONY: help models test test-quick fpga fpga-cdc vivado vivado-vhdl results formal cocotb vhdl questa results-dir

help:
	@echo "make models      Python model tests (WSL only, seconds)"
	@echo "make test        run-all.ps1 -Seeds $(SEEDS) -Mutations -Fit, then make results"
	@echo "make test-quick  run-all.ps1 -Seeds 17"
	@echo "make fpga        run-fit.ps1 for engine_axi and engine_pcie"
	@echo "make fpga-cdc    run-fit.ps1 for engine_axi_cdc (packet input on its own 125 MHz clock)"
	@echo "make vivado      Vivado implementation of the three fit tops for an Artix-7 at 50 MHz"
	@echo "make results     copy logs and reports that back the README into results/"
	@echo "make formal      SymbiYosys checks in formal/ (results/formal/summary.txt) and the engine_control equivalence check"
	@echo "make cocotb      cocotb tests of the async FIFO (two clocks), then its 4 mutants must fail"
	@echo "make vhdl        VHDL async FIFO: the same cocotb tests with GHDL, 4 VHDL mutants, EQY against the SystemVerilog"
	@echo "make vivado-vhdl Vivado implementation of engine_axi_cdc with the VHDL FIFO (mixed-language)"
	@echo "make questa      what runs in Questa Starter: cocotb FIFO tests (SV and VHDL) and a mutant each; UVM needs a full licence"

# Not "$(RESULTS):": that is the same target as "results:" below, whose
# recipe would then run before every target.
results-dir:
	@mkdir -p $(RESULTS)

models: | results-dir
	bash scripts/run-models.sh $(LOG)

# Same command as the README's "latest full run"; the fits are part of it.
test: | results-dir
	$(PS) scripts/run-all.ps1 -Seeds $(SEEDS) -Mutations -Fit $(LOG)
	bash scripts/collect-results.sh
	@$(call require,fit_engine_pcie +PASS,build/regression/summary.txt)
	@! grep -q ' FAIL ' build/regression/summary.txt || { echo 'FAIL: see build/regression/summary.txt'; exit 1; }

test-quick: | results-dir
	$(PS) scripts/run-all.ps1 -Seeds 17 $(LOG)
	@$(call require,compare_seed17 +PASS,build/regression/summary.txt)
	@! grep -q ' FAIL ' build/regression/summary.txt || { echo 'FAIL: see build/regression/summary.txt'; exit 1; }

fpga: | results-dir
	$(PS) scripts/run-fit.ps1 -Top engine_axi $(LOG)
	$(PS) scripts/run-fit.ps1 -Top engine_pcie 2>&1 | tee -a $(RESULTS)/$@.log
	@$(call require,^PASS,build/fit/engine_axi/result.txt)
	@$(call require,^PASS,build/fit/engine_pcie/result.txt)

# engine_axi behind the async FIFO, with the packet input on its own clock.
fpga-cdc: | results-dir
	$(PS) scripts/run-fit.ps1 -Top engine_axi_cdc $(LOG)
	@$(call require,^PASS,build/fit/engine_axi_cdc/result.txt)
	bash scripts/collect-results.sh

# Vivado 2025.2 out-of-context synthesis, placement and routing of the fit
# wrappers for an Artix-7 (xc7a100tcsg324-1): engine_axi and engine_pcie at
# 50 MHz, and engine_axi_cdc with its 125 MHz packet clock (plus report_cdc and
# report_bus_skew). Reports copied to results/vivado/<top>/.
VIVADO_TOPS := engine_axi engine_pcie engine_axi_cdc
vivado: | results-dir
	for t in $(VIVADO_TOPS); do $(PS) scripts/run-vivado.ps1 -Top $$t 2>&1 | tee $(RESULTS)/vivado-$$t.log; \
	  mkdir -p $(RESULTS)/vivado/$$t; \
	  cp build/vivado/$$t/{result.txt,utilization.txt,utilization_hierarchy.txt,timing_summary.txt,worst_setup_path.txt} $(RESULTS)/vivado/$$t/; done
	cp build/vivado/engine_axi_cdc/{cdc.txt,bus_skew.txt,clock_interaction.txt} $(RESULTS)/vivado/engine_axi_cdc/
	@for t in $(VIVADO_TOPS); do $(call require,^VIVADO_PASS,$(RESULTS)/vivado/$$t/result.txt); done

# engine_axi_cdc again, with the async FIFO from rtl/vhdl/stream_cdc_fifo.vhd
# in place of the SystemVerilog one: a mixed SystemVerilog and VHDL build.
vivado-vhdl: | results-dir
	$(PS) scripts/run-vivado.ps1 -Top engine_axi_cdc -VhdlFifo 2>&1 | tee $(RESULTS)/vivado-engine_axi_cdc_vhdl.log
	mkdir -p $(RESULTS)/vivado/engine_axi_cdc_vhdl
	cp build/vivado/engine_axi_cdc_vhdl/{result.txt,utilization.txt,utilization_hierarchy.txt,timing_summary.txt,worst_setup_path.txt,cdc.txt,bus_skew.txt,clock_interaction.txt} $(RESULTS)/vivado/engine_axi_cdc_vhdl/
	@$(call require,^VIVADO_PASS,$(RESULTS)/vivado/engine_axi_cdc_vhdl/result.txt)

results:
	bash scripts/collect-results.sh

# SymbiYosys proofs and covers listed in formal/tasks.txt, then the
# stream_cdc_fifo proof on 4 FIFO mutants (each must fail), then the
# equivalence check of engine_control against its pre-timing-fix version.
# Needs OSS CAD Suite on PATH (yosys with the slang plugin, sby, solvers).
formal: | results-dir
	bash scripts/run-formal.sh
	bash scripts/formal-cdc-mutants.sh
	bash scripts/equiv-engine-control.sh

# cocotb testbenches (tb/cocotb) with Icarus Verilog, then the same tests on
# the 4 stream_cdc_fifo mutants, each of which must fail.
VENV ?= .venv
COCOTB_ENV = PATH="$(VENV)/bin:$(HOME)/oss-cad-suite/bin:$$PATH"
CDC_MUTANTS = full_misses_lap write_ignores_full read_ignores_ready empty_misses_data
cocotb: | results-dir
	$(COCOTB_ENV) python -m pytest tb/cocotb -v -s 2>&1 | tee $(RESULTS)/cocotb.log
	@for m in $(CDC_MUTANTS); do \
	  if $(COCOTB_ENV) CDC_MUTANT=$$m python -m pytest tb/cocotb -q > $(RESULTS)/cocotb-$$m.log 2>&1; then \
	    echo "FAIL: cocotb tests pass on $$m"; exit 1; else echo "COCOTB_MUTATION_DETECTED $$m"; fi; \
	done 2>&1 | tee -a $(RESULTS)/cocotb.log
	@$(call require,^COCOTB_MUTATION_DETECTED empty_misses_data,$(RESULTS)/cocotb.log)

# VHDL-2008 version of the async FIFO (rtl/vhdl/stream_cdc_fifo.vhd): the
# cocotb tests above, unchanged, with GHDL; the VHDL versions of the 4 mutants,
# each of which must fail; EQY equivalence against rtl/stream_cdc_fifo.sv,
# then the same check on each mutant, which must fail. Logs in results/vhdl/.
vhdl: | results-dir
	bash scripts/vhdl-cdc-fifo.sh
	@$(call require,^VHDL_ALL_PASS,$(RESULTS)/vhdl/summary.txt)

# Questa Intel Starter FPGA Edition (Windows): the cocotb FIFO tests on the
# SystemVerilog and VHDL FIFOs, and the empty_misses_data mutant of each. The
# UVM benches need randomize() and covergroups, which the Starter licence
# refuses; one attempt is logged. Logs in results/questa/.
questa: | results-dir
	$(PS) scripts/run-questa.ps1 $(LOG)
	mkdir -p $(RESULTS)/questa
	cp build/questa/summary.txt build/questa/uvm_packet_attempt.log build/questa/cocotb_*.log $(RESULTS)/questa/
	@$(call require,^QUESTA_PASS,$(RESULTS)/$@.log)
