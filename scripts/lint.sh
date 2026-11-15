#!/usr/bin/env bash
# Verilator lint (-Wall) of the synthesizable RTL: both transport tops and the
# async FIFO. Warnings listed with a reason in scripts/lint_waivers.vlt are
# accepted; any other warning or error fails. Two rules are off for every
# file: UNUSEDSIGNAL and UNUSEDPARAM (unused bits of a wider bus or record, and
# ports a module does not use). Output in results/lint/.
set -uo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
cd "$(dirname "$0")/.."
OUT=results/lint
mkdir -p "$OUT"
verilator --version > "$OUT/version.txt"
status=0
for top in engine_axi engine_pcie stream_cdc_fifo; do
  log=$OUT/$top.txt
  verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    --top-module "$top" scripts/lint_waivers.vlt $(ls rtl/*.sv) > "$log" 2>&1
  count=$(grep -cE '^%(Warning|Error)' "$log")
  echo "LINT $top: $count warnings or errors outside the waivers" | tee -a "$log"
  [[ $count -eq 0 ]] || status=1
done
[[ $status -eq 0 ]] && echo "LINT_PASS" || echo "LINT_FAIL"
exit $status
