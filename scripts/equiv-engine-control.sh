#!/usr/bin/env bash
# Sequential equivalence check of rtl/engine_control.sv against the version
# at a git revision (default 219866b on main, before the fault-clear timing change),
# with yosys equiv_make/equiv_simple/equiv_induct. Registers are matched by
# name, so this suits changes that keep the state the same and only
# restructure logic. Then the same check on a mutant (fault_clear without its
# config_locked term) must fail, to show the check can see a difference.
# Log in results/formal/engine_control_equiv.log.
set -euo pipefail
cd "$(dirname "$0")/.."
rev=${1:-219866b}
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH="$HOME/oss-cad-suite/bin:$PATH"
work=build/equiv
rm -rf "$work"; mkdir -p "$work" results/formal
git show "$rev:rtl/engine_control.sv" | sed 's/^module engine_control\b/module engine_control_old/' > "$work/engine_control_old.sv"
cat > "$work/equiv.ys" <<'EOF'
plugin -i slang
read_slang engine_control_old.sv engine_control_new.sv --top engine_control_old --top engine_control
proc
memory -nomap
memory_map
opt_clean
equiv_make engine_control_old engine_control equiv
hierarchy -top equiv
async2sync
equiv_simple -seq 3
equiv_induct -seq 3
equiv_status -assert
EOF
log=results/formal/engine_control_equiv.log
check() {  # $1 = label; compares $work/engine_control_new.sv with the old file
  echo "== $1" >> "$log"
  (cd "$work" && yosys -q -l "$1.log" equiv.ys > /dev/null 2>&1) && rc=0 || rc=$?
  grep -E "unproven|proven|ERROR" "$work/$1.log" >> "$log" || true
  return $rc
}
echo "gold: engine_control.sv at $rev; gate: working tree" > "$log"
cp rtl/engine_control.sv "$work/engine_control_new.sv"
if check working_tree; then echo "EQUIV_PASS" | tee -a "$log"; else echo "EQUIV_FAIL" | tee -a "$log"; exit 1; fi
sed 's/ \&\& write_data==1 \&\& !config_locked;/ \&\& write_data==1;/' rtl/engine_control.sv > "$work/engine_control_new.sv"
cmp -s rtl/engine_control.sv "$work/engine_control_new.sv" && { echo "mutant not applied" | tee -a "$log"; exit 1; }
if check mutant_fault_clear_ignores_lock; then
  echo "EQUIV_MUTANT_MISSED" | tee -a "$log"; exit 1
else
  echo "EQUIV_MUTANT_DETECTED fault_clear_ignores_lock" | tee -a "$log"
fi
