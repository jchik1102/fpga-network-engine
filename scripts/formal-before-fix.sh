#!/usr/bin/env bash
# Re-run the formal proofs on the RTL as it was before the two fixes that the
# proofs found (see DESIGN.md, "Bugs found by formal verification"), to show
# that the properties catch them. Each check is expected to FAIL.
# Writes logs to results/formal/before_fix/ and exits 1 if a check passes.
set -uo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/results/formal/before_fix
mkdir -p "$OUT"; : > "$OUT/summary.txt"
status=0
# <fix commit> <module> <sby task>
while read -r commit module task; do
  w=$(mktemp -d)
  cp "$ROOT/formal/$module.sby" "$ROOT/formal/${module}_formal.sv" "$w"/
  git -C "$ROOT" show "$commit~1:rtl/$module.sv" > "$w/$module.sv"
  sed -i 's|\.\./rtl/||' "$w/$module.sby"
  (cd "$w" && sby -f "$module.sby" "$task" < /dev/null > /dev/null 2>&1)
  result=$(cut -d' ' -f1 "$w/${module}_$task/status" 2>/dev/null || echo ERROR)
  cp "$w/${module}_$task/logfile.txt" "$OUT/${module}_$task.log" 2>/dev/null
  failed=$(grep -oE "failed assertion [^ ]+" "$w/${module}_$task/logfile.txt" | sort -u | tr '\n' ' ')
  printf "%-8s %-16s %-6s %-5s %s\n" "$commit" "$module" "$task" "$result" "$failed" | tee -a "$OUT/summary.txt"
  [[ $result == FAIL ]] || status=1
  rm -rf "$w"
done <<'LIST'
41263e1 engine_control prove
5c37c7d pcie_requester prove
LIST
exit $status
