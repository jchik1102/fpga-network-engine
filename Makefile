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

.PHONY: help models test test-quick fpga results formal results-dir

help:
	@echo "make models      Python model tests (WSL only, seconds)"
	@echo "make test        run-all.ps1 -Seeds $(SEEDS) -Mutations -Fit, then make results"
	@echo "make test-quick  run-all.ps1 -Seeds 17"
	@echo "make fpga        run-fit.ps1 for engine_axi and engine_pcie"
	@echo "make results     copy logs and reports that back the README into results/"
	@echo "make formal      SymbiYosys checks in formal/ (results/formal/summary.txt)"

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

results:
	bash scripts/collect-results.sh

# SymbiYosys proofs and covers listed in formal/tasks.txt.
# Needs OSS CAD Suite on PATH (yosys with the slang plugin, sby, solvers).
formal: | results-dir
	bash scripts/run-formal.sh
