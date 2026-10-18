#!/usr/bin/env bash
# Checks of the VHDL-2008 async FIFO, rtl/vhdl/stream_cdc_fifo.vhd (make vhdl):
#   1. the cocotb tests of the SystemVerilog FIFO (tb/cocotb/cdc_fifo_tests.py),
#      unchanged, on the VHDL with GHDL; they must pass;
#   2. the same tests on the VHDL versions of the 4 FIFO mutants; each must fail;
#   3. EQY equivalence of the VHDL (GHDL Yosys plugin) against the
#      SystemVerilog (yosys-slang); it must pass;
#   4. the same equivalence check with each VHDL mutant as the gate; each must
#      fail, to show the check can see a difference.
# Logs in results/vhdl/; summary in results/vhdl/summary.txt. Exits 1 on any
# unexpected result. Needs the repo's .venv (cocotb) and OSS CAD Suite (GHDL,
# EQY, yosys with the slang and ghdl plugins).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export PATH="$ROOT/.venv/bin:$HOME/oss-cad-suite/bin:$PATH"
OUT=results/vhdl
mkdir -p "$OUT"
SUM=$OUT/summary.txt
: > "$SUM"
status=0
MUTANTS="full_misses_lap write_ignores_full read_ignores_ready empty_misses_data"
note() { echo "$*" | tee -a "$SUM"; }

{ ghdl --version | head -1; yosys -V; echo "EQY from $(command -v eqy)"; } > "$OUT/versions.txt"

# 1. cocotb on the VHDL
if python -m pytest tb/cocotb_vhdl -v -s > "$OUT/cocotb.log" 2>&1; then
  note "VHDL_COCOTB_PASS $(grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+' "$OUT/cocotb.log" | tail -1)"
else
  note "VHDL_COCOTB_FAIL (see $OUT/cocotb.log)"; status=1
fi

# 2. cocotb on the VHDL mutants
for m in $MUTANTS; do
  if CDC_MUTANT=$m python -m pytest tb/cocotb_vhdl -q > "$OUT/cocotb-$m.log" 2>&1; then
    note "VHDL_COCOTB_MUTATION_MISSED $m"; status=1
  else
    note "VHDL_COCOTB_MUTATION_DETECTED $m $(grep -oE 'FAIL=[0-9]+' "$OUT/cocotb-$m.log" | tail -1)"
  fi
done

# 3 and 4. EQY, VHDL (gate) against SystemVerilog (gold)
eqy_run() {  # $1 = label, $2 = VHDL file for the gate; prints PASS or FAIL
  local w=build/vhdl/eqy-$1
  rm -rf "$w"; mkdir -p "$w"
  cp rtl/stream_cdc_fifo.sv "$w"/
  cp formal/stream_cdc_fifo_vhdl.eqy "$w/stream_cdc_fifo.eqy"
  cp "$2" "$w/stream_cdc_fifo.vhd"
  (cd "$w" && timeout 1800 eqy -f -j 8 stream_cdc_fifo.eqy < /dev/null > eqy.out 2>&1)
  cp "$w/eqy.out" "$OUT/eqy-$1.log"
  if grep -q "Successfully proved designs equivalent" "$w/eqy.out" && grep -q "DONE (PASS" "$w/eqy.out"; then
    echo PASS
  else
    echo FAIL
  fi
}
r=$(eqy_run vhdl_vs_sv rtl/vhdl/stream_cdc_fifo.vhd)
parts=$(grep -c "Successfully proved equivalence of partition" "$OUT/eqy-vhdl_vs_sv.log")
if [[ $r == PASS ]]; then note "VHDL_EQUIV_PASS $parts partitions proved"; else note "VHDL_EQUIV_FAIL (see $OUT/eqy-vhdl_vs_sv.log)"; status=1; fi

for m in $MUTANTS; do
  mkdir -p build/vhdl/mutants
  python3 - "$m" > build/vhdl/mutants/$m.vhd <<'EOF'
import sys
sys.path.insert(0, "tb/cocotb_vhdl")
from test_cocotb_vhdl import MUTANTS
old, new = MUTANTS[sys.argv[1]]
text = open("rtl/vhdl/stream_cdc_fifo.vhd").read()
assert text.count(old) == 1, "mutant does not apply"
sys.stdout.write(text.replace(old, new))
EOF
  r=$(eqy_run "mutant_$m" build/vhdl/mutants/$m.vhd)
  failed=$(grep -oE "Failed to prove equivalence of partition [^ ]+" "$OUT/eqy-mutant_$m.log" | sed 's/.*partition //' | tr '\n' ' ')
  # Detected only if EQY ran and found unprovable partitions, not if it crashed.
  if [[ $r == FAIL && -n $failed ]]; then note "VHDL_EQUIV_MUTATION_DETECTED $m unproven: $failed"
  elif [[ $r == FAIL ]]; then note "VHDL_EQUIV_MUTATION_ERROR $m (no partition result, see $OUT/eqy-mutant_$m.log)"; status=1
  else note "VHDL_EQUIV_MUTATION_MISSED $m"; status=1; fi
done

if [[ $status -eq 0 ]]; then note "VHDL_ALL_PASS"; else note "VHDL_SOME_FAIL"; fi
exit $status
